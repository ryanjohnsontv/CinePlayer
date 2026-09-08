import Foundation
@preconcurrency import Metal
import CineKit

/// Top-level document model: opens a `.cine` file and exposes the shared
/// `DecodedFrameCache`/`PlaybackController` pair the view layer drives.
///
/// `@preconcurrency import Metal`: `open(url:)` below awaits an `MTLTexture`
/// back from `DecodedFrameCache` (an actor) into this `@MainActor` class —
/// see `DecodedFrameCache`'s doc comment for why that crossing is actually
/// safe despite `MTLTexture` not being `Sendable` in this SDK.
///
/// There is exactly one path by which any frame is ever decoded+**uploaded**
/// (to a GPU texture) in this app: through the `DecodedFrameCache`
/// constructed here in `open`. Frame 0's texture is fetched through that
/// same cache (not a separate one-off decode call) so it's warm by the time
/// `PlaybackController.currentTexture()` is first asked for it. Separately,
/// `open` also does one genuinely one-off, cache-bypassing *decode* (no
/// upload) of frame 0's raw pixels — via `CineFile.decodeFrame(at:)` — purely
/// so `CalibrationPlausibility.vetoedCalibration` has real pixel data to
/// sanity-check this file's calibration against before `uniforms` is built;
/// that pixel buffer is never retained or uploaded, so the "exactly one
/// decoded+uploaded path" claim above still holds.
///
/// `open` also kicks off `primeFileCache(at:)` (see its doc comment in
/// CineKit) in the background the instant a URL is known — before even
/// constructing `CineFile`. That's what keeps real-time playback's *first*
/// pass through a never-before-read file from being throttled by cold
/// per-page disk I/O nearly as badly as it otherwise would be: decoding and
/// scheduling smarter (`DecodedFrameCache`'s off-actor fix) only ever helps
/// once a frame's bytes are already in hand, and this is the piece that
/// gets them into hand sooner, ahead of whatever the user does first after
/// the open dialog closes.
/// Errors thrown by `CineDocumentModel`'s own narrow accessors
/// (`texture(at:)`/`writeTrimmedRange(_:to:)`) — both are only ever
/// meaningful with a file open, so both throw this rather than silently
/// no-op'ing or crashing when called with none.
public enum CineDocumentModelError: Error, CustomStringConvertible {
    case noOpenDocument

    public var description: String {
        switch self {
        case .noOpenDocument:
            return "No file is open."
        }
    }
}

@MainActor
public final class CineDocumentModel: ObservableObject {
    public let device: MTLDevice

    @Published public private(set) var currentURL: URL?
    @Published public private(set) var uniforms: ExposureUniforms = ExposureUniforms(blackLevel: 0, whiteLevel: 1023)
    @Published public private(set) var frameWidth: Int = 0
    @Published public private(set) var frameHeight: Int = 0
    @Published public private(set) var playbackController: PlaybackController?

    /// The current frame's RGB value histogram — reflects the fully graded
    /// (post-debayer, post-`GradingUniforms`, post-LUT) image, matching what
    /// a raw-editing tool's histogram shows, kept fresh by
    /// `recomputeHistogram()` (see that method's own doc comment for what
    /// triggers a recompute). `nil` until the first computation completes
    /// for whichever file is open.
    @Published public private(set) var currentHistogram: FrameHistogram?

    /// Built once, lazily, and reused for every `recomputeHistogram()`/
    /// `applyAutoExposure()` call for this model's whole lifetime —
    /// constructing a `CineRenderer` compiles two `MTLRenderPipelineState`s,
    /// a real cost not worth repeating on every frame change or grading
    /// tweak (see `ThumbnailProvider.sharedRenderer`'s doc comment for the
    /// same reasoning applied to a different caller). `nil` only if this
    /// device/shader-library combination genuinely can't build a renderer —
    /// both methods below just no-op when that's the case, same as a
    /// transient render failure.
    private lazy var histogramRenderer: CineRenderer? = try? CineRenderer(device: device)

    /// `frameWidth`/`frameHeight` as a display aspect ratio, for the video
    /// view to letterbox/pillarbox against instead of stretching to fill an
    /// arbitrary window shape. Falls back to 16:9 before any file is open
    /// (`frameWidth`/`frameHeight` are still 0 then) — an arbitrary but
    /// harmless default since nothing sizes against it until a real file's
    /// dimensions are known.
    public var videoAspectRatio: CGFloat {
        guard frameWidth > 0, frameHeight > 0 else { return 16.0 / 9.0 }
        return CGFloat(frameWidth) / CGFloat(frameHeight)
    }

    /// Zoom multiplier applied to the video viewport, on top of "fit" (the
    /// whole frame visible — `1`, this feature's only behavior before it
    /// existed). Continuous (a trackpad pinch can land on any value in
    /// `minZoomScale...maxZoomScale`), not restricted to `zoomPresets` —
    /// those are just the discrete jump-to points the toolbar's dropdown/+-
    /// buttons and the View-menu Zoom In/Out commands offer.
    ///
    /// Purely view/session state, like `showMetadataOverlay`/
    /// `showInspectorSidebar` — reset to `1`/frame-center on every
    /// `open(url:)` (see that method), never persisted to `UserDefaults` or
    /// anywhere else: unlike Debayer mode/Color Matrix (session-wide
    /// rendering-fidelity preferences), how far into a *previous*, unrelated
    /// clip you happened to be zoomed has no bearing on the next file opened.
    @Published public private(set) var zoomScale: CGFloat = CineDocumentModel.minZoomScale
    /// Where the zoomed viewport is centered, in the frame's own normalized
    /// (0...1, 0...1) texture space — `(0.5, 0.5)` is the frame's center.
    /// Mathematically inert at `zoomScale == 1` (see `ViewportUniforms`'s doc
    /// comment for why), so its value doesn't matter until zoomed in.
    @Published public private(set) var zoomCenter: CGPoint = CGPoint(x: 0.5, y: 0.5)

    /// The discrete zoom stops the toolbar's dropdown offers, and that +/-
    /// (both the toolbar buttons and the View-menu Zoom In/Out commands) step
    /// through — doubling from "fit" up to a practical pixel-peeping ceiling.
    /// A trackpad pinch is NOT restricted to these; see `zoomScale`'s own
    /// doc comment.
    public static let zoomPresets: [CGFloat] = [1, 2, 4, 8, 16]
    public static let minZoomScale: CGFloat = zoomPresets.first!
    public static let maxZoomScale: CGFloat = zoomPresets.last!

    /// `zoomScale`/`zoomCenter` packaged for `CineRenderer.render(...)`'s
    /// `viewport` parameter — read directly by `CineMetalView.Coordinator`,
    /// the same way `uniforms`/`grading` already are.
    public var viewportUniforms: ViewportUniforms {
        ViewportUniforms(scale: Float(zoomScale), centerX: Float(zoomCenter.x), centerY: Float(zoomCenter.y))
    }

    /// Where the mouse last was over the video pane, in the frame's own
    /// normalized (0...1, 0...1) texture space (already accounting for
    /// whatever zoom/pan was active at the time) — kept updated by
    /// `FocusableMTKView`'s `mouseMoved`/`mouseEntered`/`mouseExited`
    /// tracking-area callbacks, `nil` whenever the cursor is outside the
    /// video entirely. Consulted (not bound to) by `zoomIn()`/`zoomOut()`
    /// so +/- and the ⌘+/⌘- menu commands zoom in on whatever the user was
    /// last actually looking at, matching a trackpad pinch's own
    /// zoom-under-the-cursor behavior (see `adjustZoom(byMagnification:
    /// aroundNormalizedPoint:)`) instead of always zooming toward the
    /// frame's current center regardless of where the mouse is. Plain
    /// (non-`@Published`): nothing renders from this directly, it's read
    /// once at the moment a zoom action fires.
    public private(set) var lastKnownVideoMouseNormalizedPoint: CGPoint?

    public func setLastKnownVideoMouseNormalizedPoint(_ point: CGPoint?) {
        lastKnownVideoMouseNormalizedPoint = point
    }

    /// Whether the most recent `zoomScale`/`zoomCenter` write should be
    /// *presented* as an eased transition — read by
    /// `CineMetalView.Coordinator` in the same `update(...)` call that picks
    /// up the new `zoomScale`/`zoomCenter` (both are written synchronously,
    /// together, in `applyZoom` below, so they're always consistent by the
    /// time anything observes them). Deliberately NOT what actually
    /// performs the easing — see `CineMetalView.Coordinator`'s
    /// `displayedViewport` for why the interpolation itself happens there,
    /// entirely outside this `@Published` property's own fan-out, rather
    /// than as a `Task` ticking `zoomScale`/`zoomCenter` here 60 times a
    /// second (an earlier version did exactly that, and it made the
    /// animation itself look stuttery: every `@Published` write on this
    /// class fires `objectWillChange` for the *whole* object, so it was
    /// forcing every other view holding this document model — the entire
    /// "Cine Colour" sidebar included — to re-evaluate 60 times over a
    /// quarter second for a change none of them needed to react to).
    public private(set) var lastZoomChangeAnimated = false

    /// The core every public zoom entry point funnels through. `anchor` is
    /// the normalized (0...1, 0...1) texture-space point to keep visually
    /// fixed under the cursor as the scale changes (the standard "zoom to
    /// point" behavior: solving for the new center that keeps `anchor`
    /// projecting to the same on-screen position at the new scale as it did
    /// at the old one) — pass the *current* `zoomCenter` itself for an
    /// anchor-agnostic change (the dropdown: picking an exact percentage
    /// isn't a "zoom in on this spot" gesture, so whatever's centered simply
    /// stays centered, per the user's own "unless using the dropdown"
    /// carve-out).
    ///
    /// Always writes `zoomScale`/`zoomCenter` immediately — see
    /// `lastZoomChangeAnimated`'s own doc comment for why *presenting* an
    /// eased transition is a `CineMetalView.Coordinator` concern, not
    /// something this method does itself.
    ///
    /// - Parameter animated: sets `lastZoomChangeAnimated`. `true` for a
    ///   discrete action (the toolbar's +/-/dropdown, the View-menu Zoom
    ///   In/Out/Actual Size commands) — matches Photos/Preview's smooth zoom
    ///   feel. `false` — used only for `adjustZoom(byMagnification:
    ///   aroundNormalizedPoint:)` (a trackpad pinch), `panZoom` (a
    ///   scroll/drag pan), and `open(url:)`'s reset — for state changes that
    ///   are already continuous, real-time input (or need no transition at
    ///   all) in their own right, where layering an animated transition on
    ///   top would fight the user's own fingers rather than help.
    private func applyZoom(to scale: CGFloat, anchor: CGPoint, animated: Bool) {
        let targetScale = min(Self.maxZoomScale, max(Self.minZoomScale, scale))
        let targetCenter: CGPoint
        if targetScale <= Self.minZoomScale {
            targetCenter = CGPoint(x: 0.5, y: 0.5)
        } else {
            // Keeping `anchor` fixed on screen across a scale change from
            // `zoomScale` to `targetScale` means the new center must satisfy
            // `anchor + (targetCenter - anchor) * targetScale == anchor +
            // (zoomCenter - anchor) * zoomScale` (both sides are `anchor`'s
            // on-screen offset in frame-fraction units) — solving for
            // `targetCenter` gives exactly this lerp toward `anchor` by the
            // old/new scale ratio.
            let ratio = zoomScale / targetScale
            let unclamped = CGPoint(
                x: anchor.x + (zoomCenter.x - anchor.x) * ratio,
                y: anchor.y + (zoomCenter.y - anchor.y) * ratio
            )
            targetCenter = clampedZoomCenter(unclamped, forScale: targetScale)
        }
        lastZoomChangeAnimated = animated
        zoomScale = targetScale
        zoomCenter = targetCenter
    }

