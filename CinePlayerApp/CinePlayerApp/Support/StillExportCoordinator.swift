import AppKit
import CoreGraphics
import ImageIO
// `@preconcurrency`: `commandBuffer.completed()` below is a nonisolated
// async API operating on a main-actor-isolated `MTLCommandBuffer` — same
// rationale as `FrameExporter`'s (this file's predecessor's) identical
// import.
@preconcurrency import Metal
import UniformTypeIdentifiers
import CineKit
import CinePlayerCore

/// Every still-image format "Current Frame as Still…" can produce, offered
/// as one dropdown in a single `NSSavePanel`'s accessory view — replacing
/// what used to be two separate menu items/shortcuts/save panels ("Export
/// Current Frame (PNG)…" and "Export Current Frame (Raw DNG)…").
///
/// `.rawDNG` is fundamentally different in kind from the other four (raw,
/// undemosaiced sensor data bypassing the tonemap pipeline entirely, vs. a
/// rendered/graded picture) — it stays in this one dropdown anyway, rather
/// than a separate menu item, because the user-facing question is still
/// just "what file do you want on disk," and DNG already existed as a real,
/// working capability that folding into one save panel shouldn't quietly
/// drop.
enum StillExportFormat: String, CaseIterable {
    case png
    case tiff16Bit
    case jpeg
    case dpx16Bit
    case rawDNG

    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .tiff16Bit: return "TIFF (16-bit)"
        case .jpeg: return "JPEG"
        case .dpx16Bit: return "DPX (16-bit)"
        case .rawDNG: return "Raw DNG (undemosaiced)"
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .tiff16Bit: return "tiff"
        case .jpeg: return "jpg"
        case .dpx16Bit: return "dpx"
        case .rawDNG: return "dng"
        }
    }

    /// `nil` for `.dpx16Bit` — macOS's ImageIO declares no UTI for DPX at
    /// all (confirmed directly: `CGImageDestinationCopyTypeIdentifiers()`
    /// lists nothing DPX-related on this system), so `NSSavePanel.
    /// allowedContentTypes` has nothing correct to offer for it; the save
    /// panel's own `allowsOtherFileTypes` handling combined with this
    /// format's own fixed `.dpx` name-field extension is what keeps the
    /// written file correctly named regardless.
    var contentType: UTType? {
        switch self {
        case .png: return .png
        case .tiff16Bit: return .tiff
        case .jpeg: return .jpeg
        case .dpx16Bit: return nil
        case .rawDNG: return UTType("com.adobe.raw-image") ?? UTType(filenameExtension: "dng")
        }
    }
}

enum StillExportError: Error, CustomStringConvertible {
    case noOpenDocument
    case rendererCreationFailed(Error)
    case textureCreationFailed
    case commandBufferCreationFailed
    case blitEncoderCreationFailed
    case encodingFailed(StillExportFormat)
    case rawFileReopenFailed(Error)
    case rawFrameDecodeFailed(Error)

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
        case .encodingFailed(let format):
            return "Failed to encode the frame as \(format.displayName)."
        case .rawFileReopenFailed(let error):
            return "Failed to reopen the .cine file for raw export: \(error)"
        case .rawFrameDecodeFailed(let error):
            return "Failed to decode the raw frame: \(error)"
        }
    }
}

