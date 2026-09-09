import Foundation
import Metal
@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
import CineKit
import CinePlayerCore

enum BatchConvertError: Error, CustomStringConvertible {
    case badArguments(String)
    case noMetalDevice
    case noCineFilesFound(String)
    case emptyFile
    case textureCreationFailed
    case commandBufferCreationFailed
    case blitEncoderCreationFailed
    case writerCreationFailed(Error)
    case cannotAddInput
    case startWritingFailed(Error?)
    case pixelBufferPoolUnavailable
    case pixelBufferCreationFailed(CVReturn)
    case appendFailed(Error?)
    case finishWritingFailed(Error?)

    var description: String {
        switch self {
        case .badArguments(let usage): return usage
        case .noMetalDevice: return "No Metal device available on this machine."
        case .noCineFilesFound(let dir): return "No .cine files found directly inside \(dir)."
        case .emptyFile: return "File has zero frames."
        case .textureCreationFailed: return "Failed to create the offscreen render-target texture."
        case .commandBufferCreationFailed: return "Failed to create a Metal command buffer."
        case .blitEncoderCreationFailed: return "Failed to create a blit encoder to synchronize the render target."
        case .writerCreationFailed(let error): return "Failed to create the video file: \(error)"
        case .cannotAddInput: return "This codec/resolution combination isn't supported on this Mac."
        case .startWritingFailed(let error): return "Failed to start writing: \(String(describing: error))"
        case .pixelBufferPoolUnavailable: return "Failed to allocate a pixel buffer pool for encoding."
        case .pixelBufferCreationFailed(let status): return "Failed to allocate a pixel buffer (status \(status))."
        case .appendFailed(let error): return "Failed to append a frame: \(String(describing: error))"
        case .finishWritingFailed(let error): return "Failed to finish writing: \(String(describing: error))"
        }
    }
}

let usage = """
Usage: cine-batch-convert <input-directory> [options]

Converts every .cine file found directly inside <input-directory> (not
recursive) to a real video file (same base name, .mov extension), using the
same GPU debayer/tonemap/color-calibration pipeline the app's own "Export
Video…" command uses: High Quality debayer, white balance + color matrix
(subject to the same plausibility veto — see CalibrationPlausibility), full
native frame range, one output file per input file. A file that fails to
convert is reported and skipped rather than stopping the whole batch.

Options:
  --output <dir>       Where to write the .mov files (default: same as
                        <input-directory>).
  --codec <token>      One of: prores-proxy, prores-lt, prores422,
                        prores-hq, prores4444, h264, hevc (default:
                        prores-hq).
  --max-dimension <N>  Cap the long edge at N pixels, aspect ratio
                        preserved, never upscaled (default: native
                        resolution, no cap).
  --fps <N>            Output frame rate (default: each file's own
                        recorded review rate, falling back to 30 if
                        absent).
"""

struct Options {
    var inputDirectory: URL
    var outputDirectory: URL
    var codec: VideoCodecOption
    var maxDimension: Int?
    var fpsOverride: Double?
}

func parseArguments(_ arguments: [String]) throws -> Options {
    guard arguments.count >= 2 else { throw BatchConvertError.badArguments(usage) }
    let inputDirectory = URL(fileURLWithPath: arguments[1])
    var outputDirectory = inputDirectory
    var codec = VideoCodecOption.proRes422HQ
    var maxDimension: Int?
    var fpsOverride: Double?

    var index = 2
    while index < arguments.count {
        let flag = arguments[index]
        func nextValue() throws -> String {
            index += 1
            guard index < arguments.count else { throw BatchConvertError.badArguments(usage) }
            return arguments[index]
        }
        switch flag {
        case "--output":
            outputDirectory = URL(fileURLWithPath: try nextValue())
        case "--codec":
            let token = try nextValue()
            guard let match = VideoCodecOption.forCLIToken(token) else {
                throw BatchConvertError.badArguments("Unknown codec '\(token)'.\n\n\(usage)")
            }
            codec = match
        case "--max-dimension":
            guard let value = Int(try nextValue()), value > 0 else { throw BatchConvertError.badArguments(usage) }
            maxDimension = value
        case "--fps":
            guard let value = Double(try nextValue()), value > 0 else { throw BatchConvertError.badArguments(usage) }
            fpsOverride = value
        default:
            throw BatchConvertError.badArguments(usage)
        }
        index += 1
    }

    return Options(
        inputDirectory: inputDirectory,
        outputDirectory: outputDirectory,
        codec: codec,
        maxDimension: maxDimension,
        fpsOverride: fpsOverride
    )
}

