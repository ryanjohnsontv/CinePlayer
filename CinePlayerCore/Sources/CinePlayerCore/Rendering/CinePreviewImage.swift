import Foundation
@preconcurrency import Metal
import CoreGraphics
import CineKit

public enum CinePreviewImageError: Error, CustomStringConvertible {
    case noMetalDevice
    case textureCreationFailed
    case commandBufferCreationFailed
    case blitEncoderCreationFailed
    case imageCreationFailed

    public var description: String {
        switch self {
        case .noMetalDevice:
            return "No Metal device is available in this process."
        case .textureCreationFailed:
            return "Failed to create the offscreen render-target texture."
        case .commandBufferCreationFailed:
            return "Failed to create a Metal command buffer."
        case .blitEncoderCreationFailed:
            return "Failed to create a blit encoder to synchronize the render target."
        case .imageCreationFailed:
            return "Failed to construct a CGImage from the rendered pixels."
        }
    }
}

/// Renders a single, representative frame of a `.cine` file into a `CGImage`
/// — the shared entry point for CinePlayer's two Quick Look app extensions
/// (`CineThumbnailExtension`'s `QLThumbnailProvider` and
/// `CinePreviewExtension`'s `QLPreviewingController`), so neither hand-rolls
/// its own copy of "decode a frame, run it through the GPU debayer/tonemap
/// pipeline, read the pixels back." That shape already exists, proven,
/// three times over in this codebase (the `cine-diagnostic` CLI, the app's
/// `FrameExporter`, and `DNGExporter`) — this is a fourth caller of the same
/// underlying pipeline, not a reinvention of it.
///
/// **Design choice — reusing the full GPU debayer/tonemap pipeline
/// (`CineRenderer`/`Tonemap.metal`) rather than a simpler CPU-side render:**
/// Quick Look extensions run out-of-process under real, Apple-imposed time
/// and memory budgets, which might argue for the cheapest possible path.
/// But the actual workload here is rendering a SINGLE static frame, not
/// sustained playback — the thing that has actually stressed this app's
/// decode pipeline in the past (see the real-time-playback profiling work).
/// Frame decode is sub-millisecond once warm (`CineKit`'s P10 unpacker is
/// forced to compile optimized even under a Debug scheme specifically for
/// this reason), the GPU render pass is one full-screen-triangle draw at
/// native frame resolution, and Metal device/pipeline setup is the only
/// real fixed cost — on the order of tens of milliseconds. That is
/// comfortably inside a Quick Look extension's budget for a one-shot
/// render, and reusing the exact renderer already validated against every
/// real bundled sample file (CFA phase, color calibration decomposition,
/// gamma — see `ExposureUniforms`/`ColorCalibration`'s own doc comments) is
/// far more correct, and far less to maintain, than a second, independent
/// debayer implementation that could silently drift from the live app's own
/// picture over time. If a future file turns out to blow this budget (e.g.
/// an exotic resolution far larger than anything in the 4 bundled
/// samples), the fix is downsampling the render target, not abandoning the
/// GPU path.
///
/// **Design choice — fixed rendering parameters, no live-preference sync:**
/// a Quick Look extension is a separate process from the host app, with no
/// direct access to `CineDocumentModel`'s in-memory state (last-selected
/// debayer mode, the "Color Matrix" toggle, ...) — building state-sharing
/// for this (e.g. via an App Group) is real additional work, out of scope
/// here. Instead this always renders **High Quality (Malvar-He-Cutler)
/// debayer with white balance *and* the post-demosaic color matrix applied**
/// (subject to the same `CalibrationPlausibility` veto the live app itself
/// applies) — matching `CineDocumentModel.open(url:)`'s own new default
/// behavior (a freshly-opened file, with no saved preference, now defaults
/// to High Quality debayer + white balance + color matrix, together
/// targeting Rec.709 — see `storedDebayerMode`'s/`storedColorMatrixEnabled`'s
/// doc comments), so a Quick Look thumbnail/preview is color-consistent with
/// the app's own native/default view rather than a dimmer, white-balance-only
/// rendering of it. High Quality is this app's best-looking demosaic mode by
/// its own established ranking (see `DebayerMode`'s doc comment); applying
/// the full calibration (not just white balance) is what actually makes this
/// an accurate Rec.709 conversion rather than an intermediate step toward
/// one — a real user who has manually turned the "Color Matrix" toggle back
/// off in the live app (overriding that new default) won't see that specific
/// override reflected here, for the same "no live-preference sync" reason
/// the debayer mode itself doesn't sync either.
public enum CinePreviewImage {
    /// - Parameters:
    ///   - cineFile: the already-opened file to render a frame from.
    ///   - frameIndex: which frame to decode and render. Both Quick Look
    ///     call sites deliberately pass `0` — a representative single-frame
    ///     preview doesn't need to seek into the clip, and frame 0 is always
    ///     present (a `.cine` file has at least 1 frame) unlike some
    ///     arbitrary "middle" frame that would need extra bounds-checking
    ///     for a degenerate very-short clip.
    ///   - device: the Metal device to render with.
    ///   - rendererBundle: forwarded to `CineRenderer.init(device:bundle:)`
    ///     when this call needs to construct its own renderer (i.e.
    ///     `renderer` is `nil`) — ignored otherwise. Pass `Bundle.main` from
    ///     an Xcode app-extension (or app) target — like the main
    ///     `CinePlayer` app target, and unlike `CinePlayerCore` itself, an
    ///     Xcode-native target has no SwiftPM `Bundle.module` of its own
    ///     (see `CineMetalView`'s doc comment on this exact point). Each
    ///     Quick Look extension target compiles its own copy of
    ///     `Tonemap.metal` directly into its own `.appex` bundle for this
    ///     reason, exactly as the main app target already does — `nil`
    ///     (the default) resolves to `CinePlayerCore`'s own `Bundle.module`,
    ///     which is only correct for a caller that IS a SwiftPM target
    ///     linking this package directly (`cine-diagnostic`/
    ///     `cine-scrub-bench`), never an Xcode app-extension target.
    ///   - renderer: an already-constructed `CineRenderer` to reuse, or
    ///     `nil` (the default) to build a fresh one for this call.
    ///     Constructing a `CineRenderer` loads its Metal shader library and
    ///     compiles two `MTLRenderPipelineState`s — tens of milliseconds
    ///     that are trivial for a single one-shot render but add up fast
    ///     for a caller invoked once per file, such as
    ///     `CineThumbnailExtension`'s `ThumbnailProvider` rendering a whole
    ///     folder of `.cine` files in a burst: it builds one `CineRenderer`
    ///     lazily and passes it here on every subsequent call so Finder
    ///     populating a large folder doesn't re-pay shader compilation once
    ///     per file.
    public static func render(
        cineFile: CineFile,
        frameIndex: Int,
        device: MTLDevice,
        rendererBundle: Bundle? = nil,
        renderer: CineRenderer? = nil
    ) throws -> CGImage {
        let frame = try cineFile.decodeFrame(at: frameIndex)
        let rawTexture = try makeFrameTexture(device: device, frame: frame)
        let uniforms = previewUniforms(cineFile: cineFile, frame: frame)

        let renderer = try renderer ?? CineRenderer(device: device, bundle: rendererBundle)

        let targetDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: frame.width,
            height: frame.height,
            mipmapped: false
        )
        targetDescriptor.usage = [.renderTarget, .shaderRead]
        targetDescriptor.storageMode = .managed
        guard let targetTexture = device.makeTexture(descriptor: targetDescriptor) else {
            throw CinePreviewImageError.textureCreationFailed
        }

