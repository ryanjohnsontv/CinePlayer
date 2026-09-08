import SwiftUI
import CineKit
import CinePlayerCore

/// On-video metadata HUD, toggled via `documentModel.showMetadataOverlay`
/// (bound to the title-bar ⓘ button / "Show Metadata Overlay" ⌘I command in
/// `CinePlayerApp`/`ContentView`). `ContentView` composes this into a
/// `ZStack` alongside `CineMetalView` — this file never touches
/// `CineMetalView.swift` itself, and nothing here reads or writes
/// `documentModel.uniforms`, so showing/hiding it has zero effect on
/// rendering/playback of the underlying video.
///
/// **Scope note:** this file's reviewFPS-based SMPTE convention belongs to
/// the separate on-video-HUD redesign effort described below — landed and
/// reasoned about independently of, and before, the in/out-point
/// range-selection work (`ScrubberView.swift` /
/// `PlaybackController.inPoint`/`outPoint`). It should not be attributed to,
/// bundled with, or reviewed as part of that range-selection diff; the
/// range-selection feature does not touch this file at all.
///
/// This is the actual on-video overlay for the whole per-file metadata set —
/// the same field list `InspectorSidebarView` used to show in the trailing
/// sidebar before that panel was repurposed to hold color-correction +
/// export controls instead (see its own doc comment). The field
/// selection/formatting/nil-handling logic below is moved verbatim from that
/// panel, not re-derived, and is grouped into a single semi-opaque rounded
/// panel in the top-left corner so it stays legible over both very bright
/// (e.g. an overexposed clip) and very dark real footage — a shadow alone
/// was confirmed (via a real screenshot) not to be enough for the former.
///
/// Top of the panel is the single frame-numbering counter row — plain
/// "Frame N / Total", SMPTE-style `HH:MM:SS:FF@fps`, or trigger-relative
/// "Frame <signed> / <signed>", depending on the shared, persisted
/// `documentModel.frameNumberingMode` preference (see `counterText`'s own
/// doc comment). Below it: filename, resolution, native fps, elapsed time,
/// bit depth, compression, CFA pattern, shutter, and camera model — each
/// omitted (never shown as a blank row) exactly when the old panel omitted
/// it.
struct MetadataOverlayView: View {
    @ObservedObject var documentModel: CineDocumentModel
    @ObservedObject var playbackController: PlaybackController

    var body: some View {
        panel
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(12)
            // Purely informational chrome floating over the video — never
            // the target of clicks/drags meant for whatever sits underneath
            // it.
            .allowsHitTesting(false)
    }

    /// The single grouped panel: every row stacked inside one semi-opaque
    /// rounded-rect background, rather than the old per-field background
    /// chips — one background reads as one coherent HUD block instead of a
    /// scatter of separate pills once this many fields are shown at once.
    private var panel: some View {
        VStack(alignment: .leading, spacing: 3) {
            overlayRow(counterText)
            overlayRow(documentModel.currentURL?.lastPathComponent ?? "\u{2014}")
            overlayRow(resolutionText)
            if let nativeFPSText {
                overlayRow(nativeFPSText)
            }
            if let elapsedText {
                overlayRow(elapsedText)
            }
            if let sensorBitDepth = documentModel.sensorBitDepth {
                overlayRow("\(sensorBitDepth)-bit")
            }
            if !documentModel.compressionLabel.isEmpty {
                overlayRow(documentModel.compressionLabel)
            }
            if let cfaPattern = documentModel.cfaPattern {
                overlayRow(cfaPattern.hudDisplayName)
            }
            if let shutterText {
                overlayRow(shutterText)
            }
            // `cameraModel` can be present-but-empty (see
            // `CineDocumentModel.cameraModel`'s own doc comment) — most real
            // files have neither, so this row is simply omitted rather than
            // showing a blank line.
            if let cameraModel = documentModel.cameraModel, !cameraModel.isEmpty {
                overlayRow(cameraModel)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // A subtle semi-opaque backing (not fully opaque) plus each row's
        // own drop shadow — a shadow alone turned out not to be enough to
        // keep this legible over bright/overexposed footage, confirmed via
        // a real screenshot during this HUD's own review.
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }

    private func overlayRow(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.85), radius: 2)
    }

