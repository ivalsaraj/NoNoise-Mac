#include "nn_clock.h"

void nn_clock_init(nn_clock *c, uint64_t anchorHostTime, double hostTicksPerSecond,
                   double sampleRate, uint32_t periodFrames) {
    c->anchorHostTime = anchorHostTime;
    c->hostTicksPerSecond = hostTicksPerSecond;
    c->sampleRate = sampleRate;
    c->periodFrames = periodFrames;
    c->sampleTime = 0;
}

// O(1): compute the latest period boundary at/below `currentHostTime` DIRECTLY. Never loop
// once per missed period — a sleep/debugger/scheduling gap must not spin inside the HAL
// timing path. Monotonic: sampleTime never regresses.
uint32_t nn_clock_get_zero_timestamp(nn_clock *c, uint64_t currentHostTime,
                                     uint64_t *outSampleTime, uint64_t *outHostTime) {
    const double periodTicks = ((double)c->periodFrames / c->sampleRate) * c->hostTicksPerSecond;
    uint64_t newSample = c->sampleTime;
    if (currentHostTime > c->anchorHostTime && periodTicks > 0.0) {
        double elapsed = (double)(currentHostTime - c->anchorHostTime);
        uint64_t periodIndex = (uint64_t)(elapsed / periodTicks);   // floor → boundary at/below now
        newSample = periodIndex * (uint64_t)c->periodFrames;
    }
    if (newSample < c->sampleTime) newSample = c->sampleTime;        // monotonic clamp
    uint32_t advanced = (uint32_t)((newSample - c->sampleTime) / c->periodFrames);
    c->sampleTime = newSample;
    double curHostOffset = ((double)c->sampleTime / c->sampleRate) * c->hostTicksPerSecond;
    *outSampleTime = c->sampleTime;
    *outHostTime = c->anchorHostTime + (uint64_t)curHostOffset;
    return advanced;
}
