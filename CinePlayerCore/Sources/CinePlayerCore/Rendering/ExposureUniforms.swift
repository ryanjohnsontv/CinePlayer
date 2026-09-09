import Foundation
import CineKit

/// Which of the five display modes `tonemapFragment` renders. Raw values
/// mirror the `kDebayer*` constants in `Tonemap.metal` exactly — this is the
/// one place that mapping is defined.
public enum DebayerMode: UInt32, Sendable, CaseIterable, Hashable {
    /// Each raw mosaic value shown directly as grayscale (the original,
    /// pre-debayering behavior — unchanged).
    case rawSensor = 0
    /// The 2x2 CFA tile's 4 raw values averaged into one luminance value,
    /// shown (still grayscale) at full resolution — removes the
    /// checkerboard mosaic texture visible in `.rawSensor`.
    case greyScale = 1
    /// Real RGB demosaic: each missing channel copied from the nearest
    /// same-colored neighbor.
    case nearestNeighbor = 2
    /// Real RGB demosaic: each missing channel bilinearly averaged from
    /// its nearest same-colored neighbors.
    case bilinear = 3
    /// Real RGB demosaic: Malvar-He-Cutler gradient-corrected linear
    /// interpolation (H.S. Malvar, L. He, R. Cutler, "High-Quality Linear
    /// Interpolation for Demosaicing of Bayer-Patterned Color Images",
    /// ICASSP 2004).
    case highQuality = 4

    /// A short, user-facing label for a mode picker.
    public var displayName: String {
        switch self {
        case .rawSensor: return "Raw Sensor"
        case .greyScale: return "Grey Scale"
        case .nearestNeighbor: return "Nearest Neighbor"
        case .bilinear: return "Bilinear"
        case .highQuality: return "High Quality (Malvar-He-Cutler)"
        }
    }
}

/// One of the 4 possible phase alignments of a Bayer CFA's 2x2 tile,
/// identified by which corner holds the RED sample — Blue always sits at
/// the diagonally-opposite corner, and Green fills the other two, so this
/// alone fully determines the tile.
public enum CFAPhase: UInt32, Sendable, Equatable {
    /// Red at (0,0), Blue at (1,1).
    case rggb = 0
    /// Red at (1,0), Blue at (0,1).
    case grbg = 1
    /// Red at (0,1), Blue at (1,0).
    case gbrg = 2
    /// Red at (1,1), Blue at (0,0).
    case bggr = 3

    /// (x, y) parity, each 0 or 1, of the Red sample within its 2x2 tile —
    /// exactly the two values `Tonemap.metal`'s `cfaRedX`/`cfaRedY`
    /// uniforms need.
    public var redOffset: (x: UInt32, y: UInt32) {
        switch self {
        case .rggb: return (0, 0)
        case .grbg: return (1, 0)
        case .gbrg: return (0, 1)
        case .bggr: return (1, 1)
        }
    }

    /// Maps a file's `SETUP.CFA` pattern to the phase alignment its raw
    /// pixel array actually uses.
    ///
    /// `CFAPattern.bayer`'s doc comment names its pattern "gbrg", which
    /// reads most naturally as `.gbrg` — but (as that type's own doc
    /// comment on the wider ambiguity notes) a textual CFA name doesn't by
    /// itself pin down which corner of a decoded pixel array's (0,0) origin
    /// convention it starts counting from. `.gbrg` here was picked by
    /// empirical calibration, not by trusting the label alone: rendering a
    /// real capture with a complex, high-detail scene in High Quality mode
    /// and inspecting high-contrast edges (a hard object's silhouette
    /// against its background, a wire mesh against open sky) for color
    /// fringing showed clean, neutral edges at `.gbrg` and visible
    /// red/cyan fringing at the other 3 candidates — see the task's
    /// verification notes for the full comparison.
    public static func forCFAPattern(_ cfa: CFAPattern?) -> CFAPhase {
        switch cfa {
        case nil, .some(.none):
            // No real Bayer mosaic (monochrome sensor, or the field wasn't
            // present in this file) — the demosaic modes are meaningless
            // either way, so any phase is as good/bad as any other.
            return .rggb
        case .vri:
            // "gbrg / rggb depending on orientation" per CFAPattern's own
            // doc comment — `.gbrg` matches the more common orientation
            // and this camera family isn't present in any of the real
            // sample files, so it's untested; kept consistent with `.bayer`
            // below rather than guessed independently.
            return .gbrg
        case .vriV6:
            // "bggr / grbg depending on orientation" — same caveat as
            // `.vri` above.
            return .bggr
        case .bayer:
            return .gbrg
        case .bayerFlip:
            return .rggb
        }
    }
}

