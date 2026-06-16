import Foundation
import CoreAudio

/// Effective state of the Clean Incoming feature, surfaced to the UI. The toggle binds to THIS
/// (never the raw persisted flag) so it can't lie: `start()` may fail (TCC denied, own-process
/// unresolved, tap/aggregate creation failed) and the owner then retains NO engine. See the spec's
/// "Canonical effective status — never a lying toggle".
public enum IncomingCleanupStatus: Equatable {
    /// OS < 14.4 — the process-tap path is unavailable; the toggle is disabled.
    case unavailable
    /// Feature off (user has not enabled it).
    case off
    /// Engine is genuinely running (capturing + cleaning + playing).
    case cleaning
    /// User enabled it but `start()` returned false (commonly first-run TCC denial). The toggle
    /// stays on so granting permission + re-toggling retries.
    case failed
}

/// Pure, headless-testable decisions for the tap-based incoming path. Kept OUT of the
/// `@available(macOS 14.4, *)` engine so `swift test` exercises them on any host (mirrors the
/// project's "keep risky logic in tested statics" rule). Imports only Foundation + CoreAudio types.
public enum IncomingTapLogic {

    /// Validity predicate for NoNoise's own audio process object
    /// (`kAudioHardwarePropertyTranslatePIDToProcessObject`). A global-exclude tap built around an
    /// UNKNOWN own-process id would exclude *nothing* and re-capture/mute our own cleaned playback
    /// (feedback / self-mute). So `start()` must hard-fail unless this is true.
    public static func isValidProcessObject(status: OSStatus, id: AudioObjectID) -> Bool {
        status == noErr && id != AudioObjectID(kAudioObjectUnknown) && id != 0
    }

    /// What to do when the default output changes (or hardware changes) while the engine runs.
    public enum RepinAction: Equatable {
        /// Tap + aggregate are still alive — just re-point the playback output unit (cheap, bumpless).
        case repin
        /// The tap/aggregate itself died — tear down fully and rebuild.
        case rebuild
    }

    /// Re-pin vs full-rebuild decision: re-pin unless the capture side (tap/aggregate) has died.
    public static func repinDecision(tapAlive: Bool) -> RepinAction {
        tapAlive ? .repin : .rebuild
    }
}
