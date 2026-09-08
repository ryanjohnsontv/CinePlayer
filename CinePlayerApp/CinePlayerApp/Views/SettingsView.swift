import SwiftUI
import CinePlayerCore

/// The content of CinePlayer's Settings window ("CinePlayer > Settings…",
/// ⌘,) — wired in as a SwiftUI `Settings` scene in `CinePlayerApp.body`,
/// which gives it that menu item/shortcut and a real, standalone floating
/// window for free, distinct from any document window.
///
/// Most controls here bind directly to `documentModel`'s EXISTING public
/// getters/setters (`setDebayerMode`, `setColorMatrixEnabled`,
/// `setShowMetadataOverlay`, `setShowInspectorSidebar`, `setShowFileBrowser`,
/// `setFrameNumberingMode`, `clearRecentFiles`, `clearRecentLUTs`) — the
/// exact same app-wide, `UserDefaults`-persisted preferences
/// `InspectorSidebarView`'s "Color Correction" section and `CinePlayerApp`'s
/// "View" menu commands already read/write. No new persisted state or
/// `CineDocumentModel` API was needed for those: every one of them was
/// already a live, app-wide (not per-file) preference, just previously only
/// reachable from inside an open document's own UI. This window makes them
/// reachable at any time, with no file open at all — `documentModel` is a
/// single app-wide instance either way (see `CinePlayerApp.init()`), so
/// every setter here is exactly as safe to call with no document open as it
/// is with one.
///
/// Deliberately does NOT include a "Quick Look default playback speed"
/// control, even though `QuickLookPlaybackPreferences.speedMultiplier`
/// (CinePlayerCore) exists for exactly that purpose: it's meant to live in a
/// `group.com.cineplayer.shared` App Group shared with the separate,
/// sandboxed `CinePreviewExtension` process, but that entitlement can't be
/// added on this machine yet (zero code-signing identities configured —
/// see that type's own doc comment and both targets' `.entitlements`
/// files). A control here would silently do nothing to the actual Quick
/// Look extension until that's set up, which would be worse than not
/// having it — the speed picker inside any Quick Look preview itself is the
/// only place this preference is reachable for now.
struct SettingsView: View {
    @ObservedObject var documentModel: CineDocumentModel

    private var currentDebayerMode: DebayerMode {
        DebayerMode(rawValue: documentModel.uniforms.debayerMode) ?? .highQuality
    }

    var body: some View {
        Form {
            Section("Rendering Defaults") {
                Picker(
                    "Debayer Mode",
                    selection: Binding(
                        get: { currentDebayerMode },
                        set: { documentModel.setDebayerMode($0) }
                    )
                ) {
                    ForEach(DebayerMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }

                Toggle(
                    "Color Matrix",
                    isOn: Binding(
                        get: { documentModel.colorMatrixEnabled },
                        set: { documentModel.setColorMatrixEnabled($0) }
                    )
                )
            }

            Section("Frame Numbering") {
                Picker(
                    "Convention",
                    selection: Binding(
                        get: { documentModel.frameNumberingMode },
                        set: { documentModel.setFrameNumberingMode($0) }
                    )
                ) {
                    ForEach(FrameNumberingMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
            }

            Section("Sidebars") {
                Toggle(
                    "Show Metadata Overlay",
                    isOn: Binding(
                        get: { documentModel.showMetadataOverlay },
                        set: { documentModel.setShowMetadataOverlay($0) }
                    )
                )

                Toggle(
                    "Show Inspector",
                    isOn: Binding(
                        get: { documentModel.showInspectorSidebar },
                        set: { documentModel.setShowInspectorSidebar($0) }
                    )
                )

                Toggle(
                    "Show File Browser",
                    isOn: Binding(
                        get: { documentModel.showFileBrowser },
                        set: { documentModel.setShowFileBrowser($0) }
                    )
                )
            }

            Section("Recent Items") {
                Button("Clear Recent Files") {
                    documentModel.clearRecentFiles()
                }
                .disabled(documentModel.recentFileURLs.isEmpty)

                Button("Clear Recent LUTs") {
                    documentModel.clearRecentLUTs()
                }
                .disabled(documentModel.recentLUTURLs.isEmpty)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 420)
    }
}
