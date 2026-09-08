import Foundation
@preconcurrency import Metal

/// One of the 6 supported playback rates: how many frames
/// `PlaybackController` advances (or retreats, for the negative cases) per
/// `reviewFPS` tick. The raw value *is* that per-tick frame delta, so
/// `rate.rawValue` can be added straight to `currentFrameIndex` — positive
/// advances forward, negative walks backward. There is no `0` case: "not
/// playing" is represented by `PlaybackController.currentMode == nil`, not by
/// a rate of zero.
///
/// Higher speeds work by skipping frames per tick (bounded decode/prefetch
/// throughput regardless of rate) rather than by ticking faster — the same
/// approach the original single-speed forward-only loop already used at 1x,
/// generalized to the other 5 rates.
public enum PlaybackRate: Int, CaseIterable, Sendable {
    case reverseFastFast = -4
    case reverseFast = -2
    case reverseNormal = -1
    case forwardNormal = 1
    case forwardFast = 2
    case forwardFastFast = 4
}

/// What's currently driving the play loop: one of the 6 fixed-skip,
/// fixed-`reviewFPS`-cadence `PlaybackRate`s, or real-time (native capture
/// fps) playback in a given direction. Generalizes the old bare
/// `PlaybackRate?` "current rate" concept just enough to add the new mode
/// without giving it a second, parallel set of published/cancellation
/// plumbing — see `PlaybackController.currentMode` and `startPlaying`.
///
/// There is no `.rate`-and-`.realTime`-simultaneously state and no `0`/idle
/// case here either: exactly like the old `currentRate`, "not playing" is
/// `PlaybackController.currentMode == nil`, not a case of this type.
public enum PlaybackMode: Equatable, Sendable {
    case rate(PlaybackRate)
    case realTime(forward: Bool)

    /// Per-tick frame delta. `.rate` skips `PlaybackRate.rawValue` frames
    /// per tick, same as always. `.realTime` is always exactly ±1 — it never
    /// skips a captured frame; the requested playback speed comes entirely
    /// from the tick *interval* instead (see `PlaybackController.playRealTime`).
    var delta: Int {
        switch self {
        case .rate(let rate): return rate.rawValue
        case .realTime(let forward): return forward ? 1 : -1
        }
    }
}

/// Drives playback/scrubbing state for one open `.cine` file and mediates
/// every request for a displayable frame through its `DecodedFrameCache`.
///
/// `@preconcurrency import Metal`: `currentTexture()` below returns an
/// `MTLTexture` from `DecodedFrameCache` (an actor) into this `@MainActor`
/// class — see `DecodedFrameCache`'s doc comment for why that crossing is
/// actually safe despite `MTLTexture` not being `Sendable` in this SDK.
///
/// Two families of playback are supported:
///
///   - `play(rate:)` — the original mode. A fixed ~30fps ("review rate")
///     walk through every captured frame, skipping `PlaybackRate.rawValue`
///     frames per tick. Not a replay at the clip's actual capture fps — a
///     1000fps clip plays back in dramatic slow motion. Capture fps is
///     metadata only here; it never affects how fast frames advance.
///   - `playRealTime(forward:)` — true 1x motion speed: elapsed playback
///     time approximately matches elapsed real-world capture time. Never
///     skips a frame (delta is always exactly ±1, unlike `play(rate:)`'s
///     fixed-skip rates); instead the *tick interval* itself is
///     `1.0 / captureFrameRate` rather than the fixed review cadence. This
///     is what correctly handles a capture fps *below* `reviewFPS` too
///     (e.g. 24fps — playing slower than the default review rate) without
///     needing any fractional-frame-advance logic: a 24fps clip just ticks
///     every ~41.7ms instead of every ~33.3ms, still one frame per tick
///     either way.
///
/// Both families share one play loop (`startPlaying`) and one
/// `generation`-counter-based cancellation scheme — see that method and
/// `currentMode`.
@MainActor
public final class PlaybackController: ObservableObject {
    public let frameCount: Int
    /// The fixed ~30fps ("review rate") tick cadence `play(rate:)` uses —
    /// see this type's own doc comment. `private(set)`, not `let`: mutable
    /// via `setReviewFPS(_:)` below so a caller (the Quick Look preview's fps
    /// picker, at the time this was added) can change the review cadence at
    /// runtime — the main app itself never calls `setReviewFPS`, so its
    /// behavior (always the `init` default of 30) is unaffected either way.
    public private(set) var reviewFPS: Double
    /// The clip's own capture frame rate (`CineSetup.effectiveFrameRate`),
    /// if the file's metadata has one — `nil` for files missing both the
    /// 32-bit and legacy 16-bit `SETUP` frame-rate fields. Drives
    /// `playRealTime(forward:)`'s tick interval; `play(rate:)` never reads
    /// this (it always ticks at `reviewFPS` regardless).
    public let captureFrameRate: Double?
    /// `CineFileHeader.firstImageNo`, copied in at construction time: the
    /// trigger-relative frame number (Vision Research numbers frames
    /// relative to the camera's trigger point, so this is frequently
    /// negative — e.g. a pre-trigger-heavy capture can have
    /// `firstImageNo == -2658`) of this file's frame `0`. Exists purely so
    /// UI that wants to show trigger-relative frame numbers (`ScrubberView`'s
    /// three readouts) can compute `firstImageNo + currentFrameIndex` without
    /// reaching back through `CineDocumentModel`/`CineFile` for a value that
    /// belongs alongside `currentFrameIndex` itself. Never read by any
    /// playback/scrubbing logic in this file — `currentFrameIndex` and every
    /// mutator below are entirely 0-based and unaware this offset exists.
    public let firstImageNo: Int

