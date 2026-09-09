import Foundation
import CineKit
import CinePlayerCore

// MARK: - DNGWriter

/// A minimal, hand-rolled TIFF/DNG (Adobe Digital Negative) writer for a
/// single raw CFA frame. No third-party TIFF/DNG library exists in this
/// Swift-only codebase, so this writes the handful of tags a "public" DNG
/// raw file needs directly, byte-for-byte — the same level of byte-exactness
/// this project already holds itself to for the `.cine` format itself (see
/// `CineKit/SetupFieldLayout.swift`).
///
/// Tag IDs/types/counts and the `AsShotNeutral` sign convention below were
/// checked against the actual Adobe "Digital Negative (DNG) Specification"
/// text (v1.6.0.0, cross-referenced against v1.7.1.0's tag list — no
/// relevant tag changed between those versions) plus the TIFF-EP spec for
/// `CFAPattern`/`CFARepeatPatternDim` (DNG's CFA `PhotometricInterpretation`
/// explicitly defers to TIFF-EP for those two tags), not guessed from
/// memory.
enum DNGWriter {

    // MARK: TIFF type codes (TIFF 6.0 §2)

    private static let typeByte: UInt16 = 1
    private static let typeASCII: UInt16 = 2
    private static let typeShort: UInt16 = 3
    private static let typeLong: UInt16 = 4
    private static let typeRational: UInt16 = 5
    private static let typeSRational: UInt16 = 10

    /// Tag IDs used below, in the numeric order the spec assigns them (not
    /// necessarily IFD-output order — entries are explicitly sorted by tag
    /// before serialization regardless of this declaration order, since TIFF
    /// requires strictly ascending tag IDs in an IFD).
    private enum Tag {
        static let newSubfileType: UInt16 = 254
        static let imageWidth: UInt16 = 256
        static let imageLength: UInt16 = 257
        static let bitsPerSample: UInt16 = 258
        static let compression: UInt16 = 259
        static let photometricInterpretation: UInt16 = 262
        static let make: UInt16 = 271
        static let model: UInt16 = 272
        static let stripOffsets: UInt16 = 273
        static let orientation: UInt16 = 274
        static let samplesPerPixel: UInt16 = 277
        static let rowsPerStrip: UInt16 = 278
        static let stripByteCounts: UInt16 = 279
        static let planarConfiguration: UInt16 = 284
        static let software: UInt16 = 305
        // TIFF-EP (referenced, not redefined, by the DNG spec for CFA data).
        static let cfaRepeatPatternDim: UInt16 = 33421
        static let cfaPattern: UInt16 = 33422
        // DNG-specific (Chapter 4, "DNG Tags").
        static let dngVersion: UInt16 = 50706
        static let dngBackwardVersion: UInt16 = 50707
        static let uniqueCameraModel: UInt16 = 50708
        static let cfaLayout: UInt16 = 50711
        static let blackLevel: UInt16 = 50714
        static let whiteLevel: UInt16 = 50717
        static let colorMatrix1: UInt16 = 50721
        static let calibrationIlluminant1: UInt16 = 50778
        static let asShotNeutral: UInt16 = 50728
    }

    /// One not-yet-laid-out IFD entry: a tag id, TIFF type, logical value
    /// count, and its value bytes already encoded in the file's byte order
    /// (little-endian throughout, matching every other multi-byte read/write
    /// in this codebase — see `CineKit.DataReader`'s doc comment). Whether
    /// `payload` ends up inline in the 4-byte IFD value field or out in the
    /// external data area is decided purely by `payload.count` at
    /// serialization time, per the TIFF 6.0 rule (≤4 bytes inline, larger
    /// external-and-offset).
    private struct RawEntry {
        let tag: UInt16
        let type: UInt16
        let count: UInt32
        var payload: Data
    }

