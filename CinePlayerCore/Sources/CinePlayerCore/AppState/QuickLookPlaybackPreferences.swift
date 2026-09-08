import Foundation

/// INTENDED to be shared between the main CinePlayer app (`CinePlayerApp`
/// target) and the Quick Look preview extension (`CinePreviewExtension`
/// target) via a `group.com.cineplayer.shared` App Group, so "customize the
/// quick look default playback speed" could be set from the main app's own
/// Settings window and take effect the next time any file is quick-looked.
///
/// **Not actually wired up yet**: that requires a
/// `com.apple.security.application-groups` entitlement on both targets, and
/// this machine has zero code-signing identities configured — Xcode refuses
/// to build ANY target declaring an app-group entitlement without a real
/// (even free/Personal-Team) Apple ID signed in (see both targets' own
/// `.entitlements` files for the exact error). Until that's set up, `suiteName`
/// below is unreachable in practice: the sandboxed `CinePreviewExtension`
/// has no entitlement granting it access, so `UserDefaults(suiteName:)`
/// there is denied and falls through to the `.standard` fallback — which is
/// exactly the right degraded behavior (an extension-local-only preference,
/// same as before this type existed), NOT a bug to "fix" by ripping out the
/// suite-name attempt. No Settings-window UI currently calls this type for
/// exactly that reason — only `PreviewViewController` does, where it's
/// correct either way.
public enum QuickLookPlaybackPreferences {
    private static let suiteName = "group.com.cineplayer.shared"
    private static let speedMultiplierDefaultsKey = "com.cineplayer.quicklook.speedMultiplier"

    /// Falls back to `UserDefaults.standard` if the shared suite can't be
    /// opened — see this type's own doc comment for why that's the normal,
    /// expected path right now, not an error case. This preference is a
    /// minor viewing convenience, never something that should be able to
    /// break Quick Look entirely.
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// A speed multiplier applied on top of a file's own detected review
    /// rate (`Setup.fPbRate`, or `30` when absent — see
    /// `PreviewViewController.fileOwnReviewFPS`). `1.0` (the default when
    /// nothing has ever been saved, and whenever `UserDefaults.double(
    /// forKey:)` returns `0` for an absent/invalid key) means "play at
    /// exactly that file's own rate" — this preference's original behavior,
    /// before it was configurable at all. `2.0`/`5.0`/`10.0` etc. play that
    /// many times faster than that baseline, for quickly skimming a long
    /// clip, without needing to know or reason about any actual fps number.
    public static var speedMultiplier: Double {
        get {
            let stored = defaults.double(forKey: speedMultiplierDefaultsKey)
            return stored > 0 ? stored : 1.0
        }
        set { defaults.set(newValue, forKey: speedMultiplierDefaultsKey) }
    }
}
