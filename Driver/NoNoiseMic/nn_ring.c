#include "nn_ring.h"
#include <string.h>

static int is_pow2(uint32_t x) { return x != 0 && (x & (x - 1)) == 0; }

int nn_ring_init(nn_ring *r, float *storage, uint32_t capacityFrames, uint32_t channels) {
    if (!r || !storage || channels == 0 || !is_pow2(capacityFrames)) return -1;
    r->storage = storage;
    r->capacityFrames = capacityFrames;
    r->channels = channels;
    atomic_store_explicit(&r->writeEnd, 0, memory_order_relaxed);
    return 0;
}

void nn_ring_clear(nn_ring *r) {
    memset(r->storage, 0, (size_t)r->capacityFrames * r->channels * sizeof(float));
    atomic_store_explicit(&r->writeEnd, 0, memory_order_relaxed);
}

void nn_ring_write_at(nn_ring *r, uint64_t sampleTime, const float *src, uint32_t frames) {
    const uint32_t mask = r->capacityFrames - 1;
    const uint32_t ch = r->channels;
    for (uint32_t i = 0; i < frames; i++) {
        uint32_t slot = (uint32_t)((sampleTime + i) & mask);
        memcpy(&r->storage[(size_t)slot * ch], &src[(size_t)i * ch], ch * sizeof(float));
    }
    // Publish the watermark AFTER the slot writes (release): a reader that observes this end is
    // guaranteed to also observe the frame data. Single writer ⇒ a plain max, no CAS needed.
    uint64_t end = sampleTime + frames;
    if (end > atomic_load_explicit(&r->writeEnd, memory_order_relaxed)) {
        atomic_store_explicit(&r->writeEnd, end, memory_order_release);
    }
}

void nn_ring_read_at(nn_ring *r, uint64_t sampleTime, float *dst, uint32_t frames) {
    const uint32_t mask = r->capacityFrames - 1;
    const uint32_t ch = r->channels;
    // Acquire pairs with the writer's release so valid frames carry their data.
    const uint64_t end = atomic_load_explicit(&r->writeEnd, memory_order_acquire);
    const uint64_t earliest = (end > r->capacityFrames) ? (end - r->capacityFrames) : 0;
    for (uint32_t i = 0; i < frames; i++) {
        uint64_t pos = sampleTime + i;
        if (pos < earliest || pos >= end) {
            memset(&dst[(size_t)i * ch], 0, ch * sizeof(float)); // un-written / overwritten ⇒ silence
        } else {
            uint32_t slot = (uint32_t)(pos & mask);
            memcpy(&dst[(size_t)i * ch], &r->storage[(size_t)slot * ch], ch * sizeof(float));
        }
    }
}