    /// Sets the zoom level directly (a dropdown/preset selection) — not
    /// anchored to any particular point; see `applyZoom`'s own doc comment
    /// for why the dropdown is the one exception to "zoom targets the
    /// cursor."
    public func setZoomScale(_ scale: CGFloat, animated: Bool = true) {
        applyZoom(to: scale, anchor: zoomCenter, animated: animated)
    }

    /// Steps to the next preset above the current zoom (or `maxZoomScale` if
    /// already at/past the last one) — the toolbar's "+" button and the
    /// View-menu "Zoom In" command (⌘+). Anchored at
    /// `lastKnownVideoMouseNormalizedPoint` when the cursor is (or was last)
    /// over the video, falling back to the current center otherwise (e.g.
    /// the cursor has never touched the video this session).
    public func zoomIn() {
        let target = Self.zoomPresets.first { $0 > zoomScale + 0.001 } ?? Self.maxZoomScale
        applyZoom(to: target, anchor: lastKnownVideoMouseNormalizedPoint ?? zoomCenter, animated: true)
    }

    /// Steps to the next preset below the current zoom (or `minZoomScale` if
    /// already at/below the first one) — the toolbar's "-" button and the
    /// View-menu "Zoom Out" command (⌘-). Same cursor-anchoring as
    /// `zoomIn()`.
    public func zoomOut() {
        let target = Self.zoomPresets.last { $0 < zoomScale - 0.001 } ?? Self.minZoomScale
        applyZoom(to: target, anchor: lastKnownVideoMouseNormalizedPoint ?? zoomCenter, animated: true)
    }

    /// Back to "fit", frame-centered — the View-menu "Actual Size" command
    /// (⌘0, named to match the universal macOS zoom-reset convention even
    /// though "fit" isn't literally 1:1 pixel size on every window/file
    /// combination). Anchor is irrelevant here: `applyZoom` always recenters
    /// outright at `minZoomScale` regardless of which point is passed.
    public func resetZoom() {
        setZoomScale(Self.minZoomScale)
    }

    /// A trackpad pinch gesture's incremental `NSEvent.magnification` delta
    /// (see `FocusableMTKView.magnify(with:)`) — the conventional
    /// `scale *= (1 + magnification)` update, anchored at `point` (the pinch
    /// gesture's own location, so the spot between your fingers stays put as
    /// you zoom, matching Photos.app), unanimated — see `applyZoom`'s own
    /// doc comment for why.
    public func adjustZoom(byMagnification magnification: CGFloat, aroundNormalizedPoint point: CGPoint) {
        applyZoom(to: zoomScale * (1 + magnification), anchor: point, animated: false)
    }

    /// A trackpad two-finger scroll (or a plain mouse scroll wheel)'s raw
    /// point deltas, converted to a `zoomCenter` shift using `viewSize` (the
    /// video pane's own current on-screen point size) so panning tracks the
    /// gesture at a consistent, zoom-level-independent rate: at the current
    /// `zoomScale`, the visible fraction of the frame is `1/zoomScale` in
    /// each axis, spread across `viewSize` points, so one point of scroll is
    /// `(1/zoomScale) / viewSize` of the frame. No-op at `zoomScale == 1`
    /// (nothing to pan across when the whole frame is already visible) or a
    /// degenerate zero-size view. See `FocusableMTKView.scrollWheel(with:)`.
    /// Unanimated (clears `lastZoomChangeAnimated`) — same "real gesture
    /// beats a settling animation" reasoning as
    /// `adjustZoom(byMagnification:aroundNormalizedPoint:)`.
    public func panZoom(scrollDelta: CGPoint, viewSize: CGSize) {
        guard zoomScale > Self.minZoomScale, viewSize.width > 0, viewSize.height > 0 else { return }
        lastZoomChangeAnimated = false
        let visibleFraction = 1 / zoomScale
        let proposed = CGPoint(
            x: zoomCenter.x - scrollDelta.x * visibleFraction / viewSize.width,
            y: zoomCenter.y - scrollDelta.y * visibleFraction / viewSize.height
        )
        zoomCenter = clampedZoomCenter(proposed, forScale: zoomScale)
    }

    /// Pure form of the "keep `center` far enough from every edge that the
    /// visible `1/scale`-sized viewport around it never shows past the
    /// frame's own bounds" clamp (which would otherwise sample outside
    /// `0...1` — `tonemapFragment` clamps texture reads, so this wouldn't
    /// crash, but would waste zoomed-in screen space on a repeated smear of
    /// edge pixels instead of frame content). A pure function of `(center,
    /// scale)` rather than a `zoomCenter`-mutating method, so both `panZoom`
    /// and `applyZoom`'s target-center computation can share it.
    private func clampedZoomCenter(_ center: CGPoint, forScale scale: CGFloat) -> CGPoint {
        let halfVisible = 0.5 / scale
        return CGPoint(
            x: min(1 - halfVisible, max(halfVisible, center.x)),
            y: min(1 - halfVisible, max(halfVisible, center.y))
        )
    }

    /// The open file's own capture frame rate (`CineSetup.effectiveFrameRate`
    /// — prefers the 32-bit `SETUP.FrameRate` field, falls back to the
    /// legacy 16-bit one), or `nil` if neither is present. Mirrors what was
    /// just passed into `playbackController`'s own `captureFrameRate` at
    /// `open(url:)` time; exposed here too (not just on the controller)
    /// purely so `PlaybackToolbar` can show it in a tooltip without reaching
    /// through the controller for something that isn't really about
    /// playback state.
    @Published public private(set) var captureFrameRate: Double?
    /// Whether the post-demosaic color-correction matrix stage is applied.
    /// White balance (the pre-demosaic half of `cmCalib`'s decomposition) is
    /// applied unconditionally regardless of this flag — only the matrix
    /// stage toggles. Exists because the matrix stage's real, on-disk
    /// calibration data has been found to overshoot into a visible magenta
    /// cast on every sample file tested (see `ColorCalibration`'s doc
    /// comment) while white-balance-alone lands much closer to neutral, so
    /// this is a user-facing escape hatch rather than a further attempt at
    /// fixing the matrix math itself.
    @Published public private(set) var colorMatrixEnabled: Bool = true

    /// The active "Cine Colour" grading parameters (Brightness/Gain/
    /// Pedestal/Gamma-trim/Saturation/Flip Horizontal — see
    /// `GradingUniforms`), read by `CineMetalView.Coordinator` and passed
    /// through to `CineRenderer.render(...)`'s `grading` parameter, exactly
    /// the way `uniforms` already is.
    ///
    /// **Deliberately never persisted anywhere — not to `UserDefaults`, not
    /// to a sidecar file, and never written into the `.cine` file itself
    /// (which has no field for it) — and reset to `.identity` on every
    /// `open(url:)`** (see that method's own doc comment) — a deliberate
    /// asymmetry with `storedDebayerMode`/`storedColorMatrixEnabled` above,
    /// not an oversight to "fix" into matching them. Debayer mode and the
    /// color-matrix toggle are rendering-*fidelity* preferences: a single
    /// shooting setup's sensor/calibration characteristics are the same
    /// across every file opened in a session, so carrying them forward
    /// app-wide, to whatever's opened next, is the right default. A creative
    /// grade is different in kind — it's a per-shot artistic choice, not a
    /// fixed property of the camera/session — so carrying the
    /// PREVIOUSLY-open, unrelated clip's exact Brightness/Gain/Pedestal/etc.
    /// onto a freshly-opened file would be actively surprising, the same way
    /// no professional NLE auto-applies the last clip's grade to a
    /// newly-imported one. This grade's only lasting effect is whatever gets
    /// baked into a still/video export while it's dialed in
    /// (`StillExportCoordinator`/`VideoExportCoordinator`) — nothing else in
    /// the app writes it out anywhere.
    @Published public private(set) var grading: GradingUniforms = .identity

    /// The active "Color Temp" white-balance control, in Kelvin — NOT a
    /// `GradingUniforms` field (unlike `grading`'s 14 fields, this never
    /// gets uploaded to the shader directly): it's a CPU-side value that
    /// folds into the EXISTING pre-demosaic white-balance pipeline
    /// (`uniforms.wbGainR/G/B`, already read by `Tonemap.metal`'s
    /// `readClampedWB`) via `recomputeWhiteBalance()`, the same category as
    /// `colorMatrixEnabled` — a value that influences how `wbGain` gets
    /// computed, never uploaded itself. See `temperatureMultiplier(kelvin:)`.
    ///
    /// **Deliberately never persisted anywhere, and reset to `6500`
    /// (neutral) on every `open(url:)`** — mirrors `grading`'s own doc
    /// comment exactly: a creative white-balance adjustment is a per-shot
    /// artistic choice, not a fixed property of the camera/session, so
    /// carrying the PREVIOUSLY-open, unrelated clip's exact Color Temp onto
    /// a freshly-opened file would be actively surprising.
    @Published public private(set) var colorTempKelvin: Float = 6500

    /// The active WBCC (white-balance color-correction, the green/magenta
    /// axis) control. Like `colorTempKelvin` immediately above, this is a
    /// plain CPU-side value (not a `GradingUniforms` field) that folds into
    /// the existing pre-demosaic white balance via `recomputeWhiteBalance()`
    /// — see `wbccMultiplier(_:)` for the exact interpretation applied.
    ///
    /// **Deliberately never persisted anywhere, and reset to `0` (neutral)
    /// on every `open(url:)`** — same "per-shot, not a lingering app
    /// preference" reasoning as `grading`'s and `colorTempKelvin`'s own doc
    /// comments.
    @Published public private(set) var wbcc: Float = 0

    /// Whether the currently-open file's own recorded calibration
    /// (`CineSetup.colorCalibration`) was automatically overridden to
    /// identity at `open(url:)` time, because `CalibrationPlausibility`
    /// found that applying it to this file's actual frame 0 pixel data
    /// measurably pushed those statistics away from neutral rather than
    /// toward it (see that type's doc comment). Independent of, and applied
    /// *before*, the user's own manual `colorMatrixEnabled` toggle — this
    /// reflects only whether the automatic safety check itself fired, purely
    /// so the UI can surface *why* the matrix toggle might have no visible
    /// effect for this particular file. `false` for a file with no
    /// calibration at all (nothing to veto) just as much as for one whose
    /// calibration passed the check.
    @Published public private(set) var colorCalibrationVetoed: Bool = false

    /// Whether the metadata overlay HUD (`ContentView`'s corner panel) is
    /// shown atop the video view. Purely view-chrome — unlike
    /// `colorMatrixEnabled`/`uniforms`, toggling this never touches
    /// anything `CineMetalView` reads, so it has zero effect on
    /// rendering/playback either way. Initialized straight from
    /// `storedShowMetadataOverlay` in `init(device:)` (not deferred until
    /// `open(url:)`, unlike `colorMatrixEnabled`) since this toggle isn't
    /// per-file and is meaningful even with no file open yet (the ⌘I menu
    /// item's checked state should reflect the saved preference
    /// immediately).
    @Published public private(set) var showMetadataOverlay: Bool = false

