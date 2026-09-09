import SwiftUI
import AppKit
import Metal
import CinePlayerCore

/// This package has no `.app` bundle/`Info.plist` (it's a plain SwiftPM
/// executable), so the process has no declared activation policy of its own.
/// Without one, launching it — via `swift run`, a direct binary launch, or
/// Xcode's Run button — can start the process successfully with no
/// visible/active window at all: no crash, no error, just nothing on screen.
///
/// Setting the activation policy from `App.init()` (tried first) was racy:
/// it ran before AppKit had necessarily finished its own launch sequence, so
/// it worked sometimes and silently did nothing other times depending on
/// exactly when SwiftUI got around to creating the actual window. Doing it
/// in `applicationDidFinishLaunching` instead is the deterministic,
/// Apple-documented hook for "AppKit has now fully finished launching" —
/// this fires at a guaranteed-correct point, every time.
final class CinePlayerAppDelegate: NSObject, NSApplicationDelegate {
    /// Set from `CinePlayerApp.init()`, right after `documentModel` itself is
    /// created — `nil` only for the brief window before that assignment,
    /// which no AppKit callback can observe in practice (nothing calls
    /// `application(_:open:)` before `init()` returns).
    var documentModel: CineDocumentModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// The hook Finder actually uses to hand this app a file: double-
    /// clicking a `.cine` file, "Open With ▸ CinePlayer", or dropping a file
    /// on the Dock/app icon. None of those go through `OpenPanelCoordinator`
    /// (which only ever runs in response to this app's own menu items/
    /// buttons) — without this method, the app launched with no window
    /// content at all, since nothing else in this file ever received the
    /// URL Finder was trying to deliver. Routes through
    /// `OpenPanelCoordinator.openFile`, the same "open + alert on failure"
    /// path every other entry point in this app already uses, so a bad file
    /// handed in this way fails the same way a bad file picked from ⌘O does.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let documentModel else { return }
        for url in urls {
            OpenPanelCoordinator.openFile(url, documentModel: documentModel)
        }
    }
}