        guard let commandBuffer = renderer.commandQueue.makeCommandBuffer() else {
            throw CinePreviewImageError.commandBufferCreationFailed
        }

        renderer.render(
            rawTexture: rawTexture,
            uniforms: uniforms,
            into: commandBuffer,
            colorAttachment: targetTexture
        )

        // .managed textures need an explicit synchronize before CPU readback.
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw CinePreviewImageError.blitEncoderCreationFailed
        }
        blitEncoder.synchronize(resource: targetTexture)
        blitEncoder.endEncoding()

        // Plain synchronous `waitUntilCompleted()` (matching
        // `cine-diagnostic`'s CLI exactly), not the `await ...completed()`
        // async-context variant `FrameExporter` needs: `waitUntilCompleted`
        // is `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` based on whether *this*
        // function's own body is `async`, not on whether some caller further
        // up the stack happens to be — this function is a plain synchronous
        // `throws` function, so it's callable equally well from
        // `QLThumbnailProvider`'s completion-handler API and from
        // `QLPreviewingController.preparePreviewOfFile(at:) async throws`
        // (a synchronous call from an async context just runs synchronously
        // and doesn't suspend, which is always legal).
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

        return try makeCGImage(bgraPixels: pixelData, width: frame.width, height: frame.height)
    }

    /// See this type's doc comment for the reasoning behind this fixed
    /// choice of debayer mode + calibration. Deliberately built via
    /// `ExposureUniforms`'s low-level member-wise initializer (not the
    /// `init(cineFile:frame:debayerMode:)` convenience initializer used only
    /// by `cine-diagnostic`) — but still runs the file's raw calibration
    /// through the same `CalibrationPlausibility.vetoedCalibration` veto
    /// `CineDocumentModel.open(url:)` applies, using `frame` (already decoded
    /// by the caller) as the real pixel data to check it against, so this
    /// can't apply a calibration the live app itself would have rejected as
    /// implausible for this exact file — `cameraVersion` included, so a
    /// vetoed file gets the same per-camera fallback the live app and
    /// `cine-diagnostic` do, not always the generic one.
    private static func previewUniforms(cineFile: CineFile, frame: DecodedFrame) -> ExposureUniforms {
        let setup = cineFile.setup
        let levels = cineFile.effectiveBlackWhiteLevels
        let cfaPhase = CFAPhase.forCFAPattern(setup.cfa)
        let rawCalibration = setup.colorCalibration ?? .identity
        // Full white balance + color matrix — not forced to identity — the
        // same "Color Matrix on" state `CineDocumentModel.open(url:)` now
        // defaults every freshly-opened file to, subject to the same
        // plausibility veto it applies.
        let calibration = CalibrationPlausibility.vetoedCalibration(
            rawCalibration,
            frame: frame,
            cfaPhase: cfaPhase,
            blackLevel: Float(levels.black),
            whiteLevel: Float(levels.white),
            cameraVersion: setup.cameraVersion
        )
        return ExposureUniforms(
            blackLevel: Float(levels.black),
            whiteLevel: Float(levels.white),
            flipVertically: frame.needsVerticalFlip,
            debayerMode: .highQuality,
            cfaPhase: cfaPhase,
            colorCalibration: calibration,
            gamma: setup.fGamma ?? 2.2
        )
    }

    /// Same byte layout/encoding as `cine-diagnostic`'s `writePNG`/
    /// `FrameExporter`'s `pngData` — our render target is `.bgra8Unorm`
    /// (memory order B, G, R, A per pixel); `.noneSkipFirst` +
    /// `byteOrder32Little` describes exactly that layout, treating the
    /// alpha byte as ignorable since our output alpha is always 1.0.
    /// `shouldInterpolate: true` (unlike the PNG-export call sites, which
    /// pass `false`): this `CGImage` is likely to be drawn scaled down for
    /// a thumbnail or scaled to fit a preview pane, not written byte-for-byte
    /// to a file, so smooth resampling is the right default here.
    private static func makeCGImage(bgraPixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(
            rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        let bytesPerRow = width * 4

        guard let provider = CGDataProvider(data: Data(bgraPixels) as CFData) else {
            throw CinePreviewImageError.imageCreationFailed
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
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw CinePreviewImageError.imageCreationFailed
        }

        return cgImage
    }
}