    @Published public private(set) var currentFrameIndex: Int = 0
    @Published public private(set) var isPlaying: Bool = false
    /// The mode currently driving playback, or `nil` when paused. Kept in
    /// lockstep with `isPlaying` (non-nil exactly when `isPlaying` is true) —
    /// a separate property rather than folding mode into `isPlaying` itself
    /// so the transport UI can tell *which* button is active (to highlight
    /// it / toggle it back to pause on a second click) without also having
    /// to track that mapping itself.
    @Published public private(set) var currentMode: PlaybackMode?

    /// In-point (0-based frame index), or `nil` meaning "not set" — the
    /// range defaults to the full clip. Doubles as both the export-range
    /// start and a live playback boundary: `startPlaying(mode:interval:)`
    /// stops forward playback at `effectiveOutPoint` and reverse playback at
    /// `effectiveInPoint`, and jumps to the opposite bound when playback is
    /// (re)started sitting at/past the boundary it would otherwise
    /// immediately stop at. `setInPoint`/`setOutPoint` also seek the
    /// playhead to the point being set. `step(by:)`, `seek(to:)`, and
    /// `setCurrentFrameIndex` are unaffected by any of this — they still
    /// walk/clamp against the full `[0, frameCount - 1]` range regardless of
    /// whether a range is set; only the play loop itself is bounded. Only
    /// `setInPoint`/`setOutPoint`/`resetRange` below ever mutate this pair.
    @Published public private(set) var inPoint: Int?
    /// Out-point (0-based frame index), or `nil` meaning "not set" (defaults
    /// to `frameCount - 1`). See `inPoint`'s doc comment for the full
    /// playback-bounding behavior — symmetric here.
    @Published public private(set) var outPoint: Int?

    /// The most recent `PlaybackMode` playback actually started in, kept set
    /// across a `pause()` (unlike `currentMode`, which `pause()` clears back
    /// to `nil`) so a later `togglePause()` resume can put playback back
    /// into whatever mode/rate/direction it was actually in before pausing,
    /// rather than always resetting to plain forward 1x. Set alongside
    /// `currentMode` inside `startPlaying(mode:interval:)`; never cleared by
    /// `pause()`. `nil` only until the first successful `startPlaying` of
    /// the session.
    private var lastMode: PlaybackMode?

    private let cache: DecodedFrameCache
    private var playTask: Task<Void, Never>?

    /// Monotonically increasing identifier for the "current" play/pause
    /// operation. Bumped by every `play(rate:)`/`playRealTime(forward:)` and
    /// `pause()` call so a play task's deferred end-of-loop cleanup can tell
    /// whether it's still the operation in charge before touching shared
    /// state — see `startPlaying`. The same single counter (not one per
    /// mode) covers switching between modes too: calling either starter
    /// while already playing (at any rate, or in real-time) bumps this
    /// exactly like any other supersession, so a stale task from the
    /// previous mode can never clobber the new one's state.
    private var generation: Int = 0