    // MARK: - Field formatting (moved verbatim from the old
    // `InspectorSidebarView` field list — same selection, same formatting,
    // same nil-handling)

    private var resolutionText: String {
        "\(documentModel.frameWidth)\u{00D7}\(documentModel.frameHeight)"
    }

    private var nativeFPSText: String? {
        guard let fps = documentModel.captureFrameRate else { return nil }
        return "\(fps.formatted(.number.precision(.fractionLength(0)))) fps (native)"
    }

    /// Elapsed real-world capture time at the file's native fps — the
    /// actual point of a high-speed camera being able to correlate a given
    /// frame with real-world event timing. `nil` (row omitted) when the
    /// file has no usable capture frame rate, since "elapsed time" is
    /// meaningless without one.
    private var elapsedText: String? {
        guard let fps = documentModel.captureFrameRate, fps > 0 else { return nil }
        let elapsedSeconds = Double(playbackController.currentFrameIndex) / fps
        return String(format: "%.2fs elapsed", elapsedSeconds)
    }

    /// `documentModel.shutterNs` converted to whichever of µs/ms reads more
    /// naturally at that magnitude — sub-millisecond shutter speeds are the
    /// common case on a high-speed camera, where "0.3 ms" is harder to read
    /// at a glance than "300.0 \u{00b5}s".
    private var shutterText: String? {
        guard let shutterNs = documentModel.shutterNs else { return nil }
        let microseconds = Double(shutterNs) / 1000.0
        if microseconds >= 1000 {
            return String(format: "%.2f ms shutter", microseconds / 1000.0)
        }
        return String(format: "%.1f \u{00b5}s shutter", microseconds)
    }

    /// The single, shared frame-numbering counter row — whichever of
    /// plain/SMPTE/trigger-relative is currently selected
    /// (`documentModel.frameNumberingMode`), computed via the same
    /// `FrameNumberingMode.counterText` `PlaybackToolbar` uses, so this file
    /// never duplicates that composition/formatting logic.
    ///
    /// Previously this panel showed a permanently-on SMPTE timecode row
    /// (`timecodeText`) AND a separate, always-simultaneous "Frame N /
    /// Total" row (`frameCountText`) — genuinely redundant information
    /// shown twice at once. Both are replaced by this one row, whose
    /// content now depends on the shared mode preference instead of always
    /// being the review-rate SMPTE convention described in this property's
    /// former doc comment (that formula itself is unchanged — see
    /// `FrameNumberingMode.formattedFrameNumber`'s own doc comment, which
    /// now carries that reasoning).
    private var counterText: String {
        FrameNumberingMode.counterText(
            mode: documentModel.frameNumberingMode,
            currentIndex: playbackController.currentFrameIndex,
            frameCount: playbackController.frameCount,
            reviewFPS: playbackController.reviewFPS,
            firstImageNo: playbackController.firstImageNo
        )
    }
}

extension CFAPattern {
    /// Readable label for the metadata overlay. `CFAPattern`'s own cases
    /// (in CineKit's `SetupFieldLayout.swift`) document each one's real-world
    /// layout only in code comments — this surfaces that same information as
    /// user-facing text without needing to touch CineKit.
    var hudDisplayName: String {
        switch self {
        case .none: return "Monochrome"
        case .vri: return "VRI (GBRG/RGGB)"
        case .vriV6: return "VRI v6 (BGGR/GRBG)"
        case .bayer: return "Bayer (GBRG)"
        case .bayerFlip: return "Bayer (RGGB)"
        }
    }
}
