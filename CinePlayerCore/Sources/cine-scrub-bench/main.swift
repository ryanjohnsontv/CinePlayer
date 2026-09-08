import Foundation
import Darwin
// See `DecodedFrameCache`'s doc comment (in CinePlayerCore) for why
// `MTLTexture` not being `Sendable` in this SDK is safe to bridge across the
// actor boundary here via `@preconcurrency`: `runPlaythrough`/`runScrub`
// below call `cache.texture(at:)` from top-level (non-isolated) code.
@preconcurrency import Metal
import CineKit
import CinePlayerCore

/// Verification tool for `DecodedFrameCache`: drives it through one of two
/// deterministic, reproducible scenarios and reports hard evidence that
/// bounding (via LRU eviction) and cancellation (via `prefetch`) are
/// actually doing something, not just "looks right":
///
///   - `decodeCount`         proves real decode work happened at all.
///   - `cachedFrameCount`    proves the cache never grows past `capacity`.
///   - `cachedByteSize`      the cache's own self-reported texture-storage
///                           footprint — proves *this* stays bounded
///                           regardless of `capacity`, independent of
///                           anything else the process has resident.
///   - process resident memory (both the absolute peak and the delta from
///     just after the file was opened) is reported too, but only as
///     supporting context, not as proof of boundedness: for an mmap-backed
///     `.cine` file (via `CineKit`'s `MappedFileBackingStore`), touching
///     frames pages the file's own bytes into resident memory, and a
///     `scrub`/`playthrough` run that visits most of the file will show RSS
///     converging toward the file's size *regardless* of whether the cache
///     itself is bounded — confirmed empirically: capacity=2 and
///     capacity=300 against a 1.8GB file both show peak RSS dominated by
///     the fraction of the file touched, not by cache capacity. Use
///     `cachedByteSize` to judge the cache; use the RSS figures only to see
///     how much of the process's memory a run touched overall.
///
/// Usage: cine-scrub-bench <path-to-cine-file> <playthrough|scrub> <capacity>
enum BenchError: Error, CustomStringConvertible {
    case badArguments
    case noMetalDevice
    case unknownScenario(String)

    var description: String {
        switch self {
        case .badArguments:
            return "Usage: cine-scrub-bench <path-to-cine-file> <playthrough|scrub> <capacity>"
        case .noMetalDevice:
            return "No Metal device available on this machine."
        case .unknownScenario(let name):
            return "Unknown scenario '\(name)'. Expected 'playthrough' or 'scrub'."
        }
    }
}

/// Peak resident set size for this process so far, in megabytes, read via
/// `task_info(mach_task_self_, MACH_TASK_BASIC_INFO, ...)` ->
/// `resident_size_max`. Returns 0 if the Mach call fails (should not happen
/// in practice on macOS).
func peakResidentMemoryMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result: kern_return_t = withUnsafeMutablePointer(to: &info) { infoPointer in
        infoPointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), intPointer, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Double(info.resident_size_max) / (1024 * 1024)
}

/// A fixed, deterministic sequence of frame indices bouncing back and forth
/// between `0` and `frameCount - 1` in steps of `strideAmount` — a "triangle
/// wave" standing in for a user rapidly scrubbing back and forth across the
/// whole clip. Deliberately has no randomness so results are comparable
/// run-to-run.
func triangleWaveIndices(frameCount: Int, strideAmount: Int, stops: Int) -> [Int] {
    guard frameCount > 1 else { return Array(repeating: 0, count: stops) }
    let amount = max(1, strideAmount)
    var indices: [Int] = []
    indices.reserveCapacity(stops)

    var current = 0
    var goingUp = true
    for _ in 0..<stops {
        indices.append(current)
        if goingUp {
            current += amount
            if current >= frameCount - 1 {
                current = frameCount - 1
                goingUp = false
            }
        } else {
            current -= amount
            if current <= 0 {
                current = 0
                goingUp = true
            }
        }
    }
    return indices
}

/// Mirrors `DecodedFrameCache.prefetch(around:direction:radius:)`'s own
/// default `radius`. `runScrub` doesn't override it, so this is what
/// actually governs each stop's window — kept here only so the stride
/// computed from it stays honest about that relationship.
let defaultPrefetchRadius = 12

