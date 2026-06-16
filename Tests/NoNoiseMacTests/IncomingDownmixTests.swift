import XCTest
import CoreAudio
import CTapRing
@testable import Core

/// Host unit tests for the tap IOProc's channel downmix (`IncomingCleanupEngine.downmixToRing`).
/// The reviewer flagged this as the one piece of new realtime DSP that the pure ring/repin tests
/// didn't cover, so we exercise the actual runtime function directly: mono pass-through, interleaved
/// N→mono averaging, planar N→mono averaging, and chunking when a buffer exceeds the scratch capacity.
///
/// The function is gated `@available(macOS 14.4, *)` (it lives on the tap engine), so every test
/// `guard #available` and `XCTSkip`s on older hosts — same floor as the feature itself.
final class IncomingDownmixTests: XCTestCase {

    // MARK: - Builders (no CoreAudio device needed — plain in-memory buffers)

    /// Heap Float buffer initialized from `values` (caller frees).
    private func makeFloatBuffer(_ values: [Float]) -> UnsafeMutablePointer<Float> {
        let p = UnsafeMutablePointer<Float>.allocate(capacity: max(1, values.count))
        p.initialize(repeating: 0, count: max(1, values.count))
        for i in values.indices { p[i] = values[i] }
        return p
    }

    /// Drain EXACTLY `count` frames from the ring (nil on underflow).
    private func drain(_ ring: TapAudioRing, _ count: Int) -> [Float]? {
        var out = [Float](repeating: .nan, count: count)
        let ok = out.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: count) }
        return ok ? out : nil
    }

    // MARK: - Tests

    func testMonoPassesThroughUnchanged() throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("process tap path requires macOS 14.4+") }
        let frames = [Float]([5, 6, 7, 8])
        let src = makeFloatBuffer(frames)
        defer { src.deinitialize(count: frames.count); src.deallocate() }

        let abl = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(abl.unsafeMutablePointer) }
        abl[0] = AudioBuffer(mNumberChannels: 1,
                             mDataByteSize: UInt32(frames.count * MemoryLayout<Float>.size),
                             mData: UnsafeMutableRawPointer(src))

        let ring = TapAudioRing(capacityFrames: 64)
        let scratch = makeFloatBuffer([Float](repeating: 0, count: 64))
        defer { scratch.deinitialize(count: 64); scratch.deallocate() }

        IncomingCleanupEngine.downmixToRing(abl: abl, channels: 1, interleaved: true,
                                            scratch: scratch, scratchCap: 64, ring: ring.cRing)

        XCTAssertEqual(ring.availableToRead, frames.count)
        XCTAssertEqual(drain(ring, frames.count), frames)
    }

    func testInterleavedStereoAveragesToMono() throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("process tap path requires macOS 14.4+") }
        // [L,R] interleaved: (1,3)(2,6)(3,9)(4,12) → mono mean = 2,4,6,8
        let interleaved = [Float]([1, 3, 2, 6, 3, 9, 4, 12])
        let nFrames = interleaved.count / 2
        let src = makeFloatBuffer(interleaved)
        defer { src.deinitialize(count: interleaved.count); src.deallocate() }

        let abl = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(abl.unsafeMutablePointer) }
        abl[0] = AudioBuffer(mNumberChannels: 2,
                             mDataByteSize: UInt32(interleaved.count * MemoryLayout<Float>.size),
                             mData: UnsafeMutableRawPointer(src))

        let ring = TapAudioRing(capacityFrames: 64)
        let scratch = makeFloatBuffer([Float](repeating: 0, count: 64))
        defer { scratch.deinitialize(count: 64); scratch.deallocate() }

        IncomingCleanupEngine.downmixToRing(abl: abl, channels: 2, interleaved: true,
                                            scratch: scratch, scratchCap: 64, ring: ring.cRing)

        XCTAssertEqual(ring.availableToRead, nFrames)
        let out = try XCTUnwrap(drain(ring, nFrames))
        XCTAssertEqual(out, [2, 4, 6, 8])
    }

    func testPlanarStereoAveragesToMono() throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("process tap path requires macOS 14.4+") }
        // Non-interleaved: L=[1,2,3,4], R=[3,6,9,12] → mono mean = 2,4,6,8
        let left = [Float]([1, 2, 3, 4])
        let right = [Float]([3, 6, 9, 12])
        let lPtr = makeFloatBuffer(left)
        let rPtr = makeFloatBuffer(right)
        defer {
            lPtr.deinitialize(count: left.count); lPtr.deallocate()
            rPtr.deinitialize(count: right.count); rPtr.deallocate()
        }

        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(abl.unsafeMutablePointer) }
        let byteSize = UInt32(left.count * MemoryLayout<Float>.size)
        abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: UnsafeMutableRawPointer(lPtr))
        abl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: byteSize, mData: UnsafeMutableRawPointer(rPtr))

        let ring = TapAudioRing(capacityFrames: 64)
        let scratch = makeFloatBuffer([Float](repeating: 0, count: 64))
        defer { scratch.deinitialize(count: 64); scratch.deallocate() }

        IncomingCleanupEngine.downmixToRing(abl: abl, channels: 2, interleaved: false,
                                            scratch: scratch, scratchCap: 64, ring: ring.cRing)

        XCTAssertEqual(ring.availableToRead, left.count)
        let out = try XCTUnwrap(drain(ring, left.count))
        XCTAssertEqual(out, [2, 4, 6, 8])
    }

    /// A buffer larger than the scratch capacity must be chunked into the ring IN ORDER (the IOProc's
    /// `while off < frames` loop), never dropped or reordered.
    func testInterleavedChunksAcrossScratchCapacity() throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("process tap path requires macOS 14.4+") }
        // 8 stereo frames, L=n, R=n+100 → mono mean = n+50 for n in 1...8
        var interleaved: [Float] = []
        var expected: [Float] = []
        for n in 1...8 {
            interleaved.append(Float(n)); interleaved.append(Float(n + 100))
            expected.append(Float(n) + 50)
        }
        let src = makeFloatBuffer(interleaved)
        defer { src.deinitialize(count: interleaved.count); src.deallocate() }

        let abl = AudioBufferList.allocate(maximumBuffers: 1)
        defer { free(abl.unsafeMutablePointer) }
        abl[0] = AudioBuffer(mNumberChannels: 2,
                             mDataByteSize: UInt32(interleaved.count * MemoryLayout<Float>.size),
                             mData: UnsafeMutableRawPointer(src))

        let ring = TapAudioRing(capacityFrames: 64)
        let scratch = makeFloatBuffer([Float](repeating: 0, count: 3))   // cap 3 < 8 frames → 3 chunks
        defer { scratch.deinitialize(count: 3); scratch.deallocate() }

        IncomingCleanupEngine.downmixToRing(abl: abl, channels: 2, interleaved: true,
                                            scratch: scratch, scratchCap: 3, ring: ring.cRing)

        XCTAssertEqual(ring.availableToRead, expected.count)
        let out = try XCTUnwrap(drain(ring, expected.count))
        XCTAssertEqual(out, expected)
    }
}