/// A row-major 3x3 matrix, laid out as 9 individually-named `Float` fields
/// (rather than a Swift `Array`, which is heap-indirected and therefore
/// unusable in a struct that gets its raw bytes blitted straight to a GPU
/// uniform buffer). Every field has the same 4-byte size/alignment, so
/// Swift is guaranteed to lay them out contiguously with no interior
/// padding — matching a plain `float[9]` on the Metal side exactly.
public struct ColorMatrix3x3: Equatable, Sendable {
    public var m00: Float
    public var m01: Float
    public var m02: Float
    public var m10: Float
    public var m11: Float
    public var m12: Float
    public var m20: Float
    public var m21: Float
    public var m22: Float

    public static let identity = ColorMatrix3x3(rowMajor: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    /// - Parameter rowMajor: exactly 9 elements, row-major (matches
    ///   `ColorCalibration.matrix`'s layout).
    public init(rowMajor values: [Float]) {
        precondition(values.count == 9, "color matrix must have exactly 9 (3x3 row-major) elements")
        self.m00 = values[0]; self.m01 = values[1]; self.m02 = values[2]
        self.m10 = values[3]; self.m11 = values[4]; self.m12 = values[5]
        self.m20 = values[6]; self.m21 = values[7]; self.m22 = values[8]
    }
}

/// A cheap, stride-sampled proxy for "what does this frame's bulk content
/// look like, per CFA color role, before any correction" — used only to
/// sanity-check whether a file's recorded `cmCalib`/`WBGain` calibration
/// actually makes *this* frame look more neutral, not less.
///
/// Some real Vision Research capture files carry `cmCalib`/`WBGain` fields
/// that don't describe a valid correction for their own recorded content —
/// most likely left over from an earlier calibration session and never
/// refreshed for this particular clip (confirmed independently across
/// several real captures this project has been tested against: most share
/// byte-for-byte the same `cmCalib`, yet their `WBGain[0]` field — a
/// *separate*, independently stored record of the gain actually dialed in
/// for that recording — sits at the neutral default (R=B=1.0) instead of
/// the ~1.35/~1.61 that decomposing that shared `cmCalib` implies; another
/// capture's `cmCalib` is different and its `WBGain[0]` agrees with
/// decomposing *that* matrix, but applying it still measurably pushes the
/// shot's own chain-link-fence/pavement content away from neutral rather
/// than toward it, the same symptom as the others). Applying such a stale
/// calibration provably pushes scene content that's already reasonably
/// balanced *away* from neutral instead of toward it (verified by
/// rendering the real Metal pipeline against real captures). Trusting
/// `SETUP` metadata unconditionally in that case makes the picture look
/// actively worse than doing nothing, so this computes the frame's own
/// coarse gray-world statistics and only applies the recorded calibration
/// when doing so measurably reduces — rather than increases — how far
/// those statistics sit from neutral gray. A calibration that genuinely
/// corrects its own footage always passes this check (by construction:
/// bringing scene content closer to neutral is the entire point of white
/// balance), so this only ever vetoes calibrations that were already
/// making things worse, never a working one.
///
/// This gray-world check has a real blind spot: an extremely overexposed
/// clip and an extremely underexposed clip both make it fire without
/// actually detecting a bad calibration — it's measuring a frame that's
/// respectively ~99% clipped-to-white or reading pure noise-floor values
/// near black, either of which makes ANY spread-based gray-world
/// comparison meaningless (a clipped frame reads as spuriously "already
/// neutral," and near-black noise has no reliable color signal to
/// measure). `vetoedCalibration` below skips this check entirely —
/// trusting the file's own recorded calibration rather than vetoing it —
/// whenever too much of the sampled frame is clipped or at the noise floor
/// to give the gray-world comparison anything real to measure. This does
/// NOT change behavior for a frame with genuine, measurable scene content
/// (a complex, well-exposed scene measurably produces a magenta cast —
/// R/G and B/G both jumping from ~0.9/0.84 to ~1.2/1.18 — when its own
/// vetoed calibration is forced back on) — that veto continues to fire
/// exactly as before.
enum CalibrationPlausibility {
    /// Every 4th grid point in both dimensions. `stride` is an even
    /// multiple of the Bayer tile's 2-pixel period, so a scan that sampled
    /// only the single pixel at each `(x, y)` grid point would land on the
    /// same CFA phase every time (`x & 1`/`y & 1` always 0) and never
    /// actually visit 2 of the 3 color roles — see `nativeChannelAverages`
    /// below, which instead samples the full 2x2 tile anchored at each grid
    /// point. That keeps the cost down to ~1/4 of the frame (4 pixels per
    /// grid point, 1/16th as many grid points) while still visiting every
    /// CFA phase on every step, regardless of `stride`'s value.
    static let stride = 4

    /// How close (as a fraction of the full black-to-white range) a raw
    /// sample must sit to `blackLevel`/`whiteLevel` to count as clipped/
    /// noise-floor for `nativeChannelAverages`'s `degenerateFraction`.
    private static let clippingMargin: Float = 0.02

