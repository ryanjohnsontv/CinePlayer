import SwiftUI
import CinePlayerCore

/// Draggable Master/Red/Green/Blue tone curve editor. All four curves are
/// drawn overlaid; only `selectedChannel`'s is editable.
struct ToneCurveEditorView: View {
    @ObservedObject var documentModel: CineDocumentModel

    @State private var selectedChannel: ToneCurveChannel = .master

    private static let size: CGFloat = 220
    private static let handleRadius: CGFloat = 5
    private static let displaySampleCount = 64
    private static let coordinateSpaceName = "toneCurveGraph"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Channel", selection: $selectedChannel) {
                ForEach(ToneCurveChannel.allCases, id: \.self) { channel in
                    Text(channel.displayName).tag(channel)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ZStack {
                curveBackground
                curveOverlay
                ForEach(Array(selectedCurve.points.enumerated()), id: \.offset) { index, point in
                    handle(at: point, index: index)
                }
            }
            .frame(width: Self.size, height: Self.size)
            .contentShape(Rectangle())
            .coordinateSpace(.named(Self.coordinateSpaceName))
            .gesture(
                SpatialTapGesture(count: 2)
                    .onEnded { value in
                        let normalized = normalizedPoint(from: value.location)
                        documentModel.setToneCurve(
                            selectedCurve.addingPoint(x: Float(normalized.x), y: Float(normalized.y)),
                            channel: selectedChannel
                        )
                    }
            )

            HStack {
                Text("Double-click to add a point, an existing point to remove it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset \(selectedChannel.displayName) Curve") {
                    documentModel.setToneCurve(.identity, channel: selectedChannel)
                }
                .disabled(selectedCurve == .identity)
            }
        }
    }

    private var selectedCurve: ToneCurve {
        documentModel.toneCurves[selectedChannel]
    }

    private func color(for channel: ToneCurveChannel) -> Color {
        switch channel {
        case .master: return .white
        case .red: return .red
        case .green: return .green
        case .blue: return .blue
        }
    }

    private var curveBackground: some View {
        Canvas { context, size in
            let gridColor = Color.primary.opacity(0.08)
            let divisions = 4
            for i in 0...divisions {
                let fraction = CGFloat(i) / CGFloat(divisions)
                let x = fraction * size.width
                let y = fraction * size.height
                context.stroke(
                    Path { path in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                    },
                    with: .color(gridColor)
                )
                context.stroke(
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                    },
                    with: .color(gridColor)
                )
            }
            context.stroke(
                Path { path in
                    path.move(to: CGPoint(x: 0, y: size.height))
                    path.addLine(to: CGPoint(x: size.width, y: 0))
                },
                with: .color(Color.primary.opacity(0.15)),
                style: StrokeStyle(lineWidth: 1, dash: [3, 3])
            )
            context.stroke(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(Color.primary.opacity(0.2))
            )
        }
    }

    private var curveOverlay: some View {
        Canvas { context, size in
            for channel in ToneCurveChannel.allCases where channel != selectedChannel {
                Self.strokeCurve(
                    documentModel.toneCurves[channel],
                    color: color(for: channel).opacity(0.35),
                    lineWidth: 1,
                    in: context,
                    size: size
                )
            }
            Self.strokeCurve(
                selectedCurve,
                color: color(for: selectedChannel),
                lineWidth: 1.5,
                in: context,
                size: size
            )
        }
    }

    private static func strokeCurve(_ curve: ToneCurve, color: Color, lineWidth: CGFloat, in context: GraphicsContext, size: CGSize) {
        let samples: [Float] = curve.sampled(count: displaySampleCount)
        var path = Path()
        for (i, level) in samples.enumerated() {
            let x = CGFloat(i) / CGFloat(displaySampleCount - 1) * size.width
            let y = (1 - CGFloat(level)) * size.height
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        context.stroke(path, with: .color(color), lineWidth: lineWidth)
    }

    private func handle(at point: ToneCurve.Point, index: Int) -> some View {
        let viewPoint = viewPoint(from: point)
        return Circle()
            .fill(color(for: selectedChannel))
            .frame(width: Self.handleRadius * 2, height: Self.handleRadius * 2)
            .shadow(radius: 1)
            .position(viewPoint)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.coordinateSpaceName))
                    .onChanged { value in
                        let normalized = normalizedPoint(from: value.location)
                        documentModel.setToneCurve(
                            selectedCurve.moving(pointAt: index, toX: Float(normalized.x), y: Float(normalized.y)),
                            channel: selectedChannel
                        )
                    }
            )
            .simultaneousGesture(
                SpatialTapGesture(count: 2).onEnded { _ in
                    documentModel.setToneCurve(selectedCurve.removing(pointAt: index), channel: selectedChannel)
                }
            )
    }

    private func viewPoint(from point: ToneCurve.Point) -> CGPoint {
        CGPoint(x: CGFloat(point.x) * Self.size, y: (1 - CGFloat(point.y)) * Self.size)
    }

    private func normalizedPoint(from location: CGPoint) -> CGPoint {
        let x = min(max(location.x / Self.size, 0), 1)
        let y = min(max(1 - location.y / Self.size, 0), 1)
        return CGPoint(x: x, y: y)
    }
}
