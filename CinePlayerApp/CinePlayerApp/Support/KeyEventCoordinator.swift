import AppKit
import CinePlayerCore

/// Backs the app's transport shortcuts (Space, arrows, Shift+arrows,
/// Home/End, J/K/L, I/O, Shift+I/O). Plain SwiftUI `.keyboardShortcut` does not reliably
/// capture bare Space/arrow keys outside a menu, so those are handled here
/// instead.
///
/// `handle(_:)` is called directly from `CineMetalView.FocusableMTKView`'s
/// `keyDown(with:)` override, as part of the normal AppKit responder
/// chain — NOT via an `NSEvent` local monitor. An earlier version used
/// `NSEvent.addLocalMonitorForEvents(matching: .keyDown)`, but that
/// monitor's own `return nil` (meaning "consumed") turned out NOT to
/// prevent AppKit's separate default `-[NSWindow keyDown:]` "no responder
/// claims this key" fallback from also running and beeping — confirmed via
/// a live lldb breakpoint on `NSBeep`, twice independently. Handling the
/// key directly in the first responder's own `keyDown(with:)` override
/// avoids that ambiguity: this method's return value (`nil` = consumed)
/// controls whether the view calls `super.keyDown(with:)` at all, so a
/// consumed key never reaches AppKit's default fallback in the first
/// place. See `CineMetalView.swift`'s `FocusableMTKView` and the
/// project status memory's "persistent alert sound on keypress" entry for
/// the full investigation.
///
/// A singleton so `activate(documentModel:)` can be called from
/// `ContentView.onAppear` (which may run more than once across the view's
/// lifetime) while `handle(_:)` always looks up
/// `documentModel.playbackController` at the moment a key is pressed, so
/// it stays correct across closing/reopening files.
@MainActor
final class KeyEventCoordinator {
    static let shared = KeyEventCoordinator()

    private weak var documentModel: CineDocumentModel?

    private init() {}

    func activate(documentModel: CineDocumentModel) {
        self.documentModel = documentModel
    }

    /// Standard macOS virtual key codes for the keys we care about — stable
    /// across keyboard layouts, unlike `charactersIgnoringModifiers` for the
    /// arrow keys. J/K/L are `kVK_ANSI_J`/`kVK_ANSI_K`/`kVK_ANSI_L` from
    /// Carbon's `HIToolbox` (0x26/0x28/0x25); tab/escape/return/keypad-enter
    /// are `kVK_Tab`/`kVK_Escape`/`kVK_Return`/`kVK_ANSI_KeypadEnter`
    /// (0x30/0x35/0x24/0x4C) — the exclusion list `handle`'s `default` case
    /// still lets through, see below.
    private enum KeyCode {
        static let space: UInt16 = 49
        static let leftArrow: UInt16 = 123
        static let rightArrow: UInt16 = 124
        static let end: UInt16 = 119
        static let home: UInt16 = 115
        static let j: UInt16 = 38
        static let k: UInt16 = 40
        static let l: UInt16 = 37
        static let i: UInt16 = 34
        static let o: UInt16 = 31
        static let tab: UInt16 = 48
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
        static let keypadEnter: UInt16 = 76
    }

    /// Keys the broadened `default` fallback in `handle` must still let
    /// propagate even with no `.command` modifier — Tab (focus navigation
    /// between controls like the Debayer picker/Color Matrix checkbox) and
    /// Escape/Return/keypad-Enter (so an `NSSavePanel` presented by
    /// `FrameExporter`/`DNGExporter` while a file is open can still be
    /// cancelled/confirmed from the keyboard).
    private static let unmappedKeyExclusions: Set<UInt16> = [
        KeyCode.tab, KeyCode.escape, KeyCode.returnKey, KeyCode.keypadEnter,
    ]

    /// The rate L should switch to: escalates through the 3 forward tiers
    /// while already playing forward below the fastest tier; otherwise
    /// (paused, playing in reverse, already at `.forwardFastFast`, or in
    /// real-time) resets to the slowest forward tier.
    private func nextForwardRate(currentMode: PlaybackMode?) -> PlaybackRate {
        switch currentMode {
        case .rate(.forwardNormal): return .forwardFast
        case .rate(.forwardFast): return .forwardFastFast
        default: return .forwardNormal
        }
    }

    /// Symmetric to `nextForwardRate(currentMode:)`, for J's 3 reverse tiers.
    private func nextReverseRate(currentMode: PlaybackMode?) -> PlaybackRate {
        switch currentMode {
        case .rate(.reverseNormal): return .reverseFast
        case .rate(.reverseFast): return .reverseFastFast
        default: return .reverseNormal
        }
    }

    /// Returns `nil` to consume the event (the caller must NOT call
    /// `super.keyDown(with:)`), or `event` to let it propagate (the caller
    /// SHOULD call `super.keyDown(with:)`, continuing up the normal
    /// responder chain).
    ///
    /// Command-held keys are excluded up front, before the keyCode switch
    /// below, so ⌘O/⌘E/⌘⇧E/⌘Q and any other menu/app shortcut are always
    /// unaffected — including ones that happen to share a keyCode with one
    /// of the explicit transport cases below (e.g. ⌘L, ⌘K), which matter
    /// only because those cases match on `event.keyCode` alone and don't
    /// check modifiers themselves.
    ///
    /// While a file is open (the `guard` below), any non-Command keydown
    /// that reaches `default` — i.e. isn't one of the explicitly handled
    /// transport keys — is swallowed rather than left to propagate to
    /// macOS's default "invalid input" beep, *unless* it is in
    /// `unmappedKeyExclusions` (so Tab/Escape/Return/keypad-Enter keep their
    /// system/UI meaning — see that property's doc comment).
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let controller = documentModel?.playbackController else { return event }

        if event.modifierFlags.contains(.command) { return event }

        let isShiftDown = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case KeyCode.space:
            controller.togglePause()
            return nil
        case KeyCode.leftArrow:
            controller.step(by: isShiftDown ? -10 : -1)
            return nil
        case KeyCode.rightArrow:
            controller.step(by: isShiftDown ? 10 : 1)
            return nil
        case KeyCode.home:
            controller.seek(to: 0)
            return nil
        case KeyCode.end:
            controller.seek(to: max(0, controller.frameCount - 1))
            return nil
        case KeyCode.j:
            controller.play(rate: nextReverseRate(currentMode: controller.currentMode))
            return nil
        case KeyCode.k:
            controller.togglePause()
            return nil
        case KeyCode.l:
            controller.play(rate: nextForwardRate(currentMode: controller.currentMode))
            return nil
        // I/O set the range's in/out point at the current playhead, the
        // standard NLE convention — `setInPoint`/`setOutPoint` already do
        // exactly that (they're also what `ScrubberView`'s drag handles
        // call). Shift+I/O is the complementary, equally standard "go to
        // in/out point," distinct from Home/End's "go to start/end of the
        // whole file" — most useful once a trim range narrows the two.
        case KeyCode.i:
            if isShiftDown {
                controller.seek(to: controller.effectiveInPoint)
            } else {
                controller.setInPoint(controller.currentFrameIndex)
            }
            return nil
        case KeyCode.o:
            if isShiftDown {
                controller.seek(to: controller.effectiveOutPoint)
            } else {
                controller.setOutPoint(controller.currentFrameIndex)
            }
            return nil
        default:
            // `.command` is already handled by the early return above; this
            // exclusion list only needs to cover the non-Command case now.
            if Self.unmappedKeyExclusions.contains(event.keyCode) {
                return event
            }
            return nil
        }
    }
}
