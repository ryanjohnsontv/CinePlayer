import SwiftUI
import AppKit
import CinePlayerCore

/// The leading-edge file-browser sidebar's content, shown by `ContentView`
/// alongside the rest of the window when `documentModel.showFileBrowser` is
/// true (toggled via the title-bar sidebar button) — mirrors
/// `InspectorSidebarView`'s trailing-edge placement/sizing convention, just
/// on the opposite edge and with entirely different content: a genuine
/// directory *tree*, not a per-file field list.
///
/// Before any root folder has been chosen (`documentModel.fileBrowserRootURL
/// == nil`), shows a simple "Choose Folder…" empty state that reuses the
/// exact same `OpenPanelCoordinator.presentOpenPanel` flow the ⌘O command
/// and the empty-state film icon both use — not a second, divorced picker.
///
/// Once a root is chosen, its content is a `SwiftUI.OutlineGroup` (real
/// per-subfolder disclosure triangles, not a flattened list) built over
/// `FileBrowserNode`, whose `children` is a *computed* property —
/// `OutlineGroup` only ever reads it for whichever rows are currently
/// visible/expanded, so a folder's contents are enumerated lazily, one
/// directory level at a time, as the user actually expands rows, rather
/// than one eager deep recursive walk of the whole tree up front. Only
/// subdirectories and `.cine` files are ever included — everything else
/// (README.md, .gitignore, Package.swift, etc.) is filtered out by
/// `FileBrowserNode.children`.
///
/// Clicking a `.cine` row opens it via `OpenPanelCoordinator.openFile`
/// (the same `documentModel.open(url:)` + failure-alert path every other
/// open action in this app uses). Whichever file is currently open is
/// visually distinguished with a filled accent-colored row background
/// (`FileBrowserRowView` — matching Finder's own selected-row look) plus
/// accent-colored text, by comparing against `documentModel.currentURL`.
///
/// Every row (both directory and `.cine` file rows) also supports Finder-style
/// inline rename via a right-click "Rename" context-menu item — see
/// `renamingURL`/`renameText` below and `FileBrowserRowView`, which owns the
/// actual rename-mode UI/logic shared by both row kinds.
struct FileBrowserSidebarView: View {
    @ObservedObject var documentModel: CineDocumentModel

    /// The node currently in inline-rename mode (its row is showing a
    /// `TextField` instead of its normal icon+label), or `nil` when nothing
    /// is being renamed. Lives here (not inside `FileBrowserRowView` itself)
    /// so that starting a rename on one row is guaranteed to end rename mode
    /// on any other — there is only ever at most one `renamingURL` for the
    /// whole tree, shared across every row via a `Binding`.
    @State private var renamingURL: URL?

    /// The in-progress edited text for whichever row `renamingURL` points
    /// at. See `FileBrowserRowView.beginRenaming()` for how this is seeded
    /// (and why, for files, it deliberately omits the `.cine` extension).
    @State private var renameText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Files")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            if let rootURL = documentModel.fileBrowserRootURL {
                ScrollView {
                    OutlineGroup(FileBrowserNode.enumerateChildren(of: rootURL) ?? [], children: \.children) { node in
                        row(for: node)
                    }
                    .padding(12)
                }
            } else {
                emptyState
            }
        }
        .frame(width: 240)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("No folder selected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Choose Folder\u{2026}") {
                OpenPanelCoordinator.presentOpenPanel(documentModel: documentModel)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(for node: FileBrowserNode) -> some View {
        FileBrowserRowView(
            node: node,
            documentModel: documentModel,
            isCurrent: isCurrentFile(node.url),
            renamingURL: $renamingURL,
            renameText: $renameText
        )
    }

    /// Compares against `documentModel.currentURL` via
    /// `resolvingSymlinksInPath()` rather than raw `URL` equality or just
    /// `standardizedFileURL` (which only collapses `.`/`..`/redundant
    /// slashes, it does NOT resolve symlinks) — a file opened through this
    /// sidebar always matches, and resolving symlinks also makes a file
    /// opened via the ⌘O panel line up with this sidebar's own
    /// `FileManager`-enumerated `URL` for the same on-disk path even when
    /// the browser's root (or an ancestor of it) is itself a symlink/alias —
    /// a common real pattern for footage organized via a shortcut into an
    /// external drive or NAS mount.
    private func isCurrentFile(_ url: URL) -> Bool {
        guard let currentURL = documentModel.currentURL else { return false }
        return currentURL.resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
    }
}