    /// Builds a complete DNG file for one decoded frame: `NewSubfileType=0`,
    /// uncompressed 16-bit CFA data, real per-file black/white levels and
    /// white balance, an identity `ColorMatrix1` (see this type's doc
    /// comment on that deliberate scope decision), and a single uncompressed
    /// strip holding the frame's raw mosaic — physically row-reordered first
    /// if needed so the file's own row 0 is genuinely the top of the image.
    static func makeDNGData(cineFile: CineFile, frame: DecodedFrame) -> Data {
        let width = frame.width
        let height = frame.height

        // `DecodedFrame.pixels` is always in on-disk row order, regardless
        // of `needsVerticalFlip` — that flag is applied only *virtually* by
        // `Tonemap.metal`'s vertex shader (a texture-coordinate flip), never
        // physically to any buffer (confirmed: `FrameTexture.swift`'s
        // texture upload doesn't flip either). A DNG has no equivalent
        // "flip the texture coordinates" hook every raw converter is
        // guaranteed to honor for CFA data, so this physically reverses the
        // row order up front when needed. `Orientation` is written as 1
        // (normal) unconditionally either way — the buffer itself is made
        // physically correct instead of relying on a reader respecting that
        // tag for CFA data.
        let baseRedOffset = CFAPhase.forCFAPattern(cineFile.setup.cfa).redOffset
        let pixels: [UInt16]
        let redY: UInt32
        if frame.needsVerticalFlip {
            pixels = verticallyReversedRows(frame.pixels, width: width, height: height)
            // Reversing whole rows changes each row's position-parity
            // whenever `height` is even (the overwhelmingly common case):
            // the old row at index `height - 1 - y` lands at new index `y`,
            // and `(height - 1 - y) mod 2 == ((height - 1) mod 2) XOR (y mod
            // 2)`. So the new buffer's red-row parity is `((height - 1) mod
            // 2) XOR redOffset.y` — unchanged when `height` is odd, flipped
            // when it's even. Column parity (`redOffset.x`) is untouched,
            // since only whole rows are reordered, never columns. Getting
            // this wrong would swap Red and Blue everywhere whenever height
            // is even — the same kind of edge-fringing error this project's
            // `CFAPhase` was itself originally calibrated by checking for.
            let heightParity = UInt32((height - 1) & 1)
            redY = heightParity ^ baseRedOffset.y
        } else {
            pixels = frame.pixels
            redY = baseRedOffset.y
        }
        let redX = baseRedOffset.x

        let levels = cineFile.effectiveBlackWhiteLevels
        let calibration = cineFile.setup.colorCalibration ?? .identity
        let rawModel = cineFile.setup.cameraModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let modelName = (rawModel?.isEmpty == false) ? rawModel! : "Phantom"

        var entries: [RawEntry] = [
            long(Tag.newSubfileType, [0]),
            long(Tag.imageWidth, [UInt32(width)]),
            long(Tag.imageLength, [UInt32(height)]),
            short(Tag.bitsPerSample, [16]),
            short(Tag.compression, [1]), // uncompressed
            short(Tag.photometricInterpretation, [32803]), // CFA
            ascii(Tag.make, "Vision Research"),
            ascii(Tag.model, modelName),
            long(Tag.stripOffsets, [0]), // placeholder; patched in `serializeIFD`
            short(Tag.orientation, [1]), // normal — buffer is physically correct instead
            short(Tag.samplesPerPixel, [1]),
            long(Tag.rowsPerStrip, [UInt32(height)]), // single strip
            long(Tag.stripByteCounts, [UInt32(width * height * MemoryLayout<UInt16>.size)]),
            short(Tag.planarConfiguration, [1]),
            ascii(Tag.software, "CinePlayer"),
            short(Tag.cfaRepeatPatternDim, [2, 2]),
            byte(Tag.cfaPattern, cfaPatternBytes(redX: redX, redY: redY)),
            byte(Tag.dngVersion, [1, 4, 0, 0]),
            // None of the compatibility-relevant features gated by later
            // DNG versions are used here (no ActiveArea, no floating point,
            // no opcode lists, no non-default CFALayout, …) — per the DNG
            // spec's own "Appendix A: Compatibility With Previous Versions",
            // that makes 1.0.0.0 the genuinely correct (not just
            // conservative) backward-compatibility floor for this file.
            byte(Tag.dngBackwardVersion, [1, 0, 0, 0]),
            ascii(Tag.uniqueCameraModel, "Vision Research \(modelName)"),
            short(Tag.cfaLayout, [1]), // rectangular
            long(Tag.blackLevel, [UInt32(max(0, levels.black))]),
            long(Tag.whiteLevel, [UInt32(max(0, levels.white))]),
            // Deliberate identity fallback, not this file's real `cmCalib`—
            // see this type's doc comment for the full rationale (Rec.709
            // vs. XYZ-D50 colorspace mismatch, plus the matrix's own known
            // magenta-cast unreliability on every real sample file).
            srational(Tag.colorMatrix1, [
                (1, 1), (0, 1), (0, 1),
                (0, 1), (1, 1), (0, 1),
                (0, 1), (0, 1), (1, 1),
            ]),
            short(Tag.calibrationIlluminant1, [21]), // D65
            rational(Tag.asShotNeutral, asShotNeutralRationals(calibration)),
        ]
        entries.sort { $0.tag < $1.tag }

        var fileData = serializeIFD(entries: &entries)
        // Raw memory copy, no per-element byte-swap: matches
        // `FrameTexture.swift`'s identical assumption that the host is
        // little-endian (true for every Mac this app runs on, Intel or
        // Apple Silicon), which is already relied on elsewhere in this app
        // for the exact same `[UInt16]` pixel buffer.
        let stripData = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        fileData.append(stripData)
        return fileData
    }

