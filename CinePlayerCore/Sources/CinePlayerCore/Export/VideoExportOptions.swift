import AVFoundation

/// The cinema/VFX-relevant codecs any video-export path in this project
/// offers — the GUI's "Export Video…" (`VideoExportCoordinator`, in the
/// `CinePlayerApp` target) and the headless `cine-batch-convert` CLI tool
/// alike — via `AVAssetWriter`/VideoToolbox, no third-party encoding
/// library, no DNxHD (Avid's codec has no public macOS/AVFoundation
/// encoder at all). Every case was confirmed to exist as a real, named
/// `AVVideoCodecType` constant in this SDK (not guessed) and end-to-end
/// smoke-tested through a real `AVAssetWriter`/
/// `AVAssetWriterInputPixelBufferAdaptor` pipeline writing actual `.mov`
/// files `AVURLAsset` reads back correctly — ProRes 4444 XQ was considered
/// and dropped: it has no named `AVVideoCodecType` constant in this SDK at
/// all, so offering it would mean constructing an unverified raw FourCC
/// string with no confirmation any encoder actually backs it on this
/// hardware/OS. Shared here (not duplicated per call site) so both
/// consumers can never drift out of sync about which codecs are actually
/// verified to exist.
public enum VideoCodecOption: CaseIterable, Sendable {
    case proRes422Proxy
    case proRes422LT
    case proRes422
    case proRes422HQ
    case proRes4444
    case h264
    case hevc

    public var displayName: String {
        switch self {
        case .proRes422Proxy: return "Apple ProRes 422 Proxy"
        case .proRes422LT: return "Apple ProRes 422 LT"
        case .proRes422: return "Apple ProRes 422"
        case .proRes422HQ: return "Apple ProRes 422 HQ"
        case .proRes4444: return "Apple ProRes 4444"
        case .h264: return "H.264"
        case .hevc: return "HEVC (H.265)"
        }
    }

    public var avCodecType: AVVideoCodecType {
        switch self {
        case .proRes422Proxy: return .proRes422Proxy
        case .proRes422LT: return .proRes422LT
        case .proRes422: return .proRes422
        case .proRes422HQ: return .proRes422HQ
        case .proRes4444: return .proRes4444
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }

    /// A short, command-line-friendly token — used by `cine-batch-convert`'s
    /// `--codec` flag (matched case-insensitively via `forCLIToken`). The
    /// GUI never uses this; it picks a codec from `displayName` in a popup.
    public var cliToken: String {
        switch self {
        case .proRes422Proxy: return "prores-proxy"
        case .proRes422LT: return "prores-lt"
        case .proRes422: return "prores422"
        case .proRes422HQ: return "prores-hq"
        case .proRes4444: return "prores4444"
        case .h264: return "h264"
        case .hevc: return "hevc"
        }
    }

    public static func forCLIToken(_ token: String) -> VideoCodecOption? {
        let normalized = token.lowercased()
        return allCases.first { $0.cliToken == normalized }
    }
}

/// A resolution choice, expressed as a maximum long-edge dimension the
/// source frame is fit within (aspect ratio always preserved) — never
/// upscaled: every preset/custom value only ever *caps* the size, so
/// footage already smaller than the chosen preset exports at its own
/// native size unchanged rather than manufacturing fake detail. See
/// `VideoExportSizing.outputSize(nativeWidth:nativeHeight:maxDimension:)`.
public enum VideoResolutionOption: Hashable, CaseIterable, Sendable {
    case native
    case fourK
    case fullHD
    case hd
    case custom

    public var displayName: String {
        switch self {
        case .native: return "Native"
        case .fourK: return "4K (max, 3840px)"
        case .fullHD: return "1080p (max, 1920px)"
        case .hd: return "720p (max, 1280px)"
        case .custom: return "Custom…"
        }
    }

    /// `nil` for `.native` (no cap at all) and `.custom` (the caller
    /// supplies its own value instead — an accessory view's text field for
    /// the GUI, a `--max-dimension` flag for the CLI).
    public var maxDimension: Int? {
        switch self {
        case .native: return nil
        case .fourK: return 3840
        case .fullHD: return 1920
        case .hd: return 1280
        case .custom: return nil
        }
    }
}

/// Shared output-size math for any video-export path — computing this
/// once here (not per call site) is what lets `cine-batch-convert` and
/// `VideoExportCoordinator` guarantee identical sizing behavior for the
/// same inputs.
public enum VideoExportSizing {
    public static func outputSize(nativeWidth: Int, nativeHeight: Int, maxDimension: Int?) -> (width: Int, height: Int) {
        guard let maxDimension, nativeWidth > 0, nativeHeight > 0 else {
            return (evenify(max(2, nativeWidth)), evenify(max(2, nativeHeight)))
        }
        let longEdge = max(nativeWidth, nativeHeight)
        // `min(1.0, ...)`: never upscale — see this type's own doc comment.
        let scale = min(1.0, Double(maxDimension) / Double(longEdge))
        let width = evenify(max(2, Int((Double(nativeWidth) * scale).rounded())))
        let height = evenify(max(2, Int((Double(nativeHeight) * scale).rounded())))
        return (width, height)
    }

    /// Most video codecs (and some readers) require even width/height —
    /// rounds up rather than down so the output is never smaller than
    /// requested.
    public static func evenify(_ value: Int) -> Int {
        value % 2 == 0 ? value : value + 1
    }
}
