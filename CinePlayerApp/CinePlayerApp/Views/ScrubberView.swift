import SwiftUI
import CinePlayerCore

/// The scrubber: a two-tone range bar for setting an export in/out
/// selection, plus three trigger-relative frame-number readouts below it.
///
/// **Color mapping — blue = inside `[inPoint, outPoint]`, maroon = outside
/// it.** The reference tool's screenshots show a blue segment and a
/// maroon/dark-red segment sharing one bar, with solid yellow caps fixed at
/// the two extreme ends. Two mappings are equally plausible from static
/// images alone ("blue is the selection" vs. "maroon is the selection");
/// this file commits to blue-is-selected for two reasons:
///   1. Blue is already this app's accent/selection color everywhere else
///      (`PlaybackToolbar`'s active-rate transport buttons highlight in
///      `Color.accentColor`, which resolves to blue under the default
///      system accent) — reusing it for "the range currently selected"
///      keeps one consistent color meaning app-wide, whereas maroon appears
///      nowhere else in this app's UI and reads as a neutral/inert color,
///      well suited to "not part of what's selected".
///   2. In non-linear editors generally, the segment between in/out handles
///      is conventionally the brighter/cooler color (drawing the eye to
///      what will actually be exported), while the discarded head/tail
///      reads as the duller, warmer color — maroon is visually duller than
///      a saturated blue, fitting "trimmed away" better than the reverse.
///
/// The yellow end-caps are fixed at the bar's two physical edges (frame `0`
/// and `frameCount - 1`) regardless of where the in/out handles sit — they
/// mark the absolute extent of the whole clip, never the current selection,
/// and are purely decorative (never draggable).
///
/// **Range and playback are coupled, via `PlaybackController` itself:** the
/// two handle drags call only `setInPoint`/`setOutPoint` (and the reset
/// button only `resetRange()`) — this view never calls `play`/`pause`
/// directly — but those two setters now also seek the playhead to the point
/// being set, and the play loop stops at/resumes from whichever bound is
/// currently set. See `PlaybackController.inPoint`'s own doc comment for the
/// full behavior. A plain drag/click on the track background (preserving
/// this view's pre-existing behavior) calls `seek(to:)`, exactly like the
/// old full-range `Slider` it replaces.
struct ScrubberView: View {
    @ObservedObject var documentModel: CineDocumentModel
    @ObservedObject var playbackController: PlaybackController

    /// Not `.red` — a distinctly dark, desaturated maroon so it reads as
    /// "outside the selection" rather than as an alarm/error color.
    private static let maroon = Color(red: 0.45, green: 0.07, blue: 0.09)

    private static let trackHeight: CGFloat = 14
    private static let capWidth: CGFloat = 5
    private static let handleWidth: CGFloat = 9
    private static let handleHeight: CGFloat = 22
    private static let playheadWidth: CGFloat = 2
    private static let coordinateSpaceName = "ScrubberView.bar"

    private var maxIndex: Int { max(0, playbackController.frameCount - 1) }
    private var inFrame: Int { playbackController.effectiveInPoint }
    private var outFrame: Int { playbackController.effectiveOutPoint }
    private var isRangeSet: Bool { playbackController.inPoint != nil || playbackController.outPoint != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                rangeBar
                    .frame(maxWidth: .infinity, minHeight: Self.handleHeight, maxHeight: Self.handleHeight)

                Button("Reset Range") {
                    playbackController.resetRange()
                }
                .font(.caption)
                .disabled(!isRangeSet)
                .help("Clears the in/out selection back to the full clip and lets playback run to the true clip boundaries again.")
            }