    /// Whether the inspector sidebar (`ContentView`'s trailing-edge panel,
    /// today hosting the same dense per-file field list the on-video HUD
    /// used to show directly) is shown. Purely view-chrome, exactly like
    /// `showMetadataOverlay` — toggling this never touches anything
    /// `CineMetalView` reads either. Initialized straight from
    /// `storedShowInspectorSidebar` in `init(device:)` for the same reason
    /// `showMetadataOverlay` is: not per-file, and its title-bar
    /// button/menu item's state should reflect the saved preference
    /// immediately, even with no file open yet.
    @Published public private(set) var showInspectorSidebar: Bool = false

    /// Whether the file-browser sidebar (`ContentView`'s leading-edge
    /// directory-tree panel) is shown. Purely view-chrome, exactly like
    /// `showMetadataOverlay`/`showInspectorSidebar` — toggling this never
    /// touches anything `CineMetalView` reads either, and it's independent
    /// of whether a root folder has actually been chosen yet (an empty
    /// state with a "Choose Folder…" affordance is shown either way).
    /// Initialized straight from `storedShowFileBrowser` in `init(device:)`
    /// for the same reason `showInspectorSidebar` is: not per-file, and its
    /// title-bar button's state should reflect the saved preference
    /// immediately, even with no file open yet.
    @Published public private(set) var showFileBrowser: Bool = false

    /// The shared frame-numbering convention driving `PlaybackToolbar`'s
    /// counter, `MetadataOverlayView`'s on-video counter row, and
    /// `ScrubberView`'s three readouts consistently — see
    /// `FrameNumberingMode`'s own doc comment. Purely view-chrome, exactly
    /// like `showMetadataOverlay`/`showInspectorSidebar`/`showFileBrowser` —
    /// toggling this never touches anything `CineMetalView` reads either.
    /// Initialized straight from `storedFrameNumberingMode` in
    /// `init(device:)` for the same reason those three are: not per-file,
    /// and the toolbar picker's selection should reflect the saved
    /// preference immediately, even with no file open yet.
    @Published public private(set) var frameNumberingMode: FrameNumberingMode = .plain

    /// The file-browser sidebar's current root folder, or `nil` before any
    /// folder has ever been chosen. Restored at launch (see `init(device:)`)
    /// from `storedFileBrowserRootPath` when that saved path still exists on
    /// disk — only the root path itself is persisted, never the folder's
    /// contents, which are always re-enumerated fresh by
    /// `FileBrowserSidebarView` on demand.
    @Published public private(set) var fileBrowserRootURL: URL?

    /// Recently-opened `.cine` files, most-recently-opened first, capped at
    /// 10 entries. Backs the File menu's "Open Recent" submenu
    /// (`CinePlayerApp`). Restored at launch (see `init(device:)`) from
    /// `storedRecentFilePaths`, dropping any entry whose path no longer
    /// exists on disk — same "don't show a broken/missing entry" reasoning
    /// `fileBrowserRootURL`'s own restoration uses, just applied per-entry to
    /// a list instead of a single value.
    @Published public private(set) var recentFileURLs: [URL] = []

    /// The currently-loaded `.cube` LUT file's URL, or `nil` if none is
    /// loaded. Like `currentURL` (the open `.cine` file), this is never
    /// restored at launch — see `lutEnabled`'s doc comment just below for
    /// why that's a deliberate asymmetry with `recentLUTURLs`, not an
    /// oversight.
    @Published public private(set) var currentLUTURL: URL?

    /// The Metal 3D texture built from `currentLUTURL`'s parsed `CubeLUT`
    /// (via `LUTTexture.make(from:device:)`), or `nil` when no LUT is
    /// loaded. `CineMetalView.Coordinator` reads this (through its own
    /// stored copy, refreshed in `update(...)`) and passes it straight
    /// through to `CineRenderer.render(...)`'s `lutTexture` parameter; the
    /// two PNG/TIFF exporters (`FrameExporter`/`RangeExporter`) read it
    /// directly for the same purpose.
    @Published public private(set) var currentLUTTexture: MTLTexture?

    /// Whether the loaded LUT (`currentLUTTexture`) is actually applied to
    /// the render, independent of whether one is loaded at all — mirrors
    /// `colorMatrixEnabled`'s on/off-toggle shape exactly. Only meaningful
    /// once `currentLUTTexture != nil`; toggling this with none loaded is
    /// harmless (see `setLUTEnabled`) but has nothing to visibly show for
    /// it.
    ///
    /// Deliberately **not** persisted across launches, unlike
    /// `colorMatrixEnabled`/`storedDebayerMode` above: a fresh launch always
    /// starts with no LUT active, the same way it doesn't auto-open the last
    /// `.cine` file either. Only the *recent-LUTs list* (`recentLUTURLs`
    /// below) survives a relaunch — it remembers convenient shortcuts to
    /// reload from, exactly like `recentFileURLs`/"Open Recent" does for
    /// files, but re-applying one is always one deliberate click away, never
    /// automatic. Grading a whole session's footage through a specific
    /// creative LUT without ever being asked again would be a much more
    /// surprising default than "Open Recent" merely remembering a path.
    @Published public private(set) var lutEnabled: Bool = false

    /// Recently-loaded `.cube` LUT files, most-recently-loaded first, capped
    /// at **3** entries (not `recentFileURLs`'s 10 — this feature's own spec
    /// calls for a shorter list). Backs the inspector sidebar's "Recent
    /// LUTs" menu. Restored at launch (see `init(device:)`) from
    /// `storedRecentLUTPaths`, dropping any entry whose path no longer
    /// exists on disk — same reasoning `recentFileURLs`'s own restoration
    /// uses. See `lutEnabled`'s doc comment above for why persisting this
    /// list while never auto-reapplying `currentLUTTexture` itself is
    /// deliberate, not an inconsistency.
    @Published public private(set) var recentLUTURLs: [URL] = []

    /// The active `VideoExportCoordinator.exportVideo` run's progress, or
    /// `nil` when no export is in flight — `ExportProgressSheet` is shown
    /// exactly when this is non-`nil` (see `ContentView`'s `.sheet`).
    /// Unlike `showMetadataOverlay`/`showInspectorSidebar`/`showFileBrowser`
    /// above, this is deliberately **not** a persisted preference — it's
    /// transient UI state (a modal sheet's visibility, plus the object it
    /// displays), reset to `nil` every launch like any other one-off dialog.
    ///
    /// A plain `@Published` optional, not a separate `Bool` alongside a
    /// `@StateObject`-owned progress object, because the encode is already
    /// running (started by `VideoExportCoordinator` from a menu command,
    /// with no persistent SwiftUI view of its own to own `@StateObject`)
    /// by the time anything needs to observe it — the coordinator hands
    /// this document model the already-in-flight `MediaExportProgress`
    /// directly via `presentExportProgress(_:)`.
    @Published public private(set) var activeExportProgress: MediaExportProgress?

    /// The open file's sensor bit depth (`CineSetup.realBPP`), or `nil` if
    /// absent from this file's SETUP block. Exposed purely for the metadata
    /// overlay HUD; nothing else in the app reads it.
    @Published public private(set) var sensorBitDepth: Int?

    /// The open file's Color Filter Array pattern (`CineSetup.cfa`), or
    /// `nil` if absent. Exposed purely for the metadata overlay HUD — the
    /// live render pipeline gets its own CFA phase via `CFAPhase.forCFAPattern`
    /// at `open(url:)` time, independently of this.
    @Published public private(set) var cfaPattern: CFAPattern?

    /// The open file's shutter speed in nanoseconds (`CineSetup.shutterNs`),
    /// or `nil` if absent. Exposed purely for the metadata overlay HUD, which
    /// converts this to a human-readable µs/ms string.
    @Published public private(set) var shutterNs: UInt32?

    /// The open file's camera model string (`CineSetup.cameraModel`), or
    /// `nil` if absent. Can also be present-but-empty (an all-zero field
    /// within `Setup.Length`, decoded as `""` by `DataReader.fixedString`)
    /// — most real files don't have this populated either way, so the
    /// overlay treats both `nil` and `""` as "omit the row" rather than
    /// showing a blank/placeholder value.
    @Published public private(set) var cameraModel: String?

    /// Human-readable label for the open file's pixel-data compression
    /// (`BitmapInfoHeader.compression`) — e.g. "Uncompressed"/"P10"/"P12L"
    /// — rather than the raw `biCompression` integer. Exposed purely for
    /// the metadata overlay HUD; empty until a file has been opened.
    @Published public private(set) var compressionLabel: String = ""

    /// Retained so the cache (and therefore every decode) stays alive for
    /// as long as the document is open; not otherwise read directly.
    private var cache: DecodedFrameCache?

    /// Retained purely so `handleSeek(frameIndex:)` can look up a frame's
    /// on-disk byte offset (`CineFile.byteOffset(ofFrame:)`) to bias a
    /// still-in-flight file-cache warm toward — `open(url:)`'s own decode/
    /// render path never reads this directly (it goes through `cache`
    /// instead, per this type's own doc comment on there being exactly one
    /// decode+upload path).
    private var cineFile: CineFile?

    /// Whether a `primeFileCache(at:)` background warm is currently running
    /// for the open file — drives `FileCachingIndicatorView`. `true` for the
    /// whole time between a fresh `open(url:)`'s initial warm kicking off
    /// and either it (or the last `handleSeek`-triggered re-bias that
    /// superseded it) finishing.
    @Published public private(set) var isPrimingFileCache: Bool = false

    /// The in-flight `primeFileCache(at:)` background warm for whichever
    /// file is currently (or was most recently) open — retained only so a
    /// fresh `open(url:)` call can cancel a still-running previous one.
    /// Cancelling matters because a stale prime for a file the user has
    /// already navigated away from would otherwise keep competing for disk
    /// I/O against the new file's own warm-up and decode traffic for no
    /// benefit to anyone.
    private var pageCachePrimeTask: Task<Void, Never>?

    /// Bumped every time `startFileCachePrime(at:startOffset:)` starts a new
    /// warm (the initial one in `open(url:)`, or a `handleSeek` re-bias) —
    /// lets `finishFileCachePrime(generation:)` tell whether the task that
    /// just finished is still the one in charge before clearing
    /// `isPrimingFileCache`, so a stale/cancelled warm finishing late can't
    /// flip the indicator back off after a newer warm already turned it back
    /// on.
    private var pageCachePrimeGeneration: Int = 0

    /// The frame index `handleSeek` last re-biased the file-cache warm
    /// toward (or `0`, meaning "the front of the file," right after
    /// `open(url:)`'s own initial front-to-back warm starts). Reset to `0`
    /// whenever a new file opens so a previous file's bias point can't
    /// suppress the new file's first legitimate re-bias.
    private var lastPrimeBiasFrameIndex: Int = 0

    /// A seek smaller than this many frames stays well within
    /// `DecodedFrameCache`'s own bounded prefetch window (its default
    /// `capacity`/`prefetch(around:direction:radius:)` — see that type's own
    /// doc comment), so it isn't worth restarting a background disk read
    /// over. Only a jump bigger than this means the user has moved
    /// somewhere the existing warm/prefetched working set doesn't cover.
    private static let primeRebiasFrameThreshold = 60

    /// The current file's real decomposed calibration (white balance +
    /// matrix), independent of whether `colorMatrixEnabled` is currently
    /// applying the matrix half of it — retained so `setColorMatrixEnabled`
    /// can toggle the matrix on/off without re-opening the file or losing
    /// the white-balance gains it must keep applying either way.
    private var fileColorCalibration: ColorCalibration = .identity

