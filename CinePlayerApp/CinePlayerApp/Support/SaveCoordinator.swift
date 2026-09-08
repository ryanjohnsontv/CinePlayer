import AppKit
import CinePlayerCore

/// "File > Save": persists whatever's changed about the currently-open file,
/// unlike "Save As…" (`SaveAsCoordinator`), which always prompts for a
/// brand-new location. What "Save" actually touches on disk depends entirely
/// on whether a trim is active — these are two genuinely different
/// operations, not one path with a shortcut:
///
///   - When no trim is active (the effective in/out range already covers the
///     whole file), Save does nothing at all: the raw `.cine` file's content
///     wouldn't change, so rewriting it would just be a pointless,
///     potentially multi-gigabyte no-op, and the Cine Colour grade is
///     deliberately never persisted anywhere (no sidecar, nothing written
///     into the `.cine` file itself — see `CineDocumentModel.open(url:)`'s
///     doc comment) — its only lasting effect is whatever gets baked into a
///     still/video export while it's dialed in.
///   - When a trim IS active, this is exactly the destructive case
///     `SaveAsCoordinator`'s own doc comment warns an in-place save would be
///     in general — real frame data outside the selected range would be
///     permanently discarded from the user's own file, with no new
///     destination standing between them and that loss. So this path is
///     gated behind an explicit confirmation alert naming exactly how many
///     frames would be discarded, with "Cancel" as the safe, Return-
///     triggered default and a destructively styled "Overwrite" as the only
///     way past it — and only THIS path ever calls
///     `CineDocumentModel.overwriteCurrentFile(range:)`.
///
/// The actual mmap-safety mechanics of writing over a file that may still
/// have a live decoded frame mapped from it are `overwriteCurrentFile`'s own
/// concern, not this coordinator's — see that method's doc comment for why a
/// temp-file-then-atomic-rename swap is required rather than writing
/// directly over `currentURL`, and why it's only ever reached for a genuine
/// trim.
@MainActor
enum SaveCoordinator {
    static func save(documentModel: CineDocumentModel) {
        guard let controller = documentModel.playbackController else {
            presentErrorAlert(SaveAsError.noOpenDocument)
            return
        }

        // Matches `SaveAsCoordinator.saveAs`'s own reasoning: a stable range
        // is wanted, not a save racing an advancing playhead.
        controller.pause()

        let range = controller.effectiveInPoint...controller.effectiveOutPoint
        let wholeFile = range == 0...(controller.frameCount - 1)

        guard !wholeFile else {
            // No trim active: nothing about the raw file's content needs to
            // change at all, so this never touches it — not even via the
            // mmap-safe temp-file-then-atomic-replace path
            // `overwriteCurrentFile` uses for a real trim. That path would be
            // correct here too (a no-op rewrite of identical bytes), but it
            // would pointlessly rewrite a potentially multi-gigabyte camera
            // file to disk for zero actual content change. There's nothing
            // else for Save to do in this case — the grade is never
            // persisted (see this file's own doc comment) — so this is a
            // silent no-op.
            return
        }

        guard let alertResponse = presentTrimConfirmationAlert(
            documentModel: documentModel,
            controller: controller,
            range: range
        ) else {
            return
        }

        guard alertResponse == .alertSecondButtonReturn else { return }

        performOverwrite(documentModel: documentModel, range: range)
    }

    /// Confirmation alert for the "a trim is active" case — names the file
    /// being overwritten, exactly how many frames would be permanently
    /// discarded, and which frames (1-based) are being kept, matching
    /// `SaveAsCoordinator.presentSaveCinePanel`'s own 1-based
    /// `"_frames\(range.lowerBound + 1)-\(range.upperBound + 1)"` naming
    /// convention so the two dialogs describe ranges consistently. "Cancel"
    /// is added first — the safe, Return-triggered default — with
    /// "Overwrite" second and styled as a destructive action, so a stray
    /// Return keystroke can never itself discard frames.
    private static func presentTrimConfirmationAlert(
        documentModel: CineDocumentModel,
        controller: PlaybackController,
        range: ClosedRange<Int>
    ) -> NSApplication.ModalResponse? {
        let fileName = documentModel.currentURL?.lastPathComponent ?? "this file"
        let discardedCount = controller.frameCount - range.count

        let alert = NSAlert()
        alert.messageText = "Overwrite \u{201C}\(fileName)\u{201D}?"
        alert.informativeText = "This will permanently discard \(discardedCount) frame\(discardedCount == 1 ? "" : "s") outside the current in/out range, keeping only frames \(range.lowerBound + 1)\u{2013}\(range.upperBound + 1). This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        // `NSButton.hasDestructiveAction` (macOS 11+) — comfortably available
        // at this project's macOS 26 deployment target (see
        // `CinePlayerCore/Package.swift`'s `platforms` and the app target's
        // `MACOSX_DEPLOYMENT_TARGET`), so no plain-button fallback is needed.
        let overwriteButton = alert.addButton(withTitle: "Overwrite")
        overwriteButton.hasDestructiveAction = true

        return alert.runModal()
    }

    private static func performOverwrite(documentModel: CineDocumentModel, range: ClosedRange<Int>) {
        Task {
            do {
                try await documentModel.overwriteCurrentFile(range: range)
            } catch {
                presentErrorAlert(error)
            }
        }
    }

    private static func presentErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Failed to save file"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.runModal()
    }
}
