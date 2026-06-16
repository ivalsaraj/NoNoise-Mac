// tap_ring.h — CoreAudio-free lock-free single-producer / single-consumer float FIFO.
//
// Bridges the two REALTIME threads of the tap-based "Clean Incoming" path:
//   producer = the Core Audio process-tap IOProc (HAL realtime IO thread)
//   consumer = the AVAudioSourceNode render block (audio render thread)
//
// No locks, no allocation, no syscalls in write/read/drop/available — so it is safe between two
// realtime threads (a lock here, e.g. RingBuffer's os_unfair_lock, risks priority inversion /
// dropouts). Memory-ordering discipline mirrors the driver's tested nn_ring.h: the producer
// publishes `writeIndex` with release AFTER copying samples; the consumer publishes `readIndex`
// with release AFTER copying them out; each thread loads the OTHER thread's index with acquire,
// so a sample is visible to the reader iff the index that exposes it is visible.
#ifndef TAP_RING_H
#define TAP_RING_H

#include <stdint.h>
#include <stdatomic.h>

typedef struct {
    float   *storage;        // caller-owned: `capacity` floats (mono frames)
    uint32_t capacity;       // MUST be a power of two
    // Absolute, monotonically-increasing frame counters (never wrap in practice at 48 kHz: u64).
    // `writeIndex` is advanced ONLY by the producer (released after the sample copy); `readIndex`
    // ONLY by the consumer (released after the copy-out). The opposite thread acquire-loads them.
    _Atomic uint64_t writeIndex;
    _Atomic uint64_t readIndex;
} tap_ring;

// Initialize over caller-owned storage. `capacity` MUST be a power of two.
// Returns 0 on success, -1 on bad args.
int tap_ring_init(tap_ring *r, float *storage, uint32_t capacity);

// Consumer-side drain: advance readIndex to writeIndex so the FIFO reads empty. Safe to call when
// the producer is stopped (teardown); never moves writeIndex, so it cannot race a live producer.
void tap_ring_clear(tap_ring *r);

// Producer: append up to `count` mono frames from `src`. Returns the number actually written
// (fewer than `count` only when the FIFO is near-full; the overflow is dropped, never blocks).
uint32_t tap_ring_write(tap_ring *r, const float *src, uint32_t count);

// Consumer: read EXACTLY `count` frames into `dst`. Returns 1 if `count` frames were available and
// copied; 0 on underflow (and `dst` is left untouched — the caller fills silence). All-or-nothing
// matches the existing RingBuffer.read(into:count:) contract the source node already relies on.
int tap_ring_read(tap_ring *r, float *dst, uint32_t count);

// Consumer: number of frames currently available to read.
uint32_t tap_ring_available(const tap_ring *r);

// Consumer: discard up to `count` oldest frames (latency trim). Never moves past writeIndex.
void tap_ring_drop(tap_ring *r, uint32_t count);

#endif /* TAP_RING_H */
