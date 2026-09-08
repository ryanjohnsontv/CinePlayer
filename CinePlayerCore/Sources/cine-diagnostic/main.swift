import Foundation
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CineKit
import CinePlayerCore

enum DiagnosticError: Error, CustomStringConvertible {
    case badArguments
    case noMetalDevice
    case textureCreationFailed
    case commandBufferCreationFailed
    case blitEncoderCreationFailed
    case pngWriteFailed

    var description: String {
        switch self {
        case .badArguments:
            return "Usage: cine-diagnostic <path-to-cine-file> <frameIndex> <output-png-path> [mode]  (mode: raw|grey|nn|bilinear|hq, default raw)"
        case .noMetalDevice:
            return "No Metal device available on this machine."
        case .textureCreationFailed:
            return "Failed to create the offscreen render-target texture."
        case .commandBufferCreationFailed:
            return "Failed to create a Metal command buffer."
        case .blitEncoderCreationFailed:
            return "Failed to create a blit encoder to synchronize the render target."
        case .pngWriteFailed:
            return "Failed to encode/write the output PNG."
        }
    }
}

func writePNG(bgraPixels: [UInt8], width: Int, height: Int, to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    // Our render target is .bgra8Unorm (memory order B,G,R,A per pixel).
    // .noneSkipFirst + byteOrder32Little describes exactly that byte layout,
    // treating the alpha byte as ignorable (our output alpha is always 1.0).
    let bitmapInfo = CGBitmapInfo(
        rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )
    let bytesPerRow = width * 4

    guard let provider = CGDataProvider(data: Data(bgraPixels) as CFData) else {
        throw DiagnosticError.pngWriteFailed
    }

    guard let cgImage = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    ) else {
        throw DiagnosticError.pngWriteFailed
    }

    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        throw DiagnosticError.pngWriteFailed
    }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw DiagnosticError.pngWriteFailed
    }
}

/// Maps this CLI's mode token to a `DebayerMode`. `nil` for an unrecognized
/// token (rather than silently defaulting) so a typo'd mode argument fails
/// loudly instead of quietly rendering the wrong thing.
func debayerMode(forToken token: String) -> DebayerMode? {
    switch token {
    case "raw": return .rawSensor
    case "grey": return .greyScale
    case "nn": return .nearestNeighbor
    case "bilinear": return .bilinear
    case "hq": return .highQuality
    default: return nil
    }
}

func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 4 || arguments.count == 5 else {
        throw DiagnosticError.badArguments
    }
    let inputPath = arguments[1]
    guard let frameIndex = Int(arguments[2]) else {
        throw DiagnosticError.badArguments
    }
    let outputPath = arguments[3]
    // Defaults to Raw Sensor when omitted, so every pre-existing
    // 3-argument invocation (regression checks included) keeps rendering
    // exactly what it always has.
    let modeToken = arguments.count >= 5 ? arguments[4] : "raw"
    guard let mode = debayerMode(forToken: modeToken) else {
        throw DiagnosticError.badArguments
    }

    let cineFile = try CineFile(url: URL(fileURLWithPath: inputPath))
    let frame = try cineFile.decodeFrame(at: frameIndex)

    guard let device = MTLCreateSystemDefaultDevice() else {
        throw DiagnosticError.noMetalDevice
    }

    let rawTexture = try makeFrameTexture(device: device, frame: frame)

    let uniforms = ExposureUniforms(setup: cineFile.setup, frame: frame, debayerMode: mode)

    // Render OFFSCREEN through the exact same CineRenderer function the GUI
    // uses — into a private bgra8Unorm texture of the frame's dimensions.
    let renderer = try CineRenderer(device: device)

    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: frame.width,
        height: frame.height,
        mipmapped: false
    )
    targetDescriptor.usage = [.renderTarget, .shaderRead]
    targetDescriptor.storageMode = .managed
    guard let targetTexture = device.makeTexture(descriptor: targetDescriptor) else {
        throw DiagnosticError.textureCreationFailed
    }

    guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
        throw DiagnosticError.commandBufferCreationFailed
    }

    renderer.render(
        rawTexture: rawTexture,
        uniforms: uniforms,
        into: commandBuffer,
        colorAttachment: targetTexture
    )

    // .managed textures need an explicit synchronize before CPU readback.
    guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
        throw DiagnosticError.blitEncoderCreationFailed
    }
    blitEncoder.synchronize(resource: targetTexture)
    blitEncoder.endEncoding()

    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    let bytesPerRow = frame.width * 4
    var pixelData = [UInt8](repeating: 0, count: bytesPerRow * frame.height)
    pixelData.withUnsafeMutableBytes { buffer in
        targetTexture.getBytes(
            buffer.baseAddress!,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, frame.width, frame.height),
            mipmapLevel: 0
        )
    }

    try writePNG(bgraPixels: pixelData, width: frame.width, height: frame.height, to: URL(fileURLWithPath: outputPath))

    print("Wrote \(outputPath) (\(frame.width)x\(frame.height), frame \(frameIndex))")
}

do {
    try run()
} catch {
    FileHandle.standardError.write("Error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
