import Foundation

/// Pure, headless-testable routing/filtering logic for the NoNoise Mic virtual driver (the OUTGOING
/// mic path). Operates on plain values (no CoreAudio) so it runs under `swift test`.
///
/// The constants here are the Swift half of the app↔driver shared contract — they MUST stay
/// identical to the driver's C constants (see `Driver/NoNoiseMic/NoNoiseMic.c` and the plan's
/// contract table). A mismatch fails SILENTLY.
public enum VirtualMicRouting {
    // Shared contract — keep identical to the driver's constants.
    public static let visibleDeviceName = "NoNoise Mic"
    public static let engineDeviceName  = "NoNoise Mic Engine"
    public static let visibleDeviceUID  = "NoNoiseMic:visible:48k2ch"
    public static let engineDeviceUID   = "NoNoiseMic:engine:48k2ch"

    /// Known virtual sinks we will auto-route to, in priority order. A physical
    /// output is NEVER a fallback (would play cleaned audio aloud, not feed a mic).
    private static let fallbackVirtualSinks = ["BlackHole"]

    public struct DeviceInfo: Equatable {
        public let uid: String
        public let name: String
        public let isHidden: Bool
        public let hasOutput: Bool
        public init(uid: String, name: String, isHidden: Bool, hasOutput: Bool) {
            self.uid = uid; self.name = name; self.isHidden = isHidden; self.hasOutput = hasOutput
        }
    }

    // ---- Canonical predicates (ONE source — used by discovery, picker filtering, AND auto-route) ----

    /// True for our hidden engine device. Matches by UID OR name so a missing/misreported
    /// `kAudioDevicePropertyIsHidden` flag can't leak the engine into the user's picker.
    public static func isNoNoiseEngine(_ d: DeviceInfo) -> Bool {
        d.uid == engineDeviceUID || d.name == engineDeviceName
    }

    /// An output the user may pick in the APP's own picker: not hidden AND not our engine.
    public static func isSelectableOutput(_ d: DeviceInfo) -> Bool {
        !d.isHidden && !isNoNoiseEngine(d)
    }

    /// UID of the output the engine should render into: the hidden engine device if present,
    /// else a known virtual sink (BlackHole), else nil (do NOT route to a physical output —
    /// surface "install the driver" instead). Returns the device UID — the exact value the
    /// runtime resolves to an AudioObjectID, so the tested predicate IS the runtime predicate.
    public static func preferredOutputUID(from devices: [DeviceInfo]) -> String? {
        if let engine = devices.first(where: isNoNoiseEngine) { return engine.uid }
        if let bh = devices.first(where: { d in fallbackVirtualSinks.contains(where: { d.name.contains($0) }) }) {
            return bh.uid
        }
        return nil
    }

    /// Output devices to show in the app's own picker — hidden + engine excluded.
    public static func visibleOutputs(from devices: [DeviceInfo]) -> [DeviceInfo] {
        devices.filter(isSelectableOutput)
    }

    /// The device the playback engine must bind to, or `nil` meaning **do not start the engine**.
    ///
    /// `selected` is the published `AudioModel.selectedOutputDeviceID`, which `fetchOutputDevices()`
    /// assigns from a DEFERRED main-queue block — so on the first call (from `init()`) it is still 0.
    /// `resolvedEngine` is the hidden sink translated synchronously by UID, which covers that window.
    ///
    /// Starting unpinned is never acceptable: an `AVAudioEngine` with no `CurrentDevice` binds to the
    /// SYSTEM DEFAULT OUTPUT, so the cleaned voice plays into the user's speakers/headphones while
    /// "NoNoise Mic" serves silence. See `docs/knowledge/critical-patterns.md`.
    public static func playbackRouteID(selected: UInt32, resolvedEngine: UInt32) -> UInt32? {
        if selected != 0 { return selected }
        if resolvedEngine != 0 { return resolvedEngine }
        return nil
    }

    public static func shouldRepinPlaybackAfterHardwareRefresh(
        preferredRouteUID: String?,
        previousOutputDeviceID: UInt32,
        resolvedOutputDeviceID: UInt32
    ) -> Bool {
        preferredRouteUID == engineDeviceUID &&
        resolvedOutputDeviceID != 0 &&
        resolvedOutputDeviceID == previousOutputDeviceID
    }

    /// Remove the virtual mic from a list of input device names (prevents a
    /// feedback loop if the user could otherwise select it as the capture source).
    public static func filterInputs(_ names: [String]) -> [String] {
        names.filter { $0 != visibleDeviceName && $0 != engineDeviceName }
    }
}
