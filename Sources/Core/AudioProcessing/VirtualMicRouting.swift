import Foundation

/// Pure, headless-testable routing/filtering logic for the NoNoise Mic virtual driver.
/// Operates on plain values (no CoreAudio) so it runs under `swift test`.
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
        /// True if the device exposes INPUT (capture) channels. Required to reject output-only
        /// devices from the incoming-source picker.
        public let hasInput: Bool
        /// CoreAudio `kAudioDevicePropertyTransportType` as a raw `UInt32` (kept CoreAudio-free here).
        /// Lets us reject physical mics (built-in/USB/Bluetooth/HDMI/…) and accept aggregate/virtual.
        public let transportType: UInt32
        public init(uid: String, name: String, isHidden: Bool, hasOutput: Bool,
                    hasInput: Bool = false, transportType: UInt32 = 0) {
            self.uid = uid; self.name = name; self.isHidden = isHidden; self.hasOutput = hasOutput
            self.hasInput = hasInput; self.transportType = transportType
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

    /// Remove the virtual mic from a list of input device names (prevents a
    /// feedback loop if the user could otherwise select it as the capture source).
    public static func filterInputs(_ names: [String]) -> [String] {
        names.filter { $0 != visibleDeviceName && $0 != engineDeviceName }
    }

    // ---- Incoming / guest cleanup (the OTHER side) ----

    // CoreAudio `AudioDeviceTransportType` values (FourCharCodes from <CoreAudio/AudioHardwareBase.h>).
    // Mirrored here as plain UInt32 so VirtualMicRouting stays headless-testable (no CoreAudio import).
    public static let transportTypeUnknown: UInt32   = 0
    public static let transportTypeBuiltIn: UInt32   = 0x626C746E // 'bltn'
    public static let transportTypeAggregate: UInt32 = 0x67727570 // 'grup'
    public static let transportTypeVirtual: UInt32   = 0x76697274 // 'virt'
    public static let transportTypeUSB: UInt32       = 0x75736220 // 'usb '
    public static let transportTypeBluetooth: UInt32 = 0x626C7565 // 'blue'

    /// Transport types that identify a PHYSICAL mic — never a valid incoming (loopback) source.
    private static let physicalInputTransports: Set<UInt32> = [
        transportTypeBuiltIn,
        transportTypeUSB,
        transportTypeBluetooth,
        0x626C6561, // 'blea' BluetoothLE
        0x68646D69, // 'hdmi' HDMI
        0x64707274, // 'dprt' DisplayPort
        0x61697270, // 'airp' AirPlay
        0x7468756E, // 'thun' Thunderbolt
        0x70636920, // 'pci ' PCI
        0x66697265, // 'fire' FireWire
    ]

    /// True for the VISIBLE NoNoise Mic device. Matches by UID OR name — the shared contract's
    /// strongest id is the UID, so a UID match with a differing/localised name must STILL be
    /// rejected (a self-loop: capturing our own cleaned voice back as the "incoming" guest).
    /// Mirrors `isNoNoiseEngine`'s UID-or-name strategy for the hidden engine device.
    public static func isNoNoiseVisible(_ d: DeviceInfo) -> Bool {
        d.uid == visibleDeviceUID || d.name == visibleDeviceName
    }

    /// True for a device the user may pick as the INCOMING (guest) source — a loopback/aggregate
    /// INPUT carrying the call app's output. The canonical contract is "loopback/aggregate only":
    /// it must have input channels, must NOT be hidden, must NOT be our own NoNoise Mic devices
    /// (matched by UID OR name via `isNoNoiseEngine`/`isNoNoiseVisible` so a UID match with a
    /// differing name is still rejected), and must NOT be a physical mic (built-in/USB/Bluetooth/…).
    /// Known loopbacks (BlackHole/Loopback) are accepted by name even if their transport is reported
    /// as Unknown.
    public static func isSelectableIncomingSource(_ d: DeviceInfo) -> Bool {
        guard d.hasInput, !d.isHidden, !isNoNoiseEngine(d), !isNoNoiseVisible(d) else { return false }
        if physicalInputTransports.contains(d.transportType) { return false }
        // Accept: aggregate/virtual transports, or known loopback names (belt-and-suspenders for
        // drivers that report Unknown transport).
        if d.transportType == transportTypeAggregate || d.transportType == transportTypeVirtual { return true }
        if knownLoopbackNames.contains(where: { d.name.contains($0) }) { return true }
        // Unknown transport + not a known loopback → reject (we only accept proven loopback paths).
        return false
    }

    /// Devices to offer as the incoming source — physical mics, our devices, hidden, and
    /// output-only devices excluded.
    public static func selectableIncomingSources(from devices: [DeviceInfo]) -> [DeviceInfo] {
        devices.filter(isSelectableIncomingSource)
    }

    /// True for a device the user may pick to MONITOR (hear) the cleaned guest — a REAL output.
    /// The canonical contract is "real physical output only". It must HAVE output channels
    /// (`hasOutput`), must NOT be hidden, must NOT be our engine, and must NOT be a re-feed path:
    /// we REJECT virtual transports, aggregate transports, and known loopback sinks (BlackHole/
    /// Loopback). Rejecting aggregate is load-bearing: a Multi-Output / Aggregate device containing
    /// BlackHole + speakers would silently re-feed the incoming source (the captured loopback),
    /// creating a feedback path — so an aggregate is never a valid monitor output even though it
    /// has output channels.
    public static func isSelectableMonitorOutput(_ d: DeviceInfo) -> Bool {
        d.hasOutput
            && !d.isHidden
            && !isNoNoiseEngine(d)
            && d.transportType != transportTypeVirtual
            && d.transportType != transportTypeAggregate
            && !knownLoopbackNames.contains(where: { d.name.contains($0) })
    }

    /// Known software-loopback device names (matched as `contains`). Superset of `fallbackVirtualSinks`
    /// because Loopback (Rogue Amoeba) is also a valid INCOMING source but an invalid MONITOR output.
    private static let knownLoopbackNames = ["BlackHole", "Loopback"]
}