    /// The fraction of sampled pixels (at or above which) `vetoedCalibration`
    /// treats the gray-world measurement as too unreliable to trust — see
    /// `CalibrationPlausibility`'s own doc comment above for the blind spot
    /// this guards against. `0.5` (a plain majority) comfortably covers both
    /// diagnosed real cases
    /// (~99% clipped, and a near-all-noise-floor frame) with margin to
    /// spare, without being so low that a frame with only a small clipped
    /// highlight/shadow region gets its otherwise-meaningful gray-world
    /// measurement discarded too.
    private static let degenerateFractionThreshold: Float = 0.5

    /// Per-CFA-role mean of the raw mosaic, black-level subtracted, over a
    /// `stride`-sampled grid covering the whole frame, plus the fraction of
    /// those same samples that were clipped (at/near `whiteLevel`) or at the
    /// noise floor (at/near `blackLevel`) — see `clippingMargin` — before
    /// black-level subtraction, since that's the domain `blackLevel`/
    /// `whiteLevel` are themselves defined in.
    /// `nativeChannelAverages`'s return value.
    struct NativeChannelAverages {
        let r: Float
        let g: Float
        let b: Float
        let degenerateFraction: Float
    }

    static func nativeChannelAverages(frame: DecodedFrame, cfaPhase: CFAPhase, blackLevel: Float, whiteLevel: Float) -> NativeChannelAverages {
        let redOffset = cfaPhase.redOffset
        let redX = Int(redOffset.x), redY = Int(redOffset.y)
        let blueX = 1 - redX, blueY = 1 - redY
        var sumR = 0.0, sumG = 0.0, sumB = 0.0
        var countR = 0, countG = 0, countB = 0
        var degenerateCount = 0
        var totalCount = 0
        let margin = (whiteLevel - blackLevel) * clippingMargin
        let nearBlackCeiling = blackLevel + margin
        let nearWhiteFloor = whiteLevel - margin

        // Accumulates the single pixel at (x, y) into whichever channel its
        // CFA role maps to; a no-op if (x, y) falls outside the frame (only
        // possible for the tile's `+1` corners on an odd-sized frame).
        func accumulate(x: Int, y: Int) {
            guard x < frame.width, y < frame.height else { return }
            let raw = frame.pixels[y * frame.width + x]
            totalCount += 1
            if Float(raw) <= nearBlackCeiling || Float(raw) >= nearWhiteFloor {
                degenerateCount += 1
            }
            let v = Double(raw)
            let px = x & 1
            let py = y & 1
            if px == redX && py == redY {
                sumR += v; countR += 1
            } else if px == blueX && py == blueY {
                sumB += v; countB += 1
            } else {
                sumG += v; countG += 1
            }
        }

        var y = 0
        while y < frame.height {
            var x = 0
            while x < frame.width {
                // Sample the whole 2x2 CFA tile anchored at (x, y), not just
                // the single pixel at (x, y) — `stride` being an even
                // multiple of the tile's 2-pixel period means `x`/`y` alone
                // only ever land on one fixed phase, so anchoring on a
                // single pixel would silently skip 2 of the 3 color roles
                // for every phase except `.rggb`. Visiting all 4 corners
                // captures Red, Blue, and both Green sub-pixels every step,
                // independent of stride and phase.
                accumulate(x: x, y: y)
                accumulate(x: x + 1, y: y)
                accumulate(x: x, y: y + 1)
                accumulate(x: x + 1, y: y + 1)
                x += stride
            }
            y += stride
        }
        let bl = Double(blackLevel)
        let r = countR > 0 ? Float(sumR / Double(countR) - bl) : 0
        let g = countG > 0 ? Float(sumG / Double(countG) - bl) : 0
        let b = countB > 0 ? Float(sumB / Double(countB) - bl) : 0
        let degenerateFraction = totalCount > 0 ? Float(degenerateCount) / Float(totalCount) : 0
        return NativeChannelAverages(r: r, g: g, b: b, degenerateFraction: degenerateFraction)
    }

    /// Max minus min of the 3 channels — 0 for a perfectly neutral triple,
    /// larger the further it sits from gray.
    private static func spread(_ v: (Float, Float, Float)) -> Float {
        let mx = max(v.0, max(v.1, v.2))
        let mn = min(v.0, min(v.1, v.2))
        return mx - mn
    }

