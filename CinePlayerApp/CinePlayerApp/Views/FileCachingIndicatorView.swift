import SwiftUI
import CinePlayerCore

/// Small on-video HUD chip shown while `documentModel.isPrimingFileCache` is
/// true (see that property's own doc comment on `CineDocumentModel`) — the
/// background `primeFileCache(at:)` warm this reflects runs regardless of
/// whether this view exists; the point of this view is purely so a user who
/// opens a large file on slow (e.g. external/network) storage and hits play
/// right away sees "loading," not "the app is broken." Placed top-trailing,
/// deliberately the opposite corner from `MetadataOverlayView`'s top-leading
/// panel, so the two can never overlap regardless of which are visible at
/// once — this one isn't gated by `showMetadataOverlay` at all, since it's an
/// unrelated, always-relevant status rather than optional metadata chrome.
struct FileCachingIndicatorView: View {
    @ObservedObject var documentModel: CineDocumentModel

    var body: some View {
        Group {
            if documentModel.isPrimingFileCache {
                chip
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .padding(12)
        // Purely informational chrome floating over the video — never the
        // target of clicks/drags meant for whatever sits underneath it, same
        // as `MetadataOverlayView`.
        .allowsHitTesting(false)
        .animation(.easeInOut(duration: 0.25), value: documentModel.isPrimingFileCache)
    }

    private var chip: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)
            Text("Loading file\u{2026}")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.85), radius: 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // Same semi-opaque backing as `MetadataOverlayView`'s panel, for a
        // consistent HUD look between the two.
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
}