    /// Persists the last-selected debayer mode as a single, app-wide
    /// preference (not per-file) — every newly-opened file starts on
    /// whichever mode was last chosen, rather than always resetting to a
    /// fixed mode. Deliberately app-wide rather than remembered per-file: for
    /// a single camera/shooting setup the right mode is almost always the
    /// same across every file opened in a session, and per-file memory
    /// would need a whole separate keyed-storage design for a benefit most
    /// users won't need — if that turns out wrong in practice, this is the
    /// one place to revisit.
    ///
    /// Defaults to `.highQuality` (the best real demosaic mode) when no
    /// preference has ever been saved — a freshly-opened file should show a
    /// genuine, accurate color image out of the box (High Quality demosaic +
    /// white balance + color matrix, together targeting Rec.709, all default
    /// on), not the diagnostic raw grayscale mosaic. Getting this default
    /// right takes an explicit "is a preference actually saved?" check (the
    /// same pattern `storedColorMatrixEnabled` already uses just below) —
    /// `UserDefaults.integer(forKey:)` alone returns `0` for a key that was
    /// never set, and `0` is `DebayerMode.rawSensor.rawValue`, which is
    /// exactly the trap that made Raw Sensor the accidental default before
    /// this. Checking `object(forKey:) != nil` first means a *deliberately*
    /// saved preference of Raw Sensor (a real, valid raw value of `0`) is
    /// still correctly distinguished from "nothing saved yet" and honored.
    private static let debayerModeDefaultsKey = "CinePlayer.lastDebayerMode"

    private static var storedDebayerMode: DebayerMode {
        get {
            guard UserDefaults.standard.object(forKey: debayerModeDefaultsKey) != nil else {
                return .highQuality
            }
            let raw = UInt32(UserDefaults.standard.integer(forKey: debayerModeDefaultsKey))
            return DebayerMode(rawValue: raw) ?? .highQuality
        }
        set { UserDefaults.standard.set(Int(newValue.rawValue), forKey: debayerModeDefaultsKey) }
    }

    /// Persists the last-selected color-matrix toggle the same way
    /// `storedDebayerMode` persists its own choice — app-wide, not per-file,
    /// for the same reason (a single shooting setup's calibration behavior
    /// is unlikely to need per-file memory). Defaults to `true` (matrix on,
    /// today's existing behavior) when no preference has been saved yet —
    /// `UserDefaults.bool(forKey:)` alone would default an unset key to
    /// `false`, which would silently flip every fresh install's default.
    private static let colorMatrixEnabledDefaultsKey = "CinePlayer.colorMatrixEnabled"

