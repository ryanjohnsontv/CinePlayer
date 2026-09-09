import Cocoa
import QuickLookUI
import Metal
import MetalKit
import Combine
import CineKit
import CinePlayerCore

/// macOS Quick Look preview extension for `.cine` files — the full-size
/// preview Finder shows when the user presses Space (or chooses
/// File > Quick Look) on a selected `.cine` file. Distinct from
/// `CineThumbnailExtension`'s smaller icon/gallery thumbnail: Quick Look
/// tries the preview extension first for the Space-bar case and only falls
/// back to the thumbnail extension's output if no preview extension is
/// registered, so this is a separate implementation, not a thin wrapper
/// around the thumbnail one.
///
/// No storyboard: `NSExtensionPrincipalClass` in `Info.plist` points
/// straight at this class, and `loadView()` builds the view programmatically
/// — matching this project's existing preference for programmatic
/// AppKit/SwiftUI over storyboards everywhere else, and avoiding xcodegen
/// needing to wire up a `NSExtensionMainStoryboard` reference for a single
/// image view.
///
/// **The playback pipeline** drives the exact same engine the main
/// `CinePlayer` app uses for its own live playback, so a Quick Look preview
/// plays precisely as smoothly, and over the clip's entire real length —
/// there is no bounded "preview slice" concept anywhere in this pipeline,
/// unlike a simpler pre-decoded-array-plus-`Timer` approach would need:
///
/// - **`PlaybackController`** (`CinePlayerCore`) owns `currentFrameIndex`
///   and the play/pause/seek state machine. `play(rate: .forwardNormal)`
///   ticks once every `1.0 / reviewFPS` seconds (`reviewFPS` defaults to
///   30), advancing exactly one real, consecutive captured frame per tick —
///   this is what makes a high-speed capture read as genuine slow motion
///   (see that type's own doc comment): the ratio between the camera's real
///   capture rate and this ordinary ~30fps display rate does all the work,
///   rather than this preview inventing its own arbitrary playback speed.
///   It operates over the file's real, full `frameCount` — there is no
///   "preview slice" concept left anywhere in this pipeline.
/// - **`DecodedFrameCache`** (`CinePlayerCore`) is a bounded, LRU-evicting
///   actor cache of decoded-and-uploaded frame textures — the same
///   mechanism that already makes the live app's scrubbing/playback smooth
///   over arbitrarily long real footage, safe here for the same reason.
///   Every frame-index change made through `PlaybackController`'s own
///   `play`/`seek`/`step` methods (never any other path — see
///   `sliderMoved(_:)` and the Combine subscription below, which are the
///   only two places `currentFrameIndex` is ever moved from in this file)
///   automatically fires a fire-and-forget `cache.prefetch(around:direction:)`
///   biased in the direction of travel, so nothing in this file ever needs
///   to call `prefetch` itself.
/// - **`CineRenderer`** (`CinePlayerCore`) is the stateless-per-draw GPU
///   tonemap/debayer pass. One instance is built lazily on `draw(in:)`'s
///   first call and kept for the lifetime of the preview (see `renderer`'s
///   own doc comment) — constructing it compiles Metal pipeline state,
///   which is not free, so this must happen once per session, not once per
///   frame.
/// - **No LUT support, deliberately** — every `renderer.render(...)` call
///   below passes `lutTexture: nil` and `grading: .identity`. Requested
///   directly: an in-flight custom color-grading LUT is a heavier piece of
///   plumbing (loading, texture upload, per-file state) that only really
///   matters for a deliberate export/grading session, not a quick Space-bar
///   glance at a clip — out of scope for this preview, not merely deferred.
/// - **Looping is this file's own responsibility, not `PlaybackController`'s.**
///   `PlaybackController` never wraps around on its own: reaching
///   `effectiveOutPoint` during forward playback just stops it
///   (`isPlaying` goes back to `false`). A Quick Look preview should still
///   read as a continuously looping reel, so this file adds that behavior
///   itself by watching `$isPlaying` and restarting playback from
///   `effectiveInPoint` whenever it goes `false` specifically *because
///   playback ran off the end* — see the subscription set up in
///   `preparePreviewOfFile(at:)` for exactly how that's distinguished from
///   an ordinary pause (e.g. mid-scrub), which must NOT auto-resume.
/// - **Scrubbing and the idle loop are the same mechanism, not two separate
///   paths.** There is only one notion of "current frame":
///   `playbackController.currentFrameIndex`. Playing, seeking, and
///   scrubbing all just move that one value through
///   `PlaybackController`'s own methods; a single Combine subscription (see
///   below) reacts to every change identically regardless of what caused
///   it, fetching that frame's texture through the same cache and drawing
///   it through the same `MTKView`.
///
/// **Driving a plain `MTKView` with no SwiftUI involved.** The live app's
/// `CineMetalView` (`CinePlayerApp/Views/CineMetalView.swift`) gets its
/// "a frame worth redrawing is ready" signal for free from SwiftUI's own
/// diffing of an `@ObservedObject` — `updateNSView(_:context:)` runs
/// whenever `documentModel`/`playbackController` changes. This extension is
/// plain AppKit with no SwiftUI anywhere, so that trigger has to be built by
/// hand: `preparePreviewOfFile(at:)` subscribes directly to
/// `playbackController.$currentFrameIndex` (its Combine `projectedValue`
/// publisher — `PlaybackController` is a plain `@MainActor` `ObservableObject`,
/// so this works with no SwiftUI required at all), and on every emitted
/// index cancels whatever texture fetch was still in flight for the
/// previous frame, starts a fresh `Task` that awaits
/// `playbackController.currentTexture()`, and on success stores the result
/// in `rawTexture` and calls `mtkView.setNeedsDisplay(mtkView.bounds)` —
/// which is what actually triggers the next `draw(in:)` call, since
/// `mtkView.enableSetNeedsDisplay = true` means there is no free-running
/// draw loop otherwise. `draw(in:)` itself only ever pushes the
/// already-fetched, already-stored `rawTexture` through `renderer.render(...)`
/// — it never fetches synchronously, because an `MTKViewDelegate` callback
/// must stay fast and synchronous. See `handleCurrentFrameIndexChanged(_:)`
/// for the full fetch/cancel bookkeeping, which mirrors
/// `CineMetalView.Coordinator`'s own `fetchTask` in the app target as
/// closely as a SwiftUI-free AppKit context allows.
///
/// A second, independent subscription to `$isPlaying` implements the
/// looping behavior described above; both subscriptions' `AnyCancellable`s
/// live in `cancellables` for the lifetime of this controller. Neither
/// closure needs `MainActor.assumeIsolated` the way this file's old
/// `Timer`-based loop once did: `Timer.scheduledTimer(withTimeInterval:repeats:block:)`'s
/// closure parameter is explicitly typed `@Sendable`, which forces it
/// non-isolated regardless of where it's written, but Combine's
/// `sink(receiveValue:)` closure parameter carries no such annotation — a
/// closure literal with an unannotated, non-`Sendable` type is inferred to
/// share the isolation of whatever context it's formed in, so a closure
/// written inside this `@MainActor` type's own `@MainActor` method is
/// already statically known to run on the main actor, with no unsafe
/// escape hatch or per-event `Task` hop needed to touch `mtkView`/`scrubber`/
/// `frameLabel` from inside it.
///
/// `@MainActor`: `PlaybackController`/`DecodedFrameCache`'s own published
/// state and every AppKit control this type owns (`mtkView`/`scrubber`/
/// `frameLabel`) all expect to be touched from the main actor/main thread —
/// running this whole type there means no actor-hopping is ever needed to
/// read a `@Published` value or mutate a control directly. Unlike the old
/// timer-driven version, `preparePreviewOfFile(at:)` itself no longer does
/// any blocking decode/render/readback work before returning — it only
/// resolves a `MTLDevice`, opens the file's header/setup (`CineFile(url:)`,
/// cheap — no frame data touched), does one cheap one-off frame-0 decode
/// purely to sanity-check this file's color calibration (see
/// `preparePreviewOfFile`'s own comment on this), and wires up the
/// subscriptions above before kicking off playback and returning. Frame 0
/// itself is fetched and drawn asynchronously, the moment the first
/// `$currentFrameIndex` emission's fetch task completes — this method does
/// not, and does not need to, block on an actual pixel being on screen
/// before returning; Quick Look only needs the preview session validly set
/// up, not a first frame guaranteed painted.
///
/// **Transport controls, on top of the scrubber bar above:** `transportBar`
/// also hosts `rewindButton`/`playPauseButton`/`fastForwardButton`
/// (`NSButton`s with SF Symbol images) and `fpsPopUp` (an `NSPopUpButton`),
/// laid out left-to-right as [rewind] [play/pause] [fast-forward]
/// [scrubber] [frameLabel] [fps picker] — a standard media-player transport
/// row. All three buttons and the popup funnel exclusively through
/// `playbackController`'s own `play(rate:)`/`pause()`/`setReviewFPS(_:)` —
/// exactly like `scrubber`, there is still only one source of truth for
/// playback state, these buttons are just three more callers of it, not a
/// parallel state machine:
///
///   - **`playPauseButton`** is a deliberately simple on/off toggle, not a
///     "resume whatever rate was last active" control (that's what
///     `PlaybackController.togglePause()` is for, and this button does not
///     use it): pressing it while stopped always starts plain
///     `.forwardNormal`, and pressing it while *any* mode is active — fast
///     forward, reverse, whatever the rewind/fast-forward buttons below most
///     recently dialed in — always pauses. `updatePlayPauseButton(isPlaying:)`
///     keeps its image (`pause.fill` vs `play.fill`) in sync via a
///     `controller.$isPlaying` subscription (added to the same
///     `cancellables` set as the existing two), so it reflects reality
///     regardless of *what* changed the state — this button, the scrubber,
///     or the existing auto-loop-restart logic all end up visible here for
///     free, with no separate bookkeeping.
///   - **`fastForwardButton`/`rewindButton`** each cycle through their
///     3 same-direction `PlaybackRate`s on repeated presses — normal → fast
///     → fast-fast → wraps back to normal — the same repeat-to-cycle-speeds
///     gesture QuickTime Player's own transport buttons use. Pressing either
///     while not already playing in that direction starts at that
///     direction's `...Normal` rate. See `nextForwardRate()`/
///     `nextReverseRate()` for the small pattern-match this needs over
///     `currentMode` (`.rate(let rate)` vs `.realTime` vs `nil`) to decide
///     the next step.
///   - **Deliberately OUT OF SCOPE: no new looping behavior for reverse
///     playback.** The existing `$isPlaying` subscription below only loops
///     *forward* playback that naturally runs off `effectiveOutPoint` (see
///     that subscription's own long-standing comment, unchanged by this
///     addition). Reverse, fast-forward, and fast-reverse all simply stop
///     wherever `PlaybackController` already stops them (`effectiveInPoint`
///     or `effectiveOutPoint`) with no auto-restart — this was a deliberate
///     scope boundary at the time these buttons were added, not a gap to
///     "complete" later by mirroring the forward-loop logic onto
///     `effectiveInPoint`.
///   - **`fpsPopUp`** answers "Does it also support 24fps playback? Ideally
///     it covers all Phantom video system options" together with "customize
///     the quick look default playback speed... rather than FPS it would be
///     like 1x, 2x, 5x, 10x, etc." Rather than a picker over absolute
///     broadcast/film rates, this is a picker over SPEED MULTIPLIERS (1x /
///     2x / 5x / 10x) applied on top of `fileOwnReviewFPS` (this file's own
///     `Setup.fPbRate`-or-`30` rate) — "1x" plays at exactly that rate
///     (matching every prior behavior, including what used to be a separate
///     "Auto (File Rate)" item — now redundant, since multiplying by 1 IS
///     that), "2x"/"5x"/"10x" play that many times faster, for quickly
///     skimming a long clip without needing to know or reason about any
///     actual fps number. Selecting an entry persists the chosen multiplier
///     to `QuickLookPlaybackPreferences.speedMultiplier` (CinePlayerCore; a
///     `group.com.cineplayer.shared` App-Group-backed `UserDefaults` suite,
///     shared with the main app — see that type's own doc comment and both
///     targets' `.entitlements` files) — so it's picked up by every
///     subsequent preview of ANY file, AND is reachable/settable from the
///     main app's own Settings window with no file open at all — then calls
///     `playbackController?.setReviewFPS(_:)`, which — see that method's own
///     doc comment — takes effect immediately even while `.forwardNormal`/
///     etc. playback (driven by these very buttons) is already running. See
///     `fpsChanged(_:)` and `preparePreviewOfFile(at:)`'s own comments.
@MainActor
final class PreviewViewController: NSViewController, QLPreviewingController, MTKViewDelegate {
    private let mtkView = MTKView()
    private let scrubber = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let frameLabel = NSTextField(labelWithString: "")

