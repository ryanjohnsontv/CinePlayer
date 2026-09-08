import AppKit
@preconcurrency import AVFoundation
@preconcurrency import CoreVideo
@preconcurrency import Metal
import UniformTypeIdentifiers
import CinePlayerCore

// `VideoCodecOption`/`VideoResolutionOption` now live in CinePlayerCore
// (`Export/VideoExportOptions.swift`) — shared with the headless
// `cine-batch-convert` CLI tool, which needs the exact same verified codec
// list and sizing behavior without duplicating it.

enum VideoExportError: Error, CustomStringConvertible {
    case noOpenDocument
    case rendererCreationFailed(Error)
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
        case .noOpenDocument:
            return "No file is open."
        case .rendererCreationFailed(let error):
            return "Failed to create the renderer: \(error)"
        case .textureCreationFailed:
            return "Failed to create the offscreen render-target texture."
        case .commandBufferCreationFailed:
            return "Failed to create a Metal command buffer."
        case .blitEncoderCreationFailed:
            return "Failed to create a blit encoder to synchronize the render target."
        case .writerCreationFailed(let error):
            return "Failed to create the video file: \(error)"
        case .cannotAddInput:
            return "This codec/resolution combination isn't supported on this Mac."
        case .startWritingFailed(let error):
            return "Failed to start writing the video file: \(String(describing: error))"
        case .pixelBufferPoolUnavailable:
            return "Failed to allocate a pixel buffer pool for encoding."
        case .pixelBufferCreationFailed(let status):
            return "Failed to allocate a pixel buffer for encoding (status \(status))."
        case .appendFailed(let error):
            return "Failed to append a frame to the video file: \(String(describing: error))"
        case .finishWritingFailed(let error):
            return "Failed to finish writing the video file: \(String(describing: error))"
        }
    }
}

/// "File > Export > Export Video…" — renders
/// `PlaybackController.effectiveInPoint...effectiveOutPoint` (the same
/// trimmed range every other range-aware feature in this app uses — the
/// scrubber's drag-handles and the video's right-click "Set In Point"/"Set
/// Out Point" are the only ways to change it, no separate range picker
/// here) through `CineRenderer` frame-by-frame into a real `.mov` file via
/// `AVAssetWriter`.
///
/// One `NSSavePanel` (a "modified Finder window," not a custom SwiftUI
/// picker sheet) with an accessory view offering codec
/// (`VideoCodecOption`), resolution (`VideoResolutionOption`, capping the
/// long edge — never upscaling), and frame rate (defaulting to the file's
/// own review fps, freely editable) — matching `StillExportCoordinator`'s
/// "pick everything in one native dialog" shape. Once that panel returns,
/// encoding runs as a cancellable background `Task` with a small progress
/// sheet (`ExportProgressSheet`/`MediaExportProgress`, surfaced through
/// `CineDocumentModel.activeExportProgress` since the encode is already
/// running by the time any SwiftUI view could own it as `@StateObject`).
///
/// Every frame is rendered through the exact same
/// `CineRenderer.render(rawTexture:uniforms:into:colorAttachment:
/// lutTexture:grading:)` call the live view and every still exporter use —
/// `documentModel.uniforms`/`grading`/`currentLUTTexture`, fetched via
/// `documentModel.texture(at:)` (never moves the visible playhead, unlike
/// `PlaybackController.currentTexture()`) — into a private `.bgra8Unorm`
/// target at whatever size the chosen resolution resolves to, read back,
/// and handed to `AVAssetWriterInputPixelBufferAdaptor` as a
/// `kCVPixelFormatType_32BGRA` `CVPixelBuffer` — the identical byte layout
/// the PNG/JPEG still exporters' own readback already uses, so no
/// additional channel/byte-order conversion is needed to feed the encoder.
/// `AVVideoColorPropertiesKey` is set to ITU-R 709 throughout (primaries,
/// transfer function, and matrix) because the source pixels genuinely are
/// Rec.709-encoded (`Tonemap.metal`'s `applyGamma`/`rec709OETF`) — tagging
/// the file with that colorspace is a correctness statement about what's
/// actually in it, not an assumption.
@MainActor
enum VideoExportCoordinator {
    struct ExportOptions {
        var codec: VideoCodecOption
        var maxDimension: Int?
        var frameRate: Double
    }