    /// Whether applying `calibration` to this frame's own bulk statistics
    /// actually moves them closer to neutral than leaving them alone would.
    /// Assumes `native` is itself a meaningful measurement — see
    /// `vetoedCalibration`'s own degenerate-sample guard, which is what
    /// decides whether this function is even worth calling.
    static func isPlausible(_ calibration: ColorCalibration, for native: (r: Float, g: Float, b: Float)) -> Bool {
        let uncorrectedSpread = spread(native)
        let wb = (native.r * calibration.whiteBalanceR, native.g * calibration.whiteBalanceG, native.b * calibration.whiteBalanceB)
        let m = calibration.matrix
        let corrected = (
            m[0] * wb.0 + m[1] * wb.1 + m[2] * wb.2,
            m[3] * wb.0 + m[4] * wb.1 + m[5] * wb.2,
            m[6] * wb.0 + m[7] * wb.1 + m[8] * wb.2
        )
        // `<=`, not `<`: a calibration that's already a perfectly-neutral
        // no-op (spread(corrected) == uncorrectedSpread == 0) is a pass, not
        // a veto — `<` would wrongly veto that degenerate-but-correct case.
        return spread(corrected) <= uncorrectedSpread
    }

    /// Per-2x2-CFA-tile native (r, g, b) triples, sampled across the whole
    /// frame on the same `stride`-spaced grid `nativeChannelAverages` uses
    /// for its own frame-wide averages — kept as individual per-tile
    /// triples here instead of collapsed into one aggregate, so a
    /// candidate calibration's effect can be checked at each sampled
    /// location independently. This is what `clippingFraction` needs to
    /// catch a calibration that looks fine *on average* (passes
    /// `isPlausible`) while still driving specific tonal regions into
    /// negative — i.e. clamped-to-black, since `Tonemap.metal` clamps
    /// every channel to `[0,1]` right after this stage — output. A real,
    /// different blind spot from the one `isPlausible`'s own single
    /// averaged-triple comparison has by construction.
    static func nativeChannelTriples(frame: DecodedFrame, cfaPhase: CFAPhase, blackLevel: Float) -> [(r: Float, g: Float, b: Float)] {
        let redOffset = cfaPhase.redOffset
        let redX = Int(redOffset.x), redY = Int(redOffset.y)
        let blueX = 1 - redX, blueY = 1 - redY

        func sample(x: Int, y: Int) -> UInt16? {
            guard x < frame.width, y < frame.height else { return nil }
            return frame.pixels[y * frame.width + x]
        }

        var triples: [(r: Float, g: Float, b: Float)] = []
        var y = 0
        while y < frame.height {
            var x = 0
            while x < frame.width {
                var r: UInt16?
                var b: UInt16?
                var gSum = 0.0
                var gCount = 0
                for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    guard let raw = sample(x: x + dx, y: y + dy) else { continue }
                    if dx == redX && dy == redY {
                        r = raw
                    } else if dx == blueX && dy == blueY {
                        b = raw
                    } else {
                        gSum += Double(raw)
                        gCount += 1
                    }
                }
                if let r, let b, gCount > 0 {
                    let bl = Double(blackLevel)
                    triples.append((
                        r: Float(Double(r) - bl),
                        g: Float(gSum / Double(gCount) - bl),
                        b: Float(Double(b) - bl)
                    ))
                }
                x += stride
            }
            y += stride
        }
        return triples
    }

    /// The fraction of `triples` (at or above which) `vetoedCalibration`
    /// treats `calibration` as unreliable even though it already passed
    /// `isPlausible`'s frame-average check — chosen well above the low
    /// single-digit percentage of samples ordinary sensor noise can push
    /// slightly negative even for a genuinely correct calibration (a
    /// near-black region, near the clipping margin already), comfortably
    /// below the ~9%+ observed on a real file whose recorded calibration
    /// was independently confirmed bad (its own `WBGain` disagreeing with
    /// decomposing its own `cmCalib` — see `ColorCalibration`'s own doc
    /// comment on that pattern).
    private static let clippingFractionThreshold: Float = 0.05

    /// Whether `calibration` would push at least one output channel
    /// negative — i.e. clamped to black by `Tonemap.metal` right after
    /// this stage — for `triple`.
    private static func clips(_ calibration: ColorCalibration, _ triple: (r: Float, g: Float, b: Float)) -> Bool {
        let wb = (
            triple.r * calibration.whiteBalanceR,
            triple.g * calibration.whiteBalanceG,
            triple.b * calibration.whiteBalanceB
        )
        let m = calibration.matrix
        let r = m[0] * wb.0 + m[1] * wb.1 + m[2] * wb.2
        let g = m[3] * wb.0 + m[4] * wb.1 + m[5] * wb.2
        let b = m[6] * wb.0 + m[7] * wb.1 + m[8] * wb.2
        return r < 0 || g < 0 || b < 0
    }

    /// Fraction of `triples` that `clips(_:_:)` for `calibration` — the
    /// per-location counterpart to `isPlausible`'s own frame-average
    /// comparison. A calibration that's actually a valid correction for
    /// its own footage should push at most a handful of already-near-black
    /// samples slightly negative from ordinary sensor noise, not a
    /// substantial fraction of the whole frame.
    static func clippingFraction(_ calibration: ColorCalibration, for triples: [(r: Float, g: Float, b: Float)]) -> Float {
        guard !triples.isEmpty else { return 0 }
        let clippedCount = triples.reduce(into: 0) { count, triple in
            if clips(calibration, triple) { count += 1 }
        }
        return Float(clippedCount) / Float(triples.count)
    }

