import AppKit
import UniformTypeIdentifiers
import CinePlayerCore

/// "Load LUT…" / "Change LUT…" (inspector sidebar's Color Correction
/// section, `InspectorSidebarView`) and the "Recent LUTs" menu's individual
/// items — the single place any LUT-loading `NSOpenPanel` is presented, and
/// the single place a LUT-load failure is caught and alerted. Mirrors
/// `SaveAsCoordinator`'s exact shape (a local, duplicated `presentErrorAlert`
/// helper — `NSAlert`, `messageText`/`informativeText`/`.warning` — rather
/// than a shared one, matching this codebase's established convention for
/// these panel-driven coordinators).
@MainActor
enum LUTLoadCoordinator {
    /// Presents an `NSOpenPanel` filtered to `.cube` files (`canChooseFiles
    /// = true`, `canChooseDirectories = false`, single selection); on a
    /// chosen URL, delegates to `load(_:documentModel:)` below. Silently
    /// returns if the panel is cancelled — no alert — matching every other
    /// panel-driven action in this codebase (e.g.
    /// `OpenPanelCoordinator.presentOpenFilePanel`).
    static func presentLoadPanel(documentModel: CineDocumentModel) {
        let panel = NSOpenPanel()
        if let cubeType = UTType(filenameExtension: "cube") {
            panel.allowedContentTypes = [cubeType]
        }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url, documentModel: documentModel)
    }

    /// Loads `url` as a `.cube` LUT via `documentModel.loadLUT(from:)`,
    /// presenting a failure `NSAlert` on error. Also called directly (no
    /// panel involved) by the "Recent LUTs" menu's individual items, going
    /// straight to a previously-loaded URL — the same "one implementation,
    /// two entry points" shape `OpenPanelCoordinator.openFile` already uses
    /// for `.cine` files and their own "Open Recent" menu.
    static func load(_ url: URL, documentModel: CineDocumentModel) {
        do {
            try documentModel.loadLUT(from: url)
        } catch {
            presentErrorAlert(error)
        }
    }

    private static func presentErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Failed to load LUT"
        alert.informativeText = String(describing: error)
        alert.alertStyle = .warning
        alert.runModal()
    }
}
