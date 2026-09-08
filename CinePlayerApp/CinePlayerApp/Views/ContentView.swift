import SwiftUI
import CinePlayerCore

struct ContentView: View {
    @EnvironmentObject var documentModel: CineDocumentModel
    @State private var isFileDropTargeted = false

    var body: some View {
        // The file-browser sidebar lives in its own leading-edge slot,
        // outside/above the empty-state/loaded-state `if`/`else` below —
        // unlike the inspector sidebar (still exactly as it was, only
        // ever inside the loaded-state branch), the file browser must be
        // usable with no file open yet, so it can't live inside that
        // branch at all. Real layout: [file-browser sidebar, leading,
        // collapsible] | [video+scrubber+toolbar+optional-inspector, OR
        // empty state].
        HStack(spacing: 0) {
            if documentModel.showFileBrowser {
                FileBrowserSidebarView(documentModel: documentModel)
                    .transition(.move(edge: .leading).combined(with: .opacity))
                Divider()
            }

            Group {
            if let playbackController = documentModel.playbackController {
                // The inspector sidebar sits alongside the rest of the
                // window in a plain trailing-edge `HStack`, not a
                // `NavigationSplitView` — lower-risk than migrating the
                // whole app's navigation structure for what is, for now,
                // just a single field-list panel. See
                // `InspectorSidebarView`'s own doc comment for why this
                // shape doesn't preclude growing real tabbed content later.
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        // The metadata HUD is composed on top of
                        // `CineMetalView` from out here, via a plain
                        // `ZStack` — `CineMetalView` itself is never
                        // modified. See `MetadataOverlayView`'s own doc
                        // comment for its two corner strings and their
                        // update cadences.
                        ZStack {
                            // Black surround for the letterbox/pillarbox
                            // bars `.aspectRatio(contentMode: .fit)` below
                            // leaves whenever the window's own content-pane
                            // shape doesn't match the clip's aspect ratio —
                            // without this, `CineMetalView` fitted to a
                            // smaller box than its parent would show
                            // whatever the window's default background is
                            // through the gap instead of a clean letterbox.
                            Color.black
                            CineMetalView(documentModel: documentModel, playbackController: playbackController)
                                .aspectRatio(documentModel.videoAspectRatio, contentMode: .fit)
                            if documentModel.showMetadataOverlay {
                                MetadataOverlayView(documentModel: documentModel, playbackController: playbackController)
                            }
                            FileCachingIndicatorView(documentModel: documentModel)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Right-click on the video sets the in/out range at
                        // whatever frame is currently on screen — the same
                        // "mark playhead" convention professional NLEs use,
                        // complementing `ScrubberView`'s drag-handles as a
                        // second way to set the same `PlaybackController`
                        // in/out state.
                        .contextMenu {
                            Button("Set In Point") {
                                playbackController.setInPoint(playbackController.currentFrameIndex)
                            }
                            Button("Set Out Point") {
                                playbackController.setOutPoint(playbackController.currentFrameIndex)
                            }
                        }
                        ScrubberView(documentModel: documentModel, playbackController: playbackController)
                        PlaybackToolbar(documentModel: documentModel, playbackController: playbackController)
                    }

                    if documentModel.showInspectorSidebar {
                        Divider()
                        InspectorSidebarView(documentModel: documentModel, playbackController: playbackController)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: documentModel.showInspectorSidebar)
            } else {
                emptyStateView
            }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: documentModel.showFileBrowser)
        // Drop anywhere in the window, whether or not a file is already
        // open — matches the empty-state button and ⌘O, which both let you
        // open a new file/folder regardless of what's currently loaded.
        // `OpenPanelCoordinator.handleDroppedURLs` does the actual
        // file-vs-folder/extension handling; only the highlight border here
        // is view-local state.
        .dropDestination(for: URL.self) { urls, _ in
            OpenPanelCoordinator.handleDroppedURLs(urls, documentModel: documentModel)
        } isTargeted: { isFileDropTargeted = $0 }
        .overlay {
            if isFileDropTargeted {
                Rectangle()
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
        // 960 (not the original 640): with both the leading file-browser
        // sidebar and the trailing inspector sidebar open simultaneously
        // (240pt fixed width each), 640 left so little room for the actual
        // video/toolbar content that PlaybackToolbar's controls word-wrapped
        // into illegible fragments at the app's real default launch size —
        // confirmed via a live screenshot during this sidebar's own review.
        .frame(minWidth: 960, minHeight: 480)
        .onAppear {
            KeyEventCoordinator.shared.activate(documentModel: documentModel)
        }
        // Title-bar-trailing icon buttons (not floating over the video, not
        // hover-reveal), per the reference tool: an "ⓘ" info-circle that
        // toggles the on-video metadata overlay, and a sidebar-toggle icon
        // that toggles the inspector sidebar. Both reuse the exact same
        // `CineDocumentModel` state/methods the View-menu ⌘I / ⌘⌥I commands
        // in `CinePlayerApp` already drive — this is purely a second
        // affordance for the same toggles, not a parallel piece of state.
        // `.primaryAction` is the idiomatic SwiftUI placement for
        // title-bar-trailing items in a `WindowGroup`-based Mac app (no
        // `NavigationView`/`NavigationSplitView` required for it to render
        // there) — confirmed via a real screenshot, not just assumed; see
        // this workflow's verification notes.
        //
        // Symbol choices: all three confirmed to resolve to a non-nil
        // `NSImage(systemSymbolName:)` on this SDK before being used here —
        // "info.circle" for the info button, "sidebar.right" (the
        // rectangle-with-a-line-on-the-right glyph) for the inspector
        // toggle, and "sidebar.left" (its mirror image) for the new
        // file-browser toggle, matching this project's existing established
        // gotcha with SF Symbols that don't exist in this SDK (see
        // `PlaybackToolbar.swift`'s own doc comments about the same issue).
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    documentModel.toggleFileBrowser()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help("Show File Browser")

                Button {
                    documentModel.toggleMetadataOverlay()
                } label: {
                    Image(systemName: "info.circle")
                }
                .help("Show Metadata Overlay (\u{2318}I)")

                Button {
                    documentModel.toggleInspectorSidebar()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Show Inspector (\u{2318}\u{2325}I)")
            }
        }
        // "Export Video…" (`VideoExportCoordinator.exportVideo`) shows this
        // once its `NSSavePanel` accessory view returns and the encode
        // `Task` has already started — presented from here, alongside the
        // rest of the window, rather than inside the `if let
        // playbackController` branch above: a `Binding` (not a plain `Bool`
        // derived from `activeExportProgress` alone) so dismissing the
        // sheet by any means (its own buttons, or an outside click/Escape
        // when not disabled) always routes back through
        // `dismissExportProgress()`, keeping `CineDocumentModel` as the
        // single source of truth for this state either way.
        .sheet(isPresented: Binding(
            get: { documentModel.activeExportProgress != nil },
            set: { isPresented in
                if !isPresented {
                    documentModel.dismissExportProgress()
                }
            }
        )) {
            if let progress = documentModel.activeExportProgress {
                ExportProgressSheet(progress: progress, documentModel: documentModel)
            }
        }
    }

    /// Now a real `Button` (plain style, no default chrome) rather than a
    /// static, non-interactive panel — clicking anywhere in it invokes the
    /// exact same `OpenPanelCoordinator.presentOpenPanel` flow the ⌘O
    /// command and the file-browser sidebar's own "Choose Folder…"
    /// affordance both use, not a second implementation of the open-panel
    /// logic. `.contentShape(Rectangle())` extends the click target to the
    /// whole padded frame, not just the glyph/text themselves.
    private var emptyStateView: some View {
        Button {
            OpenPanelCoordinator.presentOpenPanel(documentModel: documentModel)
        } label: {
            VStack(spacing: 16) {
                Image(systemName: "film")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("No file open")
                    .font(.title2)
                Text("Click or drag in a .cine file or folder \u{2014} \u{2318}O does the same")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