/// One row's actual UI: a compact Finder-list-row-style icon+label (or, in
/// rename mode, an inline `TextField` in its place), a subtle hover
/// highlight, and — for whichever file is currently open — a filled
/// selection-style background. A dedicated view type (rather than another
/// `@ViewBuilder` method on `FileBrowserSidebarView`, as this used to be) is
/// what actually makes the hover highlight and the rename `TextField`'s focus
/// possible at all: `@State`/`@FocusState` only work as property wrappers on
/// a real `View` conformer, and every row needs its OWN independent hover
/// flag (hovering row A must never highlight row B).
///
/// Handles both directory rows and `.cine` file rows through the same body —
/// they differ only in whether the icon+label is wrapped in a `Button` that
/// opens the file, and only that inner difference is conditioned on
/// `node.isDirectory`. The context menu and the three rename methods below it
/// are never duplicated per row kind: exactly one "Rename" menu item, and one
/// begin/commit/cancel implementation, is shared by both.
private struct FileBrowserRowView: View {
    let node: FileBrowserNode
    // Not `@ObservedObject`: nothing below reads any of `documentModel`'s own
    // `@Published` properties directly (`isCurrent` is instead recomputed by
    // the parent, which DOES observe it, on every one of its own body
    // re-evaluations, and handed down fresh as a plain `Bool`) — this is only
    // ever used to invoke a couple of its methods, so a plain reference is
    // all that's needed; subscribing here too would just double-invalidate
    // this row for no benefit.
    let documentModel: CineDocumentModel
    let isCurrent: Bool
    @Binding var renamingURL: URL?
    @Binding var renameText: String

    /// Focuses the rename `TextField` the moment rename mode begins — set
    /// from the field's own `.onAppear` (see `renameField` below), since the
    /// field itself is only ever created for the instant `renamingURL` first
    /// starts pointing at this row.
    @FocusState private var isRenameFieldFocused: Bool

    /// Whether the pointer is currently over this row — purely a Finder-list
    /// hover cue (`.onHover` below), independent of `isCurrent`'s "this is
    /// the open file" selection look; both can be true/apply their own
    /// background at once, `isCurrent`'s just wins (see `rowBackground`).
    @State private var isHovering = false

    /// Re-entrancy guard for `commitRename()` — see the focus-loss
    /// `.onChange` in `renameField` below. `commitRename()`'s failure path
    /// shows a blocking `NSAlert` (`runModal()`), which makes the alert
    /// panel key and so can itself cause `isRenameFieldFocused` to observe
    /// a focus change while the original `commitRename()` call is still on
    /// the stack; without this guard that could re-enter `commitRename()`
    /// (and, on a real collision, pop a second overlapping alert) before
    /// the first call has even returned.
    @State private var isCommittingRename = false

    var body: some View {
        Group {
            if renamingURL == node.url {
                renameField
            } else {
                rowContent
                    .contextMenu {
                        Button("Rename") { beginRenaming() }
                    }
            }
        }
    }

    /// The normal (non-renaming) row: a directory is a plain icon+label (no
    /// `Button` — clicking it does nothing today; only its own disclosure
    /// triangle, owned by `OutlineGroup` itself, expands it), a `.cine` file
    /// is the same icon+label wrapped in a `Button` that opens it.
    @ViewBuilder
    private var rowContent: some View {
        if node.isDirectory {
            rowLabel
        } else {
            Button {
                OpenPanelCoordinator.openFile(node.url, documentModel: documentModel)
            } label: {
                rowLabel
            }
            .buttonStyle(.plain)
        }
    }

