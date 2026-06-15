import XCTest
@testable import Core

final class IncomingCleanupTests: XCTestCase {

    // MARK: - Helpers

    /// A loopback/aggregate INPUT (e.g. BlackHole, Loopback, an aggregate device).
    private func loopbackInput(_ uid: String, _ name: String,
                               transport: UInt32 = VirtualMicRouting.transportTypeVirtual,
                               hidden: Bool = false) -> VirtualMicRouting.DeviceInfo {
        VirtualMicRouting.DeviceInfo(uid: uid, name: name, isHidden: hidden,
                                     hasOutput: false, hasInput: true, transportType: transport)
    }

    /// A real, physical microphone (built-in / USB / Bluetooth).
    private func physicalMic(_ uid: String, _ name: String,
                             transport: UInt32) -> VirtualMicRouting.DeviceInfo {
        VirtualMicRouting.DeviceInfo(uid: uid, name: name, isHidden: false,
                                     hasOutput: false, hasInput: true, transportType: transport)
    }

    private func output(_ uid: String, _ name: String,
                        transport: UInt32 = VirtualMicRouting.transportTypeBuiltIn,
                        hidden: Bool = false) -> VirtualMicRouting.DeviceInfo {
        VirtualMicRouting.DeviceInfo(uid: uid, name: name, isHidden: hidden,
                                     hasOutput: true, hasInput: false, transportType: transport)
    }

    // MARK: - Incoming source classification

    /// A loopback/aggregate input (BlackHole) IS a valid incoming source.
    func testBlackHoleIsValidIncomingSource() {
        XCTAssertTrue(VirtualMicRouting.isSelectableIncomingSource(loopbackInput("BH:2ch", "BlackHole 2ch")))
    }

    /// An aggregate device (transport = aggregate) IS a valid incoming source.
    func testAggregateIsValidIncomingSource() {
        XCTAssertTrue(VirtualMicRouting.isSelectableIncomingSource(
            loopbackInput("agg:1", "Podcast Aggregate", transport: VirtualMicRouting.transportTypeAggregate)))
    }