/// "File > Export > Current Frame as Still…" — the single, format-agnostic
/// replacement for what used to be `FrameExporter` (PNG only) and
/// `DNGExporter` (raw DNG only). One `NSSavePanel`, one accessory-view
/// format dropdown (`StillExportFormat.allCases`), one place a user picks
/// name/location/format together — matching a native Finder save dialog's
/// own shape, not a custom SwiftUI sheet.
///
/// PNG/TIFF/JPEG all render *whatever's currently on screen* through the
/// exact same `CineRenderer.render(...)` pass `CineMetalView`'s own
/// `Coordinator` uses (`documentModel.uniforms`/`grading`/
/// `currentLUTTexture`, `playbackController.currentTexture()`) — this is
/// `FrameExporter`'s original rendering recipe, now parameterized by pixel
/// format/bit depth instead of hardcoded to 8-bit BGRA. DPX shares the
/// exact same 16-bit render path TIFF uses (`.rgba16Unorm` target), just
/// encoded by `DPXWriter` instead of `CGImageDestination` (ImageIO has no
/// DPX encoder at all). Raw DNG is `DNGExporter`'s original, deliberately
/// separate pipeline: bypasses `CineRenderer`/tonemap entirely and writes
/// the undemosaiced sensor mosaic straight from a freshly re-opened
/// `CineFile` — see `DNGWriter`'s own doc comment for why.
@MainActor
enum StillExportCoordinator {
    /// Pauses playback (if running), prompts for format + save location via
    /// one `NSSavePanel`, then renders/encodes/writes. Presents an
    /// `NSAlert` on failure instead of throwing, since this is invoked
    /// directly from a menu command with no caller to hand an error back to.
    static func exportCurrentFrame(documentModel: CineDocumentModel) async {
        guard let controller = documentModel.playbackController else {
            presentErrorAlert(StillExportError.noOpenDocument)
            return
        }

        // "Pauses playback if active" — matches `FrameExporter`'s original
        // rationale: a still frame is wanted, not one export mid-tick out
        // from under a running playback loop.
        controller.pause()

        guard let (url, format) = presentSavePanel(documentModel: documentModel, controller: controller) else {
            return // cancelled — no error, matches every other export flow
        }

        do {
            let data = try await encodedData(format: format, documentModel: documentModel, controller: controller)
            try data.write(to: url)
        } catch {
            presentErrorAlert(error)
        }
    }

    // MARK: - Save panel + format accessory

