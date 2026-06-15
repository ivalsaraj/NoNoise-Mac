import XCTest
@testable import Core

final class DeepFilterNetDSPTests: XCTestCase {
    func testReadinessIsInitiallyFalseForFreshDSP() {
        let dsp = DeepFilterNetDSP()
        XCTAssertFalse(dsp.isReady)
    }
}
