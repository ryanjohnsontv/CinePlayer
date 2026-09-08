import Foundation

/// Observable progress/cancellation state for one in-flight multi-frame
/// export (currently just `VideoExportCoordinator.exportVideo`, in the
/// `CinePlayerApp` target), surfaced through
/// `CineDocumentModel.activeExportProgress` so `ExportProgressSheet` can
/// observe it — lives here, in `CinePlayerCore`, rather than alongside the
/// coordinator itself, purely because `CineDocumentModel` needs to hold a
/// reference to it and this package cannot depend on the app target (the
/// dependency only ever runs the other way).
///
/// A fresh instance per export. Starts `isExporting == true`: unlike a
/// wizard-style "pick options, then run" sheet, there is no "not started
/// yet" phase to distinguish here — by the time anything ever observes
/// this object, the exporter that created it has already started its
/// encode `Task` (codec/resolution/fps/destination were already chosen via
/// a native `NSSavePanel` accessory view before this object even exists).
@MainActor
public final class MediaExportProgress: ObservableObject {
    @Published public var currentFrame: Int = 0
    @Published public var totalFrames: Int = 0
    @Published public var isExporting: Bool = true

    /// The running export `Task`, stored here (not just locally where it's
    /// created) so `cancel()` can reach it from a "Cancel" button's action
    /// closure without the view needing its own separate reference.
    public var task: Task<Void, Never>?

    public init() {}

    /// Requests cancellation. Cooperative, like any Swift `Task`
    /// cancellation: the exporter checks `Task.isCancelled` between frames
    /// and stops there, finalizing whatever's already been written rather
    /// than leaving a corrupt partial file.
    public func cancel() {
        task?.cancel()
    }
}
