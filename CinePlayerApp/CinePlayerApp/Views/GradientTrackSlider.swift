import SwiftUI

/// A slider whose track is filled with a color gradient instead of the
/// plain accent-colored fill a native `Slider` draws — the visual language
/// Adobe Camera Raw/Lightroom uses for their Temperature/Tint sliders,
/// where the track itself shows what each end of the dial actually does to
/// the image rather than just "how far dragged." No native SwiftUI
/// `Slider` API exposes a custom track fill, so this is a small
/// from-scratch control rather than a `Slider` modifier — deliberately
/// minimal (a single `DragGesture(minimumDistance: 0)` mapping x-position
/// straight to `range`, no keyboard/accessibility actions `Slider` gets for
/// free) since it only needs to serve the two bipolar white-balance
/// sliders `InspectorSidebarView` uses it for, not stand in as a general
/// slider replacement.
struct GradientTrackSlider: View {
    @Binding var value: Float
    let range: ClosedRange<Float>
    let gradientColors: [Color]

    private let trackHeight: CGFloat = 4
    private let thumbDiameter: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
            let thumbX = thumbDiameter / 2 + fraction * (width - thumbDiameter)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: trackHeight / 2)
                    .fill(LinearGradient(colors: gradientColors, startPoint: .leading, endPoint: .trailing))
                    .frame(height: trackHeight)
                    // A thin dark outline keeps the track legible against
                    // the sidebar's own `.regularMaterial` background —
                    // without it, the lighter end of a gradient (e.g. the
                    // yellow end of Color Temp) can wash out against a
                    // light-appearance material.
                    .overlay(
                        RoundedRectangle(cornerRadius: trackHeight / 2)
                            .strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5)
                    )

                Circle()
                    .fill(Color.white)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5))
                    .position(x: thumbX, y: geometry.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let clampedX = min(max(drag.location.x, thumbDiameter / 2), width - thumbDiameter / 2)
                        let newFraction = Double((clampedX - thumbDiameter / 2) / (width - thumbDiameter))
                        value = Float(Double(range.lowerBound) + newFraction * Double(range.upperBound - range.lowerBound))
                    }
            )
        }
        .frame(height: thumbDiameter)
    }
}
