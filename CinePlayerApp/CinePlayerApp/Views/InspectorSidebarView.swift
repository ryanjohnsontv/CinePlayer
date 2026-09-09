import SwiftUI
import CinePlayerCore

/// The trailing-edge inspector sidebar's content, shown by `ContentView`
/// alongside the rest of the window when `documentModel.showInspectorSidebar`
/// is true (toggled via the title-bar sidebar button or the ⌘⌥I menu
/// command). Only ever rendered while a file is open (`ContentView` nests it
/// inside its `if let playbackController = documentModel.playbackController`
/// branch), so nothing here needs a "no file open" disabled guard.
///
/// Four sections:
///
///   - "Color Correction": the Debayer mode picker and Color Matrix toggle,
///     moved verbatim here from `PlaybackToolbar` (same bindings, same
///     `colorMatrixToggleRelevant`-gated disabled state, same help text) —
///     the toolbar row below the scrubber is transport-only now. Also holds
///     the `.cube` LUT controls: a "LUT" on/off checkbox (disabled when
///     nothing is loaded), a "Load LUT…"/"Change LUT…" button
///     (`LUTLoadCoordinator.presentLoadPanel`), the active LUT's filename
///     once one is loaded, and — once at least one LUT has ever been
///     loaded — a "Recent LUTs" menu (capped at 3, same shape as the File
///     menu's "Open Recent") to reload one directly. Deliberately does NOT
///     offer a "Color Space" (Rec.709/Log1/Log2) picker: Vision Research's
///     own Cine File Format spec has no field recording which color space a
///     file was shot in (the one plausible candidate, a generic labeled
///     tone-curve field, is empty in every real sample file), and Log1/Log2
///     are reportedly deprecated besides — this app renders Rec.709 only. A
///     prominent orange warning `Label` used to appear at the top of this
///     section whenever `documentModel.colorCalibrationVetoed` was true —
///     temporarily removed while color-calibration work is still being
///     tested/debugged; see that removed code's own comment for why
///     `colorCalibrationVetoed` itself is untouched and this is expected to
///     come back.
///   - "Cine Colour": an ongoing grading panel (modeled on Phantom PCC's own
///     "Image Tools" — see the project's own backlog notes for the fuller
///     set of controls still to come). Sliders for Brightness, Gain (master
///     + R/G/B), Pedestal (master + R/G/B, with a purely-local "Chain
///     Pedestal Sliders" toggle that fans one slider's value out to all
///     four when chained), Gamma trim (master + independent R/G/B offsets —
///     matches PCC's own "Advanced Adjustments" panel, which exposes full
///     R/G/B gamma, not just R/B), Saturation, Hue, Color Temp, Tint
///     (WBCC), and a "Flip Horizontal" checkbox, plus a "Reset to Defaults"
///     button. Every `GradingUniforms` field binds through
///     `documentModel.grading`/`setGrading(_:)` (see `gradingBinding`
///     below) — `CineRenderer` applies these in the shared Metal pipeline
///     (`Tonemap.metal`), so this section affects the live view and every
///     export path identically. Color Temp/Tint (WBCC) are different in
///     kind from the `GradingUniforms` fields: they bind to plain
///     `CineDocumentModel` properties (`colorTempKelvin`/`wbcc`, not
///     `GradingUniforms` fields) that fold into the EXISTING pre-demosaic
///     white-balance uniforms (`uniforms.wbGainR/G/B`) rather than adding
///     new shader stages — see `CineDocumentModel.recomputeWhiteBalance()`.
///     Deliberately does NOT yet include Flare/Toe/Log-Modes/Exposure-Index/
///     a tone-curve widget, or a Flip Vertical control — all still out of
///     scope. Shows a small informational caption (never a disabled state —
///     see `gradingReachesCurrentMode`) when the active debayer mode is Raw
///     Sensor or Grey Scale, since both modes' shader paths return before
///     any grading (or white-balance) code runs at all.
///   - "Save": one button, "Save As (.cine)…", calling the exact same
///     `SaveAsCoordinator.saveAs(documentModel:)` the File menu's ⌘⇧S
///     command already calls (`CinePlayerApp.swift`) — writing a `.cine`
///     file back out (trimmed and/or otherwise) is a save, not a format
///     conversion, so it's kept visually separate from "Export" below it;
///     see `SaveAsCoordinator`'s own doc comment for why this is
///     Save-As-only, never a plain in-place Save.
///   - "Export": two buttons that call the exact same
///     `VideoExportCoordinator.exportVideo(documentModel:)` /
///     `StillExportCoordinator.exportCurrentFrame(documentModel:)`
///     functions the File menu's "Export" submenu already calls
///     (`CinePlayerApp.swift`), so there is exactly one implementation of
///     each export action, not two. Export is reserved strictly for
///     converting to a genuinely different, non-`.cine` format (a real
///     encoded video, or a still in PNG/TIFF/JPEG/DPX/raw DNG) — writing
///     `.cine` back out belongs to "Save" above, not here.
///
/// The dense per-file metadata field list (filename, resolution, native fps,
/// frame/total, elapsed time, bit depth, compression, CFA pattern, shutter,
/// camera model) this view used to show has moved to `MetadataOverlayView`,
/// which is now the actual on-video overlay for that content — see its own
/// doc comment.
/// How a `gradingSlider` row's track is colored — see the constants below
/// for the actual colors and the reasoning for each. Mirrors Adobe Camera
/// Raw/Lightroom's convention of coloring a slider by what it does to the
/// image rather than tinting every slider the same way: ACR itself doesn't
/// color Exposure/Contrast/Highlights/Shadows/Texture/Clarity, only
/// Temperature/Tint (both genuinely bipolar-by-hue, unlike a plain
/// magnitude control) — so `.plain` stays the default for everything
/// except the R/G/B channel sliders (which get `.solidTint`, identifying
/// which channel each one touches) and Color Temp/Tint (which get
/// `.gradient`, matching ACR's own Temperature/Tint sliders exactly).
private enum SliderColorStyle {
    case plain
    case solidTint(Color)
    case gradient([Color])
}