    /// Notified with the new `currentFrameIndex` whenever `seek(to:)` jumps
    /// the playhead directly — never fired by `step(by:)` or by a normal
    /// playback tick (both funnel through `setCurrentFrameIndex` directly,
    /// not `seek`), since those move by small, fixed deltas that stay well
    /// within `DecodedFrameCache`'s own prefetch window. Set by
    /// `CineDocumentModel.open(url:)` so a background file-cache warm still
    /// in flight for a just-opened large file can re-bias toward wherever
    /// the user jumps, instead of blindly continuing front-to-back — see
    /// `CineDocumentModel.handleSeek(frameIndex:)`. `nil` by default and
    /// harmless to leave unset for any other embedder of this class (the
    /// Quick Look preview extension's own `PlaybackController` never sets
    /// it). `@MainActor`, not a plain closure: both this class and
    /// `CineDocumentModel` are already `@MainActor`-isolated, and marking
    /// the closure itself lets it call back into `CineDocumentModel`
    /// without an `await` at either end.
    public var onSeek: (@MainActor (Int) -> Void)?

    public init(frameCount: Int, cache: DecodedFrameCache, reviewFPS: Double = 30, captureFrameRate: Double? = nil, firstImageNo: Int = 0) {
        self.frameCount = max(0, frameCount)
        self.cache = cache
        self.reviewFPS = reviewFPS
        self.captureFrameRate = captureFrameRate
        self.firstImageNo = firstImageNo
    }

    /// Starts (or restarts, possibly at a new rate) playback from the
    /// current frame, advancing `currentFrameIndex` by `rate.rawValue`
    /// frames every `1.0 / reviewFPS` seconds until the range end in that
    /// direction is reached, at which point it stops on its own — it never
    /// wraps around. Cancels any playback already in progress first, so
    /// calling this while already playing (at any rate, or in real-time)
    /// switches to `rate` rather than stacking loops.
    public func play(rate: PlaybackRate = .forwardNormal) {
        startPlaying(mode: .rate(rate), interval: 1.0 / reviewFPS)
    }

    /// Changes the review-rate tick cadence `play(rate:)` uses, taking
    /// effect immediately if a `.rate(...)` loop is currently running.
    ///
    /// **Why the restart-if-currently-in-`.rate`-mode branch is needed:**
    /// `play(rate:)` computes its tick `interval` *once*, from whatever
    /// `reviewFPS` was at the moment it was called — `startPlaying(mode:interval:)`
    /// takes a fixed `interval` argument, not a live-read property, and the
    /// play loop's `Task` closes over that one `Double` for its entire run.
    /// So simply mutating `reviewFPS` here would have zero effect on a
    /// `.rate(...)` loop already ticking away at the old cadence — it would
    /// only apply the next time *something else* happened to call
    /// `play(rate:)` again. Re-calling `play(rate: rate)` with the *same*
    /// `rate` is what actually picks up the new `reviewFPS`: it doesn't move
    /// `currentFrameIndex` at all, it just tears down the old tick loop and
    /// starts a fresh one — at the same rate, from the same frame, just with
    /// a new `interval` computed from the now-updated `reviewFPS`.
    ///
    /// **Why `.realTime(...)` mode is deliberately left untouched:** its tick
    /// interval comes from `captureFrameRate` (or falls back to `reviewFPS`
    /// only when `captureFrameRate` itself is unavailable — see
    /// `playRealTime(forward:)`), not from `reviewFPS` directly in the common
    /// case. A `reviewFPS` change has nothing to do with real-time playback's
    /// speed, so restarting a `.realTime(...)` loop here would be both
    /// pointless and a visible, unrequested playhead hiccup.
    ///
    /// This is a behavior-preserving, purely additive change: nothing in
    /// this package calls `setReviewFPS`, so the main app (whose
    /// `CineDocumentModel.open(url:)` never sets a custom `reviewFPS`) is
    /// entirely unaffected. Only new callers — the Quick Look preview's fps
    /// picker, at the time this was added — ever invoke this.
    public func setReviewFPS(_ fps: Double) {
        guard fps > 0, fps != reviewFPS else { return }
        reviewFPS = fps
        if case .rate(let rate) = currentMode {
            play(rate: rate)
        }
    }