    /// A generic, scene-independent fallback calibration — used instead of
    /// `.identity` when a file's own recorded calibration fails the
    /// plausibility check above, so a vetoed file gets SOME real color
    /// correction rather than none at all (identity leaves the raw sensor's
    /// own spectral response — which never matches Rec.709 primaries on its
    /// own — completely uncorrected, producing a persistent green/washed-out
    /// look).
    ///
    /// Derived by regressing CinePlayer's own raw (un-white-balanced)
    /// bilinear-demosaiced sensor RGB against a real DaVinci Resolve "zero
    /// grading" reference export of a complex real-world scene (frame 0),
    /// across 6 hand-picked scene regions (pavement, sky, foliage, dark
    /// clothing, a white shoe, black griptape) — solved as a diagonal
    /// white-balance gain first (through-origin least squares in the
    /// black-subtracted domain), then a residual 3x3 matrix on the
    /// WB-adjusted values via ridge regression (ordinary least squares plus
    /// an L2 penalty pulling each row toward its own identity vector — i.e.
    /// toward "no further correction beyond the white-balance stage above" —
    /// rather than toward zero, since WB-adjusted input should already be
    /// close to correct if that stage did its job): a plain unregularized
    /// least-squares fit reached similar color accuracy but visibly
    /// amplified sensor noise (its large, partially-cancelling coefficients,
    /// row sums only ~0.53-0.63, add channel noise variance instead of
    /// cancelling it), where the ridge-regularized version reduces
    /// pavement-region noise stddev by ~45% while measuring slightly BETTER
    /// color accuracy — a strict improvement on both axes, not a tradeoff.
    /// Validated against both the fit frame and a held-out frame (449 — a
    /// different pose entirely) of the same file: pavement, fence rust, sky,
    /// and skin tone all matched the DaVinci reference far more closely than
    /// `.identity` does.
    ///
    /// **Caveat, stated plainly**: fit from ONE file's content under ONE
    /// lighting condition, not independently verified across other Phantom
    /// sensors/scenes — a real, tested improvement over showing zero color
    /// correction, not a claimed universal calibration. Revisit if it's
    /// ever shown to look worse than identity on other real footage.
    ///
    /// **Known stale, unresolved**: this was fit directly against
    /// gamma-encoded (display-referred) pixel values rather than true
    /// linear camera-native RGB — the same domain mismatch later found and
    /// fixed for `veoFallback` (see that constant's own doc comment), which
    /// also motivated isolating `blackLevel` from `applyColorMatrix` in
    /// `Tonemap.metal` so the matrix never has to satisfy an implicit
    /// row-sum-equals-1 constraint. This fallback's own row sums (~0.86)
    /// don't satisfy that either, so its rendered behavior already shifted
    /// once when that shader fix landed — and, if the camera this was fit
    /// from also shot P10-packed footage (unconfirmed either way), shifted
    /// again when CineKit 0.1.1 started delinearizing P10 pixel data at
    /// decode time (see `veoFallback`'s own doc comment for that fix).
    /// Direction and magnitude unverified either time, since redoing this
    /// fit needs the original reference file/Resolve export (pavement/
    /// fence/sky/skin scene, frame 0) that this project no longer has
    /// access to. Revisit with the same rigor `veoFallback` got (fit in the
    /// correct linear domain, validated against direct pixel-patch
    /// comparison, not just an aggregate error metric) once that reference
    /// material is available again.
    private static let genericFallback = ColorCalibration(
        whiteBalanceR: 0.7468678858351011,
        whiteBalanceG: 0.5895917817539703,
        whiteBalanceB: 0.8536762111530525,
        matrix: [
            1.9765740714583142, -1.6167489396545385, 0.5028913041710531,
            -0.2163544403921644, -0.4770827906953295, 1.5508117575574976,
            -0.8419404627467321, -1.038717405074019, 2.7472224997552472,
        ]
    )

