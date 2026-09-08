import Foundation
@preconcurrency import Metal
import CineKit

/// A bounded, LRU-evicting cache of decoded-and-uploaded frame textures for
/// one `CineFile`.
///
/// `@preconcurrency import Metal`: Metal's key protocols (`MTLDevice`,
/// `MTLTexture`, `MTLCommandQueue`, ...) are plain Objective-C protocols in
/// this SDK, not yet annotated `Sendable` — and unlike a class, there is no
/// way to retroactively attach a `Sendable` conformance to an existing
/// protocol from outside the module that declares it (`extension MTLDevice:
/// Sendable {}` is a compiler error: protocol extensions cannot add an
/// inheritance clause). The values are genuinely safe to move across the
/// actor boundary below regardless: `MTLDevice` is a process-wide handle
/// Apple documents as safe to share and use concurrently; the `MTLTexture`
/// this actor hands out is never mutated again after `makeFrameTexture`
/// finishes uploading it (this cache is the only place a texture's pixel
/// contents are ever written). `@preconcurrency` is the mechanism Swift
/// itself provides for a framework whose Objective-C protocols haven't
/// been concurrency-audited yet, downgrading the resulting diagnostics here
/// to warnings instead of errors; it's applied only to this import (and the
/// handful of other files that actually pass these Metal types across an
/// isolation boundary), not blanket-suppressed for the whole module.
///
/// This is the single place in the app where a frame is ever decoded
/// (`CineFile.decodeFrame`) and uploaded to the GPU (`makeFrameTexture`).
/// Callers never see a raw `DecodedFrame` — only the `MTLTexture` it was
/// uploaded into — so each cache entry costs roughly `width * height * 2`
/// bytes of GPU-backed texture storage instead of also keeping the raw
/// `[UInt16]` pixel array (which `DecodedFrame` owns) alive for no reason.
///
/// Being an `actor` gives every stored property (the LRU table and the
/// in-flight-decode table) automatic mutual exclusion: concurrent calls from
/// `PlaybackController` (direct `texture(at:)` requests) and its own
/// prefetch fire-and-forget tasks all serialize through this actor's
/// executor.
///
/// The actual CPU decode (`CineFile.decodeFrame`) + GPU upload
/// (`makeFrameTexture`) work, however, deliberately does *not* run on this
/// actor's own executor — see `makeDecodeTask`/`completeDecode`. Under
/// sustained continuous playback, dozens of speculative prefetch decodes can
/// be in flight; if each one's real decode+upload work (measured up to
/// several hundred milliseconds under load) ran synchronously on this
/// actor's single serial executor with no suspension point, it would delay
/// *any* other request through this same actor — including the view layer's
/// own request for the texture of the frame currently on screen — behind
/// whatever backlog of purely speculative, not-yet-needed prefetch jobs
/// happened to be queued first. Instead, each decode+upload runs off-actor
/// on its own detached `Task`, and only hops back onto the actor briefly
/// (`completeDecode`) to record the outcome — a plain dictionary/LRU update
/// with no CPU decode or GPU upload inside it, so it can't itself become a
/// new bottleneck. `texture(at:)`'s own direct (non-speculative) decode
/// requests additionally run at `.userInitiated` priority versus
/// `prefetch`'s `.utility`, so the OS scheduler favors the frame actually
/// being displayed over frames that merely might be needed soon.
///
/// **What this off-actor/priority fix does *not* address:** everything
/// above is CPU-side scheduling of work that already has its bytes in
/// hand — reordering *which thread, and how urgently* an already-available
/// frame gets decoded. It has no way to make bytes that are not yet
/// resident in the OS page cache appear any faster. Measured: on a
/// never-before-read `.cine` file (the common "open file, immediately
/// press real-time play" first pass), real-time playback can display well
/// under 1% of a clip's frames, dominated by per-page disk I/O — the exact
/// same code against the exact same file, once its bytes are page-cache-
/// warm, displays 80-100%+ of them. That gap is disk-I/O-bound, not
/// CPU-scheduling-bound, and this type's own fix cannot close it by itself.
/// `CineDocumentModel.open`'s background `primeFileCache(at:)` call is the
/// actual mitigation for that first-pass-cold case (see its doc comment in
/// CineKit); it reduces how often a real decode here actually blocks on
/// cold disk I/O, but for a sufficiently large file opened and immediately
/// played before the OS has had time to warm it, some cold-I/O exposure on
/// the first pass remains an inherent property of reading a file nobody has
/// read yet, not something this cache (or that priming call) can fully
/// eliminate.
public actor DecodedFrameCache {
    private let cineFile: CineFile
    private let device: MTLDevice
    private let capacity: Int

    /// Cached textures, keyed by frame index.
    private var textures: [Int: MTLTexture] = [:]
    /// Usage order for LRU eviction: index 0 is least-recently-used, the
    /// last element is most-recently-used.
    private var lruOrder: [Int] = []

    /// Decode+upload work currently running (or merely scheduled but not
    /// yet started — cancellation before the decode actually begins is
    /// exactly what makes rapid scrubbing cheap) for a given frame index.
    private var inFlight: [Int: Task<MTLTexture, Error>] = [:]

    /// The generation number of whichever decode task is the *current*
    /// occupant of `inFlight[index]`, keyed by `index`. `completeDecode`'s
    /// deferred cleanup compares its own captured generation against this
    /// before touching `inFlight`, so a cancelled task's cleanup — which may
    /// run arbitrarily late, after `inFlight[index]` has already been
    /// reassigned to a newer decode for the same index — can never remove
    /// that newer task's entry out from under it.
    private var inFlightGeneration: [Int: UInt64] = [:]
    private var nextGeneration: UInt64 = 0

    /// Incremented exactly once per real `cineFile.decodeFrame` call (never
    /// on a cache hit, and never for a task that was cancelled before its
    /// decode began). Test/verification infrastructure for `cine-scrub-bench`.
    public private(set) var decodeCount: Int = 0

    public init(cineFile: CineFile, device: MTLDevice, capacity: Int = 120) {
        self.cineFile = cineFile
        self.device = device
        self.capacity = max(1, capacity)
    }

    /// Number of frames currently resident in the cache. Always `<= capacity`.
    public var cachedFrameCount: Int {
        textures.count
    }

    /// Estimated GPU-backed storage (in bytes) currently held by resident
    /// textures: `width * height * 2` per entry (16-bit-per-pixel, matching
    /// this type's own doc comment on what a cache entry costs), summed over
    /// every texture in `textures`.
    ///
    /// This is the cache's own, self-reported footprint — independent of
    /// whatever else the process has resident (e.g. mmap'd pages of the
    /// source `.cine` file). `cine-scrub-bench` reports this alongside
    /// process-wide peak RSS specifically because peak RSS alone conflates
    /// the two and cannot, by itself, demonstrate that *this cache* is
    /// memory-bounded.
    public var cachedByteSize: Int {
        textures.values.reduce(0) { $0 + $1.width * $1.height * 2 }
    }

    /// Returns the uploaded texture for `index`, decoding+uploading it first
    /// if necessary.
    ///
    /// - A cache hit returns immediately and marks `index` most-recently-used.
    /// - If a decode for `index` is already in flight (started by an earlier
    ///   `texture(at:)` call or by `prefetch`), this awaits and returns that
    ///   same task's result rather than decoding a second time.
    /// - Otherwise this starts the decode+upload, tracks it in `inFlight` so
    ///   other concurrent requests (or a later `prefetch`) can find it, and
    ///   inserts the result into the LRU cache, evicting the
    ///   least-recently-used entry if that pushes the cache over `capacity`.
    public func texture(at index: Int) async throws -> MTLTexture {
        if let cached = textures[index] {
            touch(index)
            return cached
        }
        if let existing = inFlight[index] {
            return try await existing.value
        }
        // `.userInitiated`: this is a direct request for a frame the caller
        // actually wants right now (typically the one currently on screen),
        // not a speculative `prefetch` guess — see this type's own doc
        // comment on why that priority distinction, plus running off-actor
        // at all, matters under sustained playback.
        let task = makeDecodeTask(index: index, priority: .userInitiated)
        inFlight[index] = task
        return try await task.value
    }

    /// Kicks off (fire-and-forget, but tracked) background decode+upload for
    /// frames around `index`, biased in `direction` (the way the caller's
    /// position is currently moving): `radius` frames ahead in `direction`,
    /// plus a smaller trailing margin behind.
    ///
    /// Also cancels any in-flight decode whose index has fallen outside the
    /// resulting `[index - radius, index + radius]` window — this is what
    /// keeps rapid scrubbing from leaving a growing backlog of stale decode
    /// work running for frames the caller has already moved past. A task
    /// that hasn't started its actual decode yet when cancelled skips the
    /// decode entirely (see `makeDecodeTask`), so cancellation here
    /// genuinely avoids wasted work, not just wasted waiting.
    public func prefetch(around index: Int, direction: Int, radius: Int = 12) async {
        let frameCount = cineFile.frameCount
        guard frameCount > 0 else { return }

        let clampedRadius = max(0, radius)
        let center = max(0, min(frameCount - 1, index))
        let windowLower = max(0, center - clampedRadius)
        let windowUpper = min(frameCount - 1, center + clampedRadius)

        for (idx, task) in inFlight where idx < windowLower || idx > windowUpper {
            task.cancel()
            // Remove immediately rather than waiting for the cancelled
            // task's own deferred cleanup (`completeDecode`'s `defer`) to run
            // — that cleanup only fires once the task actually gets
            // scheduled, which may be arbitrarily late. Until then, leaving
            // the dead task here would make `texture(at:)`/`prefetch`'s
            // "already in flight" checks dedupe a legitimate fresh request
            // for `idx` against this dead task and hand back its
            // `CancellationError` instead of starting a real decode.
            inFlight.removeValue(forKey: idx)
            inFlightGeneration.removeValue(forKey: idx)
        }

        let trailingMargin = max(1, clampedRadius / 3)
        var targets: [Int] = [center]

        if direction < 0 {
            if center > windowLower {
                targets.append(contentsOf: stride(from: center - 1, through: windowLower, by: -1))
            }
            let trailingUpper = min(windowUpper, center + trailingMargin)
            if trailingUpper > center {
                targets.append(contentsOf: (center + 1)...trailingUpper)
            }
        } else {
            if center < windowUpper {
                targets.append(contentsOf: stride(from: center + 1, through: windowUpper, by: 1))
            }
            let trailingLower = max(windowLower, center - trailingMargin)
            if trailingLower < center {
                targets.append(contentsOf: trailingLower...(center - 1))
            }
        }

        for idx in targets {
            guard idx >= 0, idx < frameCount else { continue }
            guard textures[idx] == nil, inFlight[idx] == nil else { continue }
            // `.utility`: purely speculative — `idx` might never actually be
            // displayed if the caller changes direction or seeks elsewhere
            // first — so it should never compete on equal footing with a
            // `texture(at:)` request for a frame someone is actually waiting
            // on right now.
            inFlight[idx] = makeDecodeTask(index: idx, priority: .utility)
        }
    }

    /// Builds (but does not await) the tracked decode+upload task for
    /// `index`, at `priority`.
    ///
    /// Deliberately `Task.detached`, not a plain `Task { ... }`: a plain
    /// `Task` created inside actor-isolated code can end up inheriting that
    /// actor's isolation (and would, defeating the whole point here); an
    /// explicitly `detached` task never inherits isolation from its creator,
    /// so this unconditionally runs on the ambient/global concurrent
    /// executor — never on this actor's own serial executor — and therefore
    /// can never block a concurrent, more urgent request through this actor
    /// (see this type's own doc comment). It also can't implicitly capture
    /// any of the actor's isolated state, which is why `cineFile`/`device`
    /// (already `Sendable`) are read out into plain locals here, while still
    /// synchronously on the actor, before the closure is built. Only the
    /// final bookkeeping step (`completeDecode`) hops back onto the actor,
    /// briefly.
    private func makeDecodeTask(index: Int, priority: TaskPriority) -> Task<MTLTexture, Error> {
        nextGeneration += 1
        let generation = nextGeneration
        inFlightGeneration[index] = generation
        let cineFile = self.cineFile
        let device = self.device
        return Task.detached(priority: priority) { [weak self] () async throws -> MTLTexture in
            // Checks cancellation *before* doing any real work: a task
            // that was cancelled by `prefetch` while it was still queued
            // (i.e. it never got a chance to run) exits without ever
            // calling `decodeFrame`, so `decodeCount` only ever reflects
            // decodes that actually happened. Everything in this `do` block
            // — the real decode + GPU upload — runs entirely off of any
            // actor, on whatever thread this task happens to execute on.
            let result: Result<MTLTexture, Error>
            do {
                try Task.checkCancellation()
                let frame = try cineFile.decodeFrame(at: index)
                let texture = try makeFrameTexture(device: device, frame: frame)
                result = .success(texture)
            } catch {
                result = .failure(error)
            }
            guard let self else { throw CancellationError() }
            return try await self.completeDecode(index: index, generation: generation, result: result)
        }
    }

    /// Runs back on this actor's own isolated executor just long enough to
    /// record the outcome of an off-actor decode+upload for `index`: on
    /// success, counts it (`decodeCount`) and stores it in the LRU cache;
    /// either way, cleans up `inFlight`/`inFlightGeneration`. Deliberately
    /// does no CPU decode or GPU upload work itself — every statement here
    /// is a plain dictionary/array update — so a backlog of these calls
    /// queued on the actor can never itself become the kind of bottleneck
    /// this type's doc comment describes; that's the entire reason the real
    /// decode work in `makeDecodeTask` was moved off of this actor.
    ///
    /// `generation` identifies which call to `makeDecodeTask` produced this
    /// particular decode. The cleanup below only clears `index`'s entries
    /// from `inFlight`/`inFlightGeneration` if `generation` still matches
    /// the one recorded there — i.e. only if nothing newer has since
    /// claimed `index`. Without this check, a cancelled task's cleanup
    /// running late (after `prefetch` already evicted it and a fresh decode
    /// for the same `index` has started) could remove that fresh task's
    /// entry instead of its own dead one. (This mirrors what used to be a
    /// `defer` in the old, single-actor-isolated `performDecode` — kept as
    /// an explicit `defer` here too, just now guarding bookkeeping only.)
    private func completeDecode(index: Int, generation: UInt64, result: Result<MTLTexture, Error>) throws -> MTLTexture {
        defer {
            if inFlightGeneration[index] == generation {
                inFlight.removeValue(forKey: index)
                inFlightGeneration.removeValue(forKey: index)
            }
        }
        let texture = try result.get()
        decodeCount += 1
        store(index: index, texture: texture)
        return texture
    }

    private func touch(_ index: Int) {
        if let position = lruOrder.firstIndex(of: index) {
            lruOrder.remove(at: position)
        }
        lruOrder.append(index)
    }

    private func store(index: Int, texture: MTLTexture) {
        textures[index] = texture
        touch(index)
        evictIfNeeded()
    }

    private func evictIfNeeded() {
        while textures.count > capacity, let oldest = lruOrder.first {
            lruOrder.removeFirst()
            textures.removeValue(forKey: oldest)
        }
    }
}