    /// Starts (or restarts) real-time playback from the current frame in
    /// `forward`'s direction: advances `currentFrameIndex` by exactly 1
    /// frame every `1.0 / captureFrameRate` seconds — true 1x motion speed —
    /// until the range end in that direction is reached, exactly like
    /// `play(rate:)`. Falls back to `1.0 / reviewFPS` (the same cadence as
    /// `play(rate: .forwardNormal)`) if `captureFrameRate` is unavailable:
    /// real-time framing is meaningless without a known capture rate, so
    /// this degrades to the review cadence rather than refusing to play.
    ///
    /// **On very-high-fps clips outrunning real decode throughput:** this
    /// loop never awaits a decode — exactly like `play(rate:)`, each tick
    /// only bumps `currentFrameIndex` and fires a fire-and-forget prefetch
    /// (`setCurrentFrameIndex`). It sleeps a fresh, fixed `interval` every
    /// iteration rather than racing to catch up to an absolute deadline, so
    /// a decode that can't keep up cannot make *this loop* spin, hang, or
    /// accumulate a backlog of queued ticks — it simply free-runs at
    /// whatever real cadence `Task.sleep(for:)` actually delivers. Whether
    /// every one of those ticks' frames actually gets decoded+shown is a
    /// separate question the view layer already answers by dropping stale
    /// work: `CineMetalView`'s fetch task (and `DecodedFrameCache`'s own
    /// in-flight cancellation) always cancels an outstanding decode as soon
    /// as a newer `currentFrameIndex` supersedes it, so a decode that's
    /// still running when the next tick lands is simply abandoned rather
    /// than queued — the visible result is dropped frames, not lag that
    /// compounds. See `PlaybackController`'s own doc comment for the
    /// measured throughput ceiling this hits in practice on a 1536fps
    /// sample.
    public func playRealTime(forward: Bool = true) {
        // `.flatMap` (not `.map`) so an explicitly-zero `captureFrameRate` —
        // a malformed/legacy `.cine` file's `SETUP.FrameRate` present but
        // stored as exactly 0, which is never physically meaningful — falls
        // back to `reviewFPS` exactly like a genuinely-absent frame rate
        // does, instead of producing `1.0 / 0.0 == .infinity` and crashing
        // `Task.sleep(for:)`/`Duration.seconds(_:)` the instant this loop's
        // first tick fires.
        let interval = captureFrameRate.flatMap { $0 > 0 ? 1.0 / $0 : nil } ?? (1.0 / reviewFPS)
        startPlaying(mode: .realTime(forward: forward), interval: interval)
    }

