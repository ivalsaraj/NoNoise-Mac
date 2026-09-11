import XCTest
@testable import Core

final class VirtualMicRoutingTests: XCTestCase {
    // uid is DELIBERATELY distinct from name so UID-based selection is actually exercised
    // (the runtime resolves the returned UID to an AudioObjectID — the name cannot be translated).
    private func dev(_ name: String, uid: String? = nil, hidden: Bool = false) -> VirtualMicRouting.DeviceInfo {
        .init(uid: uid ?? "uid:\(name)", name: name, isHidden: hidden, hasOutput: true)
    }

    func testAutoRoutePrefersEngineDevice() {
        let list = [dev("BlackHole 2ch", uid: "BH-uid"),
                    dev(VirtualMicRouting.engineDeviceName, uid: VirtualMicRouting.engineDeviceUID, hidden: true),
                    dev("MacBook Speakers")]
        // Returns the engine device's UID (not its name) — the exact value runtime resolves to an ID.
        XCTAssertEqual(VirtualMicRouting.preferredOutputUID(from: list), VirtualMicRouting.engineDeviceUID)
    }

    func testAutoRouteFallsBackToBlackHoleWhenNoEngine() {
        let list = [dev("BlackHole 2ch", uid: "BH-uid"), dev("MacBook Speakers")]
        XCTAssertEqual(VirtualMicRouting.preferredOutputUID(from: list), "BH-uid")
    }

    func testAutoRouteNeverPicksPhysicalOutput() {
        // No virtual sink present → must NOT auto-route to a physical device.
        let list = [dev("MacBook Speakers"), dev("USB Headphones")]
        XCTAssertNil(VirtualMicRouting.preferredOutputUID(from: list))
    }

    func testHiddenEngineFilteredFromOutputPicker() {
        let list = [dev("BlackHole 2ch", uid: "BH-uid"),
                    dev(VirtualMicRouting.engineDeviceName, uid: VirtualMicRouting.engineDeviceUID, hidden: true)]
        let visible = VirtualMicRouting.visibleOutputs(from: list).map(\.name)
        XCTAssertFalse(visible.contains(VirtualMicRouting.engineDeviceName))
        XCTAssertTrue(visible.contains("BlackHole 2ch"))
    }

    func testEngineFilteredByUIDEvenIfHiddenFlagMissing() {
        // Guard-pair: if the HAL fails to report kAudioDevicePropertyIsHidden, the engine
        // must STILL be excluded from the picker by its known UID.
        let list = [dev("BlackHole 2ch", uid: "BH-uid"),
                    dev(VirtualMicRouting.engineDeviceName, uid: VirtualMicRouting.engineDeviceUID, hidden: false)]
        let visible = VirtualMicRouting.visibleOutputs(from: list).map(\.name)
        XCTAssertFalse(visible.contains(VirtualMicRouting.engineDeviceName))
    }

    func testVirtualMicFilteredFromInputList() {
        let inputs = ["Built-in Microphone", VirtualMicRouting.visibleDeviceName, "USB Mic"]
        let filtered = VirtualMicRouting.filterInputs(inputs)
        XCTAssertFalse(filtered.contains(VirtualMicRouting.visibleDeviceName))
        XCTAssertEqual(filtered, ["Built-in Microphone", "USB Mic"])
    }

    func testHardwareRefreshRepinsEngineEvenWhenSelectedIDIsUnchanged() {
        XCTAssertTrue(VirtualMicRouting.shouldRepinPlaybackAfterHardwareRefresh(
            preferredRouteUID: VirtualMicRouting.engineDeviceUID,
            previousOutputDeviceID: 75,
            resolvedOutputDeviceID: 75
        ))
    }

    func testHardwareRefreshDoesNotForceRepinForBlackHoleWhenSelectedIDIsUnchanged() {
        XCTAssertFalse(VirtualMicRouting.shouldRepinPlaybackAfterHardwareRefresh(
            preferredRouteUID: "BlackHoleUID",
            previousOutputDeviceID: 12,
            resolvedOutputDeviceID: 12
        ))
    }

    // MARK: - Playback route resolution (the engine must NEVER bind to a physical output)

    func testPlaybackRouteUsesPublishedSelectionWhenAvailable() {
        XCTAssertEqual(VirtualMicRouting.playbackRouteID(selected: 75, resolvedEngine: 70), 75)
    }

    func testPlaybackRouteFallsBackToResolvedEngineBeforeSelectionIsPublished() {
        // `init()` calls setupPlaybackEngine() before fetchOutputDevices()'s DEFERRED main-queue
        // block publishes the selection, so `selected` is still 0 on that first call.
        XCTAssertEqual(VirtualMicRouting.playbackRouteID(selected: 0, resolvedEngine: 70), 70)
    }

    func testPlaybackRouteIsNilWhenNoVirtualSinkResolves() {
        // nil means DO NOT START the engine. An unpinned AVAudioEngine binds to the SYSTEM DEFAULT
        // OUTPUT — it played the cleaned voice into the user's Bluetooth headphones while
        // "NoNoise Mic" served digital silence (2026-09-11 regression).
        XCTAssertNil(VirtualMicRouting.playbackRouteID(selected: 0, resolvedEngine: 0))
    }
}
