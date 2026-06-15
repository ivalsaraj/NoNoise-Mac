#include "../NoNoiseMic/nn_ring.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int failures = 0;
#define CHECK(cond, msg) do { if(!(cond)){ printf("FAIL: %s\n", msg); failures++; } } while(0)

static void test_write_read_roundtrip(void) {
    float store[8 * 2]; nn_ring r;
    assert(nn_ring_init(&r, store, 8, 2) == 0);
    nn_ring_clear(&r);
    float in[4 * 2], out[4 * 2];
    for (int i = 0; i < 8; i++) in[i] = (float)i;
    nn_ring_write_at(&r, 0, in, 4);
    nn_ring_read_at(&r, 0, out, 4);
    CHECK(memcmp(in, out, sizeof in) == 0, "roundtrip at t=0 must match");
}

static void test_wraparound(void) {
    float store[8 * 1]; nn_ring r;
    nn_ring_init(&r, store, 8, 1);
    nn_ring_clear(&r);
    float in[6], out[6];
    for (int i = 0; i < 6; i++) in[i] = (float)(i + 1);
    nn_ring_write_at(&r, 6, in, 6);   // writes indices 6,7,0,1,2,3 (wraps)
    nn_ring_read_at(&r, 6, out, 6);
    CHECK(memcmp(in, out, sizeof in) == 0, "write/read across the wrap boundary must match");
}

static void test_init_rejects_non_pow2(void) {
    float store[10]; nn_ring r;
    CHECK(nn_ring_init(&r, store, 5, 1) == -1, "non-power-of-two capacity must be rejected");
    CHECK(nn_ring_init(&r, store, 0, 1) == -1, "zero capacity must be rejected");
}

// CRITICAL (layout): stereo is interleaved [L,R,L,R…]; L/R must never swap, even across a wrap.
static void test_stereo_channels_preserved(void) {
    float store[4 * 2]; nn_ring r;                 // capacity 4 frames, 2ch
    nn_ring_init(&r, store, 4, 2);
    nn_ring_clear(&r);
    float in[3 * 2], out[3 * 2];
    for (int f = 0; f < 3; f++) { in[f*2] = 100.0f + f; in[f*2 + 1] = 200.0f + f; } // L=10x, R=20x
    nn_ring_write_at(&r, 3, in, 3);                // start t=3 → slots 3,0,1 (wraps)
    nn_ring_read_at(&r, 3, out, 3);
    CHECK(memcmp(in, out, sizeof in) == 0, "interleaved L/R survives a wrap without swapping");
    CHECK(out[0] == 100.0f && out[1] == 200.0f, "frame 0 stays L-then-R (not swapped)");
}

// CRITICAL (privacy): reading before anything is written must yield SILENCE, never the
// uninitialized/old slot contents.
static void test_read_before_write_is_silent(void) {
    float store[8]; nn_ring r;
    nn_ring_init(&r, store, 8, 1);
    for (int i = 0; i < 8; i++) store[i] = 7.0f;   // poison: prove read zeroes, not copies
    nn_ring_clear(&r);
    float out[4];
    for (int i = 0; i < 4; i++) out[i] = -1.0f;
    nn_ring_read_at(&r, 0, out, 4);
    for (int i = 0; i < 4; i++) CHECK(out[i] == 0.0f, "read before any write must be silent");
}

// CRITICAL (privacy): once the writer STOPS, the reader advancing past the last written frame
// must serve silence — NOT replay stale speech that the modulo index still aliases to.
static void test_stale_after_writer_stops_is_silent(void) {
    float store[8]; nn_ring r;                     // capacity 8
    nn_ring_init(&r, store, 8, 1);
    nn_ring_clear(&r);
    float in[4] = { 1.0f, 2.0f, 3.0f, 4.0f };
    nn_ring_write_at(&r, 0, in, 4);                // slots 0..3 hold 1,2,3,4; writeEnd=4
    float out[4];
    for (int i = 0; i < 4; i++) out[i] = -1.0f;
    nn_ring_read_at(&r, 8, out, 4);                // t=8 → slots 0..3 (same slots!) but past writeEnd
    for (int i = 0; i < 4; i++) CHECK(out[i] == 0.0f, "reads past the last write must be silent, not stale");
}

// A block straddling the last written frame: written frames pass through, the rest are silenced.
static void test_partial_block_straddles_write_end(void) {
    float store[8]; nn_ring r;
    nn_ring_init(&r, store, 8, 1);
    nn_ring_clear(&r);
    float in[4] = { 10.0f, 20.0f, 30.0f, 40.0f };
    nn_ring_write_at(&r, 0, in, 4);                // writeEnd=4
    float out[4];
    nn_ring_read_at(&r, 2, out, 4);                // frames 2,3 valid; 4,5 past end
    CHECK(out[0] == 30.0f && out[1] == 40.0f, "in-window frames pass through");
    CHECK(out[2] == 0.0f && out[3] == 0.0f, "frames past writeEnd are silenced");
}

int main(void) {
    test_write_read_roundtrip();
    test_wraparound();
    test_init_rejects_non_pow2();
    test_stereo_channels_preserved();
    test_read_before_write_is_silent();
    test_stale_after_writer_stops_is_silent();
    test_partial_block_straddles_write_end();
    if (failures) { printf("%d failure(s)\n", failures); return 1; }
    printf("nn_ring: all tests passed\n");
    return 0;
}