    /// A VEO-family fallback for a specific Phantom camera hardware
    /// revision, identified by `CineSetup.cameraVersion` — Vision
    /// Research's own documented "version of camera hardware" field (per
    /// its official Phantom Cine File Format spec), distinct from
    /// `CineSetup.serial` (which identifies one specific physical unit,
    /// not the model/hardware revision it is) and from `cameraModel` (a
    /// human-readable name string that's absent on every VEO-family file
    /// seen so far — `cameraVersion` is the only reliable, model-level
    /// identifier available). Exists as its own fallback, distinct from
    /// `genericFallback` above, because this hardware revision's own
    /// `cmCalib` fails both plausibility checks below in a way clearly
    /// specific to its own sensor: applying it drives ~9% of sampled
    /// locations on frame 0 alone into a negative (clamped-to-black)
    /// channel, and even where it doesn't outright clip, it's measurably
    /// *farther* from a real DaVinci Resolve reference render of this
    /// camera's own footage than doing nothing at all (`.identity`) — a
    /// one-size-fits-all fallback derived from a different, unrelated
    /// Phantom hardware revision's footage (`genericFallback`) has no
    /// particular reason to correct for that either, and empirically does
    /// about as poorly as `.identity` here.
    ///
    /// Derived like `genericFallback` — a diagonal white-balance gain via
    /// through-origin least squares, then a ridge-regularized residual 3x3
    /// matrix — but critically, fit in the correct domain on both sides: true
    /// *linear* camera-native RGB (this camera's own raw sensor signal,
    /// demosaiced, identity-calibrated, with the real Rec.709 OETF
    /// *inverted* back out, and — since CineKit 0.1.1 — P10's own
    /// gamma-compander already undone at decode time by `CineFile
    /// .effectiveBlackWhiteLevels`/`P10Unpacker`) against a real DaVinci
    /// Resolve reference render's own linear scene values (its export also
    /// OETF-inverted). Two earlier versions of this fallback each had a
    /// real, independent domain bug, found and fixed in turn: fitting
    /// directly against gamma-encoded pixel values (skipping the OETF
    /// inversion) produced a matrix whose rows summed to ~0.6-0.73 instead
    /// of ~1 and looked badly washed out/desaturated despite a
    /// superficially-improved MAE; separately, fitting against CineKit
    /// <0.1.1's still-P10-companded "raw" pixels (a bug in CineKit itself,
    /// not this package) meant every fit before that point was quietly
    /// working with gamma-encoded input on the camera-native side even once
    /// the display side was correctly linearized. Sampled on a dense,
    /// uniformly-spaced grid (24px stride) across 3 frames of a real
    /// high-speed-video shoot of this camera's own footage (not hand-picked
    /// regions of one still frame).
    ///
    /// **Validated on a held-out frame the fit never saw** (frame 450,
    /// versus fit frames 50/150/300): mean absolute error against the
    /// Resolve reference (display domain, 0-255) is 6.1, versus 21.4 for
    /// `.identity` — a ~71% reduction. Performance on the fit frames (5.9)
    /// is close enough to the held-out result that this isn't overfitting
    /// to the 3 fit frames. Direct pixel-patch comparison against the real
    /// Resolve reference (not just the aggregate MAE) confirms this: every
    /// sampled patch — including green foliage, the hardest-to-match region
    /// under both earlier, domain-buggy fits (off by 20-50+ per channel) —
    /// matches within roughly 1-10 per channel, and a near-black patch
    /// matches within ~0.3.
    ///
    /// **Caveat, stated plainly**: fit from footage of ONE camera hardware
    /// revision under the lighting/exposure of one shoot, and keyed by
    /// `cameraVersion` rather than `serial` specifically so this applies to
    /// every physical unit of that same hardware revision, not just the
    /// one this was fit against — but it's still not independently
    /// verified across other units or lighting conditions. A real, measured
    /// improvement over the alternatives on this hardware revision's real
    /// footage, not a claimed universal or physically-exact color-science
    /// match. Revisit if it's ever shown to look worse than `.identity` on
    /// other real footage from the same hardware revision.
    private static let veoFallback = ColorCalibration(
        whiteBalanceR: 2.0308789512110796,
        whiteBalanceG: 0.9099304067476847,
        whiteBalanceB: 1.4673041969484928,
        matrix: [
            1.000192723667483, 0.0007430503053335955, -0.001199720125065869,
            -0.002204117987742132, 0.9985447050892037, 0.006007552953927219,
            -0.003647393783310004, -0.0020861312597412886, 1.003340758888242,
        ]
    )

    /// A known-bad-`cmCalib` Phantom hardware revision this project has a
    /// dedicated, validated fallback for — see `veoFallback`'s own doc
    /// comment. Matched by `CineSetup.cameraVersion` (Vision Research's
    /// documented "version of camera hardware" field), not `serial`, so
    /// this generalizes to every physical unit of that hardware revision
    /// automatically rather than naming one specific camera.
    private static let veoCameraVersion: UInt32 = 7011

    /// The fallback to use for a vetoed calibration on a file identified
    /// by `cameraVersion` — `veoFallback` for `veoCameraVersion`,
    /// `genericFallback` (fit from a different camera hardware revision
    /// entirely) for everything else. A one-size-fits-all fallback derived
    /// from one specific hardware revision's footage has no reason to suit
    /// a different physical camera/sensor — see `veoFallback`'s own doc
    /// comment.
    private static func fallback(forCameraVersion cameraVersion: UInt32?) -> ColorCalibration {
        switch cameraVersion {
        case veoCameraVersion: return veoFallback
        default: return genericFallback
        }
    }