    // MARK: - Color calibration → DNG tags

    /// `AsShotNeutral` (tag 50728) stores the coordinates of a perfectly
    /// neutral color *in the camera's raw linear reference space* — i.e.
    /// the code value a neutral gray target would itself read on each
    /// channel, before any white-balance correction. A raw converter then
    /// white-balances by *dividing* each channel's raw value by this
    /// number, per the DNG Specification's Chapter 6 derivation (`D =
    /// Invert(AsDiagonalMatrix(CameraNeutral))`, `D` being the diagonal
    /// white-balance scale applied to raw camera coordinates). Dividing by
    /// `AsShotNeutral` is exactly the same operation as multiplying by this
    /// app's own `ColorCalibration.whiteBalanceR/G/B` gains (applied to the
    /// raw mosaic before demosaic elsewhere in this app) — so
    /// `AsShotNeutral` must be the *reciprocal* of those gains, not the
    /// gains themselves. Verified directly against the spec text (not
    /// assumed from memory): getting this backwards would silently
    /// double-apply (or invert) the white balance in any DNG-reading raw
    /// converter.
    private static func asShotNeutralRationals(_ calibration: ColorCalibration) -> [(UInt32, UInt32)] {
        let denominator: UInt32 = 1_000_000
        func neutral(for gain: Float) -> (UInt32, UInt32) {
            guard gain.isFinite, gain > 0 else { return (denominator, denominator) } // neutral 1.0 fallback
            let value = 1.0 / gain
            let numerator = UInt32(max(0, (value * Float(denominator)).rounded()))
            return (numerator, denominator)
        }
        return [
            neutral(for: calibration.whiteBalanceR),
            neutral(for: calibration.whiteBalanceG),
            neutral(for: calibration.whiteBalanceB),
        ]
    }

    /// The DNG `CFAPattern` tag's 4 bytes: the 2x2 tile's colors in
    /// row-major (top-to-bottom, then left-to-right) scan order, using the
    /// TIFF-EP `CFAColor` convention DNG's CFA `PhotometricInterpretation`
    /// defers to (0 = Red, 1 = Green, 2 = Blue). `redX`/`redY` are the
    /// (column, row) parity of the Red sample — Blue always sits at the
    /// diagonally-opposite corner, Green fills the other two, matching
    /// exactly the same derivation `Tonemap.metal`'s `cfaColorAt` already
    /// uses (see `CFAPhase.redOffset`'s doc comment for how that phase was
    /// itself empirically calibrated against the real sample files).
    private static func cfaPatternBytes(redX: UInt32, redY: UInt32) -> [UInt8] {
        let rX = Int(redX), rY = Int(redY)
        let bX = 1 - rX, bY = 1 - rY
        var bytes: [UInt8] = []
        bytes.reserveCapacity(4)
        for row in 0..<2 {
            for col in 0..<2 {
                if col == rX && row == rY {
                    bytes.append(0) // Red
                } else if col == bX && row == bY {
                    bytes.append(2) // Blue
                } else {
                    bytes.append(1) // Green
                }
            }
        }
        return bytes
    }

    /// Physically reverses `pixels`' row order (top-for-bottom) — see
    /// `makeDNGData`'s doc comment for why this must happen physically
    /// rather than via a DNG-side orientation tag.
    private static func verticallyReversedRows(_ pixels: [UInt16], width: Int, height: Int) -> [UInt16] {
        var result = [UInt16]()
        result.reserveCapacity(pixels.count)
        for y in 0..<height {
            let sourceRow = height - 1 - y
            let start = sourceRow * width
            result.append(contentsOf: pixels[start..<(start + width)])
        }
        return result
    }

    // MARK: - IFD entry value encoders

    private static func byte(_ tag: UInt16, _ values: [UInt8]) -> RawEntry {
        RawEntry(tag: tag, type: typeByte, count: UInt32(values.count), payload: Data(values))
    }