            readouts
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .opacity(playbackController.frameCount <= 1 ? 0.4 : 1)
        .disabled(playbackController.frameCount <= 1)
    }

    // MARK: - Range bar

    private var rangeBar: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                // Track background: also owns the plain drag-to-seek
                // gesture, exactly like the old full-range `Slider` did —
                // dragging anywhere on the bar that isn't one of the two
                // handles below still just seeks playback.
                RoundedRectangle(cornerRadius: Self.trackHeight / 2)
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: Self.trackHeight)
                    .contentShape(Rectangle())
                    .gesture(seekDrag(width: width))

                // Two-tone selection fill, clipped to the same rounded
                // shape as the track. Visual only (`allowsHitTesting(false)`)
                // so drags fall through to the track gesture above, or get
                // captured by a handle on top when one sits there instead.
                twoTone(width: width)
                    .clipShape(RoundedRectangle(cornerRadius: Self.trackHeight / 2))
                    .allowsHitTesting(false)

                // Draggable in/out handles. Each still captures its own
                // drag correctly despite `endCaps`/`playhead` being drawn
                // on top of them visually (below): a view with
                // `allowsHitTesting(false)` lets a touch fall straight
                // through to whatever's beneath it, so layering order here
                // only affects which pixels win on screen, never which
                // view's gesture actually fires.
                handle(atFrame: inFrame, width: width, help: "Drag to set the in point")
                    .gesture(handleDrag(width: width, onChange: playbackController.setInPoint))

                handle(atFrame: outFrame, width: width, help: "Drag to set the out point")
                    .gesture(handleDrag(width: width, onChange: playbackController.setOutPoint))

                // Yellow end-caps are drawn *after* (visually on top of) the
                // handles, deliberately: in the default full-range state the
                // in/out handles sit exactly at the bar's two extremes, i.e.
                // physically on top of the end-caps — drawing the caps first
                // would leave them permanently hidden under a handle in
                // exactly the state real screenshots show them in. Drawing
                // them last instead means the absolute-extent markers always
                // show, and a handle only becomes visually distinct from its
                // cap once it's been dragged away from that edge.
                endCaps(width: width)
                    .allowsHitTesting(false)

                // Playhead drawn topmost of all: the current-position
                // marker should never be hidden, even on the rare frame
                // where it coincides with an end-cap or a handle.
                playhead(width: width)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: Self.coordinateSpaceName)
    }

    @ViewBuilder
    private func twoTone(width: CGFloat) -> some View {
        let xIn = xPosition(forFrame: inFrame, width: width)
        let xOut = xPosition(forFrame: outFrame, width: width)
        HStack(spacing: 0) {
            Rectangle().fill(Self.maroon).frame(width: max(0, xIn))
            Rectangle().fill(Color.blue).frame(width: max(0, xOut - xIn))
            Rectangle().fill(Self.maroon).frame(width: max(0, width - xOut))
        }
        .frame(width: max(0, width), height: Self.trackHeight)
    }

    @ViewBuilder
    private func endCaps(width: CGFloat) -> some View {
        HStack {
            Rectangle().fill(Color.yellow).frame(width: Self.capWidth, height: Self.trackHeight)
            Spacer(minLength: 0)
            Rectangle().fill(Color.yellow).frame(width: Self.capWidth, height: Self.trackHeight)
        }
        .frame(width: max(0, width))
    }

    /// The current playhead — moves independently of the in/out selection
    /// (i.e. independently of the blue/maroon boundary): this always tracks
    /// `currentFrameIndex`, never `inPoint`/`outPoint`.
    private func playhead(width: CGFloat) -> some View {
        let xPos = xPosition(forFrame: playbackController.currentFrameIndex, width: width)
        return Rectangle()
            .fill(Color.white)
            .frame(width: Self.playheadWidth, height: Self.handleHeight)
            .shadow(color: .black.opacity(0.5), radius: 1)
            .offset(x: xPos - Self.playheadWidth / 2)
    }

    private func handle(atFrame frame: Int, width: CGFloat, help: String) -> some View {
        let xPos = xPosition(forFrame: frame, width: width)
        return RoundedRectangle(cornerRadius: 2)
            .fill(Color.primary)
            .frame(width: Self.handleWidth, height: Self.handleHeight)
            .shadow(color: .black.opacity(0.4), radius: 1)
            .contentShape(Rectangle())
            .offset(x: xPos - Self.handleWidth / 2)
            .help(help)
    }

    // MARK: - Geometry helpers

    private func xPosition(forFrame frame: Int, width: CGFloat) -> CGFloat {
        guard maxIndex > 0 else { return 0 }
        return CGFloat(frame) / CGFloat(maxIndex) * width
    }

    private func frameIndex(atX x: CGFloat, width: CGFloat) -> Int {
        guard width > 0, maxIndex > 0 else { return 0 }
        let clampedFraction = min(max(0, x / width), 1)
        return Int((clampedFraction * CGFloat(maxIndex)).rounded())
    }

    // MARK: - Gestures

    private func seekDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                playbackController.seek(to: frameIndex(atX: value.location.x, width: width))
            }
    }

    private func handleDrag(width: CGFloat, onChange: @escaping (Int) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
            .onChanged { value in
                onChange(frameIndex(atX: value.location.x, width: width))
            }
    }

    // MARK: - Frame-number readouts

    /// Left/center/right readouts below the bar: left is the clip's very
    /// first frame, right is its very last frame, center is wherever the
    /// playhead currently is — all three independent of any in/out
    /// selection. Each is formatted via the shared, persisted
    /// `documentModel.frameNumberingMode` preference
    /// (`FrameNumberingMode.formattedFrameNumber`), so these stay
    /// consistent with whatever convention `PlaybackToolbar`'s counter and
    /// the on-video HUD are also showing — plain 1-based, SMPTE timecode,
    /// or trigger-relative (`firstImageNo`-offset, frequently negative on
    /// real files since Vision Research numbers frames relative to the
    /// camera's trigger point, comma-grouped via `Int.formatted()`, e.g.
    /// "-3,927").
    private var readouts: some View {
        HStack {
            Text(FrameNumberingMode.formattedFrameNumber(
                0, mode: documentModel.frameNumberingMode,
                frameCount: playbackController.frameCount,
                reviewFPS: playbackController.reviewFPS,
                firstImageNo: playbackController.firstImageNo
            ))
            Spacer()
            Text(FrameNumberingMode.formattedFrameNumber(
                playbackController.currentFrameIndex, mode: documentModel.frameNumberingMode,
                frameCount: playbackController.frameCount,
                reviewFPS: playbackController.reviewFPS,
                firstImageNo: playbackController.firstImageNo
            ))
            Spacer()
            Text(FrameNumberingMode.formattedFrameNumber(
                maxIndex, mode: documentModel.frameNumberingMode,
                frameCount: playbackController.frameCount,
                reviewFPS: playbackController.reviewFPS,
                firstImageNo: playbackController.firstImageNo
            ))
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(.secondary)
    }
}