/// A fixed set of common color-temperature targets, matching the White
/// Balance preset list every raw-editing tool (ACR included) offers
/// alongside its free-form Temperature slider — picking one sets
/// `colorTempKelvin` directly and zeroes `wbcc`, giving a clean, definite
/// starting point rather than layering a preset on top of whatever tint the
/// user had already dialed in manually. No "As Shot"/"Auto" entries here:
/// unlike a real camera raw file, a `.cine`'s own recorded white-balance
/// metadata has no exposed Kelvin-equivalent value to reverse into a
/// preset, and gray-world auto-WB would need to solve for `colorTempKelvin`/
/// `wbcc` from pixel statistics — a real, separate feature, not attempted
/// here (see `CineDocumentModel.applyAutoExposure()`'s own doc comment for
/// why "Auto" in this app is exposure-only for the same reason).

/// Whole-stop Exposure Index ladder, centered on `referenceExposureIndex`.
private enum ExposureIndexPreset: Int, CaseIterable {
    case ei100 = 100
    case ei200 = 200
    case ei400 = 400
    case ei800 = 800
    case ei1600 = 1600
    case ei3200 = 3200
    case ei6400 = 6400

    var ei: Float { Float(rawValue) }

    var displayName: String {
        rawValue == Int(CineDocumentModel.referenceExposureIndex) ? "\(rawValue) (neutral)" : "\(rawValue)"
    }
}

private enum WhiteBalancePreset: String, CaseIterable {
    case tungsten = "Tungsten"
    case fluorescent = "Fluorescent"
    case daylight = "Daylight"
    case cloudy = "Cloudy"
    case shade = "Shade"
    case neutral = "Neutral"

    var kelvin: Float {
        switch self {
        case .tungsten: return 3200
        case .fluorescent: return 4000
        case .daylight: return 5500
        case .cloudy: return 6500
        case .shade: return 7500
        case .neutral: return 6500
        }
    }

    /// The menu label — name plus its Kelvin target (e.g. "Tungsten
    /// (3200K)"), so picking one isn't a guess at what number it'll
    /// actually dial `colorTempKelvin` to.
    var displayName: String {
        "\(rawValue) (\(Int(kelvin))K)"
    }
}

/// One labeled slider row, with a live numeric readout — the shared look
/// every "Cine Colour" slider uses. A real `View` (not just a function)
/// because it needs its own `@State` to support clicking the numeric
/// readout to type an exact value, which a plain `@ViewBuilder` function
/// can't own.
///
/// Double-clicking either the label row OR the slider itself (but NOT the
/// numeric readout — that's single-click-to-edit instead, see below)
/// resets just this one control to `defaultValue`.
///
/// The slider's own double-click handler uses `.simultaneousGesture`, not
/// `.onTapGesture`/`.gesture`: `Slider` is backed by a real `NSSlider`,
/// which claims mouse-down itself for its drag handling — attaching a
/// competing/exclusive gesture would either never see the click (swallowed
/// by the slider first) or block the slider's own dragging.
/// `simultaneousGesture` lets both recognize independently, so a plain
/// double-click still resets while a click-and-drag still scrubs the value
/// normally. The label row keeps its own identical reset gesture too
/// (harmless overlap, not a fallback) since it's an established affordance
/// some users may already rely on.
private struct GradingSliderRow: View {
    let label: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let defaultValue: Float
    var description: String?
    var style: SliderColorStyle = .plain

