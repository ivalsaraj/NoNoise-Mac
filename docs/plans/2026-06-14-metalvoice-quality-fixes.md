# MetalVoice DSP Quality Fixes — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix the audio quality and real-time performance bugs in `DeepFilterNetDSP.swift` that cause muffled output and intermittent dropouts.

**Architecture:** Targeted edits inside `Sources/Core/AudioProcessing/`. Add a new `SpecHistoryRingBuffer` (O(chunk.count) per append — chunk is the hop output, 962 floats — vs O(N) memmove on the prior fixed-size array), pre-allocate all hop-local scratch and input `MLMultiArray`s so `processHop` performs no per-hop heap allocations, and switch the MLMultiArray copy path to its `withUnsafeMutableBufferPointer` fast path. Keep hidden state in `Float16` to match the model. No changes to `App/`, `CLI/`, `Resources/`, or the CoreML model file.

**Tech Stack:** Swift 5.9, Swift Package Manager, XCTest, CoreML, vDSP/Accelerate.

**Execution location:** All edits and commits go inside `/Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src/` (the cloned source repo, not the prebuilt app bundle).

---

## Context

Code review of `Sources/Core/AudioProcessing/DeepFilterNetDSP.swift` (478 lines) found seven issues affecting quality and real-time stability:

| # | File:Line | Bug | Impact |
|---|---|---|---|
| 1 | `DeepFilterNetDSP.swift:333` | `compressP = 0.6` but DFN3 was trained with `c=0.5` | Model sees wrong input distribution → muffled denoising |
| 2 | `DeepFilterNetDSP.swift:67-72, 425` | `UnitMagNormalizer.magMean` starts at `1.0`, EMA `alpha=0.99` | First ~1 s of audio is at wrong gain |
| 3 | `DeepFilterNetDSP.swift:281,295-296,311,331,355,452-453` | 8+ heap allocations per hop (every 10 ms) | GC pressure → dropouts under load |
| 4 | `DeepFilterNetDSP.swift:348,357` | `removeFirst(962)` + `append(contentsOf:)` on 9,620-element array, 100×/s | O(N) memmove per hop; replaced with O(chunk.count) ring buffer (chunk = 962, capacity = 9620) |
| 5 | `DeepFilterNetDSP.swift:389-391,421-422` | `MLMultiArray[i] = NSNumber(...)` subscript | Slow path, 77k NSNumber allocs/sec |
| 6 | `DeepFilterNetDSP.swift:96-98,389-410` | Hidden state stored as `Float`, copied via `NSNumber` to `Float16` | Float16 precision loss every frame |
| 7 | `DeepFilterNetDSP.swift:155` | `featSpecNorm = UnitMagNormalizer(count: 96)` allocated, never used | Dead code |

Tasks 2, 3, 4, 5, 6, 7, 8 below address bugs 1, 3, 4, 5, 6, 7. Bug 2 (normalizer warm-up) is a deeper design change — left for a follow-up plan. **This plan fixes 6 of 7 issues identified at audit time.**

