import XCTest
import CoreAudio
@testable import Core

/// Host unit tests for the pure, ungated decisions behind the tap-based Clean Incoming path
/// (`IncomingTapLogic`). These run on ANY host (no macOS 14.4 gate, no CoreAudio objects) — the
/// risky realtime/HAL code stays in the `@available` engine, the decisions live here and are tested.
final class IncomingTapLogicTests: XCTestCase {

    // MARK: own-process-object validity (global-exclude tap must NOT be built around an unknown id)

    func testValidProcessObjectRequiresNoErrAndRealID() {
        XCTAssertTrue(IncomingTapLogic.isValidProcessObject(status: noErr, id: AudioObjectID(42)))
    }

    func testInvalidWhenStatusIsError() {
        XCTAssertFalse(IncomingTapLogic.isValidProcessObject(status: OSStatus(-1), id: AudioObjectID(42)))
    }

    func testInvalidWhenIDIsZero() {
        XCTAssertFalse(IncomingTapLogic.isValidProcessObject(status: noErr, id: AudioObjectID(0)))
    }

    func testInvalidWhenIDIsUnknown() {
        XCTAssertFalse(IncomingTapLogic.isValidProcessObject(status: noErr,
                                                             id: AudioObjectID(kAudioObjectUnknown)))
    }

    // MARK: re-pin vs full-rebuild on default-output / hardware change

    func testRepinWhenTapStillAlive() {
        XCTAssertEqual(IncomingTapLogic.repinDecision(tapAlive: true), .repin)
    }

    func testRebuildWhenTapDied() {
        XCTAssertEqual(IncomingTapLogic.repinDecision(tapAlive: false), .rebuild)
    }
}