    /// The actual icon+text row, styled to read as a compact Finder list row
    /// rather than a spaced-out SwiftUI form row: a real per-item icon (not
    /// an SF Symbol stand-in), tight spacing, small system-size text, and
    /// small vertical padding — all noticeably tighter than `Label`'s own
    /// default sizing, which is what made this sidebar read as "elementary"
    /// rather than native.
    private var rowLabel: some View {
        HStack(spacing: 5) {
            // The REAL per-item icon Finder itself would show for this exact
            // path — folders get Finder's actual folder icon (which itself
            // varies, e.g. for a tagged/special folder), `.cine` files get
            // whatever icon their UTI resolves to — rather than a generic
            // SF Symbol stand-in. This single swap is the biggest lever for
            // "looks like Finder": `NSWorkspace` is the same system service
            // Finder's own list view uses to resolve a path to an icon, so
            // the result is pixel-for-pixel what Finder would draw here.
            Image(nsImage: NSWorkspace.shared.icon(forFile: node.url.path))
                .resizable()
                .frame(width: 16, height: 16) // Finder's own list-row icon size.
            Text(node.url.lastPathComponent)
                .font(.system(size: 13))
                .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2.5)
        .padding(.horizontal, 4)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovering in isHovering = hovering }
    }

    /// `isCurrent`'s filled selection background wins outright over the
    /// hover highlight when both would otherwise apply (opening a file and
    /// then leaving the pointer resting over its own now-selected row should
    /// keep reading as "selected", not flicker to a plain hover tint) — a
    /// proper filled rounded-rect, much closer to how Finder actually
    /// renders a selected row than the old bold-text-only treatment this
    /// replaced. `isHovering` alone gets a much lighter, purely-interactive
    /// tint with no fixed hue, matching Finder's own subtle non-selected
    /// hover cue.
    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(isCurrent ? Color.accentColor.opacity(0.15) : (isHovering ? Color.primary.opacity(0.06) : Color.clear))
    }

    /// Enters inline-rename mode for this row: seeds `renameText` with the
    /// item's current display name and points `renamingURL` at this row's
    /// `node.url`, which is what actually swaps `rowContent` for
    /// `renameField` above.
    ///
    /// For a `.cine` file, `renameText` is seeded WITHOUT the `.cine`
    /// extension — Finder's own inline rename shows the base name selected
    /// with the extension present but deliberately left out of the
    /// selection (still visible, still technically editable). SwiftUI's
    /// `TextField` has no equivalent of AppKit's `NSTextField`
    /// fine-grained initial-selection control — there's no API here to
    /// select only a sub-range of the field's initial text — so rather than
    /// fumbling a partial effort at that exact look, the simplification
    /// applied here is to omit the extension from the editable text
    /// entirely and re-append it verbatim in `commitRename()` below.
    /// Directories have no such split: the whole name is always editable.
    private func beginRenaming() {
        renameText = node.isDirectory
            ? node.url.lastPathComponent
            : node.url.deletingPathExtension().lastPathComponent
        renamingURL = node.url
    }

    /// Commits the in-progress rename: builds the destination URL (the
    /// original parent directory + the edited name, with a file's original
    /// extension re-appended — see `beginRenaming()`'s doc comment for why
    /// the extension was stripped from `renameText` in the first place), and
    /// asks `documentModel` to actually perform it on disk.
    ///
    /// A no-op (exits rename mode without touching the filesystem) if the
    /// trimmed new name is empty or identical to the current name — trimmed
    /// specifically so accidentally leaving/adding only leading/trailing
    /// whitespace doesn't attempt a real (if pointless) filesystem rename.
    /// Any real failure (permissions, a name collision, etc.) surfaces via
    /// the same `NSAlert` convention every other user-facing failure in this
    /// app uses (see `OpenPanelCoordinator.openFile`'s own catch block).
    ///
    /// Guarded by `isCommittingRename` against being re-entered while an
    /// outer call to itself is still on the stack — see that flag's own doc
    /// comment.
    private func commitRename() {
        guard !isCommittingRename else { return }
        isCommittingRename = true
        defer {
            isCommittingRename = false
            renamingURL = nil
        }

        let trimmedName = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let newFullName = node.isDirectory ? trimmedName : trimmedName + "." + node.url.pathExtension
        guard newFullName != node.url.lastPathComponent else { return }

        let newURL = node.url.deletingLastPathComponent().appendingPathComponent(newFullName)
        do {
            try documentModel.renameItem(at: node.url, to: newURL)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Failed to rename item"
            alert.informativeText = String(describing: error)
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Cancels the in-progress rename with no filesystem change at all —
    /// bound to Escape (`.onExitCommand` below) exactly the way Finder's own
    /// inline rename discards on Escape.
    private func cancelRenaming() {
        renamingURL = nil
    }

    private var renameField: some View {
        TextField("", text: $renameText)
            .font(.system(size: 13))
            .textFieldStyle(.plain)
            .padding(.vertical, 2.5)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.primary.opacity(0.06))
            )
            .focused($isRenameFieldFocused)
            .onAppear { isRenameFieldFocused = true }
            .onSubmit { commitRename() }
            .onExitCommand { cancelRenaming() }
            .onChange(of: isRenameFieldFocused) { _, isFocused in
                // Mirrors Finder's own inline-rename behavior: clicking
                // anywhere else while a rename is in progress commits it
                // (with whatever text is currently entered) rather than
                // leaving this row parked indefinitely in rename mode with
                // no obvious way out — until now, only Return/Escape ended
                // rename mode, so losing focus by any other means (clicking
                // another row, another window, anywhere) left a dead-looking
                // text field sitting in place of the row until the user
                // happened to click back into it and press Return/Escape.
                // Guarded by `renamingURL == node.url` so this only acts for
                // the row that's still actually the one being renamed —
                // `beginRenaming()` on a *different* row already reassigns
                // the shared `renamingURL` away from this one (ending this
                // row's rename mode on its own, without going through
                // `commitRename()`/`cancelRenaming()` at all), so this must
                // not also fire a stale commit for this row when that
                // happens to coincide with its own focus loss.
                guard !isFocused, renamingURL == node.url else { return }
                commitRename()
            }
    }
}

