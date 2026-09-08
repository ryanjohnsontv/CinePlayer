import AppKit
import UniformTypeIdentifiers
import CinePlayerCore

/// Shared "Open…" flow — the single place any `NSOpenPanel` is ever
/// constructed/presented in this app. There are now three panel-presenting
/// functions, not one:
///
/// - `presentOpenPanel` — the original combined file-or-folder panel, still
///   used by the empty-state film-icon button (`ContentView`) and the
///   file-browser sidebar's own "Choose Folder…" affordance
///   (`FileBrowserSidebarView`). Unchanged by, and unrelated to, the two
///   functions below.
/// - `presentOpenFilePanel` / `presentOpenFolderPanel` — restricted,
///   single-purpose panels backing the File menu's "Open File…" and "Open
///   Folder…" items (`CinePlayerApp`), which replaced that menu's old single
///   combined "Open…" item.
///
/// All three funnel actual file-opening through `openFile(_:documentModel:)`
/// below — none of them own a second, divorced copy of that open+alert
/// logic.
///
/// `presentOpenPanel` allows picking EITHER a single `.cine` file OR a
/// folder (`canChooseDirectories = true` alongside the existing
/// `canChooseFiles = true`). The `.cine` `UTType` content-type filter below
/// only ever restricts which *files* the panel enables for selection on
/// macOS — folders remain freely selectable and completely unaffected by it,
/// so no separate directories-only panel configuration is needed just to
/// also allow folders.
@MainActor
enum OpenPanelCoordinator {
    /// Presents the open panel and handles whichever kind of URL comes
    /// back:
    /// - A regular file is opened exactly as this app always has
    ///   (`openFile(_:documentModel:)` below — same `documentModel.open(url:)`
    ///   call, same failure `NSAlert` wording as before this file existed).
    /// - A directory is never handed to `documentModel.open(url:)` (which
    ///   only knows how to parse `.cine` file bytes and would throw/misbehave
    ///   on one) — instead it becomes the file-browser sidebar's new root
    ///   folder, and the sidebar is force-shown so picking a folder always
    ///   actually reveals what was just picked, even if the sidebar was
    ///   previously hidden.
    static func presentOpenPanel(documentModel: CineDocumentModel) {
        let panel = NSOpenPanel()
        if let cineType = UTType(filenameExtension: "cine") {
            panel.allowedContentTypes = [cineType]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        if exists && isDirectory.boolValue {
            documentModel.setFileBrowserRoot(url)
            documentModel.setShowFileBrowser(true)
        } else {
            openFile(url, documentModel: documentModel)
        }
    }

    /// Opens `url` as a `.cine` file via `documentModel.open(url:)`,
    /// presenting a failure `NSAlert` on error. Shared by
    /// `presentOpenPanel`'s file branch above and the file-browser
    /// sidebar's row-click handler — one implementation of "open a file,
    /// alert on failure" rather than two copies of the same wording drifting
    /// apart over time.
    static func openFile(_ url: URL, documentModel: CineDocumentModel) {
        Task {
            do {
                try await documentModel.open(url: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Failed to open file"
                alert.informativeText = String(describing: error)
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// Presents a files-only open panel (the File menu's "Open File…", ⌘O)
    /// — same `.cine` `UTType` content-type filter as `presentOpenPanel`,
    /// but `canChooseDirectories = false` so folders are never a valid pick
    /// here (unlike `presentOpenPanel`, this one never branches on the
    /// result's type). Reuses `openFile(_:documentModel:)` for the actual
    /// open, same as every other panel in this file.
    static func presentOpenFilePanel(documentModel: CineDocumentModel) {
        let panel = NSOpenPanel()
        if let cineType = UTType(filenameExtension: "cine") {
            panel.allowedContentTypes = [cineType]
        }
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFile(url, documentModel: documentModel)
    }

    /// Handles a drag-and-drop of `urls` onto the main window (`ContentView`'s
    /// `.dropDestination`) — only the first URL is used, matching every
    /// other open path in this file (`allowsMultipleSelection = false`).
    /// Unlike `presentOpenPanel`'s branch (fed by an `NSOpenPanel` whose own
    /// `.cine` `UTType` filter already restricts file picks), a Finder drag
    /// carries no such restriction, so a dropped file is only opened when its
    /// extension is actually `.cine` — anything else is silently rejected
    /// (`false`) rather than surfacing a "Failed to open file" alert for what
    /// was likely an unrelated, accidental drop. A dropped folder is always
    /// accepted, exactly like `presentOpenPanel`'s directory branch.
    static func handleDroppedURLs(_ urls: [URL], documentModel: CineDocumentModel) -> Bool {
        guard let url = urls.first else { return false }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }

        if isDirectory.boolValue {
            documentModel.setFileBrowserRoot(url)
            documentModel.setShowFileBrowser(true)
            return true
        }
        guard url.pathExtension.lowercased() == "cine" else { return false }
        openFile(url, documentModel: documentModel)
        return true
    }

    /// Presents a folders-only open panel (the File menu's "Open Folder…",
    /// ⌘⇧O) — `canChooseFiles = false`/`canChooseDirectories = true`, with no
    /// content-type filter needed since only folders are selectable at all.
    /// Sets the picked folder as the file-browser sidebar's root and forces
    /// the sidebar visible, the same two calls `presentOpenPanel`'s existing
    /// directory branch already makes.
    static func presentOpenFolderPanel(documentModel: CineDocumentModel) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        documentModel.setFileBrowserRoot(url)
        documentModel.setShowFileBrowser(true)
    }
}