    /// Whether the numeric readout is currently a live-editable `TextField`
    /// instead of plain `Text` — entered by clicking the readout, exited by
    /// pressing Return/Tab or clicking away (both funnel through
    /// `commitEdit()`).
    @State private var isEditingValue = false
    @State private var editText = ""
    @FocusState private var isTextFieldFocused: Bool

    private var help: String {
        let resetText = "Double-click to reset to \(String(format: "%.2f", defaultValue))"
        return description.map { "\($0) \(resetText)" } ?? resetText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        value = defaultValue
                    }
                Spacer()
                if isEditingValue {
                    TextField("", text: $editText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 52)
                        .focused($isTextFieldFocused)
                        .onSubmit { commitEdit() }
                        .onChange(of: isTextFieldFocused) { _, focused in
                            if !focused { commitEdit() }
                        }
                } else {
                    Text(String(format: "%.2f", value))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            editText = String(format: "%.2f", value)
                            isEditingValue = true
                            isTextFieldFocused = true
                        }
                }
            }
            .help(help)
            Group {
                switch style {
                case .plain:
                    Slider(value: $value, in: range)
                case .solidTint(let color):
                    Slider(value: $value, in: range)
                        .tint(color)
                case .gradient(let colors):
                    GradientTrackSlider(value: $value, range: range, gradientColors: colors)
                }
            }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    value = defaultValue
                }
            )
            .help(help)
        }
    }

    /// Parses `editText` and applies it (clamped to `range`) if it's a
    /// valid number; an unparseable entry (empty, non-numeric) is silently
    /// discarded rather than zeroing the value out — leaving whatever was
    /// there before is less surprising than snapping to `0` for a typo.
    private func commitEdit() {
        if let parsed = Float(editText) {
            value = min(max(parsed, range.lowerBound), range.upperBound)
        }
        isEditingValue = false
    }
}

// This view hosts every "Color Correction"/"Cine Colour"/Save/Export control
// in one place, and has grown past the default type-length threshold as a
// result — a real, tracked concern (splitting the grading groups below into
// their own small subviews is a reasonable, comparatively low-risk future
// cleanup, unlike CineDocumentModel's own case), but not something to do as
// a drive-by structural change alongside unrelated lint cleanup, without the
// chance to verify the split visually first. Revisit when it's actually
// being refactored, not before.
struct InspectorSidebarView: View { // swiftlint:disable:this type_body_length
    @ObservedObject var documentModel: CineDocumentModel
    @ObservedObject var playbackController: PlaybackController

    // MARK: - Channel/white-balance slider colors
    //
    // Not full-saturation red/green/blue, which would read as alarm/success
    // states elsewhere in macOS UI (the same reasoning `ScrubberView`'s own
    // `maroon` constant documents for its "outside selection" color) —
    // softened just enough to sit comfortably as a slider tint while still
    // being unambiguous about which channel each one is.
    private static let channelRed = Color(red: 0.92, green: 0.36, blue: 0.33)
    private static let channelGreen = Color(red: 0.36, green: 0.78, blue: 0.42)
    private static let channelBlue = Color(red: 0.38, green: 0.56, blue: 0.95)

    /// Color Temp's gradient: blue at the low-Kelvin end, yellow/orange at
    /// the high-Kelvin end — matching what raising the value actually does
    /// to the image (a higher assumed ambient-light temperature pushes the
    /// white-balance correction warmer, via `recomputeWhiteBalance()`), and
    /// matching Adobe Camera Raw's own Temperature slider convention
    /// exactly.
    private static let colorTempGradient: [Color] = [
        Color(red: 0.30, green: 0.55, blue: 0.95),
        Color(red: 0.99, green: 0.78, blue: 0.35),
    ]

    /// Tint (WBCC)'s gradient: green at the negative end, magenta at the
    /// positive end — the standard green/magenta axis white-balance UIs
    /// (ACR included) use for the axis orthogonal to color temperature.
    private static let wbccGradient: [Color] = [
        Color(red: 0.40, green: 0.80, blue: 0.45),
        Color(red: 0.87, green: 0.42, blue: 0.82),
    ]

    /// The "exposure family" — Brightness and the master Gain/Gamma
    /// sliders — gets a plain dark-to-light grayscale track instead of a
    /// hue-carrying one: these affect overall luminance, not a specific
    /// channel or white-balance axis, so a neutral gradient (dark end =
    /// "toward black," light end = "toward white") reads as "this control
    /// darkens/brightens" without implying a color meaning that isn't
    /// there. R/G/B Gain/Pedestal/Gamma keep `.solidTint`; Color Temp/Tint
    /// keep their own hue gradients — this is specifically for the
    /// non-channel, non-white-balance brightness-style controls.
    private static let grayscaleGradient: [Color] = [
        Color(white: 0.12),
        Color(white: 0.92),
    ]