/// Converts one `.cine` file to a `.mov` at `outputURL` — mirrors
/// `VideoExportCoordinator.performExport`'s (`CinePlayerApp`) core render/
/// readback/encode loop exactly, just driven directly by a `CineFile`
/// instead of a live `CineDocumentModel`: no GUI, no playhead, no
/// `DecodedFrameCache` — each frame is decoded, rendered, and encoded once,
/// in order, since nothing here ever revisits a frame the way scrubbing
/// does. Synchronous, not `async`, matching this codebase's other
/// standalone CLI tools (`cine-diagnostic`/`wb-verify`) — `finishWriting`
/// uses the completion-handler overload plus a semaphore instead of the
/// `async` variant `VideoExportCoordinator` uses in its own `Task` context.
/// Creates and starts an `AVAssetWriter` (plus its video input/pixel-buffer
/// adaptor) for `outputURL` — the writer-setup third of `convert(...)`,
/// pulled out on its own purely to keep that function's own body short
/// enough to read at a glance; no behavior differs from having it inline.
func makeAssetWriter(
    outputURL: URL, options: Options, width: Int, height: Int
) throws -> (writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor) {
    // Always start from a clean file, matching VideoExportCoordinator —
    // AVAssetWriter itself refuses to write over an existing file.
    try? FileManager.default.removeItem(at: outputURL)

    let writer: AVAssetWriter
    do {
        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    } catch {
        throw BatchConvertError.writerCreationFailed(error)
    }

    let outputSettings: [String: Any] = [
        AVVideoCodecKey: options.codec.avCodecType,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
    )

    guard writer.canAdd(input) else { throw BatchConvertError.cannotAddInput }
    writer.add(input)
    guard writer.startWriting() else { throw BatchConvertError.startWritingFailed(writer.error) }
    writer.startSession(atSourceTime: .zero)

    return (writer, input, adaptor)
}

/// Bundles `encodeFrames(_:)`'s inputs into one value purely to keep that
/// function down to a single parameter (`function_parameter_count`) — not a
/// reusable abstraction elsewhere, just this one call site's own inputs.
struct FrameEncodingContext {
    let cineFile: CineFile
    let firstFrame: DecodedFrame
    let uniforms: ExposureUniforms
    let device: MTLDevice
    let renderer: CineRenderer
    let targetTexture: MTLTexture
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let width: Int
    let height: Int
    let fps: Double
    let timescale: Int32
}

