#include "../NoNoiseMic/nn_clock.h"
#include <stdio.h>

static int failures = 0;
#define CHECK(c,m) do{ if(!(c)){ printf("FAIL: %s\n", m); failures++; } }while(0)

int main(void) {
    // 1 GHz host clock, 48k sr, 512-frame period. One period = 512/48000 s = 10666.67us
    // = 10666666.67 host ticks.
    nn_clock c;
    nn_clock_init(&c, /*anchor*/1000, /*ticks/s*/1e9, /*sr*/48000.0, /*period*/512);
    uint64_t st = 0, ht = 0;
    double periodTicks = (512.0 / 48000.0) * 1e9; // ~10,666,666.67

    // Just after the first full period: sampleTime should be 0 then advance to 512.
    nn_clock_get_zero_timestamp(&c, 1000 + (uint64_t)(periodTicks * 0.5), &st, &ht);
    CHECK(st == 0, "before the first boundary, sampleTime stays 0");

    nn_clock_get_zero_timestamp(&c, 1000 + (uint64_t)(periodTicks * 1.5), &st, &ht);
    CHECK(st == 512, "after one period, sampleTime advances by exactly one period");

    nn_clock_get_zero_timestamp(&c, 1000 + (uint64_t)(periodTicks * 3.2), &st, &ht);
    CHECK(st == 512 * 3, "monotonic advance to the latest boundary at/below now");

    // Monotonic: never goes backwards even if asked for an earlier time.
    uint64_t prev = st;
    nn_clock_get_zero_timestamp(&c, 1000 + (uint64_t)(periodTicks * 1.0), &st, &ht);
    CHECK(st >= prev, "zero-timestamp must be monotonic (never regress)");

    // Large host-time jump (wake-from-sleep / debugger pause): MUST resolve in O(1), not loop
    // once per missed period. 2 hours @ 48k = 345,600,000 frames.
    nn_clock c2;
    nn_clock_init(&c2, /*anchor*/0, /*ticks/s*/1e9, /*sr*/48000.0, /*period*/512);
    uint64_t st2 = 0, ht2 = 0;
    double twoHoursTicks = 2.0 * 3600.0 * 1e9;
    uint32_t adv = nn_clock_get_zero_timestamp(&c2, (uint64_t)twoHoursTicks, &st2, &ht2);
    uint64_t expectedPeriods = (uint64_t)(twoHoursTicks / ((512.0 / 48000.0) * 1e9));
    CHECK(st2 == expectedPeriods * 512, "huge host-time jump lands on the exact boundary");
    CHECK(adv == (uint32_t)expectedPeriods, "advance count = periods skipped (computed, not looped)");

    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("nn_clock: all tests passed\n");
    return 0;
}
