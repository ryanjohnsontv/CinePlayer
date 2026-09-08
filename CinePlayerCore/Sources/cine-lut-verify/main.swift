import Foundation
import Metal
import CineKit
import CinePlayerCore

/// End-to-end verification tool for the `.cube` LUT phase-1 pipeline
/// (`CubeLUT` parsing -> `LUTTexture` upload -> `Tonemap.metal`'s
/// `tonemapFragment` LUT-sampling stage). A build succeeding alone does not
/// prove the sampling math or texture upload format is right -- this
/// actually renders a real sample frame through the real `CineRenderer`,
/// with and without two small synthetic LUTs bound, reads the pixels back,
/// and asserts (not just prints) that the results are exactly what those
/// two LUTs should produce.
///
/// Usage: cine-lut-verify <path-to-cine-file>
enum LUTVerifyError: Error, CustomStringConvertible {
    case badArguments
    case noMetalDevice
    case textureCreationFailed
    case commandBufferCreationFailed
    case blitEncoderCreationFailed
    case verificationFailed(String)

    var description: String {
        switch self {
        case .badArguments:
            return "Usage: cine-lut-verify <path-to-cine-file>"
        case .noMetalDevice:
            return "No Metal device available on this machine."
        case .textureCreationFailed:
            return "Failed to create an offscreen render-target texture."
        case .commandBufferCreationFailed:
            return "Failed to create a Metal command buffer."
        case .blitEncoderCreationFailed:
            return "Failed to create a blit encoder to synchronize a render target."
        case .verificationFailed(let reason):
            return "LUT verification FAILED: \(reason)"
        }
    }
}

/// Renders once through the real `CineRenderer.render(...)` into an
/// offscreen, CPU-readable `.bgra8Unorm` render target and reads the pixels
/// back -- the exact same offscreen-render-and-readback recipe
/// `cine-diagnostic`'s own `main.swift` uses (private `.bgra8Unorm` target,
/// `.managed` storage, blit `synchronize` before `getBytes`).
func renderAndReadback(
    renderer: CineRenderer,
    rawTexture: MTLTexture,
    uniforms: ExposureUniforms,
    lutTexture: MTLTexture?,
    width: Int,
    height: Int,
    device: MTLDevice
) throws -> [UInt8] {
    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm,
        width: width,
        height: height,
        mipmapped: false
    )
    targetDescriptor.usage = [.renderTarget, .shaderRead]
    targetDescriptor.storageMode = .managed
    guard let targetTexture = device.makeTexture(descriptor: targetDescriptor) else {
        throw LUTVerifyError.textureCreationFailed
    }

    guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
        throw LUTVerifyError.commandBufferCreationFailed
    }

    renderer.render(
        rawTexture: rawTexture,
        uniforms: uniforms,
        into: commandBuffer,
        colorAttachment: targetTexture,
        lutTexture: lutTexture
    )

    // .managed textures need an explicit synchronize before CPU readback.
    guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
        throw LUTVerifyError.blitEncoderCreationFailed
    }
    blitEncoder.synchronize(resource: targetTexture)
    blitEncoder.endEncoding()

    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()

    let bytesPerRow = width * 4
    var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)
    pixelData.withUnsafeMutableBytes { buffer in
        targetTexture.getBytes(
            buffer.baseAddress!,
            bytesPerRow: bytesPerRow,
            from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0
        )
    }
    return pixelData
}

/// Reads the (R, G, B) triple of a `.bgra8Unorm`-readback pixel buffer at
/// (x, y) (memory order is B, G, R, A per pixel).
func pixel(_ data: [UInt8], bytesPerRow: Int, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    let index = y * bytesPerRow + x * 4
    return (r: data[index + 2], g: data[index + 1], b: data[index])
}

