import SwiftUI
import CinePlayerCore

/// Draws `histogram` as three overlaid, additively-blended color fills —
/// the same look Adobe Camera Raw's own histogram uses. Purely a display of
/// already-computed data; recomputing it (`CineDocumentModel.recomputeHistogram()`)
/// is `InspectorSidebarView`'s job, triggered by frame/grading changes, not
/// this view's — keeps this view a plain, cheap-to-redraw function of
/// whatever histogram it's handed.
struct HistogramView: View {
    let histogram: FrameHistogram?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let histogram {
                    channelPath(histogram.red, in: geometry.size)
                        .fill(Color.red.opacity(0.6))
                    channelPath(histogram.green, in: geometry.size)
                        .fill(Color.green.opacity(0.6))
                    channelPath(histogram.blue, in: geometry.size)
                        .fill(Color.blue.opacity(0.6))
                }
            }
            .blendMode(.plusLighter)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Color.black.opacity(0.25))
        }
        .frame(height: 60)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5)
        )
    }

    /// A filled area path for one channel's 256 bins, height-compressed by
    /// square root rather than linearly — a real histogram's raw counts are
    /// extremely peaky (a large flat sky or shadow region can dwarf
    /// everything else at linear scale), and sqrt-compression is the
    /// standard way photo/video histogram UIs, ACR included, keep shadow/
    /// highlight detail visible instead of one spike flattening the rest.
    private func channelPath(_ bins: [Int], in size: CGSize) -> Path {
        let maxCount: Double = bins.max().map(Double.init) ?? 0
        guard maxCount > 0 else { return Path() }
        let maxHeight = sqrt(maxCount)
        let binWidth = size.width / CGFloat(FrameHistogram.binCount)

        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))
        for (index, count) in bins.enumerated() {
            let normalizedHeight = sqrt(Double(count)) / maxHeight
            let x = CGFloat(index) * binWidth
            let y = size.height - CGFloat(normalizedHeight) * size.height
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        return path
    }
}
