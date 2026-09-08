import SwiftUI
import CinePlayerCore

/// Shown via `.sheet(isPresented:)` in `ContentView` whenever
/// `documentModel.activeExportProgress` is non-`nil` — currently only
/// `VideoExportCoordinator.exportVideo`'s encode, but written generically
/// (`MediaExportProgress` isn't video-specific) in case a future exporter
/// reuses it.
///
/// Just two states, not three: `RangeExportSheet` (this sheet's
/// predecessor) needed a `.pickingFormat` phase because it presented its
/// own format picker before anything started running. This sheet never
/// does — codec/resolution/frame rate/destination are all chosen in the
/// `NSSavePanel` accessory view *before* `documentModel.
/// activeExportProgress` is ever set, so by the time this sheet can
/// possibly appear, `progress.isExporting` is already `true`. It only ever
/// needs to distinguish "still running" from "done."
struct ExportProgressSheet: View {
    @ObservedObject var progress: MediaExportProgress
    @ObservedObject var documentModel: CineDocumentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if progress.isExporting {
                Text("Exporting\u{2026}")
                    .font(.headline)
                ProgressView(
                    "Frame \(progress.currentFrame) of \(progress.totalFrames)",
                    value: Double(progress.currentFrame),
                    total: Double(max(1, progress.totalFrames))
                )
                .progressViewStyle(.linear)

                HStack {
                    Spacer()
                    Button("Cancel") {
                        progress.cancel()
                    }
                }
            } else {
                Text("Export Finished")
                    .font(.headline)

                HStack {
                    Spacer()
                    Button("Done") {
                        documentModel.dismissExportProgress()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        // Same reasoning as `RangeExportSheet`'s identical guards: cancel
        // any still-running export if the sheet somehow disappears mid-run,
        // and don't let an incidental Escape-key/outside-click dismissal
        // bypass that — the "Cancel" button above is the correct way to
        // stop an export.
        .onDisappear {
            if progress.isExporting {
                progress.cancel()
            }
        }
        .interactiveDismissDisabled(progress.isExporting)
    }
}
