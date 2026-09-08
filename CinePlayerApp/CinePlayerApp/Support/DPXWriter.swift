import Foundation

/// A minimal, hand-rolled SMPTE 268M-2003 ("DPX", Digital Picture Exchange
/// v2.0) writer for a single 16-bit-per-channel RGB frame — no third-party
/// image library exists in this Swift-only codebase, and macOS's own
/// ImageIO has no DPX destination type at all (confirmed directly:
/// `CGImageDestinationCopyTypeIdentifiers()` lists nothing DPX-related on
/// this system), so this writes the file byte-for-byte, the same level of
/// rigor `DNGWriter` (in `DNGExporter.swift`) already holds itself to for
/// the DNG/TIFF format.
///
/// Writes only the mandatory **Generic File Header** (768 bytes) +
/// **Generic Image Header** (640 bytes) + **Generic Orientation Header**
/// (256 bytes) — 1664 bytes total, `genericSize` in the file header — and
/// omits the optional Industry-Specific (Motion Picture/Television) Header
/// and User-Defined Data entirely (`industrySize`/`userSize` both `0`),
/// which the spec explicitly allows: `imageOffset` simply points straight
/// past the generic headers to the pixel data with nothing in between.
///
/// **Big-endian** ("SDPX" magic), not this codebase's usual little-endian
/// convention (see `CineKit.DataReader`/`DNGWriter`'s own little-endian
/// choice) — deliberately: SMPTE 268M supports either byte order (a reader
/// detects it from which of "SDPX"/"XPDS" it sees and swaps accordingly),
/// but "SDPX" is overwhelmingly the convention real cinema/VFX tools
/// (Nuke, DaVinci Resolve, …) actually write and expect, and some simpler
/// tools assume it rather than truly auto-detecting — so this writes
/// big-endian for the widest real-world compatibility, matching the whole
/// point of offering DPX at all.
///
/// Every numeric field this writer doesn't have a real, meaningful value
/// for is written as the spec's own defined "unspecified" sentinel
/// (`0xFFFFFFFF` for a 32-bit int or float field, `0xFFFF` for a 16-bit
/// one) rather than a guessed real value — e.g. reference low/high data
/// code/quantity, X/Y center, border validity, pixel aspect ratio. This is
/// itself a normal, spec-legal thing for a DPX writer to do (plenty of real
/// still-frame tools leave these unset), and is safer than asserting a
/// specific value with no real basis for it.
///
/// Pixel format written: **descriptor 50 (R,G,B, no alpha)**, 16 bits per
/// sample, no packing (`bitSize == 16` needs none — packing only matters
/// for sub-32-bit-word sample sizes like 10/12-bit), no run-length
/// encoding. **Transfer characteristic and Colorimetric both set to `6`
/// (ITU-R 709-4)** — not a guess: this exporter's source pixels are always
/// the same Rec.709-gamma-encoded, display-referred RGB
/// `Tonemap.metal`'s `applyGamma`/`rec709OETF` produces (see that
/// function's own doc comment), the identical domain the PNG/TIFF/JPEG
/// still exporters already write — so `6` is the semantically correct tag
/// for what's actually in the file, not an assumption.
enum DPXWriter {
    // MARK: - Sentinels (SMPTE 268M's own "value not specified" convention)

    private static let undefinedU32: UInt32 = 0xFFFFFFFF
    private static let undefinedU16: UInt16 = 0xFFFF
    /// The spec's defined bit pattern for an "undefined" 32-bit float field
    /// is the same all-ones pattern as the integer sentinel, reinterpreted
    /// as raw bits (not the numeric value `-NaN` one would get by writing
    /// `Float(0xFFFFFFFF)` and converting) — every float field below is
    /// written via this raw bit pattern, never a converted integer.
    private static let undefinedF32Bits: UInt32 = 0xFFFFFFFF