/// Renders, encodes, and appends every frame of `cineFile` to `adaptor`/
/// `input` in order — the per-frame work loop third of `convert(...)`,
/// pulled out on its own purely to keep that function's own body short
/// enough to read at a glance; no behavior differs from having it inline.
func encodeFrames(_ context: FrameEncodingContext) throws {
    let (cineFile, width, height) = (context.cineFile, context.width, context.height)
    let bytesPerRow = width * 4

    for frameIndex in 0..<cineFile.frameCount {
        let frame = frameIndex == 0 ? context.firstFrame : try cineFile.decodeFrame(at: frameIndex)
        let rawTexture = try makeFrameTexture(device: context.device, frame: frame)

        guard let commandBuffer = context.renderer.commandQueue.makeCommandBuffer() else {
            throw BatchConvertError.commandBufferCreationFailed
        }
        context.renderer.render(rawTexture: rawTexture, uniforms: context.uniforms, into: commandBuffer, colorAttachment: context.targetTexture)
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw BatchConvertError.blitEncoderCreationFailed
        }
        blitEncoder.synchronize(resource: context.targetTexture)
        blitEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixelData.withUnsafeMutableBytes { buffer in
            context.targetTexture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }

        while !context.input.isReadyForMoreMediaData {
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard let pool = context.adaptor.pixelBufferPool else { throw BatchConvertError.pixelBufferPoolUnavailable }
        var pixelBufferOut: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
        guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
            throw BatchConvertError.pixelBufferCreationFailed(status)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = CVPixelBufferGetBaseAddress(pixelBuffer)!
        let destBytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        pixelData.withUnsafeBytes { src in
            let srcBase = src.baseAddress!
            if destBytesPerRow == bytesPerRow {
                memcpy(base, srcBase, bytesPerRow * height)
            } else {
                // The pool's own pixel buffer padded each row to a
                // different stride than our tightly-packed readback —
                // copy row by row instead of assuming they match.
                for row in 0..<height {
                    memcpy(base.advanced(by: row * destBytesPerRow), srcBase.advanced(by: row * bytesPerRow), bytesPerRow)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let time = CMTime(value: Int64((Double(frameIndex) * Double(context.timescale) / context.fps).rounded()), timescale: context.timescale)
        guard context.adaptor.append(pixelBuffer, withPresentationTime: time) else {
            throw BatchConvertError.appendFailed(context.writer.error)
        }

        if frameIndex % 100 == 0 || frameIndex == cineFile.frameCount - 1 {
            print("  frame \(frameIndex + 1)/\(cineFile.frameCount)")
        }
    }
}

func convert(inputURL: URL, outputURL: URL, options: Options, device: MTLDevice, renderer: CineRenderer) throws {
    let cineFile = try CineFile(url: inputURL)
    guard cineFile.frameCount > 0 else { throw BatchConvertError.emptyFile }

    let firstFrame = try cineFile.decodeFrame(at: 0)
    // Same convenience initializer cine-diagnostic already uses — it
    // applies CalibrationPlausibility.vetoedCalibration internally, so
    // this gets the same "don't trust an implausible recorded calibration"
    // protection the live app's own open(url:) applies, with no separate
    // call needed here.
    let uniforms = ExposureUniforms(cineFile: cineFile, frame: firstFrame, debayerMode: .highQuality)

    let fps: Double = options.fpsOverride
        ?? cineFile.setup.pbRate.map(Double.init).flatMap { $0 > 0 ? $0 : nil }
        ?? 30

    let (width, height) = VideoExportSizing.outputSize(
        nativeWidth: cineFile.bitmapInfo.width,
        nativeHeight: cineFile.bitmapInfo.height,
        maxDimension: options.maxDimension
    )

    let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
    )
    targetDescriptor.usage = [.renderTarget, .shaderRead]
    targetDescriptor.storageMode = .managed
    guard let targetTexture = device.makeTexture(descriptor: targetDescriptor) else {
        throw BatchConvertError.textureCreationFailed
    }

    let (writer, input, adaptor) = try makeAssetWriter(outputURL: outputURL, options: options, width: width, height: height)

    // Fixed, generously-fine timescale rather than deriving one from `fps`
    // directly (which may be fractional, e.g. 23.976) — every presentation
    // time is a fraction of this, so no rounding drift accumulates frame
    // over frame the way repeatedly adding a rounded per-frame duration
    // would. Matches VideoExportCoordinator exactly.
    let timescale: Int32 = 6000

    try encodeFrames(FrameEncodingContext(
        cineFile: cineFile, firstFrame: firstFrame, uniforms: uniforms,
        device: device, renderer: renderer, targetTexture: targetTexture,
        writer: writer, input: input, adaptor: adaptor,
        width: width, height: height, fps: fps, timescale: timescale
    ))

    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()

    if writer.status == .failed {
        throw BatchConvertError.finishWritingFailed(writer.error)
    }
}

func run() throws {
    let options = try parseArguments(CommandLine.arguments)

    let fileManager = FileManager.default
    let cineFiles = try fileManager.contentsOfDirectory(at: options.inputDirectory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension.lowercased() == "cine" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

    guard !cineFiles.isEmpty else {
        throw BatchConvertError.noCineFilesFound(options.inputDirectory.path)
    }

    try fileManager.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)

    guard let device = MTLCreateSystemDefaultDevice() else {
        throw BatchConvertError.noMetalDevice
    }
    // Built once, reused for every file in the batch — see
    // ThumbnailProvider.sharedRenderer's doc comment for why constructing a
    // CineRenderer per file (shader compile + pipeline state creation) is
    // real, avoidable, repeated cost.
    let renderer = try CineRenderer(device: device)

    print("Found \(cineFiles.count) .cine file\(cineFiles.count == 1 ? "" : "s") in \(options.inputDirectory.path)")

    var succeeded = 0
    var failed: [(URL, Error)] = []

    for inputURL in cineFiles {
        let outputURL = options.outputDirectory
            .appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent)
            .appendingPathExtension("mov")
        print("Converting \(inputURL.lastPathComponent) -> \(outputURL.lastPathComponent)")
        do {
            try convert(inputURL: inputURL, outputURL: outputURL, options: options, device: device, renderer: renderer)
            succeeded += 1
        } catch {
            print("  FAILED: \(error)")
            failed.append((inputURL, error))
        }
    }

    print("\nDone: \(succeeded)/\(cineFiles.count) converted.")
    if !failed.isEmpty {
        print("Failed:")
        for (url, error) in failed {
            print("  \(url.lastPathComponent): \(error)")
        }
        exit(1)
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
    exit(1)
}
