import SwiftUI
import CinePlayerCore

/// Play/pause button and a "frame N / total" readout, shown below the
/// scrubber once a file is open.
///
/// The debayer-mode picker and color-matrix toggle that used to sit here
/// (trailing edge, behind a `Spacer()`) have moved to the "Color Correction"
/// section of `InspectorSidebarView` — this row is transport-only now.
struct PlaybackToolbar: View {
    @ObservedObject var documentModel: CineDocumentModel
    @ObservedObject var playbackController: PlaybackController

    var body: some View {
        HStack(spacing: 12) {
            transportControls

            Text(FrameNumberingMode.counterText(
                mode: documentModel.frameNumberingMode,
                currentIndex: playbackController.currentFrameIndex,
                frameCount: playbackController.frameCount,
                reviewFPS: playbackController.reviewFPS,
                firstImageNo: playbackController.firstImageNo
            ))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)

            Picker("Frame Numbering", selection: Binding(
                get: { documentModel.frameNumberingMode },
                set: { documentModel.setFrameNumberingMode($0) }
            )) {
                ForEach(FrameNumberingMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 180)

            Spacer()

            zoomControls
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// "-" / preset dropdown / "+", trailing-edge (behind the `Spacer()`
    /// above) — the same slot the debayer-mode picker and color-matrix
    /// toggle used to occupy before moving to `InspectorSidebarView`'s
    /// "Color Correction" section (see this file's own top doc comment).
    /// Zoom stays here rather than following them: it's a viewport/framing
    /// concern tied to the video pane itself, not a rendering-fidelity
    /// setting grouped with color.
    ///
    /// The dropdown's selection only ever shows a highlighted match for one
    /// of `CineDocumentModel.zoomPresets` — a trackpad-pinched, in-between
    /// zoom level (e.g. 3.4x) simply shows no highlight, the same
    /// no-highlight-for-an-off-preset-value behavior most zoom dropdowns
    /// (Preview.app included) have, not a bug to work around here.
    private var zoomControls: some View {
        HStack(spacing: 6) {
            Button(action: { documentModel.zoomOut() }) {
                Image(systemName: "minus.magnifyingglass")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help("Zoom Out")
            .disabled(documentModel.zoomScale <= CineDocumentModel.minZoomScale)

            Picker("Zoom", selection: Binding(
                get: { documentModel.zoomScale },
                set: { documentModel.setZoomScale($0) }
            )) {
                ForEach(CineDocumentModel.zoomPresets, id: \.self) { preset in
                    Text(preset <= CineDocumentModel.minZoomScale ? "Fit" : "\(Int(preset))x").tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 68)

            Button(action: { documentModel.zoomIn() }) {
                Image(systemName: "plus.magnifyingglass")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help("Zoom In")
            .disabled(documentModel.zoomScale >= CineDocumentModel.maxZoomScale)
        }
    }

    /// The 6-rate transport: fast-reverse / reverse-2x / reverse-1x /
    /// play-or-pause (forward normal, existing button) / forward-2x /
    /// forward-4x, laid out symmetrically around the center play/pause
    /// button. Every button routes through
    /// `PlaybackController.togglePlay(rate:)`, so clicking the button for
    /// whichever rate is already active pauses, and clicking any other
    /// button switches straight to that rate (matching the existing
    /// play/pause button's own toggle behavior, generalized).
    ///
    /// Symbol choices: `backward.2.fill`/`backward.3.fill`/`forward.2.fill`/
    /// `forward.3.fill` (the names one might reach for first, "N stacked
    /// triangles" for "Nx") do not actually exist in this SDK —
    /// `NSImage(systemSymbolName:)` returns `nil` for all four, which is why
    /// an earlier pass at this rendered only 2 of the 6 buttons as visible
    /// glyphs. The 6 symbols below were each confirmed to resolve to a
    /// non-nil image before settling on them: `backward.end.fill`/
    /// `forward.end.fill` (skip-to-start/end, standing in for the "extreme"
    /// +-4x tier), `backward.fill`/`forward.fill` (the classic
    /// double-triangle rewind/fast-forward glyph, for the +-2x tier), and a
    /// horizontally-mirrored `play.fill` for reverse-1x (there is no
    /// separate "reverse play" symbol in the catalog, so the existing
    /// forward play triangle is flipped instead of introducing a
    /// differently-shaped glyph for what's conceptually the same "play"
    /// icon pointed the other way).
    ///
    /// The 2 real-time buttons (flanking the 6-rate group behind a
    /// `Divider`, so they read as a different *kind* of control rather than
    /// a 7th/8th speed tier) use `goforward`/`gobackward` — also confirmed
    /// to resolve to a non-nil image. Chosen over a clock/stopwatch glyph
    /// (`clock.fill`, `stopwatch.fill`, also confirmed to resolve) because
    /// those read as direction-less — mirroring one produces the same
    /// glyph, unlike `play.fill`'s triangle, so it wouldn't visually
    /// distinguish forward from reverse the way the rest of this transport
    /// does. `goforward`/`gobackward` are Apple's own pair for time-based
    /// skip controls in media UIs, so they read as "time" (matching what
    /// real-time mode actually is) while still being a genuinely directional
    /// pair rather than one glyph mirrored.
    private var transportControls: some View {
        HStack(spacing: 6) {
            realTimeButton(forward: false, systemImage: "gobackward", help: "Reverse (Real-Time)")

            Divider().frame(height: 16)

            rateButton(.reverseFastFast, systemImage: "backward.end.fill", help: "Reverse 4x")
            rateButton(.reverseFast, systemImage: "backward.fill", help: "Reverse 2x")
            reverseNormalButton

            Button(action: { playbackController.togglePlay(rate: .forwardNormal) }) {
                Image(systemName: isActive(.forwardNormal) ? "pause.fill" : "play.fill")
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .help(isActive(.forwardNormal) ? "Pause" : "Play")

            rateButton(.forwardFast, systemImage: "forward.fill", help: "Forward 2x")
            rateButton(.forwardFastFast, systemImage: "forward.end.fill", help: "Forward 4x")

            Divider().frame(height: 16)

            realTimeButton(forward: true, systemImage: "goforward", help: "Forward (Real-Time)")
        }
    }

    private var reverseNormalButton: some View {
        Button(action: { playbackController.togglePlay(rate: .reverseNormal) }) {
            Image(systemName: "play.fill")
                .scaleEffect(x: -1, y: 1)
                .frame(width: 16, height: 16)
                .foregroundStyle(isActive(.reverseNormal) ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.borderless)
        .help("Reverse")
    }

    private func isActive(_ rate: PlaybackRate) -> Bool {
        playbackController.isPlaying && playbackController.currentMode == .rate(rate)
    }

    private func isRealTimeActive(forward: Bool) -> Bool {
        playbackController.isPlaying && playbackController.currentMode == .realTime(forward: forward)
    }

    private func rateButton(_ rate: PlaybackRate, systemImage: String, help: String) -> some View {
        Button(action: { playbackController.togglePlay(rate: rate) }) {
            Image(systemName: systemImage)
                .frame(width: 16, height: 16)
                .foregroundStyle(isActive(rate) ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    /// A real-time-mode button (see `PlaybackController.playRealTime`). The
    /// tooltip appends the clip's actual capture fps when known
    /// (`documentModel.captureFrameRate`) — e.g. "Forward (Real-Time) — native
    /// 1536 fps" — so it's clear what "real-time" concretely means for
    /// *this* file, not just an abstract mode name; falls back to the plain
    /// `help` text for files without a parseable `SETUP` frame rate.
    private func realTimeButton(forward: Bool, systemImage: String, help: String) -> some View {
        let tooltip: String
        if let fps = documentModel.captureFrameRate {
            tooltip = "\(help) — native \(fps.formatted(.number.precision(.fractionLength(0)))) fps"
        } else {
            tooltip = help
        }
        return Button(action: { playbackController.toggleRealTime(forward: forward) }) {
            Image(systemName: systemImage)
                .frame(width: 16, height: 16)
                .foregroundStyle(isRealTimeActive(forward: forward) ? Color.accentColor : Color.primary)
        }
        .buttonStyle(.borderless)
        .help(tooltip)
    }
}