    /// The shared play loop behind both `play(rate:)` and
    /// `playRealTime(forward:)`: ticks every `interval` seconds, advancing
    /// `currentFrameIndex` by `mode.delta` each tick, until the range end in
    /// `mode.delta`'s direction is reached. Identical in structure (and in
    /// its `generation`-counter cancellation/supersession guarantee) to what
    /// was previously `play(rate:)`'s own private loop body — pulled out so
    /// neither mode duplicates it.
    private func startPlaying(mode: PlaybackMode, interval: Double) {
        let delta = mode.delta

        // If playback is being (re)started sitting at/past the boundary it
        // would immediately stop at (e.g. resuming forward playback already
        // parked on `effectiveOutPoint` — pressing Space/K at the very end
        // of a clip), jump to the opposite bound first so the request
        // actually starts a fresh pass through the range instead of being
        // rejected as boundary-invalid below. Unconditional — with no
        // explicit in/out range set, `effectiveInPoint`/`effectiveOutPoint`
        // are just the clip's true `0`/`frameCount - 1` edges, so this is
        // "restart from the beginning," matching ordinary media-player
        // expectations for pressing play again after a clip has finished,
        // not something that only makes sense once a trim range exists.
        if delta > 0, currentFrameIndex >= effectiveOutPoint {
            setCurrentFrameIndex(effectiveInPoint)
        } else if delta < 0, currentFrameIndex <= effectiveInPoint {
            setCurrentFrameIndex(effectiveOutPoint)
        }

        // Validate *before* touching `playTask`/`generation` at all: a
        // boundary-invalid request (e.g. asking for reverse while already
        // sitting at frame 0, or at `effectiveInPoint` with a range set)
        // must be a true no-op that leaves whatever is currently playing
        // untouched. Cancelling the previous task first (the old order)
        // would silently kill legitimate, still-valid playback in the
        // *other* direction/mode just because this new request itself
        // can't start — and since the guard below returns before
        // `generation` is bumped, the cancelled task's own deferred cleanup
        // would then find `generation` unchanged and clear
        // `isPlaying`/`currentMode` anyway, leaving playback stopped with no
        // error and nothing visibly replacing it.
        let atEnd = delta > 0 ? currentFrameIndex >= effectiveOutPoint : currentFrameIndex <= effectiveInPoint
        guard frameCount > 0, !atEnd else { return }

        playTask?.cancel()
        generation += 1
        let myGeneration = generation

        isPlaying = true
        currentMode = mode
        lastMode = mode
        playTask = Task { [weak self] in
            guard let self else { return }
            var reachedEnd = false
            while !reachedEnd {
                try? await Task.sleep(for: .seconds(interval))
                if Task.isCancelled { break }
                // Clamp the proposed next index to the effective boundary
                // *before* advancing, rather than stepping by the raw
                // `delta` and only detecting an overshoot afterward — at any
                // fixed-skip rate above 1x, the raw step can otherwise land
                // past `effectiveOutPoint`/`effectiveInPoint` when the
                // distance to the boundary isn't an exact multiple of the
                // rate's frame delta.
                let proposed = self.currentFrameIndex + delta
                let next = delta > 0 ? min(proposed, self.effectiveOutPoint) : max(proposed, self.effectiveInPoint)
                self.setCurrentFrameIndex(next)
                reachedEnd = delta > 0 ? next >= self.effectiveOutPoint : next <= self.effectiveInPoint
            }
            // Cancellation always means a newer operation (a fresh
            // `play(rate:)`/`playRealTime(forward:)`, or a
            // `pause()`/`step()`/`seek()`) already took over and bumped
            // `generation` — in that case this task's own cleanup must not
            // stomp state the newer operation already set. Only clear
            // `isPlaying`/`currentMode`/`playTask` if this task is still the
            // current generation, i.e. it ran to natural completion
            // (`reachedEnd`) without ever being superseded.
            guard self.generation == myGeneration else { return }
            self.isPlaying = false
            self.currentMode = nil
            self.playTask = nil
        }
    }

    /// Starts playing at `rate`, unless `rate` is already the active mode —
    /// in that case this pauses instead, matching the existing play/pause
    /// button's toggle behavior generalized to all 6 rates: clicking the
    /// button for the rate that's already running stops playback, while
    /// clicking a *different* rate's (or real-time's) button switches to it
    /// directly (e.g. pressing forward while reverse is playing goes
    /// straight to forward, it does not pause first).
    public func togglePlay(rate: PlaybackRate = .forwardNormal) {
        if isPlaying && currentMode == .rate(rate) {
            pause()
        } else {
            play(rate: rate)
        }
    }

    /// Starts real-time playback in `forward`'s direction, unless real-time
    /// playback in that same direction is already the active mode — in that
    /// case this pauses instead. Mirrors `togglePlay(rate:)`'s toggle
    /// behavior, generalized to real-time's 2 directions.
    public func toggleRealTime(forward: Bool = true) {
        if isPlaying && currentMode == .realTime(forward: forward) {
            pause()
        } else {
            playRealTime(forward: forward)
        }
    }

    /// Stops playback in progress (a no-op if not playing).
    public func pause() {
        generation += 1
        playTask?.cancel()
        playTask = nil
        isPlaying = false
        currentMode = nil
    }

    /// Pauses if currently playing; otherwise resumes whatever mode was
    /// actually playing before the most recent pause (`lastMode`) — a fixed
    /// rate resumes at that same rate, real-time resumes in that same
    /// direction — rather than always restarting at plain forward 1x. Backs
    /// the K and Space keyboard shortcuts, which are meant to be plain
    /// pause/resume toggles rather than "reset to forward" buttons.
    ///
    /// `lastMode == nil` (nothing has ever played yet this session) falls
    /// back to `play(rate: .forwardNormal)` rather than doing nothing —
    /// keyboard shortcuts should never be a silent no-op — though in
    /// practice this path isn't reachable from K/Space once a file is open,
    /// since opening a file doesn't itself start playback.
    public func togglePause() {
        if isPlaying {
            pause()
        } else {
            switch lastMode {
            case .rate(let rate):
                play(rate: rate)
            case .realTime(let forward):
                playRealTime(forward: forward)
            case nil:
                play(rate: .forwardNormal)
            }
        }
    }

