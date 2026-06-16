#include "tap_ring.h"
#include <string.h>

static int is_pow2(uint32_t x) { return x != 0 && (x & (x - 1)) == 0; }

int tap_ring_init(tap_ring *r, float *storage, uint32_t capacity) {
    if (!r || !storage || !is_pow2(capacity)) return -1;
    r->storage = storage;
    r->capacity = capacity;
    atomic_store_explicit(&r->writeIndex, 0, memory_order_relaxed);
    atomic_store_explicit(&r->readIndex, 0, memory_order_relaxed);
    return 0;
}

void tap_ring_clear(tap_ring *r) {
    // Consumer-side: advance readIndex up to the producer's published writeIndex (acquire so we
    // don't drain past produced data). Never moves writeIndex, so it can't corrupt a live producer.
    uint64_t w = atomic_load_explicit(&r->writeIndex, memory_order_acquire);
    atomic_store_explicit(&r->readIndex, w, memory_order_release);
}

uint32_t tap_ring_available(const tap_ring *r) {
    uint64_t w  = atomic_load_explicit(&r->writeIndex, memory_order_acquire);
    uint64_t rd = atomic_load_explicit(&r->readIndex,  memory_order_acquire);
    return (uint32_t)(w - rd);
}

uint32_t tap_ring_write(tap_ring *r, const float *src, uint32_t count) {
    uint64_t w  = atomic_load_explicit(&r->writeIndex, memory_order_relaxed); // producer owns it
    uint64_t rd = atomic_load_explicit(&r->readIndex,  memory_order_acquire); // see consumer's progress
    uint32_t used = (uint32_t)(w - rd);
    uint32_t freeFrames = r->capacity - used;
    uint32_t n = count < freeFrames ? count : freeFrames;
    if (n == 0) return 0;
    const uint32_t mask = r->capacity - 1;
    uint32_t head = (uint32_t)(w & mask);
    uint32_t first = r->capacity - head;
    if (first > n) first = n;
    memcpy(&r->storage[head], src, (size_t)first * sizeof(float));
    if (n > first) memcpy(&r->storage[0], src + first, (size_t)(n - first) * sizeof(float));
    // Publish AFTER the slot writes (release): a consumer that observes this writeIndex is
    // guaranteed to also observe the sample bytes (pairs with the acquire-load in tap_ring_read).
    atomic_store_explicit(&r->writeIndex, w + n, memory_order_release);
    return n;
}

int tap_ring_read(tap_ring *r, float *dst, uint32_t count) {
    uint64_t w  = atomic_load_explicit(&r->writeIndex, memory_order_acquire); // see producer's data
    uint64_t rd = atomic_load_explicit(&r->readIndex,  memory_order_relaxed); // consumer owns it
    if ((uint32_t)(w - rd) < count) return 0;            // underflow → caller fills silence
    const uint32_t mask = r->capacity - 1;
    uint32_t tail = (uint32_t)(rd & mask);
    uint32_t first = r->capacity - tail;
    if (first > count) first = count;
    memcpy(dst, &r->storage[tail], (size_t)first * sizeof(float));
    if (count > first) memcpy(dst + first, &r->storage[0], (size_t)(count - first) * sizeof(float));
    // Publish the freed slots AFTER copying them out (release): the producer (which acquire-loads
    // readIndex) won't overwrite a slot until the consumer has finished reading it.
    atomic_store_explicit(&r->readIndex, rd + count, memory_order_release);
    return 1;
}

void tap_ring_drop(tap_ring *r, uint32_t count) {
    uint64_t w  = atomic_load_explicit(&r->writeIndex, memory_order_acquire);
    uint64_t rd = atomic_load_explicit(&r->readIndex,  memory_order_relaxed);
    uint32_t avail = (uint32_t)(w - rd);
    uint32_t n = count < avail ? count : avail;
    atomic_store_explicit(&r->readIndex, rd + n, memory_order_release);
}
