import Foundation
import CTapRing

/// Swift owner of the lock-free C11 SPSC float ring (`tap_ring`) that bridges the tap IOProc
/// (producer) and the `AVAudioSourceNode` render block (consumer) in the tap-based Clean Incoming
/// path. Both are realtime threads, so a locking `RingBuffer` must NOT bridge them — this ring is
/// allocation/lock/syscall-free in write/read/drop/available (see `tap_ring.h`).
///
/// The underlying `tap_ring` struct holds C `_Atomic` indices, so it MUST live at a stable heap
/// address and never be copied/moved by Swift — hence it's boxed in an `UnsafeMutablePointer` and
/// only ever touched through the C functions. Realtime callers capture `cRing` (and pass their own
/// pre-allocated scratch) so the audio path makes zero Swift method/ARC calls on this object.
///
/// Threading contract: `write` is producer-only; `read`/`drop`/`availableToRead`/`clear` are
/// consumer-only (or called while the producer is stopped).
public final class TapAudioRing {
    /// Raw pointer to the C ring, for realtime callers to use with `tap_ring_*` directly (no ARC).
    public let cRing: UnsafeMutablePointer<tap_ring>
    private let storage: UnsafeMutablePointer<Float>
    public let capacity: Int

    /// `capacityFrames` is rounded UP to the next power of two (the C ring masks by capacity).
    public init(capacityFrames: Int) {
        let cap = TapAudioRing.nextPowerOfTwo(max(2, capacityFrames))
        self.capacity = cap
        self.storage = UnsafeMutablePointer<Float>.allocate(capacity: cap)
        self.storage.initialize(repeating: 0, count: cap)
        self.cRing = UnsafeMutablePointer<tap_ring>.allocate(capacity: 1)
        // tap_ring_init fully writes every field (storage/capacity/atomics) over the raw allocation.
        _ = tap_ring_init(cRing, storage, UInt32(cap))
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
        cRing.deallocate()
    }

    /// Producer: append `count` frames; returns frames actually written (drops overflow, never blocks).
    @discardableResult
    public func write(_ src: UnsafePointer<Float>, count: Int) -> Int {
        Int(tap_ring_write(cRing, src, UInt32(count)))
    }

    /// Consumer: read EXACTLY `count` frames; returns false on underflow (dst left untouched).
    public func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        tap_ring_read(cRing, dst, UInt32(count)) != 0
    }

    /// Consumer: frames currently available to read.
    public var availableToRead: Int { Int(tap_ring_available(cRing)) }

    /// Consumer: discard up to `count` oldest frames (latency trim).
    public func drop(_ count: Int) { tap_ring_drop(cRing, UInt32(count)) }

    /// Consumer-side drain (call only while the producer is stopped, e.g. teardown).
    public func clear() { tap_ring_clear(cRing) }

    private static func nextPowerOfTwo(_ n: Int) -> Int {
        var v = 1
        while v < n { v <<= 1 }
        return v
    }
}
