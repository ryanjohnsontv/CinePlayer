import AppKit
import UniformTypeIdentifiers
import CinePlayerCore

enum SaveAsError: Error, CustomStringConvertible {
    case noOpenDocument

    var description: String {
        switch self {
        case .noOpenDocument:
            return "No file is open."
        }
    }
}

/// "File > Save As…": writes the currently-open file's effective in/out
/// range back out as a brand-new `.cine` file, always via an `NSSavePanel` —
/// this always prompts for a new location and never overwrites
/// `currentURL` itself. A plain in-place "Save" command *does* now exist
/// (`SaveCoordinator`, ⌘S) — see that type's own doc comment for why a
/// narrower, confirmation-gated overwrite path is safe to layer on top of
/// the two concerns below, rather than a rollback of them:
///
///   - There's no non-destructive per-file metadata to round-trip yet.
///     Debayer mode/Color Matrix are app-wide `UserDefaults` preferences,
///     not per-file SETUP edits written back to disk, so there's nothing
///     file-specific for an in-place save to actually persist.
///   - In/out-point trimming is not purely metadata — it discards real frame
///     data outside the selected range. That must never be something a
///     single keystroke can do to the user's original camera-master file
///     with no new destination — and no confirmation — in the way.
///
/// So "Save As…" itself always prompts for a new location, exactly like
/// "Export Frame Range…"'s old trimmed-`.cine` choice used to (that choice
/// moved here verbatim — including its default-filename logic — since it
/// was never really a format conversion; see `RangeExportFormat`'s doc
/// comment). The written range is always
/// `effectiveInPoint...effectiveOutPoint`, which is simply the whole file
/// when the user never set an explicit in/out point — no special-casing
/// needed for "no trim active".
@MainActor
enum SaveAsCoordinator {
    static func saveAs(documentModel: CineDocumentModel) {
        guard let controller = documentModel.playbackController else {
            presentErrorAlert(SaveAsError.noOpenDocument)
            return
        }

        // Matches `FrameExporter`/`RangeExporter`'s established rationale: a
        // stable range is wanted, not a save racing an advancing playhead.
        controller.pause()

        let range = controller.effectiveInPoint...controller.effectiveOutPoint

        guard let url = presentSaveCinePanel(documentModel: documentModel, controller: controller, range: range) else {
            return
        }

        do {
            try documentModel.writeTrimmedRange(range, to: url)
        } catch {
            presentErrorAlert(error)
        }
    }

    /// `NSSavePanel` defaulting to `"<clip>.cine"` when `range` covers the
    /// whole file (no trim active), or `"<clip>_frames<in>-<out>.cine"`
    /// (1-based) otherwise — the exact naming logic that used to live in
    /// `RangeExporter.presentSaveCinePanel`. Returns `nil` (no error) if the
    /// user cancels.
    private static func presentSaveCinePanel(
        documentModel: CineDocumentModel,
        controller: PlaybackController,
        range: ClosedRange<Int>
    ) -> URL? {
        let panel = NSSavePanel()
        if let cineType = UTType(filenameExtension: "cine") {
            panel.allowedContentTypes = [cineType]
        }
        panel.canCreateDirectories = true

        let clipName = documentModel.currentURL?.deletingPathExtension().lastPathComponent ?? "clip"
        if range == 0...(controller.frameCount - 1) {
            panel.nameFieldStringValue = "\(clipName).cine"
        } else {
            panel.nameFieldStringValue = "\(clipName)_frames\(range.lowerBound + 1)-\(range.upperBound + 1).cine"
        }

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    private static func presentErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Failed to save file"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.runModal()
    }
}
