import XCTest
@testable import Core

final class SmartLevelControllerTests: XCTestCase {

    func testInputVolumeDefaultIsUnity() {
        XCTAssertEqual(SmartLevelController.defaultInputVolume, 1.0)
        XCTAssertEqual(SmartLevelController.runtimeInputVolume(for: 1.0), 1.0)
    }

    func testInputVolumeScalesSamples() {
        var buf = [Float](repeating: 0.8, count: 64)
        SmartLevelController.applyInputVolume(&buf, volume: 0.5)
        XCTAssertTrue(buf.allSatisfy { abs($0 - 0.4) < 1e-6 })
    }

    func testRawPeakReportsPreTrimClippingWhenTrimmedIsSafe() {
        let raw = [Float](repeating: 1.0, count: 32)
        var trimmed = raw
        SmartLevelController.applyInputVolume(&trimmed, volume: 0.5)
        XCTAssertTrue(SmartLevelController.isClipping(SmartLevelController.measurePeak(raw)))
        XCTAssertFalse(SmartLevelController.isClipping(SmartLevelController.measurePeak(trimmed)))
    }

    func testSmartLevelReducesInputVolumeAfterRepeatedHotWindows() {
        var ticks = 0
        for _ in 0..<SmartLevelController.hotTickThreshold {
            ticks = SmartLevelController.advanceHotTicks(current: ticks, wasHot: true)
        }
        let next = SmartLevelController.nextInputVolume(current: 1.0, hotTicks: ticks, enabled: true)
        XCTAssertNotNil(next)
        XCTAssertLessThan(next!, 1.0)
        XCTAssertGreaterThanOrEqual(next!, SmartLevelController.minAutoInputVolume)
    }

    func testSmartLevelDoesNotReduceFromSingleIsolatedPeak() {
        let ticks = SmartLevelController.advanceHotTicks(current: 0, wasHot: true)
        XCTAssertNil(SmartLevelController.nextInputVolume(current: 1.0, hotTicks: ticks, enabled: true))
    }

    func testSmartLevelReducesOutputGainWhenOutputClipsButInputNotHot() {
        var clipTicks = 0
        for _ in 0..<SmartLevelController.hotTickThreshold {
            clipTicks = SmartLevelController.advanceHotTicks(current: clipTicks, wasHot: true)
        }
        let next = SmartLevelController.nextOutputGain(current: 1.0, outputClipTicks: clipTicks,
                                                       inputHotTicks: 0, enabled: true)
        XCTAssertNotNil(next)
        XCTAssertLessThan(next!, 1.0)
    }

    func testSmartLevelNeverBoostsInputVolume() {
        var ticks = 0
        for _ in 0..<SmartLevelController.hotTickThreshold { ticks += 1 }
        let next = SmartLevelController.nextInputVolume(current: 0.5, hotTicks: ticks, enabled: true)
        XCTAssertNotNil(next)
        XCTAssertLessThan(next!, 0.5)
    }

    func testSmartLevelRespectsAutomaticFloor() {
        var ticks = 0
        for _ in 0..<SmartLevelController.hotTickThreshold { ticks += 1 }
        let next = SmartLevelController.nextInputVolume(current: SmartLevelController.minAutoInputVolume,
                                                        hotTicks: ticks, enabled: true)
        XCTAssertNil(next)
    }

    func testRuntimeScalarMirrorsInputVolumeValue() {
        let ui: Float = 0.73
        XCTAssertEqual(SmartLevelController.runtimeInputVolume(for: ui), 0.73, accuracy: 1e-6)
        XCTAssertEqual(SmartLevelController.runtimeInputVolume(for: 0.1), SmartLevelController.minInputVolume)
    }

    func testPeakWindowLatchesMaxUntilSnapshot() {
        var windowPeak: Float = 0
        windowPeak = SmartLevelController.latchPeak(existing: windowPeak, bufferPeak: 0.2)
        windowPeak = SmartLevelController.latchPeak(existing: windowPeak, bufferPeak: 0.95)
        windowPeak = SmartLevelController.latchPeak(existing: windowPeak, bufferPeak: 0.1)
        XCTAssertEqual(windowPeak, 0.95, accuracy: 1e-6)
    }

    func testQuietBufferDoesNotHidePriorClipInWindow() {
        var windowPeak: Float = 0
        windowPeak = SmartLevelController.latchPeak(existing: windowPeak, bufferPeak: 0.999)
        windowPeak = SmartLevelController.latchPeak(existing: windowPeak, bufferPeak: 0.01)
        XCTAssertTrue(SmartLevelController.isClipping(windowPeak))
    }

    func testSourceMicClippingReportsRawClipEvenWhenTrimmedIsHot() {
        let rawPeak: Float = 1.0
        let trimmedPeak: Float = 0.99
        XCTAssertTrue(SmartLevelController.isSourceMicClipping(rawPeak: rawPeak, rawClipSampleCount: 1))
        XCTAssertTrue(SmartLevelController.isNearCeiling(trimmedPeak))
    }
}