    /// Hue's gradient: the full rainbow, matching the actual 360° rotation
    /// this slider sweeps through (`-180...180`, both ends the same color
    /// since a hue rotation is circular) — the same convention e.g. a CSS
    /// `hue-rotate()` slider or an HSB color-wheel control uses, since
    /// unlike Color Temp/Tint (a straight-line axis between two named
    /// colors) there's no single meaningful pair of endpoint colors here.
    private static let hueGradient: [Color] = [
        Color(red: 1.00, green: 0.30, blue: 0.30),
        Color(red: 1.00, green: 0.85, blue: 0.30),
        Color(red: 0.40, green: 0.85, blue: 0.40),
        Color(red: 0.35, green: 0.80, blue: 0.85),
        Color(red: 0.40, green: 0.50, blue: 0.95),
        Color(red: 0.85, green: 0.40, blue: 0.85),
        Color(red: 1.00, green: 0.30, blue: 0.30),
    ]

    /// Saturation's gradient: neutral gray (matching `0`, fully desaturated)
    /// to a vivid, representative saturated color (matching `2`, boosted) —
    /// a static gray-to-one-color track rather than gray-to-whatever-Hue-
    /// is-currently-set-to, which would need this slider to react live to a
    /// different control's value for a benefit too subtle to be worth that
    /// coupling.
    private static let saturationGradient: [Color] = [
        Color(white: 0.55),
        Color(red: 0.95, green: 0.30, blue: 0.35),
    ]

    /// Purely a local UI concern — NOT part of `GradingUniforms`/
    /// `CineDocumentModel` at all, since which sliders the user currently
    /// sees is a display choice, not a grading parameter. When `true` (the
    /// default), the "Pedestal" section shows one slider whose value fans
    /// out to `pedestal`/`pedestalR`/`pedestalG`/`pedestalB` together (see
    /// `chainedPedestalBinding`); when `false`, it shows 4 independent
    /// sliders instead, each bound through `gradingBinding`.
    @State private var pedestalChained: Bool = true

    /// Whether each "Cine Colour" slider group is expanded — purely local UI
    /// state, same footing as `pedestalChained` above: collapsing a group
    /// hides its sliders from view, never changes any of their values.
    /// Independent per group (not one shared bool) so collapsing one, e.g.
    /// while dialing in white balance, doesn't hide the others. All default
    /// to expanded so the panel looks and behaves exactly as it did before
    /// this was added, until a user actually collapses something.
    @State private var isWhiteBalanceExpanded = true
    @State private var isGammaExpanded = true
    @State private var isExposureIndexExpanded = true
    @State private var isGainExpanded = true
    @State private var isToneCurveExpanded = true
    @State private var isPedestalExpanded = true
    @State private var isSaturationExpanded = true

    /// Debounces histogram recomputation: every trigger below cancels
    /// whatever's pending and schedules a fresh one after a short quiet
    /// period, so a rapid slider drag doesn't fire a full GPU render+
    /// readback+bin pass on every intermediate tick — only once dragging
    /// actually pauses. `recomputeHistogram()` itself is safe to call
    /// redundantly (it just republishes `currentHistogram`), so this exists
    /// purely to bound how often it runs, not for correctness.
    @State private var histogramRecomputeTask: Task<Void, Never>?