    /// Transport buttons — see this type's own doc comment ("Real transport
    /// controls") for the full behavior each implements. All three are
    /// plain SF-Symbol `NSButton`s built in `loadView()`; `playPauseButton`'s
    /// image is the only one that changes after construction (toggled by
    /// `updatePlayPauseButton(isPlaying:)`), `rewindButton`/`fastForwardButton`
    /// keep a fixed icon for their whole lifetime — cycling speed is a
    /// behavior of what they *do*, not something reflected in their image.
    private let rewindButton = NSButton()
    private let playPauseButton = NSButton()
    private let fastForwardButton = NSButton()

    /// Fixed rendered size for all three transport-bar glyphs — shared by
    /// their initial setup (`loadView()`) and `updatePlayPauseButton(
    /// isPlaying:)`'s later swap between `play.fill`/`pause.fill`, so a
    /// pause/resume can never regress back to an unconfigured, larger
    /// default-sized symbol. See `loadView()`'s own doc comment on why this
    /// exists at all.
    private static let transportGlyphConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)

    /// The fps picker described in this type's own doc comment — a fixed
    /// set of speed MULTIPLIERS (1x / 2x / 5x / 10x) applied on top of
    /// `fileOwnReviewFPS`, defaulting to "1x" to match
    /// `QuickLookPlaybackPreferences.speedMultiplier`'s own default. Built
    /// in `loadView()`, wired to `fpsChanged(_:)`.
    private let fpsPopUp = NSPopUpButton()

    /// This file's own recorded review rate — `Setup.fPbRate` when present
    /// and positive, else `30` — computed once in `preparePreviewOfFile` and
    /// retained for this preview's lifetime. The baseline
    /// `QuickLookPlaybackPreferences.speedMultiplier` multiplies against;
    /// see `fpsPopUp`'s own doc comment.
    private var fileOwnReviewFPS: Double = 30

    /// A generous but on-screen-sized default, 16:9 to match every currently
    /// bundled sample and most real camera sensor crops — refined to the
    /// clip's *actual* aspect ratio in `preparePreviewOfFile` below once the
    /// real frame size is known. This only sets the *initial* panel size;
    /// the user can always resize afterward and `mtkView`'s own Auto
    /// Layout pin (below) keeps the frame fitted proportionally at whatever
    /// size the panel ends up being.
    private static let defaultPreferredContentSize = NSSize(width: 900, height: 546)

    /// Resolved once in `preparePreviewOfFile(at:)` and kept for the
    /// lifetime of the preview — needed to construct `DecodedFrameCache`/
    /// `CineRenderer` (the latter lazily, on `draw(in:)`'s first call; see
    /// `renderer`'s own doc comment).
    private var device: MTLDevice?

    /// The bounded, LRU-evicting decode+upload cache backing
    /// `playbackController`. Retained purely so it (and therefore the
    /// `CineFile`/mmap it wraps) stays alive for as long as the preview
    /// session does — never read directly; every real access goes through
    /// `playbackController.currentTexture()`.
    private var cache: DecodedFrameCache?

    /// Drives playback/scrubbing state for the whole, real clip — the same
    /// engine class the live app uses. `currentFrameIndex` is the single
    /// source of truth for "what frame is on screen"; nothing in this file
    /// tracks a separate frame position of its own. See this type's own doc
    /// comment for the full architecture this replaces.
    private var playbackController: PlaybackController?

    /// The shared GPU tonemap/debayer renderer, constructed lazily the
    /// first time `draw(in:)` runs (mirroring `CineMetalView.Coordinator`'s
    /// own lazy construction) rather than eagerly in `preparePreviewOfFile`
    /// — building it compiles Metal pipeline state, real but modest work
    /// that's just as easy to defer to the first actual draw as to force
    /// into the setup path. Built once and kept for the session either way;
    /// see this type's own doc comment for why that "once, not per frame"
    /// matters.
    private var renderer: CineRenderer?

    /// The most recently fetched, ready-to-draw texture — analogous to
    /// `CineMetalView.Coordinator`'s own identically-purposed stored
    /// texture. Set only by `handleCurrentFrameIndexChanged(_:)`'s fetch
    /// task, read only by `draw(in:)`; `draw(in:)` never fetches this
    /// itself (an `MTKViewDelegate` callback must stay fast/synchronous —
    /// see this type's own doc comment).
    private var rawTexture: MTLTexture?

    /// The exposure/debayer/calibration parameters `draw(in:)` passes to
    /// every `renderer.render(...)` call. Computed exactly once, in
    /// `preparePreviewOfFile(at:)`, rather than per displayed frame: unlike
    /// the old `CinePreviewImage.render` (which rebuilt an `ExposureUniforms`
    /// from scratch — via its own `private` `previewUniforms(cineFile:frame:)`
    /// helper, not reachable from this file — on every single frame it
    /// rendered), black/white levels, debayer mode, CFA phase, calibration,
    /// and gamma are all properties of the *file*, not of any one frame, so
    /// there is nothing to recompute as playback advances. The one
    /// frame-shaped input that helper needed — real pixel data to sanity-
    /// check this file's calibration against (`CalibrationPlausibility`) —
    /// is supplied by a single, one-off, cache-bypassing decode of frame 0
    /// in `preparePreviewOfFile`, mirroring exactly what
    /// `CineDocumentModel.open(url:)` itself already does for the live app,
    /// via `ExposureUniforms`'s own public
    /// `init(setup:frame:debayerMode:lutEnabled:)` convenience initializer
    /// (the same computation `previewUniforms` wraps, just exposed
    /// publicly). Defaulted here to the same neutral placeholder
    /// `CineDocumentModel.uniforms` itself starts from, in case `draw(in:)`
    /// somehow ran before `preparePreviewOfFile` finished setting this
    /// (it shouldn't — `rawTexture` being `nil` already guards that path —
    /// but a harmless neutral default costs nothing).
    private var uniforms = ExposureUniforms(blackLevel: 0, whiteLevel: 1023)

    /// The in-flight fetch (if any) for whichever frame
    /// `playbackController.currentFrameIndex` most recently changed to —
    /// cancelled and replaced on every new change, exactly like
    /// `CineMetalView.Coordinator`'s own `fetchTask`. See
    /// `handleCurrentFrameIndexChanged(_:)`.
    private var textureFetchTask: Task<Void, Never>?

    /// Holds the `AnyCancellable`s for both Combine subscriptions set up in
    /// `preparePreviewOfFile(at:)` (`$currentFrameIndex` and `$isPlaying`).
    /// Cancelled automatically when this set itself deallocates alongside
    /// `self` — see `deinit`.
    private var cancellables = Set<AnyCancellable>()

    /// The backing-scale factor computed once in `preparePreviewOfFile` —
    /// see that method's own comment for why converting pixel dimensions to
    /// points by this factor matters for `preferredContentSize`. Kept as a
    /// stored property rather than a local in case a future per-frame
    /// on-demand-sizing need wants it again, even though only
    /// `preparePreviewOfFile(at:)` reads it today.
    private var pointScale: CGFloat = 2

    override func loadView() {
        // `self.view` must be a plain container that `mtkView` is pinned
        // into via Auto Layout — NOT `mtkView` itself: any content view
        // needs its 4 edges pinned to a plain container with
        // required-priority constraints and
        // `translatesAutoresizingMaskIntoConstraints = false`, so Auto
        // Layout always resolves its frame from the container's real,
        // current size, rather than being handed to Quick Look as
        // `self.view` directly.
        //
        // Relatedly: never hand a size-sensitive, points-expecting API
        // (here, `preferredContentSize`) a raw pixel count without first
        // dividing by the backing scale factor — see
        // `preparePreviewOfFile`'s own `preferredContentSize` computation,
        // which divides `cineFile.bitmapInfo`'s real pixel dimensions by
        // `pointScale` for exactly this reason.
        let container = NSView()
        container.wantsLayer = true
        // A dark, neutral surround (rather than the default transparent/
        // white background) matches how the live app's own `CineMetalView`
        // presents frames — this preview's `mtkView` is now built on
        // exactly that same shape, not just visually similar to it — and
        // avoids a jarring white-to-image edge for clips that don't fill a
        // square preview pane.
        container.layer?.backgroundColor = NSColor.black.cgColor

        // A thin transport bar under the video, matching the live app's own
        // scrubber placement — `scrubber` gives real frame-accurate seeking
        // across the whole clip (see `sliderMoved(_:)`), which, in this
        // rewritten version, is the exact same underlying mechanism that
        // also drives ordinary playback (see this type's own doc comment).
        let transportBar = NSView()
        transportBar.wantsLayer = true
        transportBar.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        // Required the moment a view is both added as a subview AND given
        // explicit NSLayoutConstraints of its own (below: pinned edges +
        // a constant height) — without this, AppKit leaves its default
        // autoresizing-mask-derived constraints active too, which pin it to
        // its (default-zero) frame size. That's not a harmless redundancy:
        // it directly conflicts with the explicit height/edge constraints
        // below, and really did fire on every single preview load (confirmed
        // via `log show` — "Conflicting constraints detected" naming this
        // exact view, AppKit "recovering" by breaking one arbitrarily). This
        // was already correctly set on `mtkView`/`scrubber`/`frameLabel`
        // just below; `transportBar` itself was the one view in this method
        // that got missed.
        transportBar.translatesAutoresizingMaskIntoConstraints = false
        configureTransportBarControls()

        // `mtkView`-specific setup, matching the live app's own
        // `CineMetalView` exactly (see that file's doc comment): driven
        // manually rather than free-running, since a redraw is only ever
        // needed when a newly-fetched `rawTexture` (or a panel resize) has
        // something new to show. `.device` is deliberately NOT set here —
        // the real `MTLDevice` isn't resolved until `preparePreviewOfFile`
        // runs; it's assigned there instead, right after
        // `MTLCreateSystemDefaultDevice()` succeeds.
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = true
        mtkView.delegate = self
        mtkView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(mtkView)
        transportBar.addSubview(rewindButton)
        transportBar.addSubview(playPauseButton)
        transportBar.addSubview(fastForwardButton)
        transportBar.addSubview(scrubber)
        transportBar.addSubview(frameLabel)
        transportBar.addSubview(fpsPopUp)
        container.addSubview(transportBar)

        // Widened from the original 32pt to comfortably fit 26-28pt square
        // transport buttons with a bit of vertical breathing room, rather
        // than cramming them into the old scrubber-only bar's height.
        let transportHeight: CGFloat = 40
        NSLayoutConstraint.activate([
            mtkView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            mtkView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            mtkView.topAnchor.constraint(equalTo: container.topAnchor),
            mtkView.bottomAnchor.constraint(equalTo: transportBar.topAnchor),

            transportBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            transportBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            transportBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            transportBar.heightAnchor.constraint(equalToConstant: transportHeight),

            // Left-to-right: [rewind] [play/pause] [fast-forward]
            // [scrubber, flexible] [frameLabel] [fps picker]. `scrubber`
            // deliberately gets no trailing/width constraint of its own —
            // exactly as in the original scrubber-only layout, its width is
            // left for Auto Layout to solve for from the fully-pinned
            // chain of views downstream of it (`frameLabel`'s fixed width,
            // then `fpsPopUp` pinned on both edges), so it's the one view
            // that actually stretches to fill whatever space the panel's
            // current width leaves over.
            rewindButton.leadingAnchor.constraint(equalTo: transportBar.leadingAnchor, constant: 8),
            rewindButton.centerYAnchor.constraint(equalTo: transportBar.centerYAnchor),
            rewindButton.widthAnchor.constraint(equalToConstant: 26),
            rewindButton.heightAnchor.constraint(equalToConstant: 26),

            playPauseButton.leadingAnchor.constraint(equalTo: rewindButton.trailingAnchor, constant: 6),
            playPauseButton.centerYAnchor.constraint(equalTo: transportBar.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 28),
            playPauseButton.heightAnchor.constraint(equalToConstant: 28),

            fastForwardButton.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 6),
            fastForwardButton.centerYAnchor.constraint(equalTo: transportBar.centerYAnchor),
            fastForwardButton.widthAnchor.constraint(equalToConstant: 26),
            fastForwardButton.heightAnchor.constraint(equalToConstant: 26),

            scrubber.leadingAnchor.constraint(equalTo: fastForwardButton.trailingAnchor, constant: 10),
            scrubber.centerYAnchor.constraint(equalTo: transportBar.centerYAnchor),

            frameLabel.leadingAnchor.constraint(equalTo: scrubber.trailingAnchor, constant: 8),
            frameLabel.widthAnchor.constraint(equalToConstant: 84),
            frameLabel.centerYAnchor.constraint(equalTo: transportBar.centerYAnchor),

            fpsPopUp.leadingAnchor.constraint(equalTo: frameLabel.trailingAnchor, constant: 8),
            fpsPopUp.trailingAnchor.constraint(equalTo: transportBar.trailingAnchor, constant: -10),
            fpsPopUp.centerYAnchor.constraint(equalTo: transportBar.centerYAnchor)
        ])

        self.view = container
        self.preferredContentSize = Self.defaultPreferredContentSize
    }

    func preparePreviewOfFile(at url: URL) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw CinePreviewImageError.noMetalDevice
        }
        self.device = device
        mtkView.device = device

        // Not stored on `self` — nothing after this method returns needs to
        // read it directly anymore. `cache`/`playbackController` (both
        // stored below) already keep it alive for the lifetime of the
        // session; a separate `self.cineFile` would just be a second,
        // redundant strong reference to the same object the old
        // implementation needed only because `sliderMoved(_:)` used to
        // decode frames on its own, independently of the idle loop.
        let cineFile = try CineFile(url: url)

        // `cineFile.bitmapInfo.width`/`.height` are PIXEL counts. Dividing
        // by the backing scale factor converts them to POINTS — what
        // `preferredContentSize` actually needs (see `loadView()`'s doc
        // comment for the full, confirmed history of why getting this wrong
        // silently produces a badly-cropped preview panel). Computed once,
        // up front — every frame of the same clip shares the same real
        // pixel resolution, so the scale factor itself doesn't vary by
        // frame.
        let scale = view.window?.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        pointScale = scale

        let pointSize = NSSize(
            width: CGFloat(cineFile.bitmapInfo.width) / scale,
            height: CGFloat(cineFile.bitmapInfo.height) / scale
        )
        let maxDimension: CGFloat = 900
        let fitScale = min(maxDimension / pointSize.width, maxDimension / pointSize.height, 1)
        preferredContentSize = NSSize(
            width: pointSize.width * fitScale,
            height: pointSize.height * fitScale
        )

        // A one-time, cache-bypassing decode of frame 0's raw pixels,
        // purely so `ExposureUniforms.init(cineFile:frame:debayerMode:lutEnabled:)`'s
        // internal `CalibrationPlausibility` check has real pixel data to
        // sanity-check this file's own recorded color calibration against —
        // mirrors `CineDocumentModel.open(url:)`'s identical one-off decode,
        // done for the identical reason. This pixel buffer is never
        // retained or uploaded to the GPU; `uniforms` is a per-file
        // constant computed once here, not recomputed per displayed frame
        // (see that property's own doc comment for why nothing here varies
        // frame-to-frame).
        let firstFrame = try cineFile.decodeFrame(at: 0)
        uniforms = ExposureUniforms(
            cineFile: cineFile,
            frame: firstFrame,
            debayerMode: .highQuality
        )

        let cache = DecodedFrameCache(cineFile: cineFile, device: device)
        // Prefer the file's own real playback rate (`Setup.fPbRate` — see
        // `CineSetup.pbRate`'s own doc comment) over the generic ~30fps
        // default, mirroring `CineDocumentModel.open(url:)`'s identical
        // fallback logic exactly, so this preview's default speed matches
        // what professional editing software already shows for the same
        // file — confirmed directly: a VEO camera set to "1080/24p" writes
        // `fPbRate == 24.0`, and editors interpret that file as exactly
        // 24.00fps with no manual conforming. Falls back to `30` both when
        // `pbRate` is absent (an older/shorter SETUP block) and when it's
        // present but `<= 0` (a malformed stored value). Retained in
        // `fileOwnReviewFPS` as the "1x" baseline the speed multiplier below
        // scales.
        fileOwnReviewFPS = cineFile.setup.pbRate.map(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 30
        // A user-set "customize the quick look default playback speed"
        // multiplier (see `QuickLookPlaybackPreferences.speedMultiplier`'s
        // own doc comment) scales this file's own rate — `1.0` (the default
        // when nothing has ever been saved) leaves it unchanged, exactly
        // what this preview's behavior was before this preference existed.
        let speedMultiplier = QuickLookPlaybackPreferences.speedMultiplier
        let reviewFPS = fileOwnReviewFPS * speedMultiplier

        let controller = PlaybackController(
            frameCount: cineFile.frameCount,
            cache: cache,
            reviewFPS: reviewFPS,
            captureFrameRate: cineFile.setup.effectiveFrameRate,
            firstImageNo: Int(cineFile.header.firstImageNo)
        )
        self.cache = cache
        self.playbackController = controller
        selectFPSPopUpItem(forMultiplier: speedMultiplier)

        // `scrubber` spans the *real* clip (`0...frameCount - 1`) — there is
        // no separate, shorter "preview reel" range anymore (see this
        // type's own doc comment). A `frameCount == 1` clip collapses
        // `maxValue` to `0`, which `NSSlider` handles fine (a slider with no
        // travel), matching there being nothing to scrub across anyway.
        scrubber.minValue = 0
        scrubber.maxValue = Double(max(cineFile.frameCount - 1, 0))
        scrubber.doubleValue = 0
        updateFrameLabel(frameNumber: 0, frameCount: cineFile.frameCount)

        subscribeToPlaybackController(controller)

        // Kicks off playback without waiting for a first frame to actually
        // land on screen — see this type's own doc comment on `@MainActor`
        // for why that's fine here. The `$currentFrameIndex` subscription
        // above already fires for frame 0's own initial value the moment
        // this subscription is created (Combine's `Published` publisher
        // emits the current value to a fresh subscriber immediately), so
        // frame 0's fetch is already in flight before `play(rate:)` below
        // ever advances anywhere.
        controller.play(rate: .forwardNormal)
    }

    /// Runs every time `playbackController.currentFrameIndex` changes, for
    /// any reason — normal playback ticking forward, a loop restart, or a
    /// `scrubber` drag (see `sliderMoved(_:)`) — there is exactly one path
    /// through this method regardless of which of those caused the change.
    /// Keeps `scrubber`/`frameLabel` in sync (setting `scrubber.doubleValue`
    /// programmatically like this does not itself invoke `scrubber`'s
    /// target/action, so this can't recursively trigger `sliderMoved(_:)`),
    /// then hands off to `refetchCurrentTexture()` for the async half of
    /// this trigger.
    private func handleCurrentFrameIndexChanged(_ frameIndex: Int) {
        guard let playbackController else { return }
        scrubber.doubleValue = Double(frameIndex)
        updateFrameLabel(frameNumber: frameIndex, frameCount: playbackController.frameCount)
        refetchCurrentTexture(playbackController: playbackController)
    }

    /// Cancels whatever texture fetch was still in flight for the previous
    /// frame and starts a fresh one for whatever frame
    /// `playbackController.currentFrameIndex` points at right now — mirrors
    /// `CineMetalView.Coordinator`'s own `fetchTask` in the app target as
    /// closely as this SwiftUI-free context allows. On success, stores the
    /// texture and calls `mtkView.setNeedsDisplay(mtkView.bounds)`, which is
    /// the only thing that actually triggers `draw(in:)` to run again
    /// (`mtkView.enableSetNeedsDisplay == true` means there is no
    /// free-running draw loop otherwise).
    private func refetchCurrentTexture(playbackController: PlaybackController) {
        textureFetchTask?.cancel()
        textureFetchTask = Task { [weak self] in
            do {
                let texture = try await playbackController.currentTexture()
                guard !Task.isCancelled, let self else { return }
                self.rawTexture = texture
                self.mtkView.setNeedsDisplay(self.mtkView.bounds)
            } catch {
                // A single failed fetch — a genuine decode error, or simply
                // this task itself having been cancelled mid-`await` by a
                // newer frame-index change superseding it — must not crash
                // this extension. Whatever `rawTexture` already held stays
                // on screen unchanged.
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Draws `rawTexture` (whichever frame was most recently fetched by
    /// `refetchCurrentTexture(playbackController:)`) through `renderer`.
    /// Deliberately does no fetching of its own — an `MTKViewDelegate`
    /// callback must stay fast and synchronous, so this only ever consumes
    /// a texture that's already been fetched and stored ahead of time. A
    /// `nil` `rawTexture` (nothing decoded yet) or a failed lazy `renderer`
    /// construction both simply skip drawing this pass, leaving `mtkView`'s
    /// default clear color showing, rather than crashing — the next
    /// successful fetch's `setNeedsDisplay` call will ask for another draw.
    func draw(in view: MTKView) {
        if renderer == nil, let device {
            renderer = try? CineRenderer(device: device, bundle: Bundle.main)
        }
        guard
            let renderer,
            let rawTexture,
            let drawable = view.currentDrawable,
            let commandBuffer = renderer.commandQueue.makeCommandBuffer()
        else { return }

        // `lutTexture: nil`/`grading: .identity` — no in-flight LUT/grading
        // support in this preview, deliberately (see this type's own doc
        // comment).
        renderer.render(
            rawTexture: rawTexture,
            uniforms: uniforms,
            into: commandBuffer,
            colorAttachment: drawable.texture,
            lutTexture: nil,
            grading: .identity
        )
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    /// Fires on genuine user interaction with `scrubber` only (setting
    /// `scrubber.doubleValue` programmatically elsewhere, in
    /// `handleCurrentFrameIndexChanged(_:)`, does not invoke this). `pause()`
    /// first, then `seek(to:)` — the *same* `$currentFrameIndex` Combine
    /// subscription set up in `preparePreviewOfFile(at:)` already handles
    /// fetching+displaying whatever frame this seeks to and keeping
    /// `scrubber`/`frameLabel` in sync, so this method itself no longer does
    /// any direct rendering/CGImage/NSImage work at all — unlike the old
    /// implementation, which drove a wholly separate synchronous
    /// `CinePreviewImage.render` call per drag tick.
    ///
    /// Calling `pause()` first (rather than relying on `seek(to:)`'s own
    /// internal `pause()` alone) is what stops the idle loop permanently
    /// until the user drags again: the `$isPlaying` subscription only
    /// restarts playback when it observes `isPlaying == false` with
    /// `currentFrameIndex` already at `effectiveOutPoint` — an ordinary
    /// mid-range scrub essentially never lands exactly there, so it
    /// correctly does not auto-resume, exactly like ordinary scrubber
    /// behavior in a real player.
    @objc private func sliderMoved(_ sender: NSSlider) {
        playbackController?.pause()
        playbackController?.seek(to: Int(sender.doubleValue.rounded()))
    }

    /// A deliberately simple on/off toggle — see this type's own doc
    /// comment for why this is NOT `PlaybackController.togglePause()`
    /// (which would resume whatever specific rate was last active).
    /// Pressing this button while stopped always starts plain
    /// `.forwardNormal`; pressing it while *any* mode is active — including
    /// a fast-forward/reverse rate dialed in by the buttons below — always
    /// pauses. `playPauseButton`'s image itself is not touched here; it's
    /// kept in sync purely by the `controller.$isPlaying` subscription set
    /// up in `preparePreviewOfFile(at:)`, so this method only ever needs to
    /// decide *which* `PlaybackController` call to make.
    @objc private func playPauseClicked() {
        guard let playbackController else { return }
        if playbackController.isPlaying {
            playbackController.pause()
        } else {
            playbackController.play(rate: .forwardNormal)
        }
    }

    /// Cycles forward speed on each press — normal → fast → fast-fast →
    /// wraps back to normal — the same repeat-to-cycle-speeds gesture
    /// QuickTime Player's own fast-forward button uses. Starts at
    /// `.forwardNormal` from any state that isn't already playing forward
    /// (paused, reverse, or real-time). See `nextForwardRate()` for the
    /// actual state transition.
    @objc private func fastForwardClicked() {
        playbackController?.play(rate: nextForwardRate())
    }

    /// The mirror of `fastForwardClicked()`: cycles reverse speed on each
    /// press — normal → fast → fast-fast → wraps back to normal — starting
    /// at `.reverseNormal` from any state that isn't already playing in
    /// reverse.
    ///
    /// **Deliberately does not loop when reverse playback reaches the
    /// clip's start.** The auto-loop-restart subscription in
    /// `preparePreviewOfFile(at:)` only watches for *forward* playback
    /// running off `effectiveOutPoint` — it does not, and is not extended
    /// here to, cover reverse reaching `effectiveInPoint`. Reverse (and
    /// fast-forward/fast-reverse generally) simply stop wherever
    /// `PlaybackController` already stops them, with no new looping
    /// behavior added for those cases. This is a deliberate scope boundary
    /// from when these buttons were added, not an oversight to "fix" later.
    @objc private func rewindClicked() {
        playbackController?.play(rate: nextReverseRate())
    }

    /// The next forward `PlaybackRate` `fastForwardClicked()` should play
    /// at, given whatever `currentMode` is right now. Pattern-matches all
    /// three shapes `currentMode` can take: a specific `.rate`, `.realTime`
    /// (forward real-time counts as "already playing forward," but has no
    /// next `PlaybackRate` tier of its own to advance through, so this
    /// treats it like "start over" at `.forwardNormal` exactly like `nil`
    /// does), or `nil` (not playing at all).
    private func nextForwardRate() -> PlaybackRate {
        switch playbackController?.currentMode {
        case .rate(.forwardNormal):
            return .forwardFast
        case .rate(.forwardFast):
            return .forwardFastFast
        case .rate(.forwardFastFast):
            return .forwardNormal
        default:
            return .forwardNormal
        }
    }

    /// The exact mirror of `nextForwardRate()` for `rewindClicked()`.
    private func nextReverseRate() -> PlaybackRate {
        switch playbackController?.currentMode {
        case .rate(.reverseNormal):
            return .reverseFast
        case .rate(.reverseFast):
            return .reverseFastFast
        case .rate(.reverseFastFast):
            return .reverseNormal
        default:
            return .reverseNormal
        }
    }

    /// Called once per `controller.$isPlaying` emission (see
    /// `preparePreviewOfFile(at:)`) to keep `playPauseButton`'s image
    /// truthful regardless of what changed playback state — this button,
    /// `scrubber`, or the auto-loop-restart logic all end up handled here
    /// identically, with no separate bookkeeping needed per cause.
    private func updatePlayPauseButton(isPlaying: Bool) {
        let symbolName = isPlaying ? "pause.fill" : "play.fill"
        let description = isPlaying ? "Pause" : "Play"
        playPauseButton.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)?
            .withSymbolConfiguration(Self.transportGlyphConfiguration)
    }

    /// Applies the speed picker's current selection. `sender.selectedItem`'s
    /// `representedObject` carries the actual multiplier `Double` set up in
    /// `loadView()` — see that method's own comment on why the value lives
    /// on the menu item itself rather than a parallel array. Persists the
    /// choice to `QuickLookPlaybackPreferences.speedMultiplier` (shared with
    /// the main app's Settings window — see that type's own doc comment) so
    /// it's picked up by every subsequent preview of any file, then applies
    /// it to THIS preview immediately via `setReviewFPS(_:)` (see
    /// `PlaybackController`'s own doc comment on it — takes effect
    /// immediately even if `.forwardNormal`/etc. playback is already
    /// running).
    @objc private func fpsChanged(_ sender: NSPopUpButton) {
        guard let multiplier = sender.selectedItem?.representedObject as? NSNumber else { return }
        QuickLookPlaybackPreferences.speedMultiplier = multiplier.doubleValue
        playbackController?.setReviewFPS(fileOwnReviewFPS * multiplier.doubleValue)
    }

    /// Keeps `fpsPopUp`'s selection truthful to the multiplier playback is
    /// actually running at, rather than always showing the "1x" item
    /// `loadView()` selects at build time regardless of the persisted
    /// `QuickLookPlaybackPreferences.speedMultiplier`. Every multiplier this
    /// preview can ever be constructed with (1/2/5/10, all from `loadView()`
    /// or `fpsChanged(_:)` itself) has a matching fixed item, so — unlike
    /// the old absolute-rate version of this method — there is no "insert a
    /// 5th item for an unrecognized value" fallback to worry about here.
    /// Called once, from `preparePreviewOfFile(at:)`.
    private func selectFPSPopUpItem(forMultiplier multiplier: Double) {
        let epsilon = 0.005
        guard let matchingTitle = fpsPopUp.itemTitles.first(where: { title in
            guard let value = fpsPopUp.item(withTitle: title)?.representedObject as? NSNumber else { return false }
            return abs(value.doubleValue - multiplier) < epsilon
        }) else { return }
        fpsPopUp.selectItem(withTitle: matchingTitle)
    }

    private func updateFrameLabel(frameNumber: Int, frameCount: Int) {
        frameLabel.stringValue = "\(frameNumber + 1) / \(frameCount)"
    }

    /// Defensive teardown for this controller's playback/fetch state.
    /// `playbackController?.pause()` stops its play loop's `Task` from
    /// advancing any further the instant this instance starts deallocating;
    /// `textureFetchTask?.cancel()` does the same for whatever fetch was
    /// still in flight. `cancellables` needs no explicit cleanup here — a
    /// `Set<AnyCancellable>` cancels every subscription it holds
    /// automatically when the set itself deallocates, which happens
    /// alongside `self` regardless.
    ///
    /// This remains the only reachable cleanup hook for this class —
    /// `QLPreviewingController`'s own protocol (checked directly in
    /// `QLPreviewingController.h`) declares no "preview dismissed"/teardown
    /// callback, only the `preparePreview...`/`providePreview...` methods
    /// already implemented above.
    isolated deinit {
        playbackController?.pause()
        textureFetchTask?.cancel()
    }
}

extension PreviewViewController {
    private func configureTransportBarControls() {
        scrubber.isContinuous = true
        scrubber.target = self
        scrubber.action = #selector(sliderMoved(_:))
        scrubber.translatesAutoresizingMaskIntoConstraints = false

        frameLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        frameLabel.textColor = .secondaryLabelColor
        frameLabel.alignment = .right
        frameLabel.translatesAutoresizingMaskIntoConstraints = false

        // Flat glyphs (no bezel), explicit white tint since the bar's
        // background is always dark regardless of appearance.
        for button in [rewindButton, playPauseButton, fastForwardButton] {
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.contentTintColor = .white
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        rewindButton.image = NSImage(systemSymbolName: "backward.fill", accessibilityDescription: "Rewind")?
            .withSymbolConfiguration(Self.transportGlyphConfiguration)
        rewindButton.target = self
        rewindButton.action = #selector(rewindClicked)

        playPauseButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Play")?
            .withSymbolConfiguration(Self.transportGlyphConfiguration)
        playPauseButton.target = self
        playPauseButton.action = #selector(playPauseClicked)

        fastForwardButton.image = NSImage(systemSymbolName: "forward.fill", accessibilityDescription: "Fast Forward")?
            .withSymbolConfiguration(Self.transportGlyphConfiguration)
        fastForwardButton.target = self
        fastForwardButton.action = #selector(fastForwardClicked)

        fpsPopUp.translatesAutoresizingMaskIntoConstraints = false
        fpsPopUp.target = self
        fpsPopUp.action = #selector(fpsChanged(_:))
        let speedOptions: [(title: String, multiplier: Double)] = [
            ("1x", 1.0),
            ("2x", 2.0),
            ("5x", 5.0),
            ("10x", 10.0)
        ]
        for option in speedOptions {
            fpsPopUp.addItem(withTitle: option.title)
            fpsPopUp.lastItem?.representedObject = option.multiplier as NSNumber
        }
        // Superseded by selectFPSPopUpItem once the saved preference loads.
        fpsPopUp.selectItem(withTitle: "1x")
    }

    private func subscribeToPlaybackController(_ controller: PlaybackController) {
        controller.$currentFrameIndex
            .sink { [weak self] frameIndex in
                self?.handleCurrentFrameIndexChanged(frameIndex)
            }
            .store(in: &cancellables)

        // Implements looping by hand. `.removeDuplicates()` avoids
        // re-triggering a restart from a redundant pause() while already
        // paused at the end (e.g. from dragging the scrubber there).
        controller.$isPlaying
            .removeDuplicates()
            .sink { [weak controller] isPlaying in
                guard let controller, !isPlaying else { return }
                guard controller.currentFrameIndex >= controller.effectiveOutPoint else { return }
                controller.seek(to: controller.effectiveInPoint)
                controller.play(rate: .forwardNormal)
            }
            .store(in: &cancellables)

        controller.$isPlaying
            .sink { [weak self] isPlaying in
                self?.updatePlayPauseButton(isPlaying: isPlaying)
            }
            .store(in: &cancellables)
    }
}