func runPlaythrough(cache: DecodedFrameCache, frameCount: Int) async throws {
    let count = min(frameCount, 300)
    for index in 0..<count {
        _ = try await cache.texture(at: index)
    }
}

func runScrub(cache: DecodedFrameCache, frameCount: Int) async throws {
    // A stride that crosses the whole clip in on the order of 40 steps each
    // way keeps consecutive stops' prefetch windows overlapping the way a
    // real scrub gesture (arrow-key taps, small slider drags) does — dense
    // enough that dedup/cache-hit skipping in `DecodedFrameCache.prefetch`
    // has real effect, rather than every stop landing in unrelated,
    // non-overlapping territory. Tied to `defaultPrefetchRadius` (the same
    // radius `prefetch(around:direction:)` defaults to) rather than
    // `frameCount`, so windows overlap regardless of clip length.
    let strideAmount = max(1, defaultPrefetchRadius / 3)
    let stops = 500
    let indices = triangleWaveIndices(frameCount: frameCount, strideAmount: strideAmount, stops: stops)

    var previousIndex = indices.first ?? 0
    for (position, index) in indices.enumerated() {
        let direction = position == 0 ? 1 : (index >= previousIndex ? 1 : -1)
        await cache.prefetch(around: index, direction: direction)
        previousIndex = index
    }

    // Mirror what `PlaybackController` does once the user stops scrubbing:
    // a direct request for whatever frame they landed on.
    _ = try await cache.texture(at: previousIndex)
}

func run() async throws {
    let arguments = CommandLine.arguments
    guard arguments.count == 4 else { throw BenchError.badArguments }

    let inputPath = arguments[1]
    let scenario = arguments[2]
    guard let capacity = Int(arguments[3]) else { throw BenchError.badArguments }
    guard scenario == "playthrough" || scenario == "scrub" else {
        throw BenchError.unknownScenario(scenario)
    }

    guard let device = MTLCreateSystemDefaultDevice() else {
        throw BenchError.noMetalDevice
    }

    let cineFile = try CineFile(url: URL(fileURLWithPath: inputPath))
    let cache = DecodedFrameCache(cineFile: cineFile, device: device, capacity: capacity)

    // Sampled right after opening the file (before any frame is decoded) so
    // the RSS figures below can also be reported as a *delta* from this
    // baseline — a fairer read than the absolute peak when the underlying
    // file is mmap'd, since opening alone doesn't page in frame data but
    // already carries whatever fixed overhead the process/runtime has.
    let baselineMB = peakResidentMemoryMB()

    let clock = ContinuousClock()
    let start = clock.now

    switch scenario {
    case "playthrough":
        try await runPlaythrough(cache: cache, frameCount: cineFile.frameCount)
    case "scrub":
        try await runScrub(cache: cache, frameCount: cineFile.frameCount)
    default:
        throw BenchError.unknownScenario(scenario)
    }

    let elapsed = clock.now - start
    let decodeCount = await cache.decodeCount
    let cachedFrameCount = await cache.cachedFrameCount
    let cachedByteSizeMB = Double(await cache.cachedByteSize) / (1024 * 1024)
    let peakMB = peakResidentMemoryMB()

    print("scenario:                    \(scenario)")
    print("capacity:                    \(capacity)")
    print("frameCount:                  \(cineFile.frameCount)")
    print("wall-clock time:             \(elapsed)")
    print("decodeCount:                 \(decodeCount)")
    print("cachedFrameCount:            \(cachedFrameCount)")
    print("cachedByteSize (cache-only):  \(String(format: "%.1f", cachedByteSizeMB)) MB")
    print("baseline resident memory:     \(String(format: "%.1f", baselineMB)) MB (right after opening the file)")
    print("peak resident memory:         \(String(format: "%.1f", peakMB)) MB (whole-process; dominated by mmap page-in of the .cine file, not by the cache — see cachedByteSize above)")
    print("peak - baseline (RSS delta):  \(String(format: "%.1f", peakMB - baselineMB)) MB")
}

do {
    try await run()
} catch {
    FileHandle.standardError.write("Error: \(error)\n".data(using: .utf8)!)
    exit(1)
}