func run() throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 2 else {
        throw LUTVerifyError.badArguments
    }
    let inputPath = arguments[1]

    let cineFile = try CineFile(url: URL(fileURLWithPath: inputPath))
    let frame = try cineFile.decodeFrame(at: 0)

    guard let device = MTLCreateSystemDefaultDevice() else {
        throw LUTVerifyError.noMetalDevice
    }

    let rawTexture = try makeFrameTexture(device: device, frame: frame)

    // High Quality demosaic so the render actually reaches the color
    // calibration + gamma + LUT stage of `tonemapFragment` -- the two
    // grayscale-only modes (Raw Sensor, Grey Scale) return before that
    // stage and are unaffected by LUTs by design (see that function's own
    // doc comment in Tonemap.metal).
    let uniformsNoLUT = ExposureUniforms(setup: cineFile.setup, frame: frame, debayerMode: .highQuality, lutEnabled: false)
    let uniformsWithLUT = ExposureUniforms(setup: cineFile.setup, frame: frame, debayerMode: .highQuality, lutEnabled: true)

    let renderer = try CineRenderer(device: device)

    // A 2x2x2 identity LUT: each grid corner's value equals its own [0,1]
    // coordinate. Trilinearly sampling this should reproduce the input
    // unchanged for any continuous input, so this render should be
    // (near-)pixel-identical to the no-LUT render -- proof that the
    // sampling/coordinate math itself is right, not just that "some
    // texture" got bound.
    let identityLUTText = [
        "LUT_3D_SIZE 2",
        "0.0 0.0 0.0",
        "1.0 0.0 0.0",
        "0.0 1.0 0.0",
        "1.0 1.0 0.0",
        "0.0 0.0 1.0",
        "1.0 0.0 1.0",
        "0.0 1.0 1.0",
        "1.0 1.0 1.0",
    ].joined(separator: "\n")

    // A 2x2x2 R<->B channel-swap LUT: the grid corner at coordinate
    // (r, g, b) is assigned the value (b, g, r). A channel swap is affine
    // (degree <= 1) in each of r/g/b separately, so trilinear interpolation
    // of these 8 corner values reproduces an EXACT swap for any continuous
    // input in [0,1] -- not just at the 8 corners themselves -- making this
    // an unambiguous, easily-checked, near-exact-tolerance comparison.
    let swapLUTText = [
        "LUT_3D_SIZE 2",
        "0.0 0.0 0.0",
        "0.0 0.0 1.0",
        "0.0 1.0 0.0",
        "0.0 1.0 1.0",
        "1.0 0.0 0.0",
        "1.0 0.0 1.0",
        "1.0 1.0 0.0",
        "1.0 1.0 1.0",
    ].joined(separator: "\n")

    let identityLUT = try CubeLUT(text: identityLUTText)
    let swapLUT = try CubeLUT(text: swapLUTText)
    let identityTexture = try LUTTexture.make(from: identityLUT, device: device)
    let swapTexture = try LUTTexture.make(from: swapLUT, device: device)

    let width = frame.width
    let height = frame.height

    let noLUTPixels = try renderAndReadback(
        renderer: renderer, rawTexture: rawTexture, uniforms: uniformsNoLUT,
        lutTexture: nil, width: width, height: height, device: device
    )
    let identityPixels = try renderAndReadback(
        renderer: renderer, rawTexture: rawTexture, uniforms: uniformsWithLUT,
        lutTexture: identityTexture, width: width, height: height, device: device
    )
    let swapPixels = try renderAndReadback(
        renderer: renderer, rawTexture: rawTexture, uniforms: uniformsWithLUT,
        lutTexture: swapTexture, width: width, height: height, device: device
    )

    let bytesPerRow = width * 4

    // A handful of sample points spread across the frame, avoiding the very
    // edge pixels.
    var samplePoints: [(x: Int, y: Int)] = []
    let stepsX = 5
    let stepsY = 4
    for sy in 1...stepsY {
        for sx in 1...stepsX {
            let x = min(width - 1, (width * sx) / (stepsX + 1))
            let y = min(height - 1, (height * sy) / (stepsY + 1))
            samplePoints.append((x, y))
        }
    }

    print("cine-lut-verify: \(inputPath), frame 0, \(width)x\(height), debayerMode=highQuality")
    print("")

    // --- Check 1: identity LUT render ~= no-LUT render -------------------
    print("Check 1: identity-LUT render vs no-LUT render (proves LUT sampling/coordinate math is correct)")
    let identityTolerance = 2
    var maxIdentityDelta = 0
    for point in samplePoints {
        let a = pixel(noLUTPixels, bytesPerRow: bytesPerRow, x: point.x, y: point.y)
        let b = pixel(identityPixels, bytesPerRow: bytesPerRow, x: point.x, y: point.y)
        let dr = abs(Int(a.r) - Int(b.r))
        let dg = abs(Int(a.g) - Int(b.g))
        let db = abs(Int(a.b) - Int(b.b))
        maxIdentityDelta = max(maxIdentityDelta, max(dr, max(dg, db)))
        print("  (\(point.x),\(point.y))  no-LUT=(\(a.r),\(a.g),\(a.b))  identity-LUT=(\(b.r),\(b.g),\(b.b))  delta=(\(dr),\(dg),\(db))")
    }
    guard maxIdentityDelta <= identityTolerance else {
        throw LUTVerifyError.verificationFailed(
            "identity LUT render differs from no-LUT render by up to \(maxIdentityDelta) (tolerance \(identityTolerance)) at some sample point -- LUT sampling/coordinate math is likely wrong."
        )
    }
    print("  OK: max per-channel delta \(maxIdentityDelta) <= tolerance \(identityTolerance)")
    print("")

    // --- Check 2: R<->B swap LUT render matches the expected swap -------
    print("Check 2: R<->B-swap-LUT render vs expected swap of the no-LUT render (swapped.R ~= noLUT.B, swapped.B ~= noLUT.R, G unchanged)")
    let swapTolerance = 2
    var maxSwapDelta = 0
    var totalRBSpread = 0
    for point in samplePoints {
        let a = pixel(noLUTPixels, bytesPerRow: bytesPerRow, x: point.x, y: point.y)
        let s = pixel(swapPixels, bytesPerRow: bytesPerRow, x: point.x, y: point.y)
        let dr = abs(Int(s.r) - Int(a.b))
        let dg = abs(Int(s.g) - Int(a.g))
        let db = abs(Int(s.b) - Int(a.r))
        maxSwapDelta = max(maxSwapDelta, max(dr, max(dg, db)))
        totalRBSpread += abs(Int(a.r) - Int(a.b))
        print("  (\(point.x),\(point.y))  no-LUT=(\(a.r),\(a.g),\(a.b))  swap-LUT=(\(s.r),\(s.g),\(s.b))  expected-swap=(\(a.b),\(a.g),\(a.r))  delta=(\(dr),\(dg),\(db))")
    }
    guard maxSwapDelta <= swapTolerance else {
        throw LUTVerifyError.verificationFailed(
            "R<->B-swap LUT render does not match the expected channel swap of the no-LUT render (max delta \(maxSwapDelta), tolerance \(swapTolerance))."
        )
    }
    print("  OK: max per-channel delta \(maxSwapDelta) <= tolerance \(swapTolerance)")
    if totalRBSpread < 10 * samplePoints.count {
        print("  NOTE: sampled R/B values are close to each other across these points (total |R-B| spread \(totalRBSpread)) -- this check is real, but not very discriminating for this particular frame/region.")
    }
    print("")

    print("SUCCESS: all cine-lut-verify checks passed.")
}

do {
    try run()
} catch {
    FileHandle.standardError.write("Error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