    private static var storedColorMatrixEnabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: colorMatrixEnabledDefaultsKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: colorMatrixEnabledDefaultsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: colorMatrixEnabledDefaultsKey) }
    }

    /// Persists the metadata-overlay-HUD toggle the same way
    /// `storedColorMatrixEnabled`/`storedDebayerMode` persist theirs —
    /// app-wide, not per-file (whether the HUD is on is a viewing
    /// preference, not something tied to any one clip). Defaults to
    /// `false` (hidden) for an unset key — unlike `storedColorMatrixEnabled`,
    /// no explicit "is the key even present" check is needed here, since
    /// `UserDefaults.bool(forKey:)`'s own built-in default for an absent key
    /// (`false`) already matches the desired default, so existing users
    /// never see this HUD appear unasked-for after an update.
    private static let showMetadataOverlayDefaultsKey = "CinePlayer.showMetadataOverlay"

    private static var storedShowMetadataOverlay: Bool {
        get { UserDefaults.standard.bool(forKey: showMetadataOverlayDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: showMetadataOverlayDefaultsKey) }
    }

    /// Persists the inspector-sidebar toggle the same way
    /// `storedShowMetadataOverlay` persists its own — app-wide, defaulting
    /// to `false` (hidden) for an unset key, for the identical reason: an
    /// absent key's `UserDefaults.bool(forKey:)` default (`false`) already
    /// matches the desired default, so existing users never see this
    /// sidebar appear unasked-for after an update.
    private static let showInspectorSidebarDefaultsKey = "CinePlayer.showInspectorSidebar"

    private static var storedShowInspectorSidebar: Bool {
        get { UserDefaults.standard.bool(forKey: showInspectorSidebarDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: showInspectorSidebarDefaultsKey) }
    }

    /// Persists the file-browser-sidebar toggle the same way
    /// `storedShowInspectorSidebar` persists its own — app-wide, defaulting
    /// to `false` (hidden) for an unset key, for the identical reason: an
    /// absent key's `UserDefaults.bool(forKey:)` default (`false`) already
    /// matches the desired default, so existing users never see this
    /// sidebar appear unasked-for after an update.
    private static let showFileBrowserDefaultsKey = "CinePlayer.showFileBrowser"

    private static var storedShowFileBrowser: Bool {
        get { UserDefaults.standard.bool(forKey: showFileBrowserDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: showFileBrowserDefaultsKey) }
    }

    /// Persists the frame-numbering-mode preference the same way
    /// `storedDebayerMode` persists its own non-boolean choice — app-wide,
    /// not per-file (a viewing preference, not something tied to any one
    /// clip), defaulting to `.plain` (today's pre-existing "Frame N /
    /// Total" convention) when no preference has been saved yet.
    private static let frameNumberingModeDefaultsKey = "CinePlayer.frameNumberingMode"

    private static var storedFrameNumberingMode: FrameNumberingMode {
        get {
            let raw = UInt32(UserDefaults.standard.integer(forKey: frameNumberingModeDefaultsKey))
            return FrameNumberingMode(rawValue: raw) ?? .plain
        }
        set { UserDefaults.standard.set(Int(newValue.rawValue), forKey: frameNumberingModeDefaultsKey) }
    }

    /// Persists the file-browser sidebar's chosen root folder as a plain
    /// path string — safe with no security-scoped bookmark machinery since
    /// this app is explicitly unsandboxed (see the project's own plan/
    /// README). `nil` (key absent) means no folder has ever been chosen.
    /// Only the path itself is ever stored — never a directory listing —
    /// so a relaunch always re-enumerates the restored root fresh from
    /// disk rather than trusting stale cached contents.
    private static let fileBrowserRootPathDefaultsKey = "CinePlayer.fileBrowserRootPath"

    private static var storedFileBrowserRootPath: String? {
        get { UserDefaults.standard.string(forKey: fileBrowserRootPathDefaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: fileBrowserRootPathDefaultsKey) }
    }

    /// Persists the "Open Recent" list as a plain array of path strings —
    /// same "no sandboxing, no security-scoped bookmark needed" reasoning as
    /// `storedFileBrowserRootPath` (this app is explicitly unsandboxed).
    /// Stored most-recently-opened first, already capped at 10 entries by
    /// the time it's written (see `recordRecentFile`).
    private static let recentFilesDefaultsKey = "CinePlayer.recentFiles"

    private static var storedRecentFilePaths: [String] {
        get { UserDefaults.standard.array(forKey: recentFilesDefaultsKey) as? [String] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: recentFilesDefaultsKey) }
    }

    /// Persists the "Recent LUTs" list the same way `storedRecentFilePaths`
    /// persists its own — a plain array of path strings, no security-scoped
    /// bookmark machinery needed (this app is unsandboxed). Stored
    /// most-recently-loaded first, already capped at 3 entries by the time
    /// it's written (see `recordRecentLUT`) — 3, not `recentFileURLs`'s 10,
    /// per this feature's own spec. Its own separate key/list: loading a
    /// LUT is never recorded into `storedRecentFilePaths`, and opening a
    /// `.cine` file is never recorded here.
    private static let recentLUTsDefaultsKey = "CinePlayer.recentLUTs"

    private static var storedRecentLUTPaths: [String] {
        get { UserDefaults.standard.array(forKey: recentLUTsDefaultsKey) as? [String] ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: recentLUTsDefaultsKey) }
    }

    /// Readable label for a `BitmapCompression` value, for the metadata
    /// overlay HUD — e.g. "P10" rather than the raw `biCompression`
    /// integer (256). `.unknown` is a real, if rare, possibility (an exotic
    /// or future camera-software revision), so it's rendered with its raw
    /// value rather than treated as a parsing failure.
    private static func compressionLabel(for compression: BitmapCompression) -> String {
        switch compression {
        case .uncompressed: return "Uncompressed"
        case .p10Packed: return "P10"
        case .p12LPacked: return "P12L"
        case .unknown(let raw): return "Unknown (\(raw))"
        }
    }

    /// `calibration` with its matrix half forced to identity when `enabled`
    /// is `false` — white balance always passes through unchanged, since
    /// `colorMatrixEnabled` only ever toggles the post-demosaic matrix
    /// stage, never white balance.
    private static func effectiveCalibration(_ calibration: ColorCalibration, matrixEnabled: Bool) -> ColorCalibration {
        guard !matrixEnabled else { return calibration }
        return ColorCalibration(
            whiteBalanceR: calibration.whiteBalanceR,
            whiteBalanceG: calibration.whiteBalanceG,
            whiteBalanceB: calibration.whiteBalanceB,
            matrix: ColorCalibration.identity.matrix
        )
    }

    /// The neutral reference point `colorTempKelvin`'s slider is normalized
    /// against — matches its own default/neutral value exactly, so
    /// `temperatureMultiplier(kelvin: referenceColorTempKelvin)` is
    /// guaranteed `(1, 1, 1)`.
    private static let referenceColorTempKelvin: Float = 6500

    /// The Tanner Helland blackbody-radiator RGB approximation — a
    /// well-known, widely-used approximate formula for converting a color
    /// temperature in Kelvin to an sRGB-ish illuminant color, used broadly
    /// for exactly this "camera white balance temperature slider" purpose.
    /// Ported verbatim (only the language changed); not independently
    /// re-derived here. Never returns 0 on any channel across the useful
    /// ~1000-40000K range this control's slider spans, by the formula's own
    /// shape — see `temperatureMultiplier(kelvin:)` for why its caller
    /// still guards the divisor defensively anyway.
    private static func blackbodyRGB(kelvin: Float) -> (r: Float, g: Float, b: Float) {
        let temp = kelvin / 100
        var r: Float, g: Float, b: Float

        if temp <= 66 {
            r = 255
        } else {
            r = 329.698727446 * pow(temp - 60, -0.1332047592)
        }
        r = min(max(r, 0), 255)

        if temp <= 66 {
            g = 99.4708025861 * log(temp) - 161.1195681661
        } else {
            g = 288.1221695283 * pow(temp - 60, -0.0755148492)
        }
        g = min(max(g, 0), 255)

        if temp >= 66 {
            b = 255
        } else if temp <= 19 {
            b = 0
        } else {
            b = 138.5177312231 * log(temp - 10) - 305.0447927307
        }
        b = min(max(b, 0), 255)

        return (r, g, b)
    }

    /// The per-channel white-balance gain multiplier for `colorTempKelvin`
    /// — ratio-normalized against `referenceColorTempKelvin` (6500K) so the
    /// reference point is a TRUE, provable no-op:
    /// `temperatureMultiplier(kelvin: referenceColorTempKelvin)` is exactly
    /// `(1, 1, 1)` by construction (a ratio of two identical values, not an
    /// approximation of one). Computed as
    /// `blackbodyRGB(reference) / blackbodyRGB(kelvin)` per channel — i.e.
    /// the gain that divides out how far `kelvin`'s own blackbody illuminant
    /// color sits from the neutral 6500K reference, pushing the image back
    /// toward it (the same direction any white-balance gain works). Guards
    /// the divisor with a small epsilon defensively — `blackbodyRGB`'s
    /// outputs are never actually 0 for any channel in the useful range (see
    /// its own doc comment), but a division is still worth guarding rather
    /// than trusting that shape blindly.
    private static func temperatureMultiplier(kelvin: Float) -> (r: Float, g: Float, b: Float) {
        let epsilon: Float = 1e-6
        let reference = blackbodyRGB(kelvin: referenceColorTempKelvin)
        let target = blackbodyRGB(kelvin: kelvin)
        return (
            r: reference.r / max(target.r, epsilon),
            g: reference.g / max(target.g, epsilon),
            b: reference.b / max(target.b, epsilon)
        )
    }

    /// WBCC (white-balance color-correction, the green/magenta axis)'s
    /// multiplier — applied ONLY to the green channel's combined gain;
    /// red/blue are untouched by this control. Interpreted as a
    /// percentage-like green-channel shift (`1 + wbcc / 100`): no
    /// authoritative source publishes Vision Research's own exact WBCC
    /// scale, so this is a reasonable, clearly-documented interpretation
    /// given the reference material this whole panel is modeled on — not
    /// presented as certainly correct. (Its own documented example value,
    /// 17.743, is a plausible real value under this reading — roughly an
    /// 18% green push.) By construction, `wbccMultiplier(0) == 1` exactly, a
    /// true no-op.
    private static func wbccMultiplier(_ wbcc: Float) -> Float {
        1 + wbcc / 100
    }

    public init(device: MTLDevice) {
        self.device = device
        self.showMetadataOverlay = Self.storedShowMetadataOverlay
        self.showInspectorSidebar = Self.storedShowInspectorSidebar
        self.showFileBrowser = Self.storedShowFileBrowser
        self.frameNumberingMode = Self.storedFrameNumberingMode

        // Restore the last-chosen root folder only if it still exists on
        // disk — a saved path pointing at a folder that's since been moved,
        // renamed, or deleted is silently dropped rather than shown as a
        // broken/empty root.
        if let storedPath = Self.storedFileBrowserRootPath,
           FileManager.default.fileExists(atPath: storedPath) {
            self.fileBrowserRootURL = URL(fileURLWithPath: storedPath)
        }

        // Restore the recent-files list, silently dropping any entry whose
        // path no longer exists on disk — same reasoning as
        // `fileBrowserRootURL`'s restoration just above, applied per-entry.
        self.recentFileURLs = Self.storedRecentFilePaths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }

        // Restore the recent-LUTs list the same way, capped at 3 — but
        // deliberately NOT restoring `currentLUTTexture`/`lutEnabled`
        // themselves: see `lutEnabled`'s own doc comment for why a fresh
        // launch always starts with no LUT active regardless of what this
        // list remembers.
        self.recentLUTURLs = Self.storedRecentLUTPaths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// Opens `url` as a `.cine` file, constructs its cache + playback
    /// controller, and decodes+uploads frame 0 through that cache before
    /// returning. Throws if the file can't be opened, frame 0 can't be
    /// decoded, or the GPU texture can't be created — in every failure case
    /// none of this model's published state is touched, so a failed `open`
    /// leaves whatever was previously open (or the empty state) intact.
    public func open(url: URL) async throws {
        // Stop the outgoing file's playback loop before swapping in a new
        // cache/controller. `PlaybackController.play()`'s Task closure binds
        // a strong `self` for the lifetime of its loop, so without this the
        // old controller (and therefore its `DecodedFrameCache`/`CineFile`)
        // stays alive and keeps decoding/advancing in the background even
        // after `self.playbackController` below points at the new file.
        self.playbackController?.pause()

        // Fired off before `CineFile(url:)` even runs: this needs nothing
        // but the URL, so there's no reason to wait for header parsing (or
        // anything else) before letting the OS start racing the disk. See
        // `primeFileCache(at:)`'s doc comment for why this matters and
        // `startFileCachePrime(at:startOffset:)`'s for why the previous one
        // is cancelled first. No bias (`startOffset` defaults to `0`): a
        // freshly opened file always starts at frame 0, so front-to-back is
        // already the right order here — `handleSeek(frameIndex:)` is what
        // re-biases this if the user jumps elsewhere before it finishes.
        startFileCachePrime(at: url)

        let cineFile = try CineFile(url: url)
        // A one-time, one-frame direct decode (bypassing the cache) purely
        // so `CalibrationPlausibility` has real pixel data to sanity-check
        // this file's own calibration against, before anything is rendered.
        // Not retained afterward — `DecodedFrameCache` never exposes raw
        // `DecodedFrame` pixel data once uploaded (see its own doc comment),
        // so this is the only way to get it. The cache's own separate decode
        // of frame 0 for actual GPU display, later in this function, still
        // happens independently of this.
        let firstFrame = try cineFile.decodeFrame(at: 0)
        let cache = DecodedFrameCache(cineFile: cineFile, device: device)
        let captureFrameRate = cineFile.setup.effectiveFrameRate
        // Default the review/playback rate to the file's own recorded
        // `SETUP.fPbRate` when present, rather than an arbitrary fixed
        // 30fps -- see `CineSetup.pbRate`'s doc comment: this is the
        // camera's own "video system" review-rate setting (e.g. VEO
        // cameras' 1080p24/25/30 menu option), distinct from
        // `captureFrameRate` above. Matching it here is what makes this
        // app's default review speed agree with professional editing
        // software's behavior for the same file (per direct user report,
        // files from a camera set to "1080/24p" are interpreted as exactly
        // 24.00fps there) instead of an always-30 default that has nothing
        // to do with the file itself.
        //
        // Guarded by `> 0` exactly like `captureFrameRate`'s own guard in
        // `PlaybackController.playRealTime(forward:)` -- a malformed or
        // garbage stored value falls back to the same 30fps default as a
        // genuinely-absent field, rather than being trusted blindly.
        let reviewFPS = cineFile.setup.pbRate.map(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 30
        let controller = PlaybackController(
            frameCount: cineFile.frameCount,
            cache: cache,
            reviewFPS: reviewFPS,
            captureFrameRate: captureFrameRate,
            firstImageNo: Int(cineFile.header.firstImageNo)
        )

        let levels = cineFile.setup.effectiveBlackWhiteLevels
        let cfaPhase = CFAPhase.forCFAPattern(cineFile.setup.cfa)
        // Falls back to a no-op calibration for files without usable
        // `cmCalib` metadata — see `CineSetup.colorCalibration`'s doc
        // comment. Then run through the same automatic plausibility veto
        // `cine-diagnostic` already applies (`CalibrationPlausibility`, via
        // `ExposureUniforms.init(setup:frame:debayerMode:)`) — using
        // `firstFrame`'s real pixel data, decoded just above — so a file
        // whose recorded calibration measurably pushes its own footage away
        // from neutral falls back to identity here too, not just in the CLI
        // tool. Retained as-is (matrix included, post-veto) in
        // `fileColorCalibration` regardless of the matrix toggle below, so
        // switching it back on later doesn't need this file reopened.
        let rawCalibration = cineFile.setup.colorCalibration ?? .identity
        let calibration = CalibrationPlausibility.vetoedCalibration(
            rawCalibration,
            frame: firstFrame,
            cfaPhase: cfaPhase,
            blackLevel: Float(levels.black),
            whiteLevel: Float(levels.white)
        )
        let matrixEnabled = Self.storedColorMatrixEnabled
        // `colorCalibration` is left at its `.identity` default here —
        // `wbGainR/G/B`/`colorMatrix` are set for real, just below, by the
        // one call to `recomputeWhiteBalance()` that also folds in
        // `colorTempKelvin`/`wbcc` (freshly reset to neutral for this newly
        // opened file). That keeps the white-balance/color-matrix
        // computation itself living in exactly one place
        // (`recomputeWhiteBalance()`), rather than duplicating
        // `effectiveCalibration(...)` inline here too.
        let uniforms = ExposureUniforms(
            blackLevel: Float(levels.black),
            whiteLevel: Float(levels.white),
            // `CineFile.needsVerticalFlip` and `DecodedFrame.needsVerticalFlip`
            // are always the same value (the latter is copied from the
            // former at decode time) — using the file-level accessor here
            // means we don't need an actual decoded frame in hand just to
            // read a per-file constant.
            flipVertically: cineFile.needsVerticalFlip,
            // Restores whichever debayer mode was last selected (app-wide,
            // not per-file) — see `storedDebayerMode`'s doc comment.
            debayerMode: Self.storedDebayerMode,
            cfaPhase: cfaPhase,
            gamma: cineFile.setup.fGamma ?? 2.2
        )

        // The single decode+upload path: goes through the cache exactly the
        // way `PlaybackController.currentTexture()` will for every frame
        // after this one.
        _ = try await cache.texture(at: 0)

        self.currentURL = url
        self.cache = cache
        self.cineFile = cineFile
        self.lastPrimeBiasFrameIndex = 0
        self.currentHistogram = nil
        controller.onSeek = { [weak self] frameIndex in
            self?.handleSeek(frameIndex: frameIndex)
        }
        self.playbackController = controller
        self.frameWidth = cineFile.bitmapInfo.width
        self.frameHeight = cineFile.bitmapInfo.height
        self.fileColorCalibration = calibration
        self.colorCalibrationVetoed = rawCalibration != calibration
        self.colorMatrixEnabled = matrixEnabled
        self.uniforms = uniforms
        // Every newly-opened file starts with a neutral grade, regardless of
        // what was dialed in on whatever was open before — see `grading`'s
        // own doc comment for why this is a deliberate asymmetry with
        // `colorMatrixEnabled`/`storedDebayerMode` just above, not an
        // oversight. Grading is purely live/session state: it's never
        // written back into the `.cine` file (the format has no field for
        // it) and never persisted to a sidecar of any kind — its only
        // lasting effect is whatever gets baked into a still/video export
        // while it's dialed in. `overwriteCurrentFile` below carries the
        // current grade across its own internal reopen explicitly, since
        // that reopen isn't the user opening a different file.
        self.grading = .identity
        // Same "per-shot, not a lingering app preference" reasoning as
        // `grading` immediately above — see `colorTempKelvin`/`wbcc`'s own
        // doc comments.
        self.colorTempKelvin = 6500
        self.wbcc = 0
        // Same reset-on-every-open treatment as grading/colorTempKelvin/wbcc
        // above; see `zoomScale`'s own doc comment. Unanimated
        // (`animated: false`): opening a file has nothing for a zoom
        // transition to visibly settle from/to that would read as
        // intentional, unlike a real in-place Zoom In/Out/Actual Size action.
        setZoomScale(Self.minZoomScale, animated: false)
        // Computes the real `uniforms.wbGainR/G/B`/`colorMatrix` for this
        // file, now that `fileColorCalibration`/`colorMatrixEnabled`/
        // `colorTempKelvin`/`wbcc` are all set above — see
        // `recomputeWhiteBalance()`'s own doc comment for why this is the
        // one place that computation happens.
        recomputeWhiteBalance()
        self.captureFrameRate = captureFrameRate
        self.sensorBitDepth = cineFile.setup.realBPP.map(Int.init)
        self.cfaPattern = cineFile.setup.cfa
        self.shutterNs = cineFile.setup.shutterNs
        self.cameraModel = cineFile.setup.cameraModel
        self.compressionLabel = Self.compressionLabel(for: cineFile.bitmapInfo.compression)
        recordRecentFile(url)
        revealContainingFolderIfNeeded(for: url)
    }

    /// Cancels whatever file-cache warm is currently in flight and starts a
    /// fresh one, optionally biased to begin at `startOffset` instead of the
    /// front of the file. Used both for the initial warm `open(url:)` kicks
    /// off (no bias — frame 0 is always where a freshly opened file starts)
    /// and for `handleSeek(frameIndex:)`'s re-bias when the user jumps
    /// elsewhere while that initial warm is still running.
    private func startFileCachePrime(at url: URL, startOffset: Int = 0) {
        pageCachePrimeTask?.cancel()
        pageCachePrimeGeneration += 1
        let generation = pageCachePrimeGeneration
        isPrimingFileCache = true
        pageCachePrimeTask = Task.detached(priority: .utility) { [weak self] in
            await primeFileCache(at: url, startOffset: startOffset)
            await self?.finishFileCachePrime(generation: generation)
        }
    }

    /// Clears `isPrimingFileCache` only if no newer warm (a fresh
    /// `open(url:)`, or a `handleSeek` re-bias) has superseded this one in
    /// the meantime — without this guard, a stale/cancelled warm finishing
    /// late could flip the indicator back off right after a newer one
    /// already turned it back on.
    private func finishFileCachePrime(generation: Int) {
        guard pageCachePrimeGeneration == generation else { return }
        isPrimingFileCache = false
    }

    /// `PlaybackController.onSeek`'s target: re-biases the still-in-flight
    /// file-cache warm toward wherever the user just jumped, rather than
    /// leaving it to grind through the file strictly front-to-back — the
    /// scenario this exists for is opening a large file on slow (e.g.
    /// external/network) storage and immediately scrubbing into the middle
    /// of it, before the initial warm has caught up that far on its own.
    /// Only acts while a warm is actually still running
    /// (`isPrimingFileCache`) — once the whole file is already page-cache-
    /// resident there's nothing left to bias toward. Only acts on jumps
    /// bigger than `primeRebiasFrameThreshold`; see that constant's own doc
    /// comment. Silently no-ops if the byte-offset lookup fails (e.g. a
    /// stale callback from a controller belonging to a file that's since
    /// been closed) — the in-flight warm simply continues wherever it was,
    /// exactly as if this had never fired.
    private func handleSeek(frameIndex: Int) {
        guard isPrimingFileCache, let cineFile, let currentURL else { return }
        guard abs(frameIndex - lastPrimeBiasFrameIndex) > Self.primeRebiasFrameThreshold else { return }
        guard let byteOffset = try? cineFile.byteOffset(ofFrame: frameIndex) else { return }
        lastPrimeBiasFrameIndex = frameIndex
        startFileCachePrime(at: currentURL, startOffset: byteOffset)
    }

    /// Switches the live display's debayer mode. Only touches `uniforms`
    /// (specifically, `uniforms.debayerMode`) — the raw texture already
    /// resident in `DecodedFrameCache` is never re-decoded or re-uploaded
    /// just because how it's *interpreted* for display changed, so this is
    /// cheap enough to call on every picker selection.
    public func setDebayerMode(_ mode: DebayerMode) {
        Self.storedDebayerMode = mode
        guard uniforms.debayerMode != mode.rawValue else { return }
        uniforms.debayerMode = mode.rawValue
    }

    /// The single place `uniforms.wbGainR/G/B`/`colorMatrix` are ever
    /// computed — called by `setColorMatrixEnabled`, `setColorTemp`,
    /// `setWBCC`, and `open(url:)` alike, so those four call sites can never
    /// drift out of sync with each other. Starts from
    /// `effectiveCalibration(fileColorCalibration, matrixEnabled:
    /// colorMatrixEnabled)` (the existing base white-balance + matrix,
    /// unchanged), then folds in `colorTempKelvin`/`wbcc` as additional
    /// pre-demosaic white-balance multipliers — Color Temp/WBCC are white
    /// balance adjustments, so they apply to `wbGainR/G/B` alongside the
    /// file's own calibration, never touching `colorMatrix` (that stays a
    /// purely post-demosaic, Color-Matrix-toggle-only concern, exactly as
    /// before).
    private func recomputeWhiteBalance() {
        let calibration = Self.effectiveCalibration(fileColorCalibration, matrixEnabled: colorMatrixEnabled)
        let tempMult = Self.temperatureMultiplier(kelvin: colorTempKelvin)
        let wbccMult = Self.wbccMultiplier(wbcc)
        uniforms.wbGainR = calibration.whiteBalanceR * tempMult.r
        uniforms.wbGainG = calibration.whiteBalanceG * tempMult.g * wbccMult
        uniforms.wbGainB = calibration.whiteBalanceB * tempMult.b
        uniforms.colorMatrix = ColorMatrix3x3(rowMajor: calibration.matrix)
    }

    /// Toggles the post-demosaic color-matrix stage on/off, leaving white
    /// balance untouched either way — see `colorMatrixEnabled`'s doc
    /// comment. Like `setDebayerMode`, this only ever touches `uniforms`
    /// (specifically its `wbGain*`/`colorMatrix` fields, both recomputed by
    /// `recomputeWhiteBalance()`) — the raw texture already resident in
    /// `DecodedFrameCache` is never re-decoded or re-uploaded.
    public func setColorMatrixEnabled(_ enabled: Bool) {
        Self.storedColorMatrixEnabled = enabled
        guard colorMatrixEnabled != enabled else { return }
        colorMatrixEnabled = enabled
        recomputeWhiteBalance()
    }

    /// Sets the "Color Temp" white-balance control (in Kelvin) — folds into
    /// the existing pre-demosaic white-balance gains via
    /// `recomputeWhiteBalance()`. Like `setColorMatrixEnabled`, this only
    /// ever touches `uniforms` (specifically `wbGainR/G/B`) — the raw
    /// texture already resident in `DecodedFrameCache` is never re-decoded
    /// or re-uploaded, so this is cheap enough to call on every slider tick.
    public func setColorTemp(_ kelvin: Float) {
        guard colorTempKelvin != kelvin else { return }
        colorTempKelvin = kelvin
        recomputeWhiteBalance()
    }

    /// Sets the WBCC (green/magenta) white-balance control — see `wbcc`'s
    /// own doc comment and `wbccMultiplier(_:)` for the exact
    /// interpretation applied. Same shape as `setColorTemp` in every other
    /// respect.
    public func setWBCC(_ value: Float) {
        guard wbcc != value else { return }
        wbcc = value
        recomputeWhiteBalance()
    }

    /// Sets the active "Cine Colour" grading parameters wholesale — the
    /// inspector sidebar's per-field sliders/toggles each read+write through
    /// this one setter (see `InspectorSidebarView`'s `gradingBinding` helper)
    /// rather than exposing 14 individual per-field setters. Guarded by the
    /// same no-op equality check `setDebayerMode`/`setColorMatrixEnabled`
    /// use. Never touches the raw texture already resident in
    /// `DecodedFrameCache` — like those two, this only changes how the
    /// existing texture is *rendered*, so it's cheap enough to call on every
    /// slider tick.
    public func setGrading(_ newValue: GradingUniforms) {
        guard grading != newValue else { return }
        grading = newValue
    }

    /// Re-renders the current frame at a small offscreen size and rebins it
    /// into `currentHistogram` — call this (via `.task(id:)`, so a rapid
    /// run of calls naturally supersedes rather than queues) whenever the
    /// displayed frame or anything that changes how it's rendered
    /// (`grading`, Color Temp/WBCC, debayer mode, Color Matrix, LUT
    /// enablement) changes. Uses the *live* grading/LUT state, matching how
    /// a real raw-editing tool's histogram always reflects current edits,
    /// not the file's untouched original.
    ///
    /// Deliberately runs its render+readback+bin work directly on this
    /// `@MainActor` method rather than hopping off-actor the way
    /// `DecodedFrameCache` does for full-resolution decode/upload work: at
    /// the small fixed size `FrameHistogramComputer` renders (128×128,
    /// independent of the source frame's native resolution), the GPU
    /// round-trip this performs is small enough not to need it. Revisit if
    /// real profiling ever shows otherwise — this is an intentional,
    /// documented simplicity-over-throughput choice, not an oversight.
    public func recomputeHistogram() async {
        guard let playbackController, let renderer = histogramRenderer else { return }
        do {
            let rawTexture = try await playbackController.currentTexture()
            guard !Task.isCancelled else { return }
            let histogram = try FrameHistogramComputer.compute(
                rawTexture: rawTexture,
                uniforms: uniforms,
                grading: grading,
                renderer: renderer,
                device: device,
                lutTexture: lutEnabled ? currentLUTTexture : nil
            )
            guard !Task.isCancelled else { return }
            currentHistogram = histogram
        } catch {
            // Best-effort: a failed/cancelled recompute just leaves
            // whatever histogram was already showing rather than surfacing
            // an error the user never asked to see, or flashing to blank.
        }
    }

    /// A one-shot "Auto" exposure adjustment (the same shape as Adobe Camera
    /// Raw's "Auto" button next to its Basic panel — see this app's own
    /// "Cine Colour" section doc comment): analyzes the frame with grading
    /// at `.identity` (never the *currently already-adjusted* picture — an
    /// Auto action should propose a fresh, independent read of the source
    /// image, not compound onto whatever the user already dialed in) and
    /// sets `GradingUniforms.brightness` to move the frame's mean encoded
    /// luma toward a conventional "well-exposed" middle-gray-ish target.
    ///
    /// Deliberately only touches `brightness` (a single additive term in the
    /// already-gamma-encoded domain — see `GradingUniforms`'s own doc
    /// comment) rather than also solving for `gain`/`pedestal` (which apply
    /// in the *linear* domain, before gamma): a full multi-parameter
    /// highlights/shadows/whites/blacks-style auto-tone would need to
    /// account for that domain difference to be correct, which is real,
    /// unverified additional complexity — a single well-reasoned brightness
    /// shift is a genuine, correct "Auto" that's honest about its own scope
    /// rather than a more ambitious solve this hasn't actually verified.
    public func applyAutoExposure() async {
        guard let playbackController, let renderer = histogramRenderer else { return }
        do {
            let rawTexture = try await playbackController.currentTexture()
            guard !Task.isCancelled else { return }
            let neutralHistogram = try FrameHistogramComputer.compute(
                rawTexture: rawTexture,
                uniforms: uniforms,
                grading: .identity,
                renderer: renderer,
                device: device
            )
            guard !Task.isCancelled else { return }

            let totalSamples = neutralHistogram.red.reduce(0, +)
            guard totalSamples > 0 else { return }
            // Each channel's own mean, computed independently from its own
            // histogram, THEN combined with Rec.709 luma weights — not a
            // per-bin blend of all three channels, which would silently
            // collapse to an unweighted average instead.
            var sumR = 0.0, sumG = 0.0, sumB = 0.0
            for bin in 0..<FrameHistogram.binCount {
                let binValue = Double(bin)
                sumR += binValue * Double(neutralHistogram.red[bin])
                sumG += binValue * Double(neutralHistogram.green[bin])
                sumB += binValue * Double(neutralHistogram.blue[bin])
            }
            let meanR = sumR / Double(totalSamples) / 255.0
            let meanG = sumG / Double(totalSamples) / 255.0
            let meanB = sumB / Double(totalSamples) / 255.0
            let meanEncoded = 0.2126 * meanR + 0.7152 * meanG + 0.0722 * meanB

            // 0.45, not 0.5: a real-world frame's mean sits slightly below
            // its perceptual "well-exposed" midpoint even when correctly
            // exposed (highlights compress less than shadows expand under
            // gamma encoding) — matching the conventional target most
            // "auto levels"/"auto exposure" implementations use rather than
            // a naive exact-middle-gray solve.
            let target = 0.45
            let newBrightness = Float(max(-0.5, min(0.5, target - meanEncoded)))
            var updated = grading
            updated.brightness = newBrightness
            setGrading(updated)
        } catch {
            // Best-effort, matching `recomputeHistogram()` — a failed/
            // cancelled Auto action just leaves grading untouched.
        }
    }

    /// Loads `url` as a `.cube` 3D LUT (`CubeLUT(contentsOf:)`), builds its
    /// Metal 3D texture (`LUTTexture.make(from:device:)`), and — only once
    /// both succeed — applies it: sets `currentLUTURL`/`currentLUTTexture`,
    /// turns `lutEnabled` on, sets `uniforms.lutEnabled = 1`, and records
    /// `url` into the recent-LUTs list (see `recordRecentLUT`).
    ///
    /// Throws whatever `CubeLUT.init(contentsOf:)`/
    /// `LUTTexture.make(from:device:)` themselves throw
    /// (`CubeLUTError`/`LUTTextureError`) — no wrapping error type is added
    /// here, since this model has nothing useful to add to either error's
    /// own description. Propagates rather than swallows/alerts:
    /// `CineDocumentModel` lives in `CinePlayerCore`, which has no AppKit/
    /// `NSAlert` available — the app-layer `LUTLoadCoordinator` is what
    /// catches and alerts, exactly like `SaveAsCoordinator`/
    /// `writeTrimmedRange` already does for `.cine` errors. On failure, none
    /// of this model's published LUT state is touched — a failed load
    /// leaves whatever LUT (or none) was previously active intact, matching
    /// `open(url:)`'s own failure behavior.
    public func loadLUT(from url: URL) throws {
        let lut = try CubeLUT(contentsOf: url)
        let texture = try LUTTexture.make(from: lut, device: device)
        currentLUTURL = url
        currentLUTTexture = texture
        lutEnabled = true
        uniforms.lutEnabled = 1
        recordRecentLUT(url)
    }

    /// Toggles whether the loaded LUT (if any) is actually applied, without
    /// touching `currentLUTTexture`/`currentLUTURL` — same on/off-only shape
    /// as `setColorMatrixEnabled`, guarded by the same no-op equality check.
    /// Resolves `uniforms.lutEnabled` against BOTH `enabled` and whether a
    /// texture actually exists, so flipping this on with nothing loaded
    /// updates the published `lutEnabled` flag (harmless — the sidebar
    /// toggle itself is disabled in that state anyway) but never sets the
    /// shader's flag with no real LUT texture bound at that slot.
    public func setLUTEnabled(_ enabled: Bool) {
        guard lutEnabled != enabled else { return }
        lutEnabled = enabled
        uniforms.lutEnabled = (enabled && currentLUTTexture != nil) ? 1 : 0
    }

    /// Clears the currently-active LUT entirely — distinct from merely
    /// disabling it via `setLUTEnabled(false)`, which keeps
    /// `currentLUTTexture` around so re-enabling doesn't need a re-load.
    /// Does not touch `recentLUTURLs`: clearing the active LUT and
    /// forgetting it ever existed in the recent-list are two different
    /// actions (the latter is `clearRecentLUTs()`).
    public func clearLUT() {
        currentLUTURL = nil
        currentLUTTexture = nil
        lutEnabled = false
        uniforms.lutEnabled = 0
    }

    /// Records `url` as the most-recently-loaded LUT, called from the end of
    /// a successful `loadLUT(from:)` — same dedup-by-resolved-path/
    /// most-recent-first/persist shape as `recordRecentFile`, just capped at
    /// 3 (this feature's own spec, not `recentFileURLs`'s 10) with its own
    /// separate `UserDefaults` key (`storedRecentLUTPaths`).
    private func recordRecentLUT(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        var urls = recentLUTURLs.filter { $0.resolvingSymlinksInPath().path != resolved.path }
        urls.insert(resolved, at: 0)
        urls = Array(urls.prefix(3))
        Self.storedRecentLUTPaths = urls.map { $0.path }
        recentLUTURLs = urls
    }

    /// Clears the "Recent LUTs" list, both the published property and its
    /// persisted `UserDefaults` entry — mirrors `clearRecentFiles()` exactly,
    /// backs the sidebar menu's own "Clear Recent LUTs" item.
    public func clearRecentLUTs() {
        Self.storedRecentLUTPaths = []
        recentLUTURLs = []
    }

    /// Sets whether the metadata overlay HUD is shown. Purely view-chrome —
    /// never touches `uniforms` or anything else `CineMetalView`'s draw path
    /// reads, so toggling it has no effect on rendering/playback of the
    /// underlying video either way.
    public func setShowMetadataOverlay(_ enabled: Bool) {
        Self.storedShowMetadataOverlay = enabled
        guard showMetadataOverlay != enabled else { return }
        showMetadataOverlay = enabled
    }

    /// Convenience for a menu-command binding (`CinePlayerApp`'s "Show
    /// Metadata Overlay" command): flips the current state.
    public func toggleMetadataOverlay() {
        setShowMetadataOverlay(!showMetadataOverlay)
    }

    /// Sets whether the inspector sidebar is shown. Purely view-chrome —
    /// see `showInspectorSidebar`'s own doc comment.
    public func setShowInspectorSidebar(_ enabled: Bool) {
        Self.storedShowInspectorSidebar = enabled
        guard showInspectorSidebar != enabled else { return }
        showInspectorSidebar = enabled
    }

    /// Convenience for a menu-command/title-bar-button binding: flips the
    /// current state.
    public func toggleInspectorSidebar() {
        setShowInspectorSidebar(!showInspectorSidebar)
    }

    /// Sets whether the file-browser sidebar is shown. Purely view-chrome —
    /// see `showFileBrowser`'s own doc comment.
    public func setShowFileBrowser(_ enabled: Bool) {
        Self.storedShowFileBrowser = enabled
        guard showFileBrowser != enabled else { return }
        showFileBrowser = enabled
    }

    /// Convenience for a title-bar-button binding: flips the current state.
    public func toggleFileBrowser() {
        setShowFileBrowser(!showFileBrowser)
    }

    /// Sets the shared frame-numbering convention. Purely view-chrome — see
    /// `frameNumberingMode`'s own doc comment.
    public func setFrameNumberingMode(_ mode: FrameNumberingMode) {
        Self.storedFrameNumberingMode = mode
        guard frameNumberingMode != mode else { return }
        frameNumberingMode = mode
    }

    /// Sets the file-browser sidebar's root folder — called by
    /// `OpenPanelCoordinator` after the user picks a directory in the open
    /// panel. Persists `url`'s path so it survives a relaunch (see
    /// `storedFileBrowserRootPath`'s doc comment); does not itself force the
    /// sidebar visible — callers that want that (as `OpenPanelCoordinator`
    /// does) call `setShowFileBrowser(true)` separately.
    public func setFileBrowserRoot(_ url: URL) {
        Self.storedFileBrowserRootPath = url.path
        fileBrowserRootURL = url
    }

    /// Renames (or moves) `oldURL` to `newURL` on disk via
    /// `FileManager.default.moveItem`, then keeps every piece of this
    /// model's own state that was pointing somewhere underneath `oldURL` in
    /// sync with the new location.
    ///
    /// Renaming is not always renaming the exact file that's open: `oldURL`
    /// can be a *folder* (renamed from a `FileBrowserSidebarView` row) that
    /// contains `currentURL` — or an entry of `recentFileURLs` — nested
    /// arbitrarily far underneath it, not just directly inside it. Left
    /// alone, `currentURL` would keep pointing at a path that stops existing
    /// the instant the move completes: the sidebar's `isCurrentFile(_:)`
    /// highlight would silently stop matching anything (its own
    /// `resolvingSymlinksInPath()` compare only works against a path that's
    /// still real), and a later attempt to reopen "the currently open file"
    /// — e.g. via `recentFileURLs`/"Open Recent" — would throw instead of
    /// finding it. So once the actual filesystem move succeeds, any tracked
    /// URL that is `oldURL` itself, or has it as a genuine path-component
    /// prefix, has that prefix string-swapped for `newURL`'s — the same
    /// "rename the folder, everything nested under it silently follows"
    /// behavior a Finder move preserves. State pointing somewhere else
    /// entirely is left untouched.
    ///
    /// Deliberately does **not** prefix-replace `fileBrowserRootURL` itself:
    /// `FileBrowserSidebarView`'s tree only ever renders rows from
    /// `FileBrowserNode.enumerateChildren(of: rootURL)` starting one level
    /// *below* the root, so the root is never itself a row this method's
    /// caller (the sidebar's rename UI) could invoke a rename on — it can
    /// never be an ancestor being renamed out from under itself.
    ///
    /// Path comparison uses the same `resolvingSymlinksInPath()` convention
    /// `FileBrowserSidebarView.isCurrentFile(_:)` and `recordRecentFile(_:)`
    /// already use, for the same reason: a folder reached through a
    /// symlinked path should still be recognized as the ancestor of a file
    /// reached through its resolved path, or vice versa. `oldURL` is
    /// resolved *before* the move (while it still exists on disk, so a
    /// symlink at its own leaf — not just an ancestor directory — resolves
    /// correctly); `newURL` is resolved only *after* the move succeeds, for
    /// the same reason in reverse.
    public func renameItem(at oldURL: URL, to newURL: URL) throws {
        let oldPath = oldURL.resolvingSymlinksInPath().path

        try FileManager.default.moveItem(at: oldURL, to: newURL)

        let newPath = newURL.resolvingSymlinksInPath().path

        // Swaps `oldPath` for `newPath` as a prefix of `path`, but only when
        // `path` is exactly `oldPath` or has it as a genuine path-component
        // prefix (`oldPath + "/"`) — a bare `hasPrefix(oldPath)` would also
        // (wrongly) match an unrelated sibling whose name merely starts with
        // the same characters, e.g. renaming "Take1" must not touch a
        // sibling folder named "Take10".
        func rebased(_ path: String) -> String? {
            if path == oldPath { return newPath }
            if path.hasPrefix(oldPath + "/") { return newPath + path.dropFirst(oldPath.count) }
            return nil
        }

        if let currentURL, let rebasedPath = rebased(currentURL.resolvingSymlinksInPath().path) {
            self.currentURL = URL(fileURLWithPath: rebasedPath)
        }

        recentFileURLs = recentFileURLs.map { url in
            guard let rebasedPath = rebased(url.resolvingSymlinksInPath().path) else { return url }
            return URL(fileURLWithPath: rebasedPath)
        }
        Self.storedRecentFilePaths = recentFileURLs.map { $0.path }
    }

    /// Keeps the file-browser sidebar's root able to actually reach whichever
    /// file was just opened — called from the end of `open(url:)`,
    /// regardless of how the open was triggered (⌘O, drag-and-drop, a
    /// Finder double-click, "Open Recent", or a sidebar row click itself).
    /// Deliberately a no-op when `url` is already reachable from the current
    /// root (including the sidebar-row-click case, where it always already
    /// is — see `FileBrowserSidebarView`'s own tree-enumeration comment) —
    /// only resets the root to `url`'s own containing folder when it
    /// genuinely isn't, so opening one file from deep inside an
    /// already-browsed project folder never collapses that broader root back
    /// down to just the file's immediate parent. Path comparison mirrors
    /// `FileBrowserSidebarView.isCurrentFile(_:)`'s own
    /// `resolvingSymlinksInPath()` use, for the same reason: a root and a
    /// file reached through different symlinked paths should still compare
    /// equal/contained.
    private func revealContainingFolderIfNeeded(for url: URL) {
        let resolvedFile = url.resolvingSymlinksInPath().standardizedFileURL.path
        if let rootURL = fileBrowserRootURL {
            let resolvedRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
            if resolvedFile == resolvedRoot || resolvedFile.hasPrefix(resolvedRoot + "/") {
                return
            }
        }
        setFileBrowserRoot(url.deletingLastPathComponent())
    }

    /// Records `url` as the most-recently-opened file, called from the end
    /// of a successful `open(url:)`. Any existing entry for the same
    /// underlying file — compared via `resolvingSymlinksInPath().path`, not
    /// raw `.path`/`URL` equality — is removed first, so re-opening an
    /// already-recent file moves it to the front instead of appearing
    /// twice, even when the two opens reached the file through different
    /// symlinked path spellings (e.g. an aliased/NAS-mounted folder vs. its
    /// canonical path). Same reasoning `FileBrowserSidebarView.isCurrentFile`
    /// already applies to its own, separate comparison. The resolved URL
    /// (not the as-passed-in one) is what's inserted/persisted, so every
    /// stored entry is in canonical form and future comparisons stay
    /// consistent. The result is truncated to 10 entries before being
    /// persisted and published.
    private func recordRecentFile(_ url: URL) {
        let resolved = url.resolvingSymlinksInPath()
        var urls = recentFileURLs.filter { $0.resolvingSymlinksInPath().path != resolved.path }
        urls.insert(resolved, at: 0)
        urls = Array(urls.prefix(10))
        Self.storedRecentFilePaths = urls.map { $0.path }
        recentFileURLs = urls
    }

    /// Clears the "Open Recent" list, both the published property and its
    /// persisted `UserDefaults` entry — backs the submenu's "Clear Menu"
    /// item.
    public func clearRecentFiles() {
        Self.storedRecentFilePaths = []
        recentFileURLs = []
    }

    /// Fetches the texture for an arbitrary frame `index`, decoding+
    /// uploading it first if it isn't already cached — delegates straight
    /// to the private `cache`'s own `texture(at:)`, the exact same call
    /// `PlaybackController.currentTexture()` makes for whatever frame is
    /// currently on screen.
    ///
    /// Unlike `PlaybackController.currentTexture()`, this never reads or
    /// touches `currentFrameIndex` — the visible playhead never moves just
    /// because some other frame's texture was fetched. This is what lets
    /// range export (`RangeExporter`'s PNG/TIFF-sequence paths) walk every
    /// frame in an export range without disturbing what's on screen, and
    /// it has no dependency on `PlaybackController` at all: only `cache` is
    /// touched here.
    ///
    /// Throws `CineDocumentModelError.noOpenDocument` if no file is open
    /// (i.e. `cache` is `nil`).
    public func texture(at index: Int) async throws -> MTLTexture {
        guard let cache else {
            throw CineDocumentModelError.noOpenDocument
        }
        return try await cache.texture(at: index)
    }

    /// Writes a trimmed copy of the currently-open file's frames in `range`
    /// (0-based, both bounds inclusive) to `url` — delegates straight to
    /// `CineFile.writeTrimmed(range:to:)`.
    ///
    /// This model doesn't retain its own long-lived reference to the open
    /// `CineFile` (only `cache` does, privately) — rather than adding one
    /// just for this, this reopens a fresh `CineFile` from `currentURL`,
    /// the same "reopen from URL; `CineFile` is mmap-backed, so this is
    /// cheap and side-effect-free" pattern `DNGExporter` (in the app
    /// target) already uses for its own raw-frame re-decode. That keeps
    /// this narrow accessor's cost paid only by its (infrequent) caller —
    /// the app target's "Save As…" (`SaveAsCoordinator`) — rather than
    /// keeping a second live `CineFile` reference around for the entire
    /// lifetime of every open document.
    ///
    /// Throws `CineDocumentModelError.noOpenDocument` if no file is open,
    /// or whatever `CineFile.init(url:)`/`writeTrimmed(range:to:)` itself
    /// throws (e.g. `CineError.invalidTrimRange`/`.writeFailed`).
    public func writeTrimmedRange(_ range: ClosedRange<Int>, to url: URL) throws {
        guard let currentURL else {
            throw CineDocumentModelError.noOpenDocument
        }
        let cineFile = try CineFile(url: currentURL)
        try cineFile.writeTrimmed(range: range, to: url)
    }

    /// The app target's plain "Save" command (`SaveCoordinator`): overwrites
    /// `currentURL` in place with `range`'s frames, rather than prompting for
    /// a brand-new location the way "Save As…"/`writeTrimmedRange(_:to:)`
    /// always does.
    ///
    /// This is NOT simply `writeTrimmedRange(range, to: currentURL)`.
    /// `writeTrimmedRange` reopens a fresh, mmap-backed `CineFile` from
    /// `currentURL` to read from — but this app's own `DecodedFrameCache`
    /// (retained by `cache`, above) may *already* hold a live mmap-backed
    /// reference into that same file's bytes for whatever frame is currently
    /// decoded/displayed. Truncating/overwriting `currentURL` directly while
    /// that mapping is still live would be a real data-corruption risk, not
    /// just a style concern: truncating a file invalidates the pages backing
    /// any existing mmap of it, out from under whatever's still reading them.
    ///
    /// So instead: `writeTrimmedRange` writes the trimmed result out to a
    /// throwaway temp file in the *same directory* as `currentURL` (same
    /// volume, so the swap below is a true atomic rename, not a
    /// copy-then-delete fallback) — a path nothing else in the app has ever
    /// touched, so the read side (a fresh `CineFile(url: currentURL)` inside
    /// `writeTrimmedRange`) is completely unaffected by the write side. Only
    /// once that succeeds is the temp file atomically swapped into place over
    /// `currentURL` via `FileManager.replaceItemAt`, rather than a manual
    /// remove-then-move. That specific API is what makes the swap safe even
    /// while a live mmap of the OLD file content might still be open
    /// elsewhere in the app (`DecodedFrameCache`'s cached frames): under Unix
    /// path/inode semantics, a rename onto an existing path is invisible to
    /// any file descriptor/mmap already open on the old inode — existing
    /// readers keep seeing the OLD bytes until they close/unmap it, and only
    /// a future, fresh `open()` of the path (i.e. a future
    /// `CineFile(url:)` — see `open(url:)` below) ever sees the new content.
    /// Nothing currently holds `currentURL` open by path across this call in
    /// a way that would see a half-written file, but this is also why the
    /// temp file is never simply written directly over `currentURL`: doing
    /// that would defeat the entire reason a fresh `CineFile(url:)` reopen
    /// inside `writeTrimmedRange` is safe to call as it currently is written.
    ///
    /// `wholeFile` tells this method whether `range` covers the entire
    /// currently-open clip — computed by the caller (`SaveCoordinator`, which
    /// already has `PlaybackController` in hand for exactly this comparison)
    /// rather than recomputed here, mirroring how `writeTrimmedRange`/
    /// `open(url:)` already divide responsibility: this model's file-I/O
    /// methods take the values they need as parameters rather than reaching
    /// into `playbackController` themselves. When `true`, the file's content
    /// didn't meaningfully change (the rewritten copy holds every frame the
    /// original did), so this returns right after the swap with nothing else
    /// to refresh. When `false`, a genuine subset was written — the file on
    /// disk now has fewer frames than this model's in-memory
    /// `playbackController`/`frameCount` still reflect — so `open(url:
    /// currentURL)` is called to bring every derived property back in sync
    /// with what was actually just written. `open(url:)` always resets
    /// grading/Color Temp/WBCC to neutral (there's no sidecar or any other
    /// persistence to restore from — see that method's own doc comment), so
    /// this method captures the live grade before the reopen and reassigns
    /// it after, purely in memory: this reopen is an implementation detail
    /// of Save, not the user opening a different file, and shouldn't blow
    /// away in-progress color work just because trimming happens to be
    /// implemented as write-then-reopen.
    ///
    /// Throws `CineDocumentModelError.noOpenDocument` if no file is open, or
    /// whatever `writeTrimmedRange`/`FileManager.replaceItemAt` themselves
    /// throw. On failure before the swap, `currentURL` is untouched — the
    /// original file is never modified until a complete trimmed copy already
    /// exists safely on disk under a different name.
    /// Only ever called for a GENUINE trim (`range` narrower than the whole
    /// file) — `SaveCoordinator`'s plain "Save" now branches before this is
    /// ever reached: when no trim is active, there's nothing left for Save to
    /// do at all (grading is never persisted — see `open(url:)`'s doc
    /// comment), so it does nothing rather than reaching this method. That's
    /// why this method no longer takes a `wholeFile` flag or has a "return
    /// before reopening" branch — reaching this method at all now implies
    /// real frame data is being discarded, which in turn always makes the
    /// in-memory `playbackController`/`frameCount` stale relative to what's
    /// now on disk, so the unconditional reopen below is always warranted.
    public func overwriteCurrentFile(range: ClosedRange<Int>) async throws {
        guard let currentURL else {
            throw CineDocumentModelError.noOpenDocument
        }

        let tempURL = currentURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).cine")

        // Registered before the write is even attempted, so a partially
        // written (or already-swapped-away) temp file is always cleaned up —
        // or silently no-ops via `try?` if it no longer exists — regardless
        // of which step below throws or succeeds.
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try writeTrimmedRange(range, to: tempURL)
        // The returned URL (the original's post-replace location, per
        // `replaceItemAt`'s own documented behavior) is never a different
        // path than `currentURL` itself here — no `backupItemName`/
        // `.usingNewMetadataOnly` options are passed, so it's discarded.
        _ = try FileManager.default.replaceItemAt(currentURL, withItemAt: tempURL)

        // Captured before the reopen, which unconditionally resets these to
        // neutral (see `open(url:)`'s doc comment) — reassigned after, so
        // this Save doesn't silently discard whatever grade was dialed in.
        let preservedGrading = grading
        let preservedColorTempKelvin = colorTempKelvin
        let preservedWBCC = wbcc

        try await open(url: currentURL)

        self.grading = preservedGrading
        self.colorTempKelvin = preservedColorTempKelvin
        self.wbcc = preservedWBCC
        recomputeWhiteBalance()
    }

    /// Shows `ExportProgressSheet` for an already-in-flight export — called
    /// by `VideoExportCoordinator.exportVideo` right after it starts the
    /// encode `Task`. See `activeExportProgress`'s own doc comment for why
    /// this is transient, unpersisted state.
    public func presentExportProgress(_ progress: MediaExportProgress) {
        activeExportProgress = progress
    }

    /// Dismisses `ExportProgressSheet`. Does **not** cancel the export
    /// itself — `ExportProgressSheet`'s own `onDisappear` handles that if
    /// the sheet closes mid-export (e.g. an unexpected dismissal), the same
    /// "closing the UI and stopping the work are different actions" split
    /// `RangeExportSheet` used to draw.
    public func dismissExportProgress() {
        activeExportProgress = nil
    }
}