    /// Builds a complete, standalone DPX file for one already-rendered
    /// 16-bit RGBA frame.
    ///
    /// - Parameter rgba16BigEndianSourceLittleEndian: the raw pixel buffer
    ///   exactly as read back from an `.rgba16Unorm` Metal texture — 4
    ///   consecutive **native-endian** (little-endian on every Mac this
    ///   runs on) `UInt16` samples per pixel, R/G/B/A order, row-major,
    ///   top-down (matches `RangeExporter.renderTIFFData16Bit`'s own
    ///   readback exactly — see that function's doc comment for why this
    ///   layout/endianness/row-order is verified, not assumed). Alpha is
    ///   dropped (always exactly `1.0` out of `tonemapFragment`, so it
    ///   carries no real information — matching the PNG/TIFF exporters'
    ///   own `.noneSkipFirst`/`.noneSkipLast` treatment of the same
    ///   channel) and each remaining R/G/B sample is byte-swapped to
    ///   big-endian, since this writer's declared magic number commits the
    ///   *entire* file, pixel data included, to big-endian.
    static func makeDPXData(rgba16Pixels: [UInt8], width: Int, height: Int) -> Data {
        let genericFileHeaderSize = 768
        let genericImageHeaderSize = 640
        let genericOrientationHeaderSize = 256
        let genericSize = genericFileHeaderSize + genericImageHeaderSize + genericOrientationHeaderSize
        let imageOffset = UInt32(genericSize) // no industry header, no user data
        let bytesPerSample = 2
        let samplesPerPixel = 3 // R, G, B — no alpha (descriptor 50)
        let imageDataSize = width * height * samplesPerPixel * bytesPerSample
        let fileSize = UInt32(genericSize + imageDataSize)

        var out = Data(capacity: genericSize + imageDataSize)
        appendGenericFileHeader(to: &out, imageOffset: imageOffset, fileSize: fileSize, genericSize: UInt32(genericSize))
        appendGenericImageHeader(to: &out, width: width, height: height, imageOffset: imageOffset)
        appendGenericOrientationHeader(to: &out, width: width, height: height)
        appendPixelData(to: &out, rgba16Pixels: rgba16Pixels, width: width, height: height)
        return out
    }

    // MARK: - Generic File Header (768 bytes)

    private static func appendGenericFileHeader(to out: inout Data, imageOffset: UInt32, fileSize: UInt32, genericSize: UInt32) {
        let start = out.count
        appendASCII(&out, "SDPX", padTo: 4) // magic number (big-endian file)
        appendU32(&out, imageOffset)
        appendASCII(&out, "V2.0", padTo: 8) // DPX version
        appendU32(&out, fileSize)
        appendU32(&out, undefinedU32) // ditto key — not applicable to a standalone still
        appendU32(&out, genericSize)
        appendU32(&out, 0) // industry-specific header size — omitted entirely
        appendU32(&out, 0) // user-defined data size — none
        appendASCII(&out, "", padTo: 100) // file name — left blank rather than guessed
        appendASCII(&out, "", padTo: 24) // creation date/time — left blank rather than guessed
        appendASCII(&out, "CinePlayer", padTo: 100) // creator
        appendASCII(&out, "", padTo: 200) // project name
        appendASCII(&out, "", padTo: 200) // copyright
        appendU32(&out, undefinedU32) // encryption key — unencrypted
        appendZeros(&out, 104) // reserved
        precondition(out.count - start == 768, "Generic File Header must be exactly 768 bytes")
    }

    // MARK: - Generic Image Header (640 bytes)

    private static func appendGenericImageHeader(to out: inout Data, width: Int, height: Int, imageOffset: UInt32) {
        let start = out.count
        appendU16(&out, 0) // orientation: left-to-right, top-to-bottom
        appendU16(&out, 1) // number of image elements
        appendU32(&out, UInt32(width)) // pixels per line
        appendU32(&out, UInt32(height)) // lines per element

        // Element 0: the real R,G,B image data.
        appendImageElement(
            to: &out,
            descriptor: 50, // R, G, B (no alpha)
            transferAndColorimetric: 6, // ITU-R 709-4 — see this type's own doc comment
            bitSize: 16,
            dataOffset: imageOffset
        )
        // Elements 1-7: unused, all fields left at their "undefined"
        // sentinel — the spec only requires `numberElements` (above) to say
        // how many are real; the rest can be present-but-unused.
        for _ in 1..<8 {
            appendImageElement(to: &out, descriptor: 0, transferAndColorimetric: 0, bitSize: 0, dataOffset: undefinedU32, unused: true)
        }

        appendZeros(&out, 52) // reserved, pads Generic Image Header to 640 bytes total
        precondition(out.count - start == 640, "Generic Image Header must be exactly 640 bytes")
    }

