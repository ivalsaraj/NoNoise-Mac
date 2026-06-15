// nn_clock.h — CoreAudio-free zero-timestamp math for a fixed-period virtual device.
#ifndef NN_CLOCK_H
#define NN_CLOCK_H
#include <stdint.h>

typedef struct {
    uint64_t anchorHostTime;     // host ticks at the moment IO started
    double   hostTicksPerSecond; // mach timebase: ticks per second
    double   sampleRate;         // e.g. 48000.0
    uint32_t periodFrames;       // ring period in frames (e.g. capacityFrames)
    uint64_t sampleTime;         // running zero-timestamp sample position
} nn_clock;

void nn_clock_init(nn_clock *c, uint64_t anchorHostTime, double hostTicksPerSecond,
                   double sampleRate, uint32_t periodFrames);

// Given the current host time, advance to the latest period boundary at or before it.
// Writes the zero-timestamp pair. Returns the number of periods advanced this call.
uint32_t nn_clock_get_zero_timestamp(nn_clock *c, uint64_t currentHostTime,
                                     uint64_t *outSampleTime, uint64_t *outHostTime);
#endif