    /// Pauses playback, prompts for codec/resolution/fps + save location via
    /// one `NSSavePanel`, then starts the (cancellable, backgrounded) encode
    /// and shows its progress. Presents an `NSAlert` on failure instead of
    /// throwing, since this is invoked directly from a menu command with no
    /// caller to hand an error back to.
    static func exportVideo(documentModel: CineDocumentModel) {
        guard let controller = documentModel.playbackController else {
            presentErrorAlert(VideoExportError.noOpenDocument)
            return
        }

        controller.pause()

        guard let (url, options) = presentSavePanel(documentModel: documentModel, controller: controller) else {
            return // cancelled — no error, matches every other export flow
        }

        let range = controller.effectiveInPoint...controller.effectiveOutPoint
        let progress = MediaExportProgress()
        progress.totalFrames = range.count
        documentModel.presentExportProgress(progress)

        progress.task = Task {
            await performExport(url: url, options: options, range: range, documentModel: documentModel, progress: progress)
        }
    }

    // MARK: - Save panel + accessory

    private static func presentSavePanel(
        documentModel: CineDocumentModel,
        controller: PlaybackController
    ) -> (url: URL, options: ExportOptions)? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.quickTimeMovie]

        let clipName = documentModel.currentURL?.deletingPathExtension().lastPathComponent ?? "clip"
        panel.nameFieldStringValue = "\(clipName).mov"

        let lower = controller.effectiveInPoint + 1
        let upper = controller.effectiveOutPoint + 1
        let count = controller.effectiveOutPoint - controller.effectiveInPoint + 1
        let rangeDescription = "Frames \(lower)\u{2013}\(upper) (\(count) frame\(count == 1 ? "" : "s"))"

        let defaultFPS = controller.reviewFPS
        let accessory = VideoExportAccessory(defaultFrameRate: defaultFPS, rangeDescription: rangeDescription)
        panel.accessoryView = accessory.view

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, accessory.currentOptions())
    }

    // MARK: - Encoding

    private static func performExport(
        url: URL,
        options: ExportOptions,
        range: ClosedRange<Int>,
        documentModel: CineDocumentModel,
        progress: MediaExportProgress
    ) async {
        defer { progress.isExporting = false }

        let (width, height) = VideoExportSizing.outputSize(
            nativeWidth: documentModel.frameWidth,
            nativeHeight: documentModel.frameHeight,
            maxDimension: options.maxDimension
        )
        let device = documentModel.device

        let renderer: CineRenderer
        do {
            renderer = try CineRenderer(device: device, bundle: Bundle.main)
        } catch {
            presentErrorAlert(VideoExportError.rendererCreationFailed(error))
            return
        }

        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .managed
        guard let targetTexture = device.makeTexture(descriptor: targetDescriptor) else {
            presentErrorAlert(VideoExportError.textureCreationFailed)
            return
        }

        // Always start from a clean file — `NSSavePanel` already confirmed
        // any overwrite with the user before returning, and `AVAssetWriter`
        // itself refuses to write over an existing file.
        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            presentErrorAlert(VideoExportError.writerCreationFailed(error))
            return
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

        guard writer.canAdd(input) else {
            presentErrorAlert(VideoExportError.cannotAddInput)
            return
        }
        writer.add(input)
        guard writer.startWriting() else {
            presentErrorAlert(VideoExportError.startWritingFailed(writer.error))
            return
        }
        writer.startSession(atSourceTime: .zero)

        // A fixed, generously-fine timescale rather than deriving one from
        // `options.frameRate` directly (which may be fractional, e.g.
        // 23.976) — every presentation time below is computed as a fraction
        // of this, so no rounding drift accumulates frame over frame the
        // way repeatedly adding a rounded per-frame duration would.
        let timescale: Int32 = 6000

        for (offset, frameIndex) in range.enumerated() {
            if Task.isCancelled { break }

            do {
                let rawTexture = try await documentModel.texture(at: frameIndex)
                guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
                    throw VideoExportError.commandBufferCreationFailed
                }
                renderer.render(
                    rawTexture: rawTexture,
                    uniforms: documentModel.uniforms,
                    into: commandBuffer,
                    colorAttachment: targetTexture,
                    lutTexture: documentModel.currentLUTTexture,
                    grading: documentModel.grading
                )
                guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
                    throw VideoExportError.blitEncoderCreationFailed
                }
                blitEncoder.synchronize(resource: targetTexture)
                blitEncoder.endEncoding()
                commandBuffer.commit()
                await commandBuffer.completed()

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

                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard let pool = adaptor.pixelBufferPool else {
                    throw VideoExportError.pixelBufferPoolUnavailable
                }
                var pixelBufferOut: CVPixelBuffer?
                let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
                guard status == kCVReturnSuccess, let pixelBuffer = pixelBufferOut else {
                    throw VideoExportError.pixelBufferCreationFailed(status)
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
                        // different stride than our tightly-packed
                        // readback — copy row by row instead of assuming
                        // they match.
                        for row in 0..<height {
                            memcpy(base.advanced(by: row * destBytesPerRow), srcBase.advanced(by: row * bytesPerRow), bytesPerRow)
                        }
                    }
                }
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

                let time = CMTime(value: Int64((Double(offset) * Double(timescale) / options.frameRate).rounded()), timescale: timescale)
                guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                    throw VideoExportError.appendFailed(writer.error)
                }
            } catch {
                presentErrorAlert(error)
                input.markAsFinished()
                await writer.finishWriting()
                try? FileManager.default.removeItem(at: url)
                return
            }

            progress.currentFrame = offset + 1
        }

        input.markAsFinished()
        await writer.finishWriting()

        if writer.status == .failed {
            presentErrorAlert(VideoExportError.finishWritingFailed(writer.error))
        }
    }

    private static func presentErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Failed to export video"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// A plain `NSPopUpButton`/`NSTextField`-based `NSSavePanel` accessory view
