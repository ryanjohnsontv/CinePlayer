import QuickLookThumbnailing
import CoreGraphics
import Metal
import CineKit
import CinePlayerCore
import os.log

/// Everything this extension logs goes through this one `Logger` — the OS's
/// own bootstrap/XPC-handshake log lines for a freshly-launched extension
/// process say nothing about whether `provideThumbnail` itself ran, how
/// long it took, or what `request.maximumSize`/`.scale` it was asked to
/// satisfy, so without this there's no way to diagnose a dispatch/timing
/// issue from logs alone. Filter with:
/// `log show --predicate 'subsystem == "com.cineplayer.app.CineThumbnailExtension"'`.
private let thumbnailLog = Logger(subsystem: "com.cineplayer.app.CineThumbnailExtension", category: "provideThumbnail")

/// macOS Quick Look thumbnail extension for `.cine` files — generates the
/// small icon/gallery-view thumbnail Finder shows (list view, icon view,
/// column view's icon column, and Spotlight/Launchpad-style previews),
/// distinct from the larger Space-bar preview `CinePreviewExtension`
/// provides. This is a real, separate `NSExtensionPointIdentifier`
/// (`com.apple.quicklook.thumbnail`) from Quick Look's own
/// (`com.apple.quicklook.preview`) — Finder may ask for a thumbnail without
/// ever asking for a full preview (e.g. just scrolling a folder), so this
/// has to stand on its own rather than being a scaled-down version of the
/// preview extension's own output.
///
/// All the actual decode+render work is `CinePreviewImage.render` (in
/// `CinePlayerCore`) — see that type's doc comment for why reusing the full
/// GPU debayer/tonemap pipeline is the right call even under a Quick Look
/// extension's tighter time/resource budget, and for the fixed rendering
/// choice (High Quality debayer + white balance, no color matrix, frame 0)
/// used here since this extension has no access to the host app's live
/// user preferences across the process boundary.
final class ThumbnailProvider: QLThumbnailProvider {
    /// Built once, lazily, and shared across every `provideThumbnail` call
    /// this extension process handles — `CineRenderer.init` loads its Metal
    /// shader library and compiles two `MTLRenderPipelineState`s, a
    /// tens-of-milliseconds fixed cost that's trivial for one file but was
    /// being re-paid on *every* file: Finder asks for a thumbnail per
    /// visible `.cine` file when a folder opens, all handled by this same
    /// long-lived process, and the old code called `CineRenderer(device:...)`
    /// fresh inside `CinePreviewImage.render` on each of those calls — the
    /// root cause of the reported "opening a folder with lots of cine files
    /// is slow" regression. `static let` gives thread-safe, build-exactly-
    /// once semantics for free. `Bundle.main` — see
    /// `CinePreviewImage.render`'s doc comment on why an Xcode app-extension
    /// target (unlike `CinePlayerCore` itself) has no `Bundle.module` of its
    /// own. `Result`, not a plain optional, so a real construction failure
    /// (e.g. a shader compile error) surfaces its actual error to Quick
    /// Look instead of collapsing into a generic "no Metal device" message.
    /// `nonisolated(unsafe)`: neither `MTLDevice` nor `CineRenderer` is
    /// `Sendable`, but this is safe by construction — the initializer
    /// closure runs exactly once (Swift guarantees `static let` init is
    /// thread-safe), and every call site only reads the already-built
    /// device/renderer afterward, never mutates it.
    private nonisolated(unsafe) static let sharedRenderer: Result<(device: MTLDevice, renderer: CineRenderer), Error> = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return .failure(CinePreviewImageError.noMetalDevice)
        }
        do {
            let renderer = try CineRenderer(device: device, bundle: Bundle.main)
            return .success((device, renderer))
        } catch {
            return .failure(error)
        }
    }()

    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        let start = DispatchTime.now()
        thumbnailLog.log(
            "start: \(request.fileURL.lastPathComponent, privacy: .public) maxSize=\(String(describing: request.maximumSize), privacy: .public) scale=\(request.scale, privacy: .public)"
        )
        do {
            let shared = try Self.sharedRenderer.get()

            let cineFile = try CineFile(url: request.fileURL)
            let cgImage = try CinePreviewImage.render(
                cineFile: cineFile,
                frameIndex: 0,
                device: shared.device,
                renderer: shared.renderer
            )

            // Fit the frame's own aspect ratio inside `request.maximumSize`
            // rather than stretching it to fill a mismatched box (a `.cine`
            // frame's aspect ratio is whatever the camera's sensor crop was,
            // essentially never square) or handing back a full-resolution
            // context Quick Look didn't ask for.
            let contextSize = Self.aspectFitSize(
                CGSize(width: cgImage.width, height: cgImage.height),
                within: request.maximumSize
            )

            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            thumbnailLog.log(
                "rendered: \(request.fileURL.lastPathComponent, privacy: .public) in \(elapsedMs, privacy: .public)ms contextSize=\(String(describing: contextSize), privacy: .public)"
            )

            let reply = QLThumbnailReply(contextSize: contextSize) { context in
                // `contextSize` is in the POINTS space `request.maximumSize`
                // and `aspectFitSize` above are both expressed in, but the
                // actual `CGContext` Quick Look hands this closure is backed
                // by a pixel buffer at `request.scale` (2x on every Retina
                // display) — scaling the destination rect by `request.scale`
                // here (contextSize itself must stay in points, since that's
                // what tells Quick Look how large a tile to lay out/center)
                // makes our draw call fill the context's real backing
                // resolution instead of just its bottom-left quarter.
                let scale = request.scale
                let pixelRect = CGRect(
                    origin: .zero,
                    size: CGSize(width: contextSize.width * scale, height: contextSize.height * scale)
                )
                context.draw(cgImage, in: pixelRect)
                return true
            }
            let totalMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
            thumbnailLog.log("replying: \(request.fileURL.lastPathComponent, privacy: .public) total=\(totalMs, privacy: .public)ms")
            handler(reply, nil)
        } catch {
            thumbnailLog.error(
                "failed: \(request.fileURL.lastPathComponent, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
            handler(nil, error)
        }
    }

    /// The largest size that fits `imageSize` inside `boundingSize` while
    /// preserving its aspect ratio (scales up or down as needed — Finder's
    /// grid/icon views expect the returned thumbnail to actually fill the
    /// tile it asked for, not just "no larger than").
    private static func aspectFitSize(_ imageSize: CGSize, within boundingSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              boundingSize.width > 0, boundingSize.height > 0 else {
            return boundingSize
        }
        let scale = min(boundingSize.width / imageSize.width, boundingSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}