/// One row of the file-browser tree: either a subdirectory (shown with a
/// disclosure triangle whenever it contains at least one qualifying entry)
/// or a `.cine` file (a leaf, no triangle). `Identifiable` via its own `url`
/// so `OutlineGroup` can diff rows without a separate synthesized ID.
struct FileBrowserNode: Identifiable {
    let url: URL
    let isDirectory: Bool

    var id: URL { url }

    /// This node's immediate children, or `nil` for a file (no disclosure
    /// triangle) and for a directory with no qualifying entries at all
    /// (also no triangle — nothing useful to expand into). Computed fresh
    /// on every read rather than cached: `OutlineGroup` only calls this for
    /// rows currently on screen/expanded, so a freshly-expanded folder's
    /// listing is always current. The listing itself is one shallow
    /// `FileManager.contentsOfDirectory` call, but each subdirectory found
    /// that way is then probed with a real (early-exiting) recursive walk
    /// of its own — see `directoryRecursivelyContainsCineFile`'s own doc
    /// comment — to decide whether it's worth showing at all.
    var children: [FileBrowserNode]? {
        guard isDirectory else { return nil }
        return Self.enumerateChildren(of: url)
    }

    /// Shallow (single-level) enumeration of `directoryURL`, filtered down
    /// to subdirectories and `.cine` files only (everything else — README,
    /// .gitignore, Package.swift, etc. — is excluded), sorted directories
    /// first then alphabetically within each group. Returns `nil` (rather
    /// than an empty array) when enumeration fails outright or the
    /// directory has no qualifying entries, so callers can use the result
    /// directly as an `OutlineGroup`/`FileBrowserNode.children` value
    /// without a separate "is this empty" check.
    static func enumerateChildren(of directoryURL: URL) -> [FileBrowserNode]? {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let nodes: [FileBrowserNode] = entries.compactMap { entryURL in
            let isDirectory = (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory {
                // Unlike this function's own shallow, single-level listing,
                // this is a real recursive walk — the only way to answer
                // "would expanding this ever show anything" without
                // expanding it. Exits as soon as it finds one `.cine` file,
                // so a folder that DOES qualify is cheap; only a folder with
                // none anywhere in its subtree pays the full walk, and only
                // once per render of its parent row (no caching — this is a
                // small source-repo-sized tree, not an arbitrary filesystem
                // browser, so that cost hasn't been worth the staleness risk
                // a cache would add).
                guard Self.directoryRecursivelyContainsCineFile(entryURL) else { return nil }
                return FileBrowserNode(url: entryURL, isDirectory: true)
            } else if entryURL.pathExtension.lowercased() == "cine" {
                return FileBrowserNode(url: entryURL, isDirectory: false)
            } else {
                return nil
            }
        }

        guard !nodes.isEmpty else { return nil }

        return nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
    }

    /// Whether `directoryURL` contains at least one `.cine` file, anywhere
    /// in its subtree — used to hide folders from the browser that could
    /// never lead to a `.cine` file no matter how far you expand into them
    /// (README, `.git`, build folders, etc.). `nil` from `enumerator` (e.g.
    /// the directory can't be read) is treated as "contains nothing", same
    /// as `enumerateChildren`'s own failure handling above.
    private static func directoryRecursivelyContainsCineFile(_ directoryURL: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        for case let url as URL in enumerator where url.pathExtension.lowercased() == "cine" {
            return true
        }
        return false
    }
}