    /// `nil` if the panel is cancelled.
    private static func presentSavePanel(
        documentModel: CineDocumentModel,
        controller: PlaybackController
    ) -> (url: URL, format: StillExportFormat)? {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true

        let clipName = documentModel.currentURL?.deletingPathExtension().lastPathComponent ?? "clip"
        let baseName = "\(clipName)_frame\(controller.currentFrameIndex + 1)"

        let accessory = StillFormatAccessory(initialFormat: .png) { [weak panel] newFormat in
            guard let panel else { return }
            panel.allowedContentTypes = newFormat.contentType.map { [$0] } ?? []
            panel.nameFieldStringValue = "\(baseName).\(newFormat.fileExtension)"
        }
        panel.accessoryView = accessory.view
        panel.allowedContentTypes = StillExportFormat.png.contentType.map { [$0] } ?? []
        panel.nameFieldStringValue = "\(baseName).\(StillExportFormat.png.fileExtension)"

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, accessory.selectedFormat)
    }

    // MARK: - Render + encode, by format

    private static func encodedData(
        format: StillExportFormat,
        documentModel: CineDocumentModel,
        controller: PlaybackController
    ) async throws -> Data {
        switch format {
        case .png:
            let (pixels, width, height) = try await renderBGRA8(documentModel: documentModel, controller: controller)
            return try pngData(bgraPixels: pixels, width: width, height: height)
        case .jpeg:
            let (pixels, width, height) = try await renderBGRA8(documentModel: documentModel, controller: controller)
            return try jpegData(bgraPixels: pixels, width: width, height: height)
        case .tiff16Bit:
            let (pixels, width, height) = try await renderRGBA16(documentModel: documentModel, controller: controller)
            return try tiffData16Bit(rgba16Pixels: pixels, width: width, height: height)
        case .dpx16Bit:
            let (pixels, width, height) = try await renderRGBA16(documentModel: documentModel, controller: controller)
            return DPXWriter.makeDPXData(rgba16Pixels: pixels, width: width, height: height)
        case .rawDNG:
            guard let url = documentModel.currentURL else { throw StillExportError.noOpenDocument }
            return try buildDNGData(url: url, frameIndex: controller.currentFrameIndex)
        }
    }

    /// Renders the current frame into a private `.bgra8Unorm` target and
    /// reads it back — identical recipe to `FrameExporter`'s original
    /// `renderCurrentFramePNGData`, stopping short of the final
    /// format-specific encode so PNG and JPEG can share it.
    private static func renderBGRA8(
        documentModel: CineDocumentModel,
        controller: PlaybackController
    ) async throws -> (pixels: [UInt8], width: Int, height: Int) {
        let rawTexture = try await controller.currentTexture()
        let device = documentModel.device

        let renderer: CineRenderer
        do {
            renderer = try CineRenderer(device: device, bundle: Bundle.main)
        } catch {
            throw StillExportError.rendererCreationFailed(error)
        }

        let width = rawTexture.width
        let height = rawTexture.height

        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .managed
        guard let targetTexture = device.makeTexture(descriptor: targetDescriptor) else {
            throw StillExportError.textureCreationFailed
        }

        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            throw StillExportError.commandBufferCreationFailed
        }

        renderer.render(
            rawTexture: rawTexture,
            uniforms: documentModel.uniforms,
            into: commandBuffer,
            colorAttachment: targetTexture,
            lutTexture: documentModel.currentLUTTexture,
            grading: documentModel.grading,
            toneCurveTextures: documentModel.toneCurveTextures
        )

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw StillExportError.blitEncoderCreationFailed
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
        return (pixelData, width, height)
    }

    /// Same shape as `renderBGRA8`, but into a private `.rgba16Unorm`
    /// target (`CineRenderer`'s second pipeline state) — identical recipe
    /// to `RangeExporter.renderTIFFData16Bit`'s original, just for
    /// whatever's currently on screen instead of an arbitrary frame index.
    private static func renderRGBA16(
        documentModel: CineDocumentModel,
        controller: PlaybackController
    ) async throws -> (pixels: [UInt8], width: Int, height: Int) {
        let rawTexture = try await controller.currentTexture()
        let device = documentModel.device

        let renderer: CineRenderer
        do {
            renderer = try CineRenderer(device: device, bundle: Bundle.main)
        } catch {
            throw StillExportError.rendererCreationFailed(error)
        }

        let width = rawTexture.width
        let height = rawTexture.height

        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .managed
        guard let targetTexture = device.makeTexture(descriptor: targetDescriptor) else {
            throw StillExportError.textureCreationFailed
        }

        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            throw StillExportError.commandBufferCreationFailed
        }

        renderer.render(
            rawTexture: rawTexture,
            uniforms: documentModel.uniforms,
            into: commandBuffer,
            colorAttachment: targetTexture,
            lutTexture: documentModel.currentLUTTexture,
            grading: documentModel.grading,
            toneCurveTextures: documentModel.toneCurveTextures
        )

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw StillExportError.blitEncoderCreationFailed
        }
        blitEncoder.synchronize(resource: targetTexture)
        blitEncoder.endEncoding()

        commandBuffer.commit()
        await commandBuffer.completed()

        let bytesPerRow = width * 8 // 4 channels * 2 bytes/channel
        var pixelData = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixelData.withUnsafeMutableBytes { buffer in
            targetTexture.getBytes(
                buffer.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        return (pixelData, width, height)
    }

    /// Re-opens `url` as an independent `CineFile` purely to decode one raw
    /// frame — `CineFile` is mmap-backed, so a second, throwaway open of
    /// the already-open document's own file is cheap and side-effect-free.
    /// Identical to `DNGExporter`'s original `buildDNGData`.
    private static func buildDNGData(url: URL, frameIndex: Int) throws -> Data {
        let cineFile: CineFile
        do {
            cineFile = try CineFile(url: url)
        } catch {
            throw StillExportError.rawFileReopenFailed(error)
        }

        let frame: DecodedFrame
        do {
            frame = try cineFile.decodeFrame(at: frameIndex)
        } catch {
            throw StillExportError.rawFrameDecodeFailed(error)
        }

        return DNGWriter.makeDNGData(cineFile: cineFile, frame: frame)
    }

}