/// — not SwiftUI-hosted, matching `StillFormatAccessory`'s own reasoning
/// (native Finder-dialog feel, no SwiftUI-in-`NSSavePanel` layout/
/// first-responder risk). Three rows (codec, resolution, frame rate) plus a
/// read-only range-summary label, stacked vertically; the resolution row's
/// custom-max-dimension field only appears once "Custom…" is selected.
@MainActor
private final class VideoExportAccessory: NSObject {
    let view: NSView

    private let codecPopUp: NSPopUpButton
    private let resolutionPopUp: NSPopUpButton
    private let customDimensionField: NSTextField
    private let frameRateField: NSTextField

    init(defaultFrameRate: Double, rangeDescription: String) {
        let rangeLabel = NSTextField(labelWithString: rangeDescription)
        rangeLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        rangeLabel.textColor = .secondaryLabelColor

        let codecPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        codecPopUp.addItems(withTitles: VideoCodecOption.allCases.map(\.displayName))
        codecPopUp.selectItem(withTitle: VideoCodecOption.proRes422HQ.displayName)
        self.codecPopUp = codecPopUp

        let resolutionPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        resolutionPopUp.addItems(withTitles: VideoResolutionOption.allCases.map(\.displayName))
        resolutionPopUp.selectItem(withTitle: VideoResolutionOption.native.displayName)
        self.resolutionPopUp = resolutionPopUp

        let customDimensionField = NSTextField(string: "1920")
        customDimensionField.alignment = .right
        customDimensionField.isHidden = true
        self.customDimensionField = customDimensionField

        let frameRateField = NSTextField(string: Self.formattedFPS(defaultFrameRate))
        frameRateField.alignment = .right
        self.frameRateField = frameRateField

        func row(_ label: String, _ control: NSView, extra: NSView? = nil) -> NSStackView {
            var views: [NSView] = [NSTextField(labelWithString: label), control]
            if let extra { views.append(extra) }
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 8
            return stack
        }

        let stack = NSStackView(views: [
            rangeLabel,
            row("Codec:", codecPopUp),
            row("Resolution:", resolutionPopUp, extra: customDimensionField),
            row("Frame Rate:", frameRateField),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        self.view = container

        super.init()
        resolutionPopUp.target = self
        resolutionPopUp.action = #selector(resolutionChanged(_:))
    }

    @objc private func resolutionChanged(_ sender: NSPopUpButton) {
        let isCustom = sender.titleOfSelectedItem == VideoResolutionOption.custom.displayName
        customDimensionField.isHidden = !isCustom
    }

    func currentOptions() -> VideoExportCoordinator.ExportOptions {
        let codec = VideoCodecOption.allCases.first { $0.displayName == codecPopUp.titleOfSelectedItem } ?? .proRes422HQ
        let resolution = VideoResolutionOption.allCases.first { $0.displayName == resolutionPopUp.titleOfSelectedItem } ?? .native
        let maxDimension: Int?
        if resolution == .custom {
            maxDimension = Int(customDimensionField.stringValue) ?? nil
        } else {
            maxDimension = resolution.maxDimension
        }
        let frameRate = Double(frameRateField.stringValue) ?? 30
        return VideoExportCoordinator.ExportOptions(
            codec: codec,
            maxDimension: maxDimension,
            frameRate: frameRate > 0 ? frameRate : 30
        )
    }

    private static func formattedFPS(_ fps: Double) -> String {
        fps.rounded() == fps ? String(format: "%.0f", fps) : String(format: "%.3f", fps)
    }
}