    /// Pauses playback, then moves `delta` frames from the current index
    /// (clamped to the valid range).
    public func step(by delta: Int) {
        pause()
        setCurrentFrameIndex(currentFrameIndex + delta)
    }

    /// Pauses playback, then jumps directly to `index` (clamped to the
    /// valid range).
    public func seek(to index: Int) {
        pause()
        setCurrentFrameIndex(index)
        onSeek?(currentFrameIndex)
    }

    /// `inPoint`, defaulting to the first frame (`0`) when unset — for
    /// consumers that want the *effective* range start without each having
    /// to repeat the "`nil` means start of clip" default themselves.
    public var effectiveInPoint: Int { inPoint ?? 0 }

    /// `outPoint`, defaulting to the last frame (`frameCount - 1`) when
    /// unset. Mirrors `effectiveInPoint`.
    public var effectiveOutPoint: Int { outPoint ?? max(0, frameCount - 1) }

    /// Sets the range's in point (range start), then seeks the playhead to
    /// it — the same convention professional NLEs use for "set in point at
    /// playhead," and what keeps a live drag on `ScrubberView`'s in-handle
    /// moving the visible frame in lockstep with the handle.
    ///
    /// Clamped to `[0, frameCount - 1]`, and additionally clamped to never
    /// exceed the current out point (`effectiveOutPoint`, i.e. `outPoint`
    /// defaulting to the last frame when unset): dragging the in-handle
    /// rightward past the out-handle stops it flush against the out-handle
    /// rather than swapping which handle is "in" vs. "out" or producing an
    /// inverted (`inPoint > outPoint`) range. A clamp-to-touching, no-swap
    /// rule was chosen over swapping the two roles because this is driven
    /// live from a drag gesture (`ScrubberView`'s in-handle) — swapping
    /// roles mid-drag would mean the handle the user's cursor is still on
    /// suddenly becomes the *other* handle, which is far more disorienting
    /// than the handle simply refusing to cross its sibling.
    public func setInPoint(_ index: Int) {
        guard frameCount > 0 else { return }
        let upperBound = effectiveOutPoint
        let clamped = max(0, min(upperBound, index))
        inPoint = clamped
        seek(to: clamped)
    }

    /// Sets the range's out point (range end) — symmetric to `setInPoint`:
    /// clamped to `[0, frameCount - 1]` and to never fall below the current
    /// in point (`effectiveInPoint`), then seeks the playhead to it. See
    /// `setInPoint`'s doc comment for why this clamps rather than swaps, and
    /// for the seek-on-set rationale.
    public func setOutPoint(_ index: Int) {
        guard frameCount > 0 else { return }
        let lowerBound = effectiveInPoint
        let upperBound = max(0, frameCount - 1)
        let clamped = min(upperBound, max(lowerBound, index))
        outPoint = clamped
        seek(to: clamped)
    }

    /// Clears both in and out points, restoring the default full-clip
    /// export range. Never touches playback state.
    public func resetRange() {
        inPoint = nil
        outPoint = nil
    }

    /// The texture for the frame currently on screen, decoding+uploading it
    /// first if it isn't already cached. This is the only way the view
    /// layer obtains a frame to draw.
    public func currentTexture() async throws -> MTLTexture {
        try await cache.texture(at: currentFrameIndex)
    }

    /// The single place `currentFrameIndex` is ever mutated: clamps to the
    /// valid range, then — if the (clamped) value actually changed — kicks
    /// off a fire-and-forget prefetch biased in the direction of travel.
    /// This stands in for a `didSet` observer (which does not compose
    /// cleanly with `@Published`'s own storage); every public mutator above
    /// funnels through here, so the clamping/prefetching guarantee holds
    /// regardless of entry point.
    private func setCurrentFrameIndex(_ newValue: Int) {
        guard frameCount > 0 else {
            currentFrameIndex = 0
            return
        }
        let clamped = max(0, min(frameCount - 1, newValue))
        guard clamped != currentFrameIndex else { return }

        let direction = clamped > currentFrameIndex ? 1 : -1
        currentFrameIndex = clamped

        let target = clamped
        Task { [weak self] in
            await self?.cache.prefetch(around: target, direction: direction)
        }
    }
}