@main
struct CinePlayerApp: App {
    @NSApplicationDelegateAdaptor(CinePlayerAppDelegate.self) private var appDelegate
    @StateObject private var documentModel: CineDocumentModel

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Self.presentMetalUnavailableAlertAndExit()
        }
        let model = CineDocumentModel(device: device)
        _documentModel = StateObject(wrappedValue: model)
        appDelegate.documentModel = model
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(documentModel)
        }
        .commands {
            // The File menu's "Open…" is three items, not one: a plain
            // "Open File…" (⌘O, matching standard macOS convention for a
            // files-only open), a sibling "Open Folder…" (⌘⇧O, since ⌘O is
            // already taken — doesn't collide with any other shortcut in
            // this file: ⌘E, ⌘⇧E, ⌘I, ⌘⌥I), and an "Open Recent" submenu
            // listing `documentModel.recentFileURLs`. None of these touch
            // `OpenPanelCoordinator.presentOpenPanel` (the older combined
            // file-or-folder panel) — that function and its other call
            // sites (`ContentView`'s empty-state button,
            // `FileBrowserSidebarView`'s "Choose Folder…") are unrelated to
            // this menu and unchanged by it.
            CommandGroup(replacing: .newItem) {
                Button("Open File…") {
                    OpenPanelCoordinator.presentOpenFilePanel(documentModel: documentModel)
                }
                .keyboardShortcut("o", modifiers: [.command])

                Button("Open Folder…") {
                    OpenPanelCoordinator.presentOpenFolderPanel(documentModel: documentModel)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Menu("Open Recent") {
                    ForEach(documentModel.recentFileURLs, id: \.self) { url in
                        Button(url.lastPathComponent) {
                            OpenPanelCoordinator.openFile(url, documentModel: documentModel)
                        }
                    }

                    if !documentModel.recentFileURLs.isEmpty {
                        Divider()
                        Button("Clear Menu") {
                            documentModel.clearRecentFiles()
                        }
                    }
                }
            }
            // Claims SwiftUI's standard Save-item File-menu position. Now
            // hosts two commands, not one: a plain "Save" (⌘S) that
            // overwrites the currently-open file in place, and "Save As…"
            // (⌘⇧S), which always prompts for a brand-new location the way
            // it always has. "Save" is a guarded, confirmation-gated
            // overwrite, not an unconditionally-safe one — see
            // `SaveCoordinator`/`CineDocumentModel.overwriteCurrentFile`
            // for the actual mmap-safety and trim-confirmation mechanics
            // that make an in-place save safe to offer at all here. "Save
            // As…" remains exactly what `SaveAsCoordinator`'s own doc
            // comment already describes: always a new destination, never
            // an in-place overwrite of its own.
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    save()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(documentModel.playbackController == nil)

                Button("Save As\u{2026}") {
                    saveAs()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(documentModel.playbackController == nil)
            }
            // A single "Export" submenu, not a flat list of sibling items —
            // replaces what used to be three separate File-menu entries
            // ("Export Current Frame (PNG)…" ⌘E, "Export Current Frame (Raw
            // DNG)…" ⌘⇧E, "Export Frame Range…") with exactly two actions:
            // a still (any of `StillExportFormat`'s cases, chosen in its own
            // `NSSavePanel` accessory view — PNG/DNG are no longer separate
            // menu items/shortcuts) and a video (`VideoExportCoordinator`,
            // replacing the old PNG/16-bit-TIFF *sequence* export outright —
            // see that coordinator's own doc comment for why a real encoded
            // movie file, not an image-sequence folder, is what "Export
            // Video…" produces). Neither keeps ⌘E/⌘⇧E: a submenu item isn't
            // the kind of single, unambiguous action a bare keyboard
            // shortcut should point at once there are two of them.
            CommandGroup(after: .newItem) {
                Menu("Export") {
                    Button("Export Video…") {
                        VideoExportCoordinator.exportVideo(documentModel: documentModel)
                    }
                    .disabled(documentModel.playbackController == nil)

                    Button("Current Frame as Still…") {
                        exportCurrentFrameAsStill()
                    }
                    .disabled(documentModel.playbackController == nil)
                }
            }
            // A new "View" menu, not folded into an existing one: this is
            // pure view-chrome (no effect on rendering/playback — see
            // `CineDocumentModel.setShowMetadataOverlay`/
            // `setShowInspectorSidebar`), so it belongs with SwiftUI's own
            // `.commands`/`.keyboardShortcut` mechanism exactly like the
            // Export commands above, never routed through
            // `KeyEventCoordinator` (that class is for bare-key playback
            // transport shortcuts only). Neither ⌘I nor ⌘⌥I collides with
            // any of this app's existing shortcuts (⌘O, ⌘⇧O, ⌘S, ⌘⇧S) or
            // with the bare-key transport shortcuts (Space/arrows/Home/End/
            // J/K/L), which only ever fire without ⌘ held — see
            // `KeyEventCoordinator.handle`'s own early `.command` bail-out.
            // Both toggles are also reachable via the
            // title-bar icon buttons `ContentView` adds (`.toolbar {
            // ToolbarItemGroup(placement: .primaryAction) { ... } }`) —
            // those buttons and these menu items/shortcuts drive the exact
            // same `CineDocumentModel` state, not two parallel copies of it.
            CommandGroup(after: .toolbar) {
                Toggle(
                    "Show Metadata Overlay",
                    isOn: Binding(
                        get: { documentModel.showMetadataOverlay },
                        set: { documentModel.setShowMetadataOverlay($0) }
                    )
                )
                .keyboardShortcut("i", modifiers: [.command])

                Toggle(
                    "Show Inspector",
                    isOn: Binding(
                        get: { documentModel.showInspectorSidebar },
                        set: { documentModel.setShowInspectorSidebar($0) }
                    )
                )
                .keyboardShortcut("i", modifiers: [.command, .option])
            }

            // A separate group (renders as its own menu section, divided
            // from the toggles above) for the video pane's zoom, matching
            // the universal macOS zoom-shortcut convention (Safari, Preview,
            // Maps, Photos all use exactly ⌘+/⌘-/⌘0 for this). These drive
            // the exact same `CineDocumentModel` zoom methods the toolbar's
            // "-"/dropdown/"+" controls do (`PlaybackToolbar.zoomControls`)
            // — not a parallel copy of the state, same relationship as the
            // toggles above and their title-bar buttons.
            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    documentModel.zoomIn()
                }
                .keyboardShortcut("+", modifiers: [.command])
                .disabled(documentModel.playbackController == nil)

                Button("Zoom Out") {
                    documentModel.zoomOut()
                }
                .keyboardShortcut("-", modifiers: [.command])
                .disabled(documentModel.playbackController == nil)

                Button("Actual Size") {
                    documentModel.resetZoom()
                }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(documentModel.playbackController == nil)
            }
        }

        // "CinePlayer > Settings…" (⌘,) — a real, standalone Settings
        // window/panel, distinct from any document window, so every
        // app-wide preference below is reachable with no file open at all.
        // See `SettingsView`'s own doc comment for why no new
        // `CineDocumentModel` API was needed to support this.
        Settings {
            SettingsView(documentModel: documentModel)
        }
    }

    /// Shown at launch when no Metal-capable GPU is available. Blocks with a
    /// modal alert instead of crashing (unlike a force-unwrapped
    /// `MTLCreateSystemDefaultDevice()!`), then terminates the app since
    /// `CineDocumentModel` cannot function without a device.
    private static func presentMetalUnavailableAlertAndExit() -> Never {
        let alert = NSAlert()
        alert.messageText = "Metal Is Required"
        alert.informativeText = "CinePlayer requires a Mac with a Metal-capable GPU. "
            + "No such GPU could be found on this Mac, so CinePlayer cannot run."
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        exit(1)
    }

    private func exportCurrentFrameAsStill() {
        Task {
            await StillExportCoordinator.exportCurrentFrame(documentModel: documentModel)
        }
    }

    private func save() {
        SaveCoordinator.save(documentModel: documentModel)
    }

    private func saveAs() {
        SaveAsCoordinator.saveAs(documentModel: documentModel)
    }
}