    /// THE CONTRACT FIX: a real physical microphone is NOT an incoming source.
    /// (Currently passes the draft predicate — this is the failing-first test that proves the bug.)
    func testPhysicalMicIsNotAnIncomingSource() {
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(
            physicalMic("blt:in", "MacBook Pro Microphone", transport: VirtualMicRouting.transportTypeBuiltIn)))
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(
            physicalMic("usb:mic", "Yeti Stereo Microphone", transport: VirtualMicRouting.transportTypeUSB)))
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(
            physicalMic("bt:ap", "AirPods Pro", transport: VirtualMicRouting.transportTypeBluetooth)))
    }

    /// Our own NoNoise Mic devices are NOT valid incoming sources (would loop the cleaned mic back in).
    func testNoNoiseMicIsNotAnIncomingSource() {
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(
            loopbackInput(VirtualMicRouting.visibleDeviceUID, VirtualMicRouting.visibleDeviceName)))
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(
            loopbackInput(VirtualMicRouting.engineDeviceUID, VirtualMicRouting.engineDeviceName)))
    }

    /// SELF-LOOP FIX: the visible NoNoise Mic is rejected by UID even when its NAME differs
    /// (localised / renamed). The shared contract's strongest id is the UID, so a UID match
    /// with a differing name must STILL be rejected — proves `isNoNoiseVisible` matches by UID.
    func testNoNoiseVisibleRejectedByUIDWhenNameDiffers() {
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(
            loopbackInput(VirtualMicRouting.visibleDeviceUID, "Renamed Virtual Input")))
    }

    /// A device with no input channels is never an incoming source (you can't capture it).
    func testOutputOnlyDeviceIsNotAnIncomingSource() {
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(output("spk:0", "MacBook Pro Speakers")))
    }

    /// A hidden device is never offered as an incoming source.
    func testHiddenDeviceIsNotAnIncomingSource() {
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(
            loopbackInput("hidden:x", "Some Hidden Device", hidden: true)))
    }

    /// The selectable-incoming-source filter drops physical mics + our devices + hidden, keeps loopbacks.
    func testIncomingSourceFilterKeepsLoopbackDropsMicsAndOurs() {
        let devices = [
            loopbackInput("BH:2ch", "BlackHole 2ch"),
            loopbackInput("LB:1", "Loopback Audio"),
            physicalMic("blt:in", "MacBook Pro Microphone", transport: VirtualMicRouting.transportTypeBuiltIn),
            loopbackInput(VirtualMicRouting.visibleDeviceUID, VirtualMicRouting.visibleDeviceName),
            loopbackInput("hidden:x", "Hidden", hidden: true),
        ]
        let kept = VirtualMicRouting.selectableIncomingSources(from: devices).map(\.name)
        XCTAssertEqual(kept, ["BlackHole 2ch", "Loopback Audio"])
    }

    // MARK: - Monitor (hear-them) output classification

    /// A real physical output (built-in speakers / headphones) IS a valid monitor output.
    func testSpeakersAreValidMonitorOutput() {
        XCTAssertTrue(VirtualMicRouting.isSelectableMonitorOutput(output("spk:0", "MacBook Pro Speakers")))
    }

    /// A physical USB / Bluetooth OUTPUT remains a valid monitor output (real output, not a re-feed).
    func testPhysicalUSBAndBluetoothOutputsAreValidMonitorOutputs() {
        XCTAssertTrue(VirtualMicRouting.isSelectableMonitorOutput(
            output("usb:out", "USB Audio Device", transport: VirtualMicRouting.transportTypeUSB)))
        XCTAssertTrue(VirtualMicRouting.isSelectableMonitorOutput(
            output("bt:ap", "AirPods Pro", transport: VirtualMicRouting.transportTypeBluetooth)))
    }

    /// Routing the monitor into a loopback sink (BlackHole) or our engine would re-loop — reject it.
    func testLoopbackAndEngineAreNotMonitorOutputs() {
        XCTAssertFalse(VirtualMicRouting.isSelectableMonitorOutput(
            output("BH:2ch", "BlackHole 2ch", transport: VirtualMicRouting.transportTypeVirtual)))
        XCTAssertFalse(VirtualMicRouting.isSelectableMonitorOutput(
            output(VirtualMicRouting.engineDeviceUID, VirtualMicRouting.engineDeviceName)))
    }

    /// REAL-OUTPUT-ONLY FIX (a): an input-only device (no output channels) is NOT a monitor output,
    /// even if its transport is aggregate. The monitor must actually be able to play audio.
    func testInputOnlyAggregateIsNotAMonitorOutput() {
        XCTAssertFalse(VirtualMicRouting.isSelectableMonitorOutput(
            loopbackInput("agg:in", "Input-Only Aggregate",
                          transport: VirtualMicRouting.transportTypeAggregate)))
    }

    /// REAL-OUTPUT-ONLY FIX (b): a Multi-Output / Aggregate device (BlackHole + speakers) is NOT a
    /// valid monitor output — even though it has output channels — because it would re-feed the
    /// captured loopback and create a feedback path. Aggregate transport is rejected outright.
    func testAggregateMultiOutputIsNotAMonitorOutput() {
        XCTAssertFalse(VirtualMicRouting.isSelectableMonitorOutput(
            output("multi:1", "Multi-Output Device",
                   transport: VirtualMicRouting.transportTypeAggregate)))
    }

    /// REAL-OUTPUT-ONLY FIX (c): a physical built-in OUTPUT (speakers) with output channels remains
    /// valid — guards against the new `hasOutput`/aggregate gates over-rejecting real outputs.
    func testBuiltInOutputRemainsValidMonitorOutput() {
        XCTAssertTrue(VirtualMicRouting.isSelectableMonitorOutput(
            output("spk:builtin", "MacBook Pro Speakers",
                   transport: VirtualMicRouting.transportTypeBuiltIn)))
    }
}