    /// `calibration`, or a per-camera fallback (see
    /// `fallback(forCameraVersion:)`) if applying it to `frame`'s own bulk
    /// statistics fails either
    /// plausibility check below — the single shared veto decision both
    /// `ExposureUniforms.init(cineFile:frame:debayerMode:lutEnabled:)` (used
    /// by `cine-diagnostic`) and `CineDocumentModel.open(url:)` (the live
    /// app) apply, so the two can never drift out of sync with each
    /// other. Skips the frame scan entirely for an already-identity
    /// `calibration` (identity is trivially its own no-op fixed point, so
    /// it can never fail either check, and a file with no recorded
    /// calibration at all has no generic fallback to reach for either —
    /// this only replaces a *specifically distrusted* recorded
    /// calibration, not a genuinely absent one) — purely a cost saving,
    /// not a behavior difference.
    ///
    /// Two independent checks, either of which can veto: `isPlausible`
    /// (does this calibration move the frame's *average* statistics
    /// toward neutral) and `clippingFraction` (does it also avoid driving
    /// a substantial fraction of individual sampled locations negative) —
    /// see that function's own doc comment for why the first, coarser
    /// check alone isn't sufficient; a calibration can pass on average
    /// while still clipping specific tonal regions hard.
    ///
    /// Also skips both plausibility checks — trusting `calibration`
    /// rather than measuring against it — when `nativeChannelAverages`
    /// reports too much of the frame is clipped or at the noise floor to
    /// give the gray-world comparison anything real to measure (see
    /// `CalibrationPlausibility`'s own doc comment for the blind spot this
    /// guards against).
    static func vetoedCalibration(
        _ calibration: ColorCalibration,
        frame: DecodedFrame,
        cfaPhase: CFAPhase,
        blackLevel: Float,
        whiteLevel: Float,
        cameraVersion: UInt32? = nil
    ) -> ColorCalibration {
        guard calibration != .identity else { return calibration }
        let native = nativeChannelAverages(frame: frame, cfaPhase: cfaPhase, blackLevel: blackLevel, whiteLevel: whiteLevel)
        guard native.degenerateFraction < degenerateFractionThreshold else { return calibration }
        guard isPlausible(calibration, for: (native.r, native.g, native.b)) else { return fallback(forCameraVersion: cameraVersion) }
        let triples = nativeChannelTriples(frame: frame, cfaPhase: cfaPhase, blackLevel: blackLevel)
        guard clippingFraction(calibration, for: triples) < clippingFractionThreshold else { return fallback(forCameraVersion: cameraVersion) }
        return calibration
    }
}

/// Uniform parameters passed to the Tonemap vertex/fragment shader pair.
///
/// Memory layout must exactly mirror the `ExposureUniforms` struct declared
/// in `Shaders/Tonemap.metal` (twenty 4-byte fields, no padding: the
/// original six, plus 3 white-balance gains, a 9-element color matrix, a
/// gamma value, and `lutEnabled`).
///
/// `blackLevel`/`whiteLevel` are the only inputs to the plain linear
/// stretch applied to every channel/mode. `flipVertically` rides along in
/// the same buffer purely so the vertex stage can orient the full-screen
/// triangle's texture coordinates correctly for frames where
/// `DecodedFrame.needsVerticalFlip == true`, without introducing a second
/// uniform buffer. `debayerMode`/`cfaRedX`/`cfaRedY` select which of the
/// five display modes is rendered and (for the 3 real demosaic modes) which
/// Bayer phase alignment to demosaic against.
///
/// `wbGainR`/`G`/`B` and `colorMatrix` are the camera color calibration
/// pipeline: the white-balance gains are applied per-channel to the raw
/// mosaic (by CFA color role) *before* demosaicing, the color matrix to the
/// demosaiced RGB triple *after* — both only meaningful for (and only
/// applied to) the 3 real demosaic modes. `.rawSensor`/`.greyScale` ignore
/// both, unchanged from before this pipeline existed. Default values (all
/// gains 1, `colorMatrix` identity) are themselves a correct no-op/neutral
/// calibration, matching `ColorCalibration.identity`.
///
/// `gamma` rides along in the same buffer but is **not currently read** by
/// the shader's display-encoding stage — `Tonemap.metal`'s `applyGamma` was
/// changed from a `gamma`-parameterized `pow(x, 1/gamma)` power law to the
/// real, fixed ITU-R BT.709 opto-electronic transfer function (a piecewise
/// curve with no free parameter), so there is currently no per-file "gamma"
/// to plug in: the native view is meant to be a genuine, single fixed
/// Rec.709 conversion, not a tunable approximation of one. The field (and
/// `SETUP.fGamma`'s plumbing into it, in `CineDocumentModel.open(url:)`/
/// `CinePreviewImage.previewUniforms`) is kept rather than deleted — ripping
/// it out would touch the uniform buffer's byte layout on both the Swift and
/// Metal sides for comparatively little benefit, and it's the natural slot
/// to wire back up if a future custom-gamma/Log/Linear "Paint Mode" (see the
/// project's own backlog notes) needs a per-file or user-adjustable curve
/// again. Until then, changing this value has no visible effect.
public struct ExposureUniforms: Equatable {
    public var blackLevel: Float
    public var whiteLevel: Float
    /// 0 or 1. Non-zero when the source frame must be vertically flipped
    /// before display (mirrors `DecodedFrame.needsVerticalFlip`).
    public var flipVertically: UInt32
    /// Mirrors `DebayerMode.rawValue`.
    public var debayerMode: UInt32
    /// (x, y) parity of the Red sample within its 2x2 CFA tile — mirrors
    /// `CFAPhase.redOffset`. Only meaningful for the 3 real demosaic modes.
    public var cfaRedX: UInt32
    public var cfaRedY: UInt32
    public var wbGainR: Float
    public var wbGainG: Float
    public var wbGainB: Float
    public var colorMatrix: ColorMatrix3x3
    public var gamma: Float
    /// 0 or 1. Non-zero enables `tonemapFragment`'s post-gamma 3D LUT
    /// sampling stage (see `LUTTexture`/`CineRenderer.render`'s `lutTexture`
    /// parameter). Phase 1 (this struct) only carries the flag; no caller
    /// in this codebase sets it to `true` yet -- that's wired up by a later
    /// phase once a real LUT can actually be loaded/selected in the app.
    public var lutEnabled: UInt32