    /// One 72-byte "Image Element Data Structure" entry.
    private static func appendImageElement(
        to out: inout Data,
        descriptor: UInt8,
        transferAndColorimetric: UInt8,
        bitSize: UInt8,
        dataOffset: UInt32,
        unused: Bool = false
    ) {
        let start = out.count
        appendU32(&out, 0) // data sign: 0 = unsigned
        appendU32(&out, undefinedU32) // reference low data code value
        appendF32Bits(&out, undefinedF32Bits) // reference low quantity
        appendU32(&out, undefinedU32) // reference high data code value
        appendF32Bits(&out, undefinedF32Bits) // reference high quantity
        appendU8(&out, descriptor)
        appendU8(&out, unused ? 0 : transferAndColorimetric) // transfer characteristic
        appendU8(&out, unused ? 0 : transferAndColorimetric) // colorimetric
        appendU8(&out, bitSize)
        appendU16(&out, 0) // packing: 0 — no padding needed at 16 bits/sample
        appendU16(&out, 0) // encoding: 0 — no run-length encoding
        appendU32(&out, dataOffset)
        appendU32(&out, 0) // end-of-line padding
        appendU32(&out, 0) // end-of-image padding
        appendASCII(&out, "", padTo: 32) // description
        precondition(out.count - start == 72, "Image Element entry must be exactly 72 bytes")
    }

    // MARK: - Generic Orientation Header (256 bytes)

    private static func appendGenericOrientationHeader(to out: inout Data, width: Int, height: Int) {
        let start = out.count
        appendU32(&out, undefinedU32) // X offset
        appendU32(&out, undefinedU32) // Y offset
        appendF32Bits(&out, undefinedF32Bits) // X center
        appendF32Bits(&out, undefinedF32Bits) // Y center
        appendU32(&out, UInt32(width)) // X original size
        appendU32(&out, UInt32(height)) // Y original size
        appendASCII(&out, "", padTo: 100) // source file name
        appendASCII(&out, "", padTo: 24) // source creation date/time
        appendASCII(&out, "", padTo: 32) // input device name
        appendASCII(&out, "", padTo: 32) // input device serial number
        for _ in 0..<4 { appendU16(&out, undefinedU16) } // border validity: XL, XR, YT, YB
        for _ in 0..<2 { appendU32(&out, undefinedU32) } // pixel aspect ratio: H, V
        appendZeros(&out, 28) // reserved
        precondition(out.count - start == 256, "Generic Orientation Header must be exactly 256 bytes")
    }

    // MARK: - Pixel data

    /// Drops alpha and byte-swaps each remaining R/G/B `UInt16` sample from
    /// native (little-)endian to big-endian — see `makeDPXData`'s own doc
    /// comment on `rgba16BigEndianSourceLittleEndian`'s exact input shape.
    private static func appendPixelData(to out: inout Data, rgba16Pixels: [UInt8], width: Int, height: Int) {
        let pixelCount = width * height
        out.reserveCapacity(out.count + pixelCount * 6)
        rgba16Pixels.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: UInt16.self) // 4 per pixel: R, G, B, A
            for pixel in 0..<pixelCount {
                let base = pixel * 4
                appendU16(&out, samples[base]) // R
                appendU16(&out, samples[base + 1]) // G
                appendU16(&out, samples[base + 2]) // B
                // samples[base + 3] (alpha) intentionally dropped.
            }
        }
    }

    // MARK: - Primitive big-endian encoders

    private static func appendU8(_ data: inout Data, _ value: UInt8) {
        data.append(value)
    }

    private static func appendU16(_ data: inout Data, _ value: UInt16) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private static func appendU32(_ data: inout Data, _ value: UInt32) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    /// Appends a raw 32-bit float bit pattern, byte-order-swapped like any
    /// other 32-bit field — used only for the sentinel "undefined" value
    /// today (see `undefinedF32Bits`), never a computed real float, so this
    /// takes the already-`UInt32` bit pattern directly rather than a
    /// `Float` (avoids ever tempting a future caller into passing a
    /// converted integer through `Float(x)` instead of a true bit-pattern
    /// reinterpretation).
    private static func appendF32Bits(_ data: inout Data, _ bits: UInt32) {
        appendU32(&data, bits)
    }

    private static func appendZeros(_ data: inout Data, _ count: Int) {
        data.append(Data(repeating: 0, count: count))
    }

    /// NUL-padded (not space-padded) ASCII field, truncated if `string`'s
    /// UTF-8 encoding is somehow longer than `padTo` — every string field
    /// in this file is well within its budget by construction (mostly
    /// empty or short fixed literals), so truncation is a defensive
    /// backstop, not an expected path.
    private static func appendASCII(_ data: inout Data, _ string: String, padTo count: Int) {
        var bytes = Array(string.utf8.prefix(count))
        while bytes.count < count { bytes.append(0) }
        data.append(contentsOf: bytes)
    }
}