**Source of the c=0.5 compression constant:** the upstream [`Rikorose/DeepFilterNet`](https://github.com/Rikorose/DeepFilterNet) spectral compression is `c=0.5` (see `libdf/src/df/df.c::df_compress_t` in the C backend, mirrored in the Python `deepfilternet/modules.py::compress`). The bundled `DeepFilterNet3_Streaming.mlmodelc` is a CoreML export of that architecture trained at `c=0.5`.

---

## Task 1: Add test target scaffolding

**Files:**
- Modify: `MetalVoice-src/Package.swift`
- Create: `MetalVoice-src/Tests/MetalVoiceTests/MetalVoiceDSPTests.swift`

**Step 1: Add `.testTarget` to `Package.swift`**

After the existing `.executableTarget(name: "MetalVoiceCLI", ...)` block, append:

```swift
        .testTarget(
            name: "MetalVoiceTests",
            dependencies: ["Core"],
            path: "Tests/MetalVoiceTests"
        )
```

**Step 2: Create the test file with a placeholder test**

`Tests/MetalVoiceTests/MetalVoiceDSPTests.swift`:

```swift
import XCTest
@testable import Core

final class MetalVoiceDSPTests: XCTestCase {
    func testScaffolding() {
        XCTAssertTrue(true)
    }
}
```

**Step 3: Run tests to verify scaffolding works**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift test
```

Expected: `Test Suite 'All tests' passed` (1 test).

**Step 4: Commit**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
git add Package.swift Tests/
git commit -m "test: add MetalVoiceTests target scaffolding"
```

---

## Task 2: Fix compression exponent (c=0.6 → c=0.5) — TDD

The current `compressP` is a `let` local to `processHop`, so a unit test cannot reach it. Promote it to a `static let` on `DeepFilterNetDSP`, then assert it from a test. The test FAILS while the constant is `0.6`, PASSES after we set it to `0.5`.

**Files:**
- Modify: `MetalVoice-src/Tests/MetalVoiceTests/MetalVoiceDSPTests.swift`
- Modify: `MetalVoice-src/Sources/Core/AudioProcessing/DeepFilterNetDSP.swift:96, 333, 433`

**Step 1: Refactor — promote `compressP` to `static let` (no behavior change yet)**

In `DeepFilterNetDSP.swift`, add a class-level static constant with the other static-ish constants. Place it right after the `class DeepFilterNetDSP {` line, before the existing instance constants:

```swift
    /// Spectral compression exponent. Must match the value used when the
    /// CoreML model was trained. The upstream DeepFilterNet3 uses c=0.5.
    /// Exposed as `static let` so a test can assert it.
    static let compressionExponent: Float = 0.6
```

In `processHop(...)`, replace the local declaration:

```swift
        let compressP: Float = 0.6 // Correct DFN3 Value (Boosts Loudness vs 0.5)
```

with:

```swift
        let compressP = Self.compressionExponent
```

(Keep the local `compressP` so the rest of `processHop` doesn't need to change. The `decompExp` line on 433 reads `compressP` and is unchanged.)

**Step 2: Add a failing test**

Append to `MetalVoiceDSPTests`:

```swift
    func testCompressionExponentMatchesModelTraining() {
        // DeepFilterNet3 was trained with spectral compression c=0.5.
        // Any other value feeds the model an out-of-distribution input.
        XCTAssertEqual(DeepFilterNetDSP.compressionExponent, 0.5,
                       "DeepFilterNet3 model was trained with c=0.5; do not change.")
    }

    func testCompressionRoundTripC0_5() {
        // Sanity check on the math at c=0.5 (does not exercise the live constant).
        let magnitudes: [Float] = [0.001, 0.05, 0.3, 0.7, 1.0]
        let c: Float = 0.5
        let eps: Float = 1e-10
        for m in magnitudes {
            let scale = pow(m + eps, c - 1.0)
            let compR = m * scale  // phase=0
            let normalized = compR  // UnitMagNormalizer with magMean=1.0 is identity
            let compMag = abs(normalized)
            let decompExp = (1.0 / c) - 1.0
            let decompScale = pow(compMag + eps, decompExp)
            let recovered = normalized * decompScale
            XCTAssertEqual(recovered, m, accuracy: 1e-5,
                           "c=0.5 round-trip failed for m=\(m): got \(recovered)")
        }
    }
```

**Step 3: Run the new tests — the first MUST FAIL, the second MUST PASS**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift test --filter MetalVoiceDSPTests
```

Expected:
- `testCompressionExponentMatchesModelTraining` — FAILS (`0.6 != 0.5`)
- `testCompressionRoundTripC0_5` — PASSES

**Step 4: Fix — change the static constant from 0.6 to 0.5**

In `DeepFilterNetDSP.swift`, change:

```swift
    static let compressionExponent: Float = 0.6
```

to:

```swift
    static let compressionExponent: Float = 0.5
```

**Step 5: Re-run tests — both MUST PASS**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift test --filter MetalVoiceDSPTests
```

Expected: both tests pass.

**Step 6: Commit**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
git add Sources/Core/AudioProcessing/DeepFilterNetDSP.swift Tests/
git commit -m "fix(dsp): use c=0.5 compression to match DFN3 training distribution"
```

---

## Task 3: Add `SpecHistoryRingBuffer` — TDD (always-full semantic)

The DSP needs the ring buffer to behave like the pre-existing `[Float](repeating: 0, count: capacity)` arrays: **always full after init**, pre-loaded with zeros, with oldest values dropped on overflow. This matches the model's input shape (always a full capacity-shaped `MLMultiArray`) and avoids a crash during the first 9 hops.

**Files:**
- Create: `MetalVoice-src/Sources/Core/AudioProcessing/SpecHistoryRingBuffer.swift`
- Modify: `MetalVoice-src/Tests/MetalVoiceTests/MetalVoiceDSPTests.swift`

**Step 1: Write failing tests**

Append to `MetalVoiceDSPTests`:

```swift
    func testRingBufferStartsFullOfZeros() {
        let buf = SpecHistoryRingBuffer(capacity: 5)
        var out = [Float](repeating: 0, count: 5)
        buf.copyChronological(into: &out)
        XCTAssertEqual(out, [0, 0, 0, 0, 0], "buffer must be capacity-shaped, zero-padded")
    }

    func testRingBufferAppendKeepsNewestAtEnd() {
        let buf = SpecHistoryRingBuffer(capacity: 5)
        buf.append([1, 2, 3])
        var out = [Float](repeating: 0, count: 5)
        buf.copyChronological(into: &out)
        XCTAssertEqual(out, [0, 0, 1, 2, 3],
                       "newest values must land at the end (T-1); older slots stay zero")
    }

    func testRingBufferDropsOldestOnOverflow() {
        let buf = SpecHistoryRingBuffer(capacity: 5)
        buf.append([1, 2, 3])
        buf.append([4, 5, 6, 7])  // drops 1, 2 from the oldest slots
        var out = [Float](repeating: 0, count: 5)
        buf.copyChronological(into: &out)
        XCTAssertEqual(out, [3, 4, 5, 6, 7])
    }

    func testRingBufferWrapAround() {
        let buf = SpecHistoryRingBuffer(capacity: 6)
        buf.append([1, 2, 3, 4])
        buf.append([5, 6, 7])  // drops 1, keeps 2,3,4,5,6,7
        var out = [Float](repeating: 0, count: 6)
        buf.copyChronological(into: &out)
        XCTAssertEqual(out, [2, 3, 4, 5, 6, 7])
    }

    func testRingBufferChunkLargerThanCapacity() {
        let buf = SpecHistoryRingBuffer(capacity: 3)
        buf.append([1, 2, 3, 4, 5])  // chunk.count >= capacity
        var out = [Float](repeating: 0, count: 3)
        buf.copyChronological(into: &out)
        XCTAssertEqual(out, [3, 4, 5])
    }
```

**Step 2: Run tests — must FAIL (type doesn't exist yet)**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift test --filter SpecHistoryRingBuffer
```

Expected: FAIL with `Cannot find 'SpecHistoryRingBuffer' in scope`.

**Step 3: Implement `SpecHistoryRingBuffer` (always-full)**

Create `Sources/Core/AudioProcessing/SpecHistoryRingBuffer.swift`:

```swift
import Foundation

/// Fixed-capacity ring buffer of `Float` values for ML feature history.
///
/// **Semantic:** the buffer is always full after `init` — pre-loaded with zeros
/// in every slot. `append(_:)` shifts the head pointer and overwrites the oldest
/// values, never growing past `capacity`. `copyChronological(into:)` always writes
/// exactly `capacity` values in oldest-first order, with unwritten slots left as
/// zero. This matches the pre-existing `[Float](repeating: 0, count: capacity)`
/// arrays that the CoreML input MLMultiArrays expect.
final class SpecHistoryRingBuffer {
    private var storage: [Float]
    private var head: Int = 0  // index of the oldest element
    let capacity: Int

    /// Always equal to `capacity` after init. Exposed for parity with the
    /// pre-ring-buffer `[Float]` arrays it replaces.
    var count: Int { capacity }

    init(capacity: Int) {
        precondition(capacity > 0, "capacity must be > 0")
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    /// Append a chunk. If `chunk.count >= capacity`, only the last `capacity`
    /// values are kept and the head resets to 0.
    ///
    /// **Allocation note:** the `chunk.count >= capacity` path calls
    /// `Array(chunk.suffix(capacity))`, which allocates a new backing buffer.
    /// In DSP use, chunks (e.g. 962 floats per hop) are always much smaller
    /// than capacity (e.g. 9620), so the allocation path is never taken in
    /// practice. If a caller is going to pass chunks of arbitrary size, be
    /// aware of this.
    func append(_ chunk: [Float]) {
        if chunk.isEmpty { return }
        if chunk.count >= capacity {
            storage = Array(chunk.suffix(capacity))
            head = 0
            return
        }
        let writeStart = (head + capacity) % capacity
        if writeStart + chunk.count <= capacity {
            // No wrap
            for (i, v) in chunk.enumerated() {
                storage[writeStart + i] = v
            }
        } else {
            // Wrap around
            let firstChunk = capacity - writeStart
            for i in 0..<firstChunk { storage[writeStart + i] = chunk[i] }
            for i in 0..<(chunk.count - firstChunk) { storage[i] = chunk[firstChunk + i] }
        }
        head = (head + chunk.count) % capacity
    }

    /// Copy all `capacity` values into `out` in chronological order (oldest first).
    /// `out.count` must equal `self.capacity`.
    func copyChronological(into out: inout [Float]) {
        precondition(out.count == capacity,
                     "out.count (\(out.count)) must equal capacity (\(capacity))")
        if capacity == 0 { return }
        if head == 0 {
            for i in 0..<capacity { out[i] = storage[i] }
        } else {
            let firstChunk = capacity - head
            for i in 0..<firstChunk { out[i] = storage[head + i] }
            for i in 0..<head { out[firstChunk + i] = storage[i] }
        }
    }
}
```

**Step 4: Run tests — must PASS**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift test --filter SpecHistoryRingBuffer
```

Expected: 5 tests pass.

**Step 5: Commit**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
git add Sources/Core/AudioProcessing/SpecHistoryRingBuffer.swift Tests/
git commit -m "feat(dsp): add SpecHistoryRingBuffer (O(chunk.count) per append, always-full) for ML feature history"
```

---

## Task 4: Wire `SpecHistoryRingBuffer` into `DeepFilterNetDSP`

This task only changes the history storage and the three append sites. It does **not** touch the rest of `processHop`'s allocations — those are addressed in Task 5. Task 4 is independently buildable on its own.

**Files:**
- Modify: `MetalVoice-src/Sources/Core/AudioProcessing/DeepFilterNetDSP.swift`

**Step 1: Replace the three history `[Float]` properties with ring-buffer instances**

In `DeepFilterNetDSP.swift`, replace (around lines 106-112):

```swift
    // shape: [10, 481, 2] -> 10 * 481 * 2 = 9620
    private var specHistory: [Float] = [Float](repeating: 0, count: 9620)
    
    // shape: [10, 32] -> 320
    private var erbHistory: [Float] = [Float](repeating: 0, count: 320)
    
    // shape: [10, 96, 2] -> 1920
    private var featSpecHistory: [Float] = [Float](repeating: 0, count: 1920)
```

with:

```swift
    // Ring buffers for ML feature history (O(chunk.count) per append; chunk is 962, capacity 9620)
    private let specHistory = SpecHistoryRingBuffer(capacity: 9620)
    private let erbHistory = SpecHistoryRingBuffer(capacity: 320)
    private let featSpecHistory = SpecHistoryRingBuffer(capacity: 1920)
```

**Step 2: Replace the "Update History (Shift)" blocks in `processHop`**

Replace the three shift blocks (current lines 321-326, 346-360) with simple `append` calls. Keep the local `var fullCompressed = [Float](...)` declaration unchanged (it gets removed in Task 5):

```swift
        // 3b. ERB History
        erbHistory.append(erbFeat)
        
        // 3c. Spec History
        specHistory.append(fullCompressed)
        
        // 3d. Feat Spec History (first 96 complex bins = 192 floats)
        let featSlice = Array(fullCompressed[0..<(96 * 2)])
        featSpecHistory.append(featSlice)
```

**Step 3: Replace the history → MLMultiArray copy block (current lines 374-386)**

The pre-fix code reads from `specHistory[i]` etc. (Swift array subscript) — that API no longer exists. Replace the entire copy block with this, using **local `var` scratch arrays** sized to capacity (zero-padded for unwritten slots, which matches the ring buffer's always-full semantic):

```swift
                // Copy ring-buffer history into capacity-shaped zero-padded scratch,
                // then into the per-hop MLMultiArrays.
                var specScratch = [Float](repeating: 0, count: 9620)
                var erbScratch = [Float](repeating: 0, count: 320)
                var featScratch = [Float](repeating: 0, count: 1920)
                specHistory.copyChronological(into: &specScratch)
                erbHistory.copyChronological(into: &erbScratch)
                featSpecHistory.copyChronological(into: &featScratch)

                specMulti.withUnsafeMutableBufferPointer(ofType: Float.self) { ptr, _ in
                    for i in 0..<min(ptr.count, specScratch.count) { ptr[i] = specScratch[i] }
                }
                erbMulti.withUnsafeMutableBufferPointer(ofType: Float.self) { ptr, _ in
                    for i in 0..<min(ptr.count, erbScratch.count) { ptr[i] = erbScratch[i] }
                }
                featMulti.withUnsafeMutableBufferPointer(ofType: Float.self) { ptr, _ in
                    for i in 0..<min(ptr.count, featScratch.count) { ptr[i] = featScratch[i] }
                }
```

(The 6 per-hop `MLMultiArray(shape:)` allocations on lines 367-372 are left in place for now; Task 5 replaces them with pre-allocated instances. The per-hop allocation is acceptable as a stepping stone — the heavy lifting (O(N) history shifts) is what this task eliminates.)

**Step 4: Build to verify**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift build
```

Expected: succeeds with no warnings.

**Step 5: Commit**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
git add Sources/Core/AudioProcessing/DeepFilterNetDSP.swift
git commit -m "perf(dsp): use SpecHistoryRingBuffer; remove O(N) history shifts"
```

---

## Task 5: Pre-allocate scratch buffers + pre-allocate input MLMultiArrays (one atomic refactor)

The previous version of this plan had two compile-blocking mistakes that are fixed here:

1. **`let magSq = magSqScratch; magSq[i] = ...` does NOT mutate `magSqScratch`.** Swift `[Float]` is a value type with copy-on-write. Assigning to a `let` local makes a (logically) shared reference; the first subscript mutation triggers a COW copy that mutates the **local**, not the class property. So scratch is never reused, just allocated and immediately copied. The fix is to **drop the `let` aliases entirely** and use the stored property name (`magSqScratch[i] = ...`) at every use site.
2. **Non-optional `let MLMultiArray` properties can't be initialized after `self` is used.** The previous plan put the `MLMultiArray` allocations at the end of `init()`, but `initFilterbank()` (line 147) already mutates `self` mid-init. The fix is to allocate all stored properties — scratch arrays AND `MLMultiArray`s — at the very top of `init()`, before any `self` use.

This is a large but atomic refactor. Net change: ~50 lines added, ~25 lines removed, all in `Sources/Core/AudioProcessing/DeepFilterNetDSP.swift`.

**Files:**
- Modify: `MetalVoice-src/Sources/Core/AudioProcessing/DeepFilterNetDSP.swift`

**Step 1: Add stored scratch + MLMultiArray properties (all non-optional `let`s for `MLMultiArray`, all `var [Float]` with empty defaults for scratch)**

After the existing `var olaBuffer: [Float] = []` line (around line 121), add:

```swift
    // Pre-allocated scratch (reused every hop; never realloc in hot path).
    // The empty default + init() allocation lets us allocate them before
    // any other use of `self`.
    private var windowedInput: [Float] = []
    private var magSqScratch: [Float] = []
    private var magScratch: [Float] = []
    private var erbFeatScratch: [Float] = []
    private var fullCompressedScratch: [Float] = []
    private var recoveredRealScratch: [Float] = []
    private var recoveredImagScratch: [Float] = []
    private var specScratch: [Float] = []
    private var erbScratch: [Float] = []
    private var featScratch: [Float] = []
    private var featSliceScratch: [Float] = []  // holds first 96 complex bins of fullCompressed
    private var zeroHopScratch: [Float] = []    // reusable zero buffer of size `hopSize` for OLA tail-fill

    // Pre-allocated input MLMultiArrays (allocated once, rewritten in-place each hop).
    // `MLMultiArray` is a class, so `let` is fine — and required here so we can
    // allocate at init() time.
    private let specBufIn: MLMultiArray
    private let erbBufIn: MLMultiArray
    private let featSpecBufIn: MLMultiArray
    private let hEncIn: MLMultiArray
    private let hErbIn: MLMultiArray
    private let hDfIn: MLMultiArray
```

**Step 2: Reorder `init()` so all stored properties are allocated at the TOP — before any `self` use**

The current `init()` (lines 123-170) immediately does `fftSetup = vDSP_DFT_zop_CreateSetup(...)` and then calls `initFilterbank()` (line 147), which mutates `self.erbFilterbank`. After the reordering, the FIRST thing `init()` does — after the existing `super.init()` — is allocate the new scratch and `MLMultiArray` properties. The existing FFT/window/filterbank/normalizer setup follows unchanged.

Replace the entire body of `init()` (the section between `super.init()` and the `Task { ... model load ... }` block) with the following. Lines marked with `// existing` are unchanged from the original; lines marked with `// NEW` are added:

```swift
        // ===== NEW: allocate all stored properties first (before any `self` use) =====
        h_enc_buf = [Float](repeating: 0, count: 256)
        h_erb_buf = [Float](repeating: 0, count: 2 * 256)
        h_df_buf = [Float](repeating: 0, count: 2 * 256)

        // Pre-allocate reusable hop scratch
        windowedInput = [Float](repeating: 0, count: frameSize)
        magSqScratch = [Float](repeating: 0, count: 481)
        magScratch = [Float](repeating: 0, count: 481)
        erbFeatScratch = [Float](repeating: 0, count: 32)
        fullCompressedScratch = [Float](repeating: 0, count: 481 * 2)
        recoveredRealScratch = [Float](repeating: 0, count: frameSize)
        recoveredImagScratch = [Float](repeating: 0, count: frameSize)
        specScratch = [Float](repeating: 0, count: 9620)
        erbScratch = [Float](repeating: 0, count: 320)
        featScratch = [Float](repeating: 0, count: 1920)
        featSliceScratch = [Float](repeating: 0, count: 192)
        zeroHopScratch = [Float](repeating: 0, count: hopSize)

        // Pre-allocate input MLMultiArrays. Shapes are constants; `try!` is safe.
        // (Task 7 will convert h_*_buf storage to [Float16] to match these.)
        specBufIn = try! MLMultiArray(shape: [1, 1, 10, 481, 2], dataType: .float32)
        erbBufIn = try! MLMultiArray(shape: [1, 1, 10, 32], dataType: .float32)
        featSpecBufIn = try! MLMultiArray(shape: [1, 1, 10, 96, 2], dataType: .float32)
        hEncIn = try! MLMultiArray(shape: [1, 1, 256], dataType: .float16)
        hErbIn = try! MLMultiArray(shape: [1, 2, 256], dataType: .float16)
        hDfIn = try! MLMultiArray(shape: [1, 2, 256], dataType: .float16)

        // ===== existing: FFT, window, filterbank, normalizers =====
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(frameSize), vDSP_DFT_Direction.FORWARD)
        fftSetupInv = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(frameSize), vDSP_DFT_Direction.INVERSE)

        window = [Float](repeating: 0, count: frameSize)
        vDSP_hann_window(&window, vDSP_Length(frameSize), Int32(vDSP_HANN_DENORM))
        var n = Int32(frameSize)
        vvsqrtf(&window, window, &n)

        realIn = [Float](repeating: 0, count: frameSize)
        imaginaryIn = [Float](repeating: 0, count: frameSize)
        realOut = [Float](repeating: 0, count: frameSize)
        imaginaryOut = [Float](repeating: 0, count: frameSize)

        initFilterbank()

        olaBuffer = [Float](repeating: 0, count: frameSize)

        erbNorm = MeanSubNormalizer(count: 32)
        specNorm = UnitMagNormalizer(count: 481)
        featSpecNorm = UnitMagNormalizer(count: 96)  // Task 8 removes this

        // ===== existing: async model load =====
        Task {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all
                self.model = try await DeepFilterNet3_Streaming.load(configuration: config)
                self.initHiddenStates()
                self.isModelLoaded = true
                print("DSP: DFN3 Model Loaded")
            } catch {
                print("DSP: Model Load Error: \(error)")
            }
        }
```

> **Note on `MLMultiArray` reuse safety:** CoreML's `prediction(input:)` is synchronous on the calling thread, so reusing the same `MLMultiArray` across sequential predictions is safe (the prediction consumes the input before returning). This DSP is single-threaded (one render thread), so there is no race.

**Step 3: Refactor `processHop` — replace every `var`/`let` array declaration with the stored scratch, and every per-hop `MLMultiArray` allocation with the pre-allocated instance**

This is a global rename inside `processHop`. The pattern is:
- Remove every `var X = [Float](repeating: 0, count: N)` declaration.
- Remove every `let X = scratchY` alias for an array.
- Replace every read or write of the local name (`X`) with the stored scratch name (`scratchY`).
- The `let X = mlmultiRef` aliases for `MLMultiArray` STAY (those are class types, no COW).

Use this exact rename map:

| Remove (declaration) | Replace every use of |
|---|---|
| `var windowedInput = frame` | `windowedInput` (the stored property) |
| `var magSq = [Float](repeating: 0, count: 481)` | `magSqScratch` |
| `var mag = [Float](repeating: 0, count: 481)` | `magScratch` |
| `var erbFeat = [Float](repeating: 0, count: 32)` | `erbFeatScratch` |
| `var fullCompressed = [Float](repeating: 0, count: 481 * 2)` | `fullCompressedScratch` |
| `var recoveredReal = [Float](repeating: 0, count: frameSize)` | `recoveredRealScratch` (handled via `withUnsafeMutableBufferPointer` — see ISTFT block below) |
| `var recoveredImag = [Float](repeating: 0, count: frameSize)` | `recoveredImagScratch` (handled via `withUnsafeMutableBufferPointer` — see ISTFT block below) |
| `let featSlice = Array(fullCompressed[0..<(96 * 2)])` | replace with copy loop into `featSliceScratch` (below) |

For the slice replacement, change:
```swift
        let featSlice = Array(fullCompressed[0..<(96 * 2)])
        featSpecHistory.append(featSlice)
```
to:
```swift
        for i in 0..<(96 * 2) { featSliceScratch[i] = fullCompressedScratch[i] }
        featSpecHistory.append(featSliceScratch)
```

For the `windowedInput` declaration, change:
```swift
        var windowedInput = frame
```
to:
```swift
        for i in 0..<frameSize { windowedInput[i] = frame[i] }
```

In the inference block, replace the six per-hop `MLMultiArray(shape:)` allocations (lines 367-372 in the original) with `let` aliases to the pre-allocated instances:

```swift
                // MLMultiArrays are pre-allocated in init() and rewritten in-place each hop.
                let specMulti = specBufIn
                let erbMulti = erbBufIn
                let featMulti = featSpecBufIn
                let hEncMulti = hEncIn
                let hErbMulti = hErbIn
                let hDfMulti = hDfIn
```

Replace the three local scratch arrays in the inference block (the ones added by Task 4: `var specScratch = ...`, etc.) — remove the `var` declarations; the properties are already declared on the class. The rest of the copy code (the `specHistory.copyChronological(into: &specScratch)` etc.) stays the same — the `&specScratch` syntax now borrows the class property instead of a local.

The per-bin vDSP and array reads inside the `for i in 0..<481` loop on lines 298-303 become:
```swift
        for i in 0..<481 {
            let r = realOut[i]
            let im = imaginaryOut[i]
            magSqScratch[i] = (r * r) + (im * im)
            magScratch[i] = sqrt(magSqScratch[i])
        }
```

The energy computation (line 306-307) becomes:
```swift
        var energy: Float = 0
        vDSP_sve(magSqScratch, 1, &energy, vDSP_Length(481))
```

The ERB feature loop (lines 311-316) becomes:
```swift
        for i in 0..<32 {
            erbFeatScratch[i] = log10(erbFeatScratch[i] + 1e-10)
        }
        erbNorm?.normalize(&erbFeatScratch, update: shouldUpdateNorm)
```

The compressed-spec loop (lines 335-340) becomes:
```swift
        for i in 0..<481 {
            let m = magScratch[i]
            let scale = pow(m + epsilon, compressP - 1.0)
            fullCompressedScratch[i*2] = realOut[i] * scale
            fullCompressedScratch[i*2+1] = imaginaryOut[i] * scale
        }
```

The unit-mag normalize call (line 344) becomes:
```swift
        specNorm?.normalize(&fullCompressedScratch, update: shouldUpdateNorm)
```

The three history-appends (lines 384-392) become:
```swift
        erbHistory.append(erbFeatScratch)
        specHistory.append(fullCompressedScratch)
        // (featSpecHistory.append already updated above with featSliceScratch)
```

The ISTFT and OLA block (lines 452-476) becomes. The ISTFT scratch must be passed to vDSP as `UnsafeMutablePointer<Float>`, which we obtain via `withUnsafeMutableBufferPointer` on the stored properties — **never** through a local `var` alias (Swift `[Float]` is a value type with COW, so a local alias would trigger a copy on first mutation and not actually mutate the class property). The OLA tail-fill uses the pre-allocated `zeroHopScratch` instead of a freshly-allocated `[Float](repeating: 0, count: hopSize)`:

```swift
        // 5. ISTFT
        // Wrap the vDSP calls in withUnsafeMutableBufferPointer so the inout
        // pointers reference the class properties' actual storage, not a
        // COW-copied local.
        recoveredRealScratch.withUnsafeMutableBufferPointer { realPtr in
            recoveredImagScratch.withUnsafeMutableBufferPointer { imagPtr in
                if let invSetup = fftSetupInv {
                    vDSP_DFT_Execute(invSetup, realOut, imaginaryOut, realPtr.baseAddress!, imagPtr.baseAddress!)
                }
                vDSP_vmul(realPtr.baseAddress!, 1, window, 1, realPtr.baseAddress!, 1, vDSP_Length(frameSize))
                var scale = (1.0 / Float(frameSize)) * outputGain
                vDSP_vsmul(realPtr.baseAddress!, 1, &scale, realPtr.baseAddress!, 1, vDSP_Length(frameSize))

                // 6. Overlap-Add into olaBuffer, then emit the head of olaBuffer
                //    (post-OLA) to outputBuffer. The output slice must come from
                //    olaBuffer, not recoveredRealScratch — otherwise overlap from
                //    prior frames is bypassed and OLA continuity breaks.
                olaBuffer.withUnsafeMutableBufferPointer { olaPtr in
                    vDSP_vadd(realPtr.baseAddress!, 1, olaPtr.baseAddress!, 1, olaPtr.baseAddress!, 1, vDSP_Length(frameSize))
                    let readySlice = UnsafeBufferPointer(start: olaPtr.baseAddress, count: hopSize)
                    outputBuffer.append(contentsOf: readySlice)
                }
            }
        }

        // 7. Shift OLA state (in-place memmove + reusable zero fill)
        olaBuffer.removeFirst(hopSize)  // O(N) memmove, no allocation
        olaBuffer.append(contentsOf: zeroHopScratch)  // no allocation (capacity pre-reserved)
```

> **Why no local `var recoveredReal = recoveredRealScratch`?**
> A local `var` would trigger COW on first mutation through it: the local and the class property would split into two buffers, the local would be mutated, and the class property would be left at its pre-call state. `withUnsafeMutableBufferPointer` avoids this by giving vDSP a pointer that goes straight at the class property's storage.

> **Why no `Array(olaBuffer[0..<hopSize])`?**
> That constructor materialises a new `[Float]` of size `hopSize` per hop. `UnsafeBufferPointer(start:count:)` is a non-owning view — `Array.append(contentsOf:)` iterates and copies element-by-element without first materialising an intermediate array.

> **Why no `[Float](repeating: 0, count: hopSize)` in the OLA tail-fill?**
> Allocated per hop. Replaced with the pre-allocated `zeroHopScratch` (sized at `hopSize`, filled with zeros in `init()`). `olaBuffer.append(contentsOf: zeroHopScratch)` is a memcpy with no allocation because `olaBuffer`'s capacity was pre-reserved to `frameSize` in `init()`.

**Step 4: Build to verify**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift build
```

Expected: succeeds.

**Step 5: Run the full test suite to make sure nothing broke**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift test
```

Expected: all tests pass.

**Step 6: Commit**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
git add Sources/Core/AudioProcessing/DeepFilterNetDSP.swift
git commit -m "perf(dsp): pre-allocate scratch buffers and input MLMultiArrays"
```

---

## Task 6: Optimize `MLMultiArray` access — replace NSNumber subscript with `withUnsafeMutableBufferPointer`

**Files:**
- Modify: `MetalVoice-src/Sources/Core/AudioProcessing/DeepFilterNetDSP.swift`

**Step 1: Replace the read path (current lines 421-422)**

The `enhanced[[zero, zero, zero, iNum, zero] as [NSNumber]]` pattern is a slow dynamic-dispatch call per bin, per frame. For 481 bins × 100 Hz = 48k slow calls per second.

Replace the loop body (lines 418-438) with a direct buffer read:

```swift
                // Read enhanced_spec directly from its Float16 buffer (no NSNumber per bin)
                enhanced.withUnsafeBufferPointer(ofType: Float16.self) { ePtr in
                    for i in 0..<481 {
                        let r = ePtr[i * 2]
                        let im = ePtr[i * 2 + 1]
                        let valR = Float(r)
                        let valI = Float(im)
                        
                        // 1. De-Normalize (Undo UnitMag)
                        let mean = specNorm?.magMean[i] ?? 1.0
                        let compR = valR * mean
                        let compI = valI * mean
                        
                        // 2. De-Compress (Undo 0.5 power)
                        let compMag = sqrt(compR * compR + compI * compI)
                        let decompExp = (1.0 / compressP) - 1.0  // = 1.0 for c=0.5
                        let decompScale = pow(compMag + 1e-10, decompExp)
                        
                        realOut[i] = compR * decompScale
                        imaginaryOut[i] = compI * decompScale
                    }
                }
```

This also drops the unused `zero`/`one`/`iNum` NSNumber constants from the inference block.

**Step 2: Build to verify**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift build
```

Expected: succeeds.

**Step 3: Commit**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
git add Sources/Core/AudioProcessing/DeepFilterNetDSP.swift
git commit -m "perf(dsp): read enhanced_spec via withUnsafeBufferPointer (no NSNumber)"
```

---

## Task 7: Switch hidden state storage to `Float16` (eliminate per-frame precision loss)

**Files:**
- Modify: `MetalVoice-src/Sources/Core/AudioProcessing/DeepFilterNetDSP.swift`

**Step 1: Change hidden state property types (lines 96-98)**

Replace:
```swift
    // Hidden State STORAGE (Flat Float Buffers)
    private var h_enc_buf: [Float]
    private var h_erb_buf: [Float]
    private var h_df_buf: [Float]
```

with:
```swift
    // Hidden State STORAGE (Float16 to match model I/O and avoid per-frame rounding)
    private var h_enc_buf: [Float16]
    private var h_erb_buf: [Float16]
    private var h_df_buf: [Float16]
```

**Step 2: Update the `init()` allocation (lines 125-127)**

Replace:
```swift
        h_enc_buf = [Float](repeating: 0, count: 256)
        h_erb_buf = [Float](repeating: 0, count: 2 * 256)
        h_df_buf = [Float](repeating: 0, count: 2 * 256)
```

with:
```swift
        h_enc_buf = [Float16](repeating: 0, count: 256)
        h_erb_buf = [Float16](repeating: 0, count: 2 * 256)
        h_df_buf = [Float16](repeating: 0, count: 2 * 256)
```

**Step 3: Replace the NSNumber copy-into-`MLMultiArray` loop (current lines 389-391)**

Replace:
```swift
                // Copy States (Float -> Float16 via NSNumber for safety)
                for i in 0..<h_enc_buf.count { hEncMulti[i] = NSNumber(value: h_enc_buf[i]) }
                for i in 0..<h_erb_buf.count { hErbMulti[i] = NSNumber(value: h_erb_buf[i]) }
                for i in 0..<h_df_buf.count { hDfMulti[i] = NSNumber(value: h_df_buf[i]) }
```

with:
```swift
                // Copy States (Float16 buffer → Float16 MLMultiArray, no NSNumber)
                hEncMulti.withUnsafeMutableBufferPointer(ofType: Float16.self) { dst, _ in
                    for i in 0..<min(dst.count, h_enc_buf.count) { dst[i] = h_enc_buf[i] }
                }
                hErbMulti.withUnsafeMutableBufferPointer(ofType: Float16.self) { dst, _ in
                    for i in 0..<min(dst.count, h_erb_buf.count) { dst[i] = h_erb_buf[i] }
                }
                hDfMulti.withUnsafeMutableBufferPointer(ofType: Float16.self) { dst, _ in
                    for i in 0..<min(dst.count, h_df_buf.count) { dst[i] = h_df_buf[i] }
                }
```

**Step 4: Replace the copy-back-from-`MLMultiArray` loop (current lines 403-411)**

Replace:
```swift
                // Check if buffers match size (Safety)
                if oEnc.count == h_enc_buf.count {
                    for i in 0..<h_enc_buf.count { h_enc_buf[i] = oEnc[i].floatValue }
                }
                if oErb.count == h_erb_buf.count {
                    for i in 0..<h_erb_buf.count { h_erb_buf[i] = oErb[i].floatValue }
                }
                if oDf.count == h_df_buf.count {
                    for i in 0..<h_df_buf.count { h_df_buf[i] = oDf[i].floatValue }
                }
```

with:
```swift
                // Copy states back: Float16 → Float16 (no rounding, no NSNumber)
                oEnc.withUnsafeBufferPointer(ofType: Float16.self) { src in
                    let n = min(src.count, h_enc_buf.count)
                    for i in 0..<n { h_enc_buf[i] = src[i] }
                }
                oErb.withUnsafeBufferPointer(ofType: Float16.self) { src in
                    let n = min(src.count, h_erb_buf.count)
                    for i in 0..<n { h_erb_buf[i] = src[i] }
                }
                oDf.withUnsafeBufferPointer(ofType: Float16.self) { src in
                    let n = min(src.count, h_df_buf.count)
                    for i in 0..<n { h_df_buf[i] = src[i] }
                }
```

**Step 5: Build and test**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift build && swift test
```

Expected: build clean, all tests pass.

**Step 6: Commit**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
git add Sources/Core/AudioProcessing/DeepFilterNetDSP.swift
git commit -m "perf(dsp): keep hidden state in Float16; drop NSNumber conversions"
```

---

## Task 8: Remove dead code (`featSpecNorm`)

**Files:**
- Modify: `MetalVoice-src/Sources/Core/AudioProcessing/DeepFilterNetDSP.swift:155`

**Step 1: Delete the unused line**

In `init()`, delete:
```swift
        featSpecNorm = UnitMagNormalizer(count: 96)
```

**Step 2: Delete the unused property declaration (line 35)**

In the property block, delete:
```swift
    private var featSpecNorm: UnitMagNormalizer?
```

**Step 3: Build to verify**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift build
```

Expected: succeeds.

**Step 4: Commit**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
git add Sources/Core/AudioProcessing/DeepFilterNetDSP.swift
git commit -m "chore(dsp): remove unused featSpecNorm"
```

---

## Task 9: Build, bundle, and manual smoke test

**Files:**
- Modify: none (build-only)

**Step 1: Verify the CoreML model file was NOT modified**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
git status --short Resources/DeepFilterNet3_Streaming.mlmodelc
git diff --stat -- Resources/DeepFilterNet3_Streaming.mlmodelc
```

Expected: empty output. The plan must not have touched the bundled model. If anything is dirty, stop and investigate before continuing.

**Step 2: Run the test suite — gate on it before release build**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift test
```

Expected: all 8 tests pass. If anything fails, stop and fix before proceeding.

**Step 3: Release build**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift build -c release
```

Expected: build succeeds, binary at `.build/release/MetalVoice`.

**Step 4: Run the bundling script**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
bash bundle.sh
```

Expected: produces `MetalVoice.app` in the repo root and copies `MetalVoiceCLI` to the repo root.

**Step 5: Back up the current install before overwriting**

```bash
if [ -d /Applications/MetalVoice.app ]; then
  ts=$(date +%Y%m%d-%H%M%S)
  cp -R /Applications/MetalVoice.app "/tmp/MetalVoice.app.bak.$ts"
  echo "Backup saved to /tmp/MetalVoice.app.bak.$ts"
fi
```

(Rollback is `rm -rf /Applications/MetalVoice.app && cp -R /tmp/MetalVoice.app.bak.<ts> /Applications/MetalVoice.app`.)

**Step 6: Move the new app into Applications (overwriting the old build)**

```bash
rm -rf /Applications/MetalVoice.app
cp -R /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src/MetalVoice.app /Applications/
xattr -dr com.apple.quarantine /Applications/MetalVoice.app
```

**Step 7: Manual smoke test**

1. Open `/Applications/MetalVoice.app` (right-click → Open the first time).
2. Pick `Built-in Microphone` (or your USB mic) as Input, `BlackHole 2ch` as Output.
3. Toggle AI on (green dot in menu).
4. Open QuickTime Player → File → New Audio Recording → set input to `BlackHole 2ch` → record 10 seconds of normal speech.
5. Listen back. Expected: clean speech, background noise attenuated, **no robotic artifacts**, no dropouts. If you previously heard a muffled/hollow quality, it should now be gone.

**Step 8: Verify the new app's binary differs from the old one**

```bash
shasum -a 256 /Applications/MetalVoice.app/Contents/MacOS/MetalVoice \
  /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice.app/Contents/MacOS/MetalVoice
```

The hashes should differ — this confirms a fresh build.

**Step 9: If the new build is worse, roll back**

```bash
rm -rf /Applications/MetalVoice.app
ls -dt /tmp/MetalVoice.app.bak.* | head -1 | xargs -I{} cp -R {} /Applications/MetalVoice.app
```

---

## Task 10: Update project docs

**Files:**
- Create: `MetalVoice-src/AGENTS.md` (if not present)

**Step 1: Create `AGENTS.md` capturing the project-specific patterns established by this fix**

```markdown
# MetalVoice — Project Notes for AI Agents

## DSP architecture invariants
- DeepFilterNet3 model was trained with **spectral compression exponent c=0.5** (NOT 0.5 ± epsilon). The constant lives at `DeepFilterNetDSP.compressionExponent`. Changing it misaligns input/output distributions and degrades denoising.
- `MLMultiArray` access must go through `withUnsafeMutableBufferPointer(ofType:)` / `withUnsafeBufferPointer(ofType:)`. The `NSNumber` subscript path is a 10–100× slowdown and is banned.
- Hidden state (`h_enc_buf`, `h_erb_buf`, `h_df_buf`) is stored in `Float16` to match the model. Promoting to `Float` introduces per-frame rounding drift.

## Real-time audio rules
- `processHop` runs on the AVAudioEngine render thread. **No avoidable heap allocations in `processHop`**: all hop-local scratch (`windowedInput`, `magSqScratch`, `magScratch`, `erbFeatScratch`, `fullCompressedScratch`, `recoveredRealScratch`, `recoveredImagScratch`, `featSliceScratch`, `zeroHopScratch`) and all input `MLMultiArray`s (`specBufIn`, `erbBufIn`, `featSpecBufIn`, `hEncIn`, `hErbIn`, `hDfIn`) are stored on the class and pre-allocated in `init()`. **Mutate them directly** (e.g. `magSqScratch[i] = ...`) — do NOT bind them to a local `let`/`var` first; Swift arrays COW-copy on first mutation through a local binding, defeating the purpose. For vDSP-style inout pointer APIs (`vDSP_DFT_Execute`, `vDSP_vmul`, `vDSP_vsmul`, `vDSP_vadd`), use `withUnsafeMutableBufferPointer` on the stored property and pass `baseAddress!`.
- All ML feature history (spec / erb / feat-spec) goes through `SpecHistoryRingBuffer` — never use Swift `Array.removeFirst` on a long-lived feature buffer.
- `process(input:count:output:)` (the outer entry point, not `processHop`) **does** still allocate an `Array(...)` for the input chunk. That is acceptable; the render callback runs on a background queue and the cost is bounded by `count`. Do not "fix" this without first measuring.
- The ML model produces **fresh** output `MLMultiArray`s each prediction (CoreML's API contract). Only the *input* `MLMultiArray`s are pre-allocated and reused; output arrays are not.
- Pre-allocated `MLMultiArray`s are safe to reuse because `prediction(input:)` is synchronous and the DSP is single-threaded.
```

**Step 2: Commit**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
git add AGENTS.md
git commit -m "docs: add AGENTS.md capturing DSP invariants from quality fix"
```

---

## Done criteria

- [ ] 6 of the 7 audit bugs fixed (bug 2 — normalizer warm-up — deferred to a follow-up plan). Net diff ~150 lines across 2 files in `Sources/Core/AudioProcessing/`.
- [ ] `swift test` passes (8 tests: 1 scaffold + 2 compression + 5 ring buffer — see Test Inventory below).
- [ ] `swift build -c release` clean.
- [ ] `git status --short Resources/DeepFilterNet3_Streaming.mlmodelc` empty — the bundled model was not touched.
- [ ] `bash bundle.sh` produces a working `MetalVoice.app`.
- [ ] `/Applications/MetalVoice.app` replaced; prior version backed up to `/tmp/MetalVoice.app.bak.<ts>`.
- [ ] Manual smoke test: AI toggle removes noise without robotic/muffled artifacts. The prior `compressP=0.6` should be perceptibly fixed (clearer, less hollow).
- [ ] `AGENTS.md` captures the DSP invariants so future agents don't regress.

### Test Inventory
| Task | Test | Asserts |
|---|---|---|
| 1 | `testScaffolding` | test target compiles |
| 2 | `testCompressionExponentMatchesModelTraining` | `DeepFilterNetDSP.compressionExponent == 0.5` (FAILS at 0.6) |
| 2 | `testCompressionRoundTripC0_5` | compress→decompress recovers magnitude |
| 3 | `testRingBufferStartsFullOfZeros` | init → capacity-shaped zero buffer |
| 3 | `testRingBufferAppendKeepsNewestAtEnd` | newest values land at the T-1 end |
| 3 | `testRingBufferDropsOldestOnOverflow` | FIFO drop on capacity overflow |
| 3 | `testRingBufferWrapAround` | storage wrap-around across hop boundaries |
| 3 | `testRingBufferChunkLargerThanCapacity` | chunk.count ≥ capacity keeps only the last `capacity` |
| **Total** | **8 tests** | |