    public init(
        blackLevel: Float,
        whiteLevel: Float,
        flipVertically: Bool = false,
        debayerMode: DebayerMode = .rawSensor,
        cfaPhase: CFAPhase = .rggb,
        colorCalibration: ColorCalibration = .identity,
        gamma: Float = 2.2,
        lutEnabled: Bool = false
    ) {
        self.blackLevel = blackLevel
        self.whiteLevel = whiteLevel
        self.flipVertically = flipVertically ? 1 : 0
        self.debayerMode = debayerMode.rawValue
        let redOffset = cfaPhase.redOffset
        self.cfaRedX = redOffset.x
        self.cfaRedY = redOffset.y
        self.wbGainR = colorCalibration.whiteBalanceR
        self.wbGainG = colorCalibration.whiteBalanceG
        self.wbGainB = colorCalibration.whiteBalanceB
        self.colorMatrix = ColorMatrix3x3(rowMajor: colorCalibration.matrix)
        // Not currently read by the shader (see this field's doc comment
        // above) — a gamma of 0 (or negative) is harmless today, but this
        // guards against a degenerate on-disk file value the same way
        // `effectiveBlackWhiteLevels` guards its divisor, so the field stays
        // a well-formed input whenever something does start reading it again
        // (e.g. a future custom-gamma "Paint Mode"), rather than trusting
        // every possible on-disk float unconditionally.
        self.gamma = gamma > 0 ? gamma : 2.2
        self.lutEnabled = lutEnabled ? 1 : 0
    }

    /// Derives the black/white points, CFA phase, and color calibration
    /// from `cineFile` and carries forward `frame.needsVerticalFlip` — the
    /// one place this mapping is defined, so the GUI app and
    /// `cine-diagnostic` can't drift out of sync with each other.
    ///
    /// Takes the whole `CineFile`, not just `cineFile.setup`, specifically
    /// so `CineFile.effectiveBlackWhiteLevels` (not `CineSetup`'s own,
    /// lower-level property of nearly the same name) is what supplies the
    /// black/white points here — see that property's own doc comment for
    /// why a P10-packed file's `SETUP.BlackLevel`/`WhiteLevel` alone aren't
    /// the right numbers to tone-map `frame`'s actual (now-linearized)
    /// pixel data against.
    public init(
        cineFile: CineFile,
        frame: DecodedFrame,
        debayerMode: DebayerMode = .rawSensor,
        lutEnabled: Bool = false
    ) {
        let setup = cineFile.setup
        let levels = cineFile.effectiveBlackWhiteLevels
        let cfaPhase = CFAPhase.forCFAPattern(setup.cfa)
        let calibration = CalibrationPlausibility.vetoedCalibration(
            setup.colorCalibration ?? .identity,
            frame: frame,
            cfaPhase: cfaPhase,
            blackLevel: Float(levels.black),
            whiteLevel: Float(levels.white),
            cameraVersion: setup.cameraVersion
        )
        self.init(
            blackLevel: Float(levels.black),
            whiteLevel: Float(levels.white),
            flipVertically: frame.needsVerticalFlip,
            debayerMode: debayerMode,
            cfaPhase: cfaPhase,
            colorCalibration: calibration,
            gamma: setup.fGamma ?? 2.2,
            lutEnabled: lutEnabled
        )
    }
}