    private func scheduleHistogramRecompute() {
        histogramRecomputeTask?.cancel()
        histogramRecomputeTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await documentModel.recomputeHistogram()
        }
    }

    /// A single-line camera-info caption below the histogram — mirrors
    /// Adobe Camera Raw's own "ISO 500  85 mm  f/1.8  1/500s" row, using
    /// whatever of this file's fields are actually present (same optional-
    /// field omission convention `MetadataOverlayView` already uses, not a
    /// parallel one) rather than a fixed set every camera necessarily has.
    private var metadataCaption: String? {
        var parts: [String] = ["\(documentModel.frameWidth)\u{00D7}\(documentModel.frameHeight)"]
        if let fps = documentModel.captureFrameRate {
            parts.append("\(fps.formatted(.number.precision(.fractionLength(0)))) fps")
        }
        if let bitDepth = documentModel.sensorBitDepth {
            parts.append("\(bitDepth)-bit")
        }
        if let shutterNs = documentModel.shutterNs {
            let microseconds = Double(shutterNs) / 1000.0
            if microseconds >= 1000 {
                parts.append(String(format: "%.2f ms", microseconds / 1000.0))
            } else {
                parts.append(String(format: "%.1f \u{00b5}s", microseconds))
            }
        }
        return parts.joined(separator: "   ")
    }

    private var currentMode: DebayerMode {
        DebayerMode(rawValue: documentModel.uniforms.debayerMode) ?? .rawSensor
    }

    /// The color-matrix toggle only means anything for the 3 real demosaic
    /// modes — `.rawSensor`/`.greyScale` never read `colorMatrix`/`wbGain*`
    /// at all (see `Tonemap.metal`), so the control is disabled rather than
    /// left live-but-inert for those two modes.
    private var colorMatrixToggleRelevant: Bool {
        currentMode == .nearestNeighbor || currentMode == .bilinear || currentMode == .highQuality
    }

    /// Whether the current debayer mode's shader path ever reaches the
    /// "Cine Colour" grading code at all. `.rawSensor`/`.greyScale` both
    /// `return` from `tonemapFragment` before `stretched`/`encoded` are ever
    /// computed (see `Tonemap.metal`), so every grading slider is a genuine,
    /// unreachable no-op in those two modes — not merely imperceptible.
    /// Unlike `colorMatrixToggleRelevant`, the sliders themselves are left
    /// live (disabling 13 individual controls would be more disruptive than
    /// helpful for a section this size); only an informational caption is
    /// shown below, same idea as `colorMatrixHelpText`.
    private var gradingReachesCurrentMode: Bool {
        currentMode == .nearestNeighbor || currentMode == .bilinear || currentMode == .highQuality
    }

    /// The toggle's help text, with an extra sentence appended when
    /// `CalibrationPlausibility` (see `CineDocumentModel.colorCalibrationVetoed`'s
    /// doc comment) already overrode this file's own calibration to
    /// identity — purely informational, so a curious user who toggles this
    /// checkbox and sees no visible change for a specific file has somewhere
    /// to discover why. The toggle itself stays fully checkable/uncheckable
    /// either way; this never introduces a new disabled state.
    private var colorMatrixHelpText: String {
        let base = "Applies the camera's post-demosaic color-correction matrix. Turn off if colors look off "
            + "(white balance stays on either way) — the file's stored matrix is known to overshoot into a magenta cast on some files."
        guard documentModel.colorCalibrationVetoed else { return base }
        return base + " (currently overridden: this file's own calibration didn't look reliable on its first frame)"
    }

    /// Builds a `Binding` for a single `GradingUniforms` field without
    /// repeating the read-modify-write-through-`setGrading` boilerplate for
    /// each of the 13 individually-bindable numeric fields — every "Cine
    /// Colour" slider below goes through this (the one exception being
    /// "Pedestal" while chained, which needs to fan out to 4 fields at once
    /// and so uses its own `chainedPedestalBinding` instead).
    private func gradingBinding<T>(_ keyPath: WritableKeyPath<GradingUniforms, T>) -> Binding<T> {
        Binding(
            get: { documentModel.grading[keyPath: keyPath] },
            set: { newValue in
                var updated = documentModel.grading
                updated[keyPath: keyPath] = newValue
                documentModel.setGrading(updated)
            }
        )
    }

    /// The chained "Pedestal" slider's binding: reads `pedestal` (the 4
    /// fields are always kept equal while chained, so any one of them is
    /// representative) and, on write, sets `pedestal`/`pedestalR`/
    /// `pedestalG`/`pedestalB` all to the same new value in one
    /// `setGrading` call.
    private var chainedPedestalBinding: Binding<Float> {
        Binding(
            get: { documentModel.grading.pedestal },
            set: { newValue in
                var updated = documentModel.grading
                updated.pedestal = newValue
                updated.pedestalR = newValue
                updated.pedestalG = newValue
                updated.pedestalB = newValue
                documentModel.setGrading(updated)
            }
        )
    }

    /// `GradingUniforms.flipHorizontal` is a `UInt32` (0 or 1) on the wire —
    /// this maps it to/from the `Bool` a `Toggle` needs.
    private var flipHorizontalBinding: Binding<Bool> {
        Binding(
            get: { documentModel.grading.flipHorizontal != 0 },
            set: { newValue in
                var updated = documentModel.grading
                updated.flipHorizontal = newValue ? 1 : 0
                documentModel.setGrading(updated)
            }
        )
    }

    private var flipVerticalBinding: Binding<Bool> {
        Binding(
            get: { documentModel.grading.flipVertical != 0 },
            set: { newValue in
                var updated = documentModel.grading
                updated.flipVertical = newValue ? 1 : 0
                documentModel.setGrading(updated)
            }
        )
    }

    private var rotationQuarterTurnsBinding: Binding<UInt32> {
        Binding(
            get: { documentModel.grading.rotationQuarterTurns },
            set: { newValue in
                var updated = documentModel.grading
                updated.rotationQuarterTurns = newValue
                documentModel.setGrading(updated)
            }
        )
    }

    @ViewBuilder
    private var rotationSection: some View {
        HStack {
            Text("Rotate")
            Spacer()
            // .menu, not .segmented: four segments don't fit this sidebar's
            // width without wrapping.
            Picker("Rotate", selection: rotationQuarterTurnsBinding) {
                Text("0°").tag(UInt32(0))
                Text("90°").tag(UInt32(1))
                Text("180°").tag(UInt32(2))
                Text("270°").tag(UInt32(3))
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
        }
    }

    @ViewBuilder
    private var exposureIndexSection: some View {
        HStack {
            Text("Base EI")
            Spacer()
            Text("\(Int(CineDocumentModel.referenceExposureIndex)) ISO")
                .foregroundStyle(.secondary)
        }
        Menu("Selected EI: \(Int(documentModel.exposureIndex)) ISO") {
            ForEach(ExposureIndexPreset.allCases, id: \.self) { preset in
                Button(preset.displayName) {
                    documentModel.setExposureIndex(preset.ei)
                }
            }
        }
    }

    /// Thin compatibility wrapper so every existing call site below stays
    /// unchanged — actual rendering/state now lives in `GradingSliderRow`
    /// (needs real `@State` for click-to-type-a-value, which a plain
    /// `@ViewBuilder` function can't own).
    /// - Parameter description: `nil` (the default, every call site today)
    ///   for a control whose name is already self-explanatory (Brightness,
    ///   Gain, …); pass real text for a future control whose name alone
    ///   wouldn't be.
    /// - Parameter style: `.plain` (the default) for an ordinary accent-
    ///   colored `Slider`; `.solidTint`/`.gradient` swap in a colored track
    ///   — see `SliderColorStyle`'s own doc comment for when each applies.
    private func gradingSlider(_ label: String, value: Binding<Float>, in range: ClosedRange<Float>, defaultValue: Float, description: String? = nil, style: SliderColorStyle = .plain) -> some View {
        GradingSliderRow(label: label, value: value, range: range, defaultValue: defaultValue, description: description, style: style)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Histogram + camera info + Auto — deliberately OUTSIDE the
            // `ScrollView` below, always visible above every section,
            // mirroring Adobe Camera Raw's own layout: the histogram never
            // scrolls away regardless of how far down the slider list you
            // are.
            VStack(alignment: .leading, spacing: 6) {
                HistogramView(histogram: documentModel.currentHistogram)

                if let metadataCaption {
                    Text(metadataCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button("Auto") {
                    Task { await documentModel.applyAutoExposure() }
                }
                .help("Analyzes this frame and adjusts Brightness for a conventional, well-exposed tonal range.")
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            Text("Color Correction")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            ScrollView {
                // A plain `ScrollView { A; B; C }` stacks its direct
                // children with the *default* implicit VStack alignment
                // (center), not `.leading` — invisible for the Debayer/Cine
                // Colour sections below since their widest child is always
                // a full-width `Slider`, but it silently centered the
                // Save/Export sections (whose widest child is just a
                // button, narrower than the sidebar) as a block instead of
                // hugging the same left edge as everything else. This outer
                // `VStack(alignment: .leading)` makes every section's
                // alignment explicit instead of depending on that default.
                VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    // The `documentModel.colorCalibrationVetoed` warning
                    // banner that used to live here is temporarily removed
                    // while color-calibration work is still being tested/
                    // debugged — it was getting in the way, not that the
                    // underlying signal is wrong. `colorCalibrationVetoed`
                    // itself is untouched; reinstate this banner (or a
                    // calmer version of it, now that the fallback is a real
                    // calibration rather than `.identity`) once that
                    // settles.

                    Picker(
                        "Debayer",
                        selection: Binding(
                            get: { currentMode },
                            set: { documentModel.setDebayerMode($0) }
                        )
                    ) {
                        ForEach(DebayerMode.allCases, id: \.self) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)

                    Toggle(
                        "Color Matrix",
                        isOn: Binding(
                            get: { documentModel.colorMatrixEnabled },
                            set: { documentModel.setColorMatrixEnabled($0) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .disabled(!colorMatrixToggleRelevant)
                    .help(colorMatrixHelpText)

                    Toggle(
                        "LUT",
                        isOn: Binding(
                            get: { documentModel.lutEnabled },
                            set: { documentModel.setLUTEnabled($0) }
                        )
                    )
                    .toggleStyle(.checkbox)
                    .disabled(documentModel.currentLUTTexture == nil)
                    .help(documentModel.currentLUTTexture == nil
                          ? "Disabled: no .cube LUT is loaded yet. Use \u{201C}Load LUT\u{2026}\u{201D} below."
                          : "Applies the loaded 3D color LUT on top of the debayer/color-matrix pipeline above.")

                    Button(documentModel.currentLUTURL == nil ? "Load LUT\u{2026}" : "Change LUT\u{2026}") {
                        LUTLoadCoordinator.presentLoadPanel(documentModel: documentModel)
                    }

                    if let lutURL = documentModel.currentLUTURL {
                        Text(lutURL.lastPathComponent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !documentModel.recentLUTURLs.isEmpty {
                        Menu("Recent LUTs") {
                            ForEach(documentModel.recentLUTURLs, id: \.self) { url in
                                Button(url.lastPathComponent) {
                                    LUTLoadCoordinator.load(url, documentModel: documentModel)
                                }
                            }

                            Divider()
                            Button("Clear Recent LUTs") {
                                documentModel.clearRecentLUTs()
                            }
                        }
                    }
                }
                .padding(12)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Cine Colour")
                        .font(.headline)

                    if !gradingReachesCurrentMode {
                        Text("Has no effect in Raw Sensor / Grey Scale debayer modes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    // Ordered to follow Adobe Camera Raw's Basic panel where
                    // this app's own simpler linear-gain/pedestal/gamma-trim
                    // model has a reasonable analog: White Balance first
                    // (ACR always leads with Temperature/Tint), then overall
                    // level (Brightness ~ Exposure), midtone curve shaping
                    // (Gamma ~ Contrast), the multiplicative highlight-end
                    // control (Gain ~ Whites), the additive black-point
                    // control (Pedestal ~ Blacks — ACR's own Whites-then-
                    // Blacks adjacency), and finally Saturation/Hue, matching
                    // Vibrance/Saturation sitting at the very end of ACR's
                    // Basic panel. There's no ACR equivalent for per-channel
                    // R/G/B variants of any of these, so each family keeps
                    // its existing master-then-R/G/B grouping unchanged.
                    //
                    // Color Temp/WBCC are white-balance controls, not
                    // `GradingUniforms` fields — they bind to plain
                    // `CineDocumentModel` properties via a direct
                    // `Binding(get:set:)` rather than `gradingBinding`
                    // (which only works for `GradingUniforms` fields). See
                    // `CineDocumentModel.recomputeWhiteBalance()`.
                    //
                    // Each multi-control group below is a collapsible
                    // `DisclosureGroup` (all expanded by default) so a long
                    // "Cine Colour" panel can be collapsed down to just the
                    // groups currently being worked on — Brightness stays a
                    // plain slider outside any group since collapsing a
                    // single control buys nothing.
                    DisclosureGroup("White Balance", isExpanded: $isWhiteBalanceExpanded) {
                        Menu("White Balance Presets") {
                            ForEach(WhiteBalancePreset.allCases, id: \.self) { preset in
                                Button(preset.displayName) {
                                    documentModel.setColorTemp(preset.kelvin)
                                    documentModel.setWBCC(0)
                                }
                            }
                        }

                        gradingSlider("Color Temp", value: Binding(
                            get: { documentModel.colorTempKelvin },
                            set: { documentModel.setColorTemp($0) }
                        ), in: 2000...10000, defaultValue: 6500, style: .gradient(Self.colorTempGradient))

                        gradingSlider("Tint (WBCC)", value: Binding(
                            get: { documentModel.wbcc },
                            set: { documentModel.setWBCC($0) }
                        ), in: -50...50, defaultValue: 0, style: .gradient(Self.wbccGradient))
                    }

                    Divider()

                    gradingSlider(
                        "Brightness", value: gradingBinding(\.brightness),
                        in: -0.5...0.5, defaultValue: 0, style: .gradient(Self.grayscaleGradient)
                    )

                    Divider()

                    DisclosureGroup("Gamma", isExpanded: $isGammaExpanded) {
                        gradingSlider(
                            "Gamma", value: gradingBinding(\.gammaTrim),
                            in: 0.2...3.0, defaultValue: 1, style: .gradient(Self.grayscaleGradient)
                        )
                        gradingSlider(
                            "R Gamma", value: gradingBinding(\.gammaTrimR),
                            in: -1.0...1.0, defaultValue: 0, style: .solidTint(Self.channelRed)
                        )
                        gradingSlider(
                            "G Gamma", value: gradingBinding(\.gammaTrimG),
                            in: -1.0...1.0, defaultValue: 0, style: .solidTint(Self.channelGreen)
                        )
                        gradingSlider(
                            "B Gamma", value: gradingBinding(\.gammaTrimB),
                            in: -1.0...1.0, defaultValue: 0, style: .solidTint(Self.channelBlue)
                        )
                    }

                    Divider()

                    DisclosureGroup("Exposure Index", isExpanded: $isExposureIndexExpanded) {
                        exposureIndexSection
                    }

                    Divider()

                    DisclosureGroup("Gain", isExpanded: $isGainExpanded) {
                        gradingSlider("Gain", value: gradingBinding(\.gain), in: 0...4, defaultValue: 1, style: .gradient(Self.grayscaleGradient))
                        gradingSlider("R Gain", value: gradingBinding(\.gainR), in: 0...4, defaultValue: 1, style: .solidTint(Self.channelRed))
                        gradingSlider("G Gain", value: gradingBinding(\.gainG), in: 0...4, defaultValue: 1, style: .solidTint(Self.channelGreen))
                        gradingSlider("B Gain", value: gradingBinding(\.gainB), in: 0...4, defaultValue: 1, style: .solidTint(Self.channelBlue))
                    }

                    Divider()

                    DisclosureGroup("Pedestal", isExpanded: $isPedestalExpanded) {
                        Toggle("Chain Pedestal Sliders", isOn: $pedestalChained)
                            .toggleStyle(.checkbox)

                        if pedestalChained {
                            gradingSlider("Pedestal", value: chainedPedestalBinding, in: -0.5...0.5, defaultValue: 0)
                        } else {
                            gradingSlider("Pedestal", value: gradingBinding(\.pedestal), in: -0.5...0.5, defaultValue: 0)
                            gradingSlider(
                                "R Pedestal", value: gradingBinding(\.pedestalR),
                                in: -0.5...0.5, defaultValue: 0, style: .solidTint(Self.channelRed)
                            )
                            gradingSlider(
                                "G Pedestal", value: gradingBinding(\.pedestalG),
                                in: -0.5...0.5, defaultValue: 0, style: .solidTint(Self.channelGreen)
                            )
                            gradingSlider(
                                "B Pedestal", value: gradingBinding(\.pedestalB),
                                in: -0.5...0.5, defaultValue: 0, style: .solidTint(Self.channelBlue)
                            )
                        }
                    }

                    Divider()

                    DisclosureGroup("Saturation & Hue", isExpanded: $isSaturationExpanded) {
                        gradingSlider(
                            "Saturation", value: gradingBinding(\.saturation),
                            in: 0...2, defaultValue: 1, style: .gradient(Self.saturationGradient)
                        )
                        gradingSlider("Hue", value: gradingBinding(\.hue), in: -180...180, defaultValue: 0, style: .gradient(Self.hueGradient))
                    }

                    Divider()

                    DisclosureGroup("Tone Curve", isExpanded: $isToneCurveExpanded) {
                        ToneCurveEditorView(documentModel: documentModel)
                    }

                    Divider()

                    Toggle("Flip Horizontal", isOn: flipHorizontalBinding)
                        .toggleStyle(.checkbox)
                    Toggle("Flip Vertical", isOn: flipVerticalBinding)
                        .toggleStyle(.checkbox)
                    rotationSection

                    Button("Reset to Defaults") {
                        documentModel.setGrading(.identity)
                        documentModel.setColorTemp(6500)
                        documentModel.setWBCC(0)
                        documentModel.setExposureIndex(CineDocumentModel.referenceExposureIndex)
                        documentModel.resetToneCurves()
                    }
                }
                .padding(12)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Save")
                        .font(.headline)

                    Button("Save As (.cine)\u{2026}") {
                        SaveAsCoordinator.saveAs(documentModel: documentModel)
                    }
                }
                .padding(12)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Export")
                        .font(.headline)

                    Button("Export Video\u{2026}") {
                        VideoExportCoordinator.exportVideo(documentModel: documentModel)
                    }

                    Button("Current Frame as Still\u{2026}") {
                        Task {
                            await StillExportCoordinator.exportCurrentFrame(documentModel: documentModel)
                        }
                    }
                }
                .padding(12)
                }
            }
        }
        .frame(width: 240)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
        // Every trigger the displayed picture can actually change through —
        // scrubbing/playback, any grading slider, Color Temp/Tint, debayer
        // mode, Color Matrix, LUT on/off — reschedules a debounced
        // histogram recompute (see `scheduleHistogramRecompute()`). `.task`
        // fires the first computation as soon as this sidebar appears,
        // without waiting for something to change first.
        .onChange(of: playbackController.currentFrameIndex) { _, _ in scheduleHistogramRecompute() }
        .onChange(of: documentModel.grading) { _, _ in scheduleHistogramRecompute() }
        .onChange(of: documentModel.toneCurves) { _, _ in scheduleHistogramRecompute() }
        .onChange(of: documentModel.colorTempKelvin) { _, _ in scheduleHistogramRecompute() }
        .onChange(of: documentModel.wbcc) { _, _ in scheduleHistogramRecompute() }
        .onChange(of: documentModel.uniforms.debayerMode) { _, _ in scheduleHistogramRecompute() }
        .onChange(of: documentModel.colorMatrixEnabled) { _, _ in scheduleHistogramRecompute() }
        .onChange(of: documentModel.lutEnabled) { _, _ in scheduleHistogramRecompute() }
        .task { scheduleHistogramRecompute() }
    }
}