    private static func short(_ tag: UInt16, _ values: [UInt16]) -> RawEntry {
        var data = Data(capacity: values.count * 2)
        for v in values {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return RawEntry(tag: tag, type: typeShort, count: UInt32(values.count), payload: data)
    }

    private static func long(_ tag: UInt16, _ values: [UInt32]) -> RawEntry {
        var data = Data(capacity: values.count * 4)
        for v in values {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return RawEntry(tag: tag, type: typeLong, count: UInt32(values.count), payload: data)
    }

    /// NUL-terminated per TIFF's ASCII convention — `count` includes that
    /// terminator.
    private static func ascii(_ tag: UInt16, _ string: String) -> RawEntry {
        var bytes = Array(string.utf8)
        bytes.append(0)
        return RawEntry(tag: tag, type: typeASCII, count: UInt32(bytes.count), payload: Data(bytes))
    }

    private static func rational(_ tag: UInt16, _ values: [(UInt32, UInt32)]) -> RawEntry {
        var data = Data(capacity: values.count * 8)
        for (numerator, denominator) in values {
            var n = numerator.littleEndian
            var d = denominator.littleEndian
            withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &d) { data.append(contentsOf: $0) }
        }
        return RawEntry(tag: tag, type: typeRational, count: UInt32(values.count), payload: data)
    }

    private static func srational(_ tag: UInt16, _ values: [(Int32, Int32)]) -> RawEntry {
        var data = Data(capacity: values.count * 8)
        for (numerator, denominator) in values {
            var n = numerator.littleEndian
            var d = denominator.littleEndian
            withUnsafeBytes(of: &n) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: &d) { data.append(contentsOf: $0) }
        }
        return RawEntry(tag: tag, type: typeSRational, count: UInt32(values.count), payload: data)
    }

    // MARK: - Layout + serialization

    /// Serializes `entries` (which must already be sorted strictly ascending
    /// by tag — TIFF requires this) into a complete little-endian ("II")
    /// TIFF/DNG byte stream: the 8-byte header, the single IFD (entry count
    /// + 12-byte entries + a trailing 0 "no next IFD" offset), then every
    /// oversized entry's external value data, back-to-back. Values ≤4 bytes
    /// are written inline in the entry's own value/offset field (left-
    /// justified, zero-padded — the correct encoding for little-endian
    /// TIFF); larger values are appended to the external data area and the
    /// entry's field instead holds that area's offset.
    ///
    /// The `stripOffsets` entry is special-cased: its true value (where the
    /// pixel strip written by the caller, right after this function's
    /// return, will actually land) isn't known until every other tag's
    /// layout has been decided, so it's passed in as a `0` placeholder and
    /// patched here once the external-data area's total size — and
    /// therefore the strip's real starting offset — is known.
    private static func serializeIFD(entries: inout [RawEntry]) -> Data {
        precondition(
            zip(entries, entries.dropFirst()).allSatisfy { $0.tag < $1.tag },
            "IFD entries must be strictly ascending, unique tag IDs"
        )

        let headerSize = 8
        let ifdSize = 2 + entries.count * 12 + 4 // count + entries + next-IFD offset
        var cursor = headerSize + ifdSize // header + ifd sizes are always even (see below)

        var externalOffsets = [Int?](repeating: nil, count: entries.count)
        var stripOffsetsIndex: Int?
        for i in entries.indices {
            if entries[i].tag == Tag.stripOffsets {
                stripOffsetsIndex = i
            }
            if entries[i].payload.count > 4 {
                externalOffsets[i] = cursor
                cursor += entries[i].payload.count
                // TIFF offsets conventionally fall on even boundaries.
                if cursor % 2 != 0 { cursor += 1 }
            }
        }

        let stripDataOffset = cursor
        if let idx = stripOffsetsIndex {
            var offset = UInt32(stripDataOffset).littleEndian
            entries[idx].payload = withUnsafeBytes(of: &offset) { Data($0) }
        }

        var out = Data(capacity: stripDataOffset)

        // --- Header: "II" (little-endian), magic 42, offset to IFD 0 ---
        out.append(contentsOf: [0x49, 0x49])
        appendLE(&out, UInt16(42))
        appendLE(&out, UInt32(headerSize))

        // --- IFD ---
        appendLE(&out, UInt16(entries.count))
        for i in entries.indices {
            let entry = entries[i]
            appendLE(&out, entry.tag)
            appendLE(&out, entry.type)
            appendLE(&out, entry.count)
            if let offset = externalOffsets[i] {
                appendLE(&out, UInt32(offset))
            } else {
                var inline = entry.payload
                while inline.count < 4 { inline.append(0) } // zero-pad, left-justified
                out.append(inline.prefix(4))
            }
        }
        appendLE(&out, UInt32(0)) // no next IFD

        // --- External data area, in the same order offsets were assigned ---
        for i in entries.indices {
            guard let offset = externalOffsets[i] else { continue }
            while out.count < offset { out.append(0) } // even-boundary padding, if any
            out.append(entries[i].payload)
        }
        while out.count < stripDataOffset { out.append(0) }

        return out
    }

    private static func appendLE(_ data: inout Data, _ value: UInt16) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    private static func appendLE(_ data: inout Data, _ value: UInt32) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
}
