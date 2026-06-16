import XCTest
@testable import Core

/// Host unit tests for the lock-free SPSC ring (`TapAudioRing` over the C `tap_ring`). Mirrors the
/// driver's `nn_ring` host tests: fill / drain / wraparound / overflow / underflow / drop / clear.
/// These exercise the pure FIFO math single-threaded (the atomics' cross-thread visibility is the
/// same discipline as the tested `nn_ring`, validated there + by the realtime smoke matrix).
final class TapAudioRingTests: XCTestCase {

    /// Append `values` via the producer API; returns the number of frames actually written.
    @discardableResult
    private func write(_ ring: TapAudioRing, _ values: [Float]) -> Int {
        values.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: values.count) }
    }

    /// Read EXACTLY `count` frames; returns the frames on success, nil on underflow.
    private func read(_ ring: TapAudioRing, _ count: Int) -> [Float]? {
        var out = [Float](repeating: .nan, count: count)
        let ok = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: count) }
        return ok ? out : nil
    }

    func testCapacityRoundsUpToPowerOfTwo() {
        XCTAssertEqual(TapAudioRing(capacityFrames: 1000).capacity, 1024)
        XCTAssertEqual(TapAudioRing(capacityFrames: 1024).capacity, 1024)
        XCTAssertEqual(TapAudioRing(capacityFrames: 1025).capacity, 2048)
    }

    func testWriteThenReadRoundTrips() {
        let ring = TapAudioRing(capacityFrames: 8)
        XCTAssertEqual(write(ring, [1, 2, 3, 4]), 4)
        XCTAssertEqual(ring.availableToRead, 4)
        XCTAssertEqual(read(ring, 4), [1, 2, 3, 4])
        XCTAssertEqual(ring.availableToRead, 0)
    }

    func testReadUnderflowReturnsFalseAndLeavesDestUntouched() {
        let ring = TapAudioRing(capacityFrames: 8)
        write(ring, [9, 8])                       // only 2 available
        var dst: [Float] = [-1, -1, -1, -1]
        let ok = dst.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: 4) }
        XCTAssertFalse(ok)
        XCTAssertEqual(dst, [-1, -1, -1, -1])     // all-or-nothing: dst untouched on underflow
        XCTAssertEqual(ring.availableToRead, 2)   // and nothing was consumed
    }

    func testWraparoundPreservesOrder() {
        let ring = TapAudioRing(capacityFrames: 8)   // capacity 8
        write(ring, [1, 2, 3, 4, 5, 6])              // write 6
        XCTAssertEqual(read(ring, 6), [1, 2, 3, 4, 5, 6])
        // read=write=6; the next 6-frame write straddles the capacity boundary (head=6).
        write(ring, [10, 20, 30, 40, 50, 60])
        XCTAssertEqual(read(ring, 6), [10, 20, 30, 40, 50, 60])
    }

    func testWriteOverflowWritesOnlyFreeFramesAndDropsRest() {
        let ring = TapAudioRing(capacityFrames: 8)   // can hold exactly 8
        XCTAssertEqual(write(ring, Array(repeating: 1, count: 10)), 8)   // 2 dropped
        XCTAssertEqual(ring.availableToRead, 8)
        XCTAssertEqual(write(ring, [99]), 0)         // full → writes nothing, never blocks
    }

    func testDropAdvancesReadButNeverPastWrite() {
        let ring = TapAudioRing(capacityFrames: 8)
        write(ring, [1, 2, 3, 4])
        ring.drop(2)
        XCTAssertEqual(ring.availableToRead, 2)
        XCTAssertEqual(read(ring, 2), [3, 4])
        write(ring, [5, 6])
        ring.drop(100)                               // clamps to available; never overruns writeIndex
        XCTAssertEqual(ring.availableToRead, 0)
    }

    func testClearDrainsToEmpty() {
        let ring = TapAudioRing(capacityFrames: 8)
        write(ring, [1, 2, 3, 4, 5])
        ring.clear()
        XCTAssertEqual(ring.availableToRead, 0)
        XCTAssertNil(read(ring, 1))                  // empty → underflow
    }
}