// MARK: - Encoding (ImageIO)

extension StillExportCoordinator {
    /// Identical byte layout/encoding to `FrameExporter`'s original `pngData`.
    private static func pngData(bgraPixels: [UInt8], width: Int, height: Int) throws -> Data {
        try imageIOData(
            bgraPixels: bgraPixels, width: width, height: height,
            utType: .png, format: .png
        )
    }

    /// Same `.bgra8Unorm` readback PNG uses, encoded as JPEG instead —
    /// ImageIO's JPEG encoder ignores/discards the (always-`1.0`, meaningless
    /// for a JPEG anyway — the format has no alpha channel) alpha byte on
    /// its own, so no separate premultiply/strip step is needed beyond the
    /// same `.noneSkipFirst` bitmap info every other BGRA8 readback here
    /// already uses.
    private static func jpegData(bgraPixels: [UInt8], width: Int, height: Int) throws -> Data {
        try imageIOData(
            bgraPixels: bgraPixels, width: width, height: height,
            utType: .jpeg, format: .jpeg
        )
    }

    private static func imageIOData(bgraPixels: [UInt8], width: Int, height: Int, utType: UTType, format: StillExportFormat) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        let bytesPerRow = width * 4

        guard let provider = CGDataProvider(data: Data(bgraPixels) as CFData) else {
            throw StillExportError.encodingFailed(format)
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
            throw StillExportError.encodingFailed(format)
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, utType.identifier as CFString, 1, nil
        ) else {
            throw StillExportError.encodingFailed(format)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw StillExportError.encodingFailed(format)
        }
        return mutableData as Data
    }

    /// Identical byte layout/encoding to `RangeExporter`'s original
    /// `tiffData` — see that function's doc comment for the
    /// channel-order/endianness verification this depends on.
    private static func tiffData16Bit(rgba16Pixels: [UInt8], width: Int, height: Int) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue
        )
        let bytesPerRow = width * 8

        guard let provider = CGDataProvider(data: Data(rgba16Pixels) as CFData) else {
            throw StillExportError.encodingFailed(.tiff16Bit)
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 16,
            bitsPerPixel: 64,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            throw StillExportError.encodingFailed(.tiff16Bit)
        }

        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData, UTType.tiff.identifier as CFString, 1, nil
        ) else {
            throw StillExportError.encodingFailed(.tiff16Bit)
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw StillExportError.encodingFailed(.tiff16Bit)
        }
        return mutableData as Data
    }

    private static func presentErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Failed to export still"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.runModal()
    }
}

/// A plain `NSPopUpButton`-based `NSSavePanel` accessory view — not a
/// SwiftUI-hosted one — offering `StillExportFormat.allCases`. Plain AppKit
/// (not `NSHostingView`) matches how a real Finder save dialog's own
/// built-in format accessories (e.g. Preview.app's "Export As…") are built,
/// and sidesteps any first-responder/layout quirk hosting SwiftUI inside an
/// `NSSavePanel` accessory view could introduce.
@MainActor
private final class StillFormatAccessory: NSObject {
    let view: NSView
    private(set) var selectedFormat: StillExportFormat
    private let onChange: (StillExportFormat) -> Void
    private let popUp: NSPopUpButton

    init(initialFormat: StillExportFormat, onChange: @escaping (StillExportFormat) -> Void) {
        self.selectedFormat = initialFormat
        self.onChange = onChange

        let label = NSTextField(labelWithString: "Format:")
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.addItems(withTitles: StillExportFormat.allCases.map(\.displayName))
        popUp.selectItem(withTitle: initialFormat.displayName)
        self.popUp = popUp

        let stack = NSStackView(views: [label, popUp])
        stack.orientation = .horizontal
        stack.spacing = 8
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
        popUp.target = self
        popUp.action = #selector(formatChanged(_:))
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        guard let title = sender.titleOfSelectedItem,
              let format = StillExportFormat.allCases.first(where: { $0.displayName == title }) else { return }
        selectedFormat = format
        onChange(format)
    }
}
