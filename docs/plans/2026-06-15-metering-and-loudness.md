# Metering & Loudness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship one shared **render-thread telemetry layer** that publishes lock-free scalars, and build two synergistic features on top of it: (1) a **Live HUD** — input/output level, sample-peak + a CLIP indicator, an "AI working hard" confidence signal, and added latency in ms; and (2) an **integrated LUFS loudness meter** (ITU-R BS.1770 K-weighting) with an optional **target-loudness normalization** stage (−14 / −16 LUFS) bounded by a true-peak-style ceiling that extends the existing `Limiter`.

**Architecture:** A new pure value type **`LoudnessMeter`** (Core/AudioProcessing) implements **real ITU-R BS.1770** K-weighting (the standard two-stage filter: a high-shelf "head" stage + an RLB high-pass stage, using the published 48 kHz biquad coefficients) → mean-square → gated integration, plus sample-peak tracking — fully headless-testable and validated at multiple frequencies against the BS.1770 calibration. The render/DSP threads publish metering state to the UI through plain **lock-free scalar snapshots** on `AudioModel` (mirroring the existing `DeepFilterNetDSP.outputGain` / `suppressionStrength` pattern — atomic 32-bit loads/stores on arm64, **no locks**). The `LoudnessMeter` value itself is **never read cross-thread**: it is mutated only on the render thread, which copies its plain getters into scalar snapshots (`tMomentaryLUFS`, `tIntegratedLUFS`, `tLoudnessSamplePeak`) that the UI timer reads — exactly like `inputLevel`. The render callback writes input level, output level, sample-peak, clip flag, added-latency, the LUFS snapshots, and (from `DeepFilterNetDSP`) an AI-confidence scalar derived from the model's per-bin gain reduction. A modest ~25 Hz `Timer` on `AudioModel` snapshots those scalars into `@Published` properties for SwiftUI. The HUD reuses `MeterView`; loudness normalization adds a pre-limiter auto-gain stage in `VoiceChain`, gated by a persisted `mv.*` toggle and target.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Package Manager, XCTest, Accelerate (per-sample scalar/biquad math; no CoreML dependency in any new pure type).

**GitHub Issue:** #3 — https://github.com/ivalsaraj/NoNoise-Mac/issues/3

**Execution location:** Run all commands from the package root — the directory that contains `Package.swift`. All paths in this plan are relative to that root.

---

## Context

### Why this feature
NoNoise Mac cleans the mic but gives the user **no feedback**: is my voice getting through? Is the AI actually suppressing anything, or is the room quiet? Am I clipping? Am I too quiet / too loud for the platform? Today the only signal is a single `inputLevel` RMS bar (`ContentView.MeterView`). Two creator-grade asks recur: a **Live HUD** that proves the pipeline is working (and warns on clipping), and a **loudness meter + normalization** so a streamer/podcaster lands near the platform target (−14 LUFS YouTube/Spotify, −16 LUFS Apple Podcasts) without manual gain-riding.

Both features want the **same data off the render thread** — levels, peaks, suppression activity. Building two ad-hoc paths would duplicate the unsafe main↔render plumbing. So this plan builds **one telemetry layer** first, then layers the HUD and the LUFS work on it.

### The non-negotiable constraint: the render thread stays allocation-free and lock-free
This plan satisfies it structurally (`docs/knowledge/critical-patterns.md` → "The render thread is allocation-free", "Suppression knobs are lock-free scalars (arm64)"):

1. **Telemetry is plain `Float`/`Int32` scalars**, written from the render/DSP threads and read from main — exactly the `outputGain` / `suppressionStrength` / `attenuationLimitDb` pattern. 32-bit aligned scalar load/store is atomic on arm64. **No locks, no `os_unfair_lock`, no queues** in the hot path.
2. **No allocation in `process`/`processHop`/the render callback.** Level/peak accumulation is scalar arithmetic over the existing in-place buffer; the AI-confidence accumulator reuses values already computed inside the per-bin blend loop.
3. **All BS.1770 / loudness math lives in a pure, headless-testable value type** (`LoudnessMeter`) with no CoreAudio/CoreML dependency — same rule as `Biquad`/`Compressor`/`resolveOutputBin`. The `LoudnessMeter` **struct is never read from the main thread**: it is mutated only on the render thread, which copies its plain getters into lock-free scalar snapshots that the UI timer reads. `AudioModel` itself is **not** unit-tested (its `init()` starts CoreAudio/AVFoundation); it is verified by `swift build` + the green Core suite + the manual smoke test.
4. **UI refresh is modest (~25 Hz), not per-sample.** A single `Timer.publish`/`Timer.scheduledTimer` on the main run loop snapshots the scalars into `@Published` properties — no needless polling, no per-buffer main-thread hops (the existing per-callback `inputLevel` `DispatchQueue.main.async` is **replaced** by the timer snapshot to cut main-thread churn).

### Honest scope calls (stated up front, per the perf mandate)
- **Sample-peak + CLIP flag for v1, NOT oversampled true-peak.** True ITU-R BS.1770-4 true-peak requires ≥4× oversampling per channel on the render thread — too heavy for an always-on menu-bar utility on every buffer. v1 ships **sample-peak** detection plus a **latched best-effort clip flag** — the render callback STORES 1 when any sample reaches a near-0 dBFS threshold; the UI timer reads the flag, shows CLIP, then clears it. It is deliberately NOT a monotonic counter: a cross-thread `&+=` read-modify-write is not atomic, so we only ever store 0/1 (a single atomic store on arm64), and a flag missed for one ~40 ms tick is acceptable for a UX warning. The loudness normalization ceiling is a **sample-peak ceiling labeled −3 dB "peak"** (not certified dBTP). True-peak oversampling is explicitly deferred; the `LoudnessMeter` API leaves room to add it later without changing call sites. This is documented in the UI copy and in `CONCEPTS.md` so we never claim certified true-peak.
- **Integrated (gated) LUFS as the headline number; momentary LUFS as the live needle.** Full BS.1770 integrated loudness gates with an absolute −70 LUFS gate **and** a relative −10 LU gate over the whole program — the relative gate needs the running mean of block loudnesses, which we keep as a streaming accumulator (no unbounded history). The HUD shows **momentary** loudness (400 ms window) as the live readout because it is cheap and responsive; the **integrated** number accumulates since the session/meter reset. Both come from the same `LoudnessMeter`. Short-term (3 s) is **not** shown in v1 (no third window) — stated so reviewers don't expect it.
- **AI-confidence is a derived heuristic, not a model output.** DeepFilterNet3 does not emit a "confidence". We derive an **activity** signal = average per-bin gain reduction the blend applied this hop (`1 − wetMag/dryMag`, clamped 0…1, energy-weighted), smoothed. High value = "AI is working hard" (lots of noise being removed). This is computed inside the existing blend loop in `DeepFilterNetDSP.processHop`, where `wetMag`/`dryMag` are already needed for the attenuation floor — near-zero extra cost. It is a UX hint, labeled as such; it is **not** a quality guarantee.

### Current code facts (verified against the repo)
- **Telemetry today:** `AudioModel.inputLevel: Float` (`Sources/Core/AudioModel.swift:24`) is the only meter. It is computed as a strided RMS in `captureOutput(...)` (lines ~673–687) and pushed with `DispatchQueue.main.async { self.inputLevel = rms }` **per capture callback**. There is **no** output-side meter, no peak, no clip, no latency readout.
- **Render callback** (`AudioModel.init`, the `AVAudioSourceNode` closure, lines ~153–193): reads `latencyTarget = 2400` samples (a hardcoded local, line ~167), pulls from `ringBuffer`, applies gain via `vDSP_vsmul`, then `if isAIEnabled { dsp.process(...); chain.process(...) }`. This is the render thread — **allocation-free, no locks**.
- **Added latency** is deterministic: the source-node `latencyTarget` (2400 / 48000 = 50 ms) plus the DSP's STFT hop latency (`frameSize 960` analysis / `hopSize 480`, i.e. one frame ≈ 20 ms) plus the AVAudioEngine I/O buffer. v1 reports the **known fixed component** (ring-buffer target + STFT frame) as "added latency", computed on main from constants — no per-sample measurement.
- **Lock-free scalar pattern** is already blessed: `DeepFilterNetDSP.outputGain` / `suppressionStrength` / `attenuationLimitDb` are plain `public var Float`, written from main, read on the render thread (`AGENTS.md` → "Presets & intensity knobs"; `critical-patterns.md` → "Suppression knobs are lock-free scalars"). Telemetry scalars are the **reverse direction** (render→main) but the same atomicity argument holds on arm64.
- **The blend loop** (`DeepFilterNetDSP.processHop`, lines ~498–509) iterates 481 bins, reading `wetR/wetI` (enhanced) and `rawSpecScratch` (dry) and calling `resolveOutputBin`. `resolveOutputBin` already computes `dryMag`/`wetMag` when `minGain > 0`. The AI-activity accumulator hooks in here.
- **`VoiceChain`** (`Sources/Core/AudioProcessing/VoiceChain.swift`) runs `hp → lowShelf → highShelf → presence → deEsser → comp → limiter` per sample (the Broadcast Voice stages already landed). `configure(_:)` recomputes coefficients on **main**; `process(_:count:)` runs on the **render thread**, allocation-free. The **limiter is last** and is the final ceiling guard. Loudness normalization adds a scalar make-up gain **before** the limiter.
- **`Biquad`** (`Sources/Core/AudioProcessing/Biquad.swift`) is a TDF-II RBJ biquad with `setBypass / setHighPass / setLowShelf / setHighShelf / setPeaking`, a `dcGain` test helper, and `process`. Its coefficients are `private`. **Real BS.1770 K-weighting needs the *exact* published two-stage coefficients**, not RBJ approximations — so Task 1 adds one small public method `setCoefficients(b0:b1:b2:a1:a2:)` to `Biquad` (a direct normalized-coefficient setter, additive and backward-compatible) and feeds it the standard 48 kHz K-weighting numbers. No existing `Biquad` behavior changes.
- **`Limiter`** (`Sources/Core/AudioProcessing/Dynamics.swift`) is `configure(ceilingDb:releaseMs:sampleRate:)` + per-sample `process` with a hard clamp. The normalization ceiling reuses this — we do **not** write a second limiter.
- **Persistence** uses the `mv.*` namespace via the `PrefKey` enum (`AudioModel.swift:114`), `persistSettings()` (~263), `loadSettings()` (~272), guarded by `isApplyingPreset`. New keys: `mv.loudnessNorm` (Bool) + `mv.loudnessTarget` (Float).
- **Tests** live in `Tests/NoNoiseMacTests/` (`@testable import Core`), run headless with `swift test`. Style references: `VoiceChainTests.swift`, `NoNoiseMacDSPTests.swift` (pure static-helper tests), `BroadcastVoiceTests.swift`.
- **UI:** `ContentView.swift` has `statusCard` (which already hosts `MeterView(level: audioModel.inputLevel)`), the shared `MeterView`, and the `nnCard()` modifier. `SettingsView.swift` → `GeneralSettingsView` has `suppressionCard` / `gainCard` and the `sliderRow(...)` / `sectionHeader(...)` helpers.

### Design decisions
- **One set of telemetry scalars, snapshotted once per UI tick.** The metering scalars live directly on `AudioModel` (the engine owns the truth). The render/DSP threads write them directly; a ~25 Hz timer reads them and assigns the `@Published` mirror properties. The `LoudnessMeter` struct is **owned and mutated only on the render thread** — the render callback copies its `momentaryLUFS` / `integratedLUFS` / `samplePeak` getters into `tMomentaryLUFS` / `tIntegratedLUFS` / `tLoudnessSamplePeak` scalars; the timer reads only those scalars, never the meter object. Rationale: a single source, a single main-thread touch-point, zero locks, no cross-thread struct access.
- **`LoudnessMeter` is the single source of loudness math** (mirroring how `resolveOutputBin`/`minGain` own the blend math and `Biquad` owns filter math). It owns real BS.1770 K-weighting (the standard two-stage shelf + RLB high-pass with the published 48 kHz coefficients), momentary + integrated computation, gating, and sample-peak. It is `Sendable`-friendly value semantics and 100% unit-tested against known BS.1770 reference values at **multiple frequencies** (the 1 kHz mono calibration tone plus a low-frequency and a high-frequency check that bound the K-weighting curve).
- **Loudness normalization is a gentle scalar auto-gain toward target, computed on main, applied as a lock-free scalar in `VoiceChain` before the limiter.** The meter (running on the DSP/render side) reports integrated/momentary loudness; the main-thread timer computes a target gain (`target − measured`, slew-limited to avoid pumping, clamped to a sane range e.g. ±12 dB) and writes a `loudnessGain` scalar that `VoiceChain.process` multiplies in. The limiter (−3 dB-labeled ceiling) catches any resulting peak. No new render-thread allocation; no per-sample gain solving.
- **Normalization is OFF by default.** Default behavior is byte-for-byte unchanged (gain = 1.0, meter purely passive/observational). Persisted under `mv.loudnessNorm` / `mv.loudnessTarget` (default target −14 LUFS).
- **Tuning values are documented starting points**, tunable after listening (same convention as the presets and Broadcast Voice).

### Telemetry fields (the whole HUD in one table)

| Field | Type | Written by | Meaning |
|---|---|---|---|
| `inputLevel` | `Float` | render callback (pre-DSP RMS) | mic level 0…~1 (existing semantics, moved to telemetry) |
| `outputLevel` | `Float` | render callback (post-chain RMS) | cleaned/processed output level |
| `samplePeak` | `Float` | render callback (post-chain max\|x\|) | peak magnitude this window |
| `tClipFlag` | `Int32` | render callback (set 1 when a sample ≥ clip threshold) | latched best-effort clip flag → UI shows CLIP, cleared each tick |
| `aiActivity` | `Float` | `DeepFilterNetDSP.processHop` blend loop | smoothed avg gain reduction 0…1 ("AI working hard") |
| `tMomentaryLUFS` | `Float` | render callback (snapshot of `LoudnessMeter.momentaryLUFS`) | live 400 ms loudness (−∞…0) |
| `tIntegratedLUFS` | `Float` | render callback (snapshot of `LoudnessMeter.integratedLUFS`) | gated integrated loudness since reset |
| `tLoudnessSamplePeak` | `Float` | render callback (snapshot of `LoudnessMeter.samplePeak`) | post-chain sample-peak since reset |
| `addedLatencyMs` | `Float` | main (from constants) | fixed pipeline latency readout |

### Telemetry update predicate (one canonical rule)
There is exactly **one** rule for when each scalar updates, used identically in Task 6 and the manual smoke test:
- **Render-side telemetry** (`outputLevel`, `outputPeak`, `tClipFlag`, `tMomentaryLUFS`, `tIntegratedLUFS`, `tLoudnessSamplePeak`, and `aiActivity`) is written **only inside the `if isAIEnabled` render branch** (after `dsp.process` / `chain.process`). So it is live **only while Noise Cancellation is ON**; when AI is OFF these hold their last value.
- **`inputLevel`** is the one exception: written in `captureOutput`, it updates **whenever audio is captured**, regardless of `isAIEnabled`.
- `addedLatencyMs` is a one-time constant (set in `init`).

Do NOT describe these any other way elsewhere in the plan — this table + rule are authoritative.

---

## Task 0: Branch

- [ ] **Step 1: Create a feature branch** (repo is on `main` with unrelated working-tree changes — do NOT stage those)

```bash
# Run from the package root (the directory that contains Package.swift)
git checkout -b feat/metering-and-loudness
```

Expected: `Switched to a new branch 'feat/metering-and-loudness'`. Throughout this plan, `git add` **only the specific files named in each task** — never `git add -A`/`.`.

---

## Task 1: `LoudnessMeter` — BS.1770 K-weighting + momentary loudness — TDD

The pure loudness value type. Start with **real ITU-R BS.1770** K-weighting and the momentary (400 ms) measurement, validated against the standard calibration tone at multiple frequencies.

**Files:**
- Modify: `Sources/Core/AudioProcessing/Biquad.swift` (add a direct-coefficient setter)
- Create: `Sources/Core/AudioProcessing/LoudnessMeter.swift`
- Create: `Tests/NoNoiseMacTests/LoudnessMeterTests.swift`

- [ ] **Step 1: Write the failing tests** — create `Tests/NoNoiseMacTests/LoudnessMeterTests.swift`

```swift
import XCTest
@testable import Core

final class LoudnessMeterTests: XCTestCase {

    /// A fresh meter reports silence (the −∞ sentinel) before any audio.
    func testFreshMeterIsSilent() {
        let m = LoudnessMeter(sampleRate: 48000)
        XCTAssertEqual(m.momentaryLUFS, LoudnessMeter.silenceLUFS, accuracy: 1e-3)
        XCTAssertEqual(m.integratedLUFS, LoudnessMeter.silenceLUFS, accuracy: 1e-3)
    }

    /// Feed `seconds` of a sine at `freq`/`dbfs` into a fresh meter and return its
    /// momentary LUFS. Helper so the calibration tests stay readable.
    private func measureMomentaryLUFS(freq: Float, dbfs: Float, seconds: Float = 0.6) -> Float {
        var m = LoudnessMeter(sampleRate: 48000)
        let amp = powf(10, dbfs / 20.0)
        let n = Int(seconds * 48000)
        for i in 0..<n { m.process(amp * sinf(2 * Float.pi * freq * Float(i) / 48000)) }
        return m.momentaryLUFS
    }

    /// BS.1770 calibration anchor: a 1 kHz sine at −20 dBFS reads ≈ −23 LUFS mono
    /// (the standard −3.01 LU mono offset; the K-weighting gain at 1 kHz is ≈ 0 dB).
    /// Tolerance is tight (±0.5 LU) because REAL BS.1770 coefficients must hit the
    /// reference, not merely approximate it.
    func testKWeighted1kSineReadsCalibratedLUFS() {
        XCTAssertEqual(measureMomentaryLUFS(freq: 1000, dbfs: -20), -23.0, accuracy: 0.5,
                       "−20 dBFS 1 kHz sine must read ≈ −23 LUFS (BS.1770 mono)")
    }

    /// The K-weighting RLB high-pass attenuates low frequencies: a 60 Hz tone at the
    /// SAME −20 dBFS reads several LU QUIETER than the 1 kHz reference (the curve dips
    /// well below 0 dB at 60 Hz). This proves the high-pass stage is real, not a no-op.
    func testKWeightingAttenuatesLowFrequency() {
        let ref = measureMomentaryLUFS(freq: 1000, dbfs: -20)
        let low = measureMomentaryLUFS(freq: 60,   dbfs: -20)
        XCTAssertLessThan(low, ref - 1.0,
                          "BS.1770 K-weighting must roll off 60 Hz below the 1 kHz reference")
    }

    /// The K-weighting high-shelf boosts highs: a 6 kHz tone at the SAME −20 dBFS reads
    /// LOUDER than the 1 kHz reference (the +4 dB shelf is fully engaged above ~2 kHz).
    /// This proves the shelf stage is real and lifts (not flattens) the top end.
    func testKWeightingBoostsHighFrequency() {
        let ref  = measureMomentaryLUFS(freq: 1000, dbfs: -20)
        let high = measureMomentaryLUFS(freq: 6000, dbfs: -20)
        XCTAssertGreaterThan(high, ref + 1.0,
                             "BS.1770 K-weighting high-shelf must lift 6 kHz above the 1 kHz reference")
    }

    /// Louder in ⇒ higher (less negative) LUFS — monotonic.
    func testLouderInputReadsHigherLUFS() {
        XCTAssertGreaterThan(measureMomentaryLUFS(freq: 1000, dbfs: -12),
                             measureMomentaryLUFS(freq: 1000, dbfs: -20))
        XCTAssertGreaterThan(measureMomentaryLUFS(freq: 1000, dbfs: -20),
                             measureMomentaryLUFS(freq: 1000, dbfs: -30))
    }

    /// Sample-peak tracks the true max magnitude fed since reset.
    func testSamplePeakTracksMaxMagnitude() {
        var m = LoudnessMeter(sampleRate: 48000)
        for x in [Float(0.1), -0.4, 0.9, -0.2] { m.process(x) }
        XCTAssertEqual(m.samplePeak, 0.9, accuracy: 1e-6)
    }

    /// reset() returns the meter to the silent/no-peak state.
    func testResetClearsState() {
        var m = LoudnessMeter(sampleRate: 48000)
        for i in 0..<24000 { m.process(0.5 * sinf(2 * Float.pi * 1000 * Float(i) / 48000)) }
        m.reset()
        XCTAssertEqual(m.momentaryLUFS, LoudnessMeter.silenceLUFS, accuracy: 1e-3)
        XCTAssertEqual(m.samplePeak, 0, accuracy: 1e-9)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter LoudnessMeterTests`
Expected: compile error — `cannot find 'LoudnessMeter' in scope`.

- [ ] **Step 3: Add a direct-coefficient setter to `Biquad`** — `Sources/Core/AudioProcessing/Biquad.swift`

The RBJ factories cannot reproduce the *exact* BS.1770 filter, so add a small public setter for pre-computed normalized coefficients (additive — no existing behavior changes). Place it next to `setBypass()`:

```swift
    /// Set pre-computed, already-normalized (a0 == 1) biquad coefficients directly.
    /// Used for filters whose coefficients are specified by a standard (e.g. the
    /// ITU-R BS.1770 K-weighting stages) rather than derived from an RBJ formula.
    public mutating func setCoefficients(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }
```

- [ ] **Step 4: Implement `LoudnessMeter` (real BS.1770 K-weighting + momentary + sample-peak)** — create `Sources/Core/AudioProcessing/LoudnessMeter.swift`

```swift
import Foundation

/// ITU-R BS.1770 (K-weighted) loudness meter — a pure, allocation-free value type.
/// Stage 1 = the "pre-filter" head high-shelf (≈ +4 dB above ~1.5 kHz); stage 2 =
/// the RLB high-pass (≈ −3 dB at ~38 Hz). Both use the STANDARD's published 48 kHz
/// biquad coefficients (not RBJ approximations) so the meter reads true BS.1770
/// loudness across the spectrum. Then: K-weighted mean-square over a sliding
/// momentary window (400 ms). Mono measurement applies the standard −0.691 dB
/// calibration offset. Integrated (gated) loudness is added in Task 2.
///
/// Sample-peak is tracked alongside (NOT certified true-peak — see CONCEPTS.md;
/// oversampled dBTP is deferred for the Apple-Silicon perf mandate).
///
/// IMPORTANT: this struct is mutated ONLY on the render thread. `AudioModel` copies
/// its scalar getters into lock-free telemetry snapshots; it is never read from the
/// main thread (no cross-thread struct access — see the plan's Architecture note).
public struct LoudnessMeter {
    /// Sentinel "silence" value (well below the BS.1770 absolute gate of −70 LUFS).
    public static let silenceLUFS: Float = -120

    private let sampleRate: Float
    private var shelf = Biquad()       // K-weighting stage 1 (head high-shelf)
    private var hp = Biquad()          // K-weighting stage 2 (RLB high-pass)

    // Momentary window: sum of K-weighted mean-square over the last ~400 ms.
    private var momentaryRing: [Float]
    private var momentaryHead = 0
    private var momentaryFilled = 0
    private var momentarySum: Float = 0

    private(set) public var samplePeak: Float = 0

    public init(sampleRate: Float = 48000) {
        self.sampleRate = sampleRate
        // The published BS.1770 K-weighting coefficients below are defined at 48 kHz,
        // which is the engine's fixed render rate (see AGENTS.md DSP invariants). Guard
        // the assumption so a future rate change fails loudly instead of mis-measuring.
        assert(sampleRate == 48000, "BS.1770 K-weighting coefficients assume 48 kHz")
        // ITU-R BS.1770 K-weighting — the standard's two-stage filter, specified
        // directly as 48 kHz biquad coefficients (BS.1770-4 Tables 1 & 2). These are
        // the canonical, widely-published numbers; do NOT swap in RBJ approximations
        // (the multi-frequency calibration tests bound the error tightly).
        //
        // Stage 1: head/pre-filter high-shelf (+4 dB shelf, ~1.5 kHz hinge).
        shelf.setCoefficients(b0: 1.53512485958697, b1: -2.69169618940638, b2: 1.19839281085285,
                              a1: -1.69065929318241, a2: 0.73248077421585)
        // Stage 2: RLB high-pass (~38 Hz, removes sub-bass energy from the measure).
        hp.setCoefficients(b0: 1.0, b1: -2.0, b2: 1.0,
                           a1: -1.99004745483398, a2: 0.99007225036621)
        let windowLen = max(1, Int(0.4 * sampleRate))   // 400 ms momentary window
        momentaryRing = [Float](repeating: 0, count: windowLen)
    }

    public mutating func reset() {
        shelf.reset(); hp.reset()
        for i in 0..<momentaryRing.count { momentaryRing[i] = 0 }
        momentaryHead = 0; momentaryFilled = 0; momentarySum = 0
        samplePeak = 0
    }

    /// Feed one sample. Updates the K-weighted momentary mean-square ring and the
    /// sample-peak. Allocation-free.
    @inline(__always)
    public mutating func process(_ x: Float) {
        let mag = abs(x)
        if mag > samplePeak { samplePeak = mag }
        let k = hp.process(shelf.process(x))     // K-weighted sample
        let sq = k * k
        // Sliding-window sum: subtract the slot we overwrite, add the new square.
        momentarySum += sq - momentaryRing[momentaryHead]
        momentaryRing[momentaryHead] = sq
        momentaryHead += 1
        if momentaryHead == momentaryRing.count { momentaryHead = 0 }
        if momentaryFilled < momentaryRing.count { momentaryFilled += 1 }
    }

    /// Loudness of the current momentary (400 ms) window, in LUFS. Returns the
    /// silence sentinel until the window has any energy.
    public var momentaryLUFS: Float {
        Self.loudness(meanSquare: momentaryFilled > 0 ? momentarySum / Float(momentaryFilled) : 0)
    }

    /// Integrated (gated) loudness — implemented in Task 2. Until then it mirrors
    /// momentary so the property exists for the telemetry wiring.
    public var integratedLUFS: Float { momentaryLUFS }

    /// LUFS from a K-weighted mean-square value, with the BS.1770 −0.691 dB offset.
    /// Returns the silence sentinel for non-positive energy.
    static func loudness(meanSquare ms: Float) -> Float {
        guard ms > 0 else { return silenceLUFS }
        return -0.691 + 10 * log10f(ms)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter LoudnessMeterTests`
Expected: 7 tests PASS (silence, 1 kHz calibration, low-freq roll-off, high-freq lift, monotonic, sample-peak, reset). The calibration tone and the two frequency-shape tests pass because the coefficients are the REAL BS.1770 numbers — do NOT loosen the tolerances or swap in RBJ approximations; if a frequency test fails, the coefficients were mistranscribed.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/AudioProcessing/Biquad.swift Sources/Core/AudioProcessing/LoudnessMeter.swift Tests/NoNoiseMacTests/LoudnessMeterTests.swift
git commit -m "feat(dsp): add LoudnessMeter (real BS.1770 K-weighting + momentary LUFS + sample-peak)"
```

---

## Task 2: Integrated (gated) LUFS — TDD

Add gated integration to `LoudnessMeter`: per-400 ms-block loudness, absolute −70 LUFS gate, relative −10 LU gate over the running block set. Use a streaming accumulator (no unbounded history).

**Files:**
- Modify: `Sources/Core/AudioProcessing/LoudnessMeter.swift`
- Modify: `Tests/NoNoiseMacTests/LoudnessMeterTests.swift` (add tests)

- [ ] **Step 1: Write the failing tests** — add inside `LoudnessMeterTests`

```swift
    // MARK: - Integrated (gated) loudness

    /// A steady tone yields an integrated value ≈ its momentary value.
    func testIntegratedMatchesSteadyTone() {
        var m = LoudnessMeter(sampleRate: 48000)
        let amp = powf(10, -20.0 / 20.0)
        for i in 0..<96000 { m.process(amp * sinf(2 * Float.pi * 1000 * Float(i) / 48000)) } // 2 s
        XCTAssertEqual(m.integratedLUFS, m.momentaryLUFS, accuracy: 1.0)
        XCTAssertEqual(m.integratedLUFS, -23.0, accuracy: 1.0)
    }

    /// Silence below the absolute −70 LUFS gate does NOT drag the integrated value
    /// down: a loud passage followed by silence still integrates near the loud level.
    func testIntegratedGatesOutSilence() {
        var m = LoudnessMeter(sampleRate: 48000)
        let amp = powf(10, -20.0 / 20.0)
        for i in 0..<96000 { m.process(amp * sinf(2 * Float.pi * 1000 * Float(i) / 48000)) } // 2 s loud
        for _ in 0..<96000 { m.process(0) }                                                  // 2 s silence
        XCTAssertEqual(m.integratedLUFS, -23.0, accuracy: 1.5,
                       "gated integration must ignore the silent gap")
    }

    /// Integrated loudness ignores blocks below the relative gate (quiet vs loud).
    func testIntegratedIsGatedNotPlainAverage() {
        var m = LoudnessMeter(sampleRate: 48000)
        let loud = powf(10, -14.0 / 20.0)
        let quiet = powf(10, -50.0 / 20.0)  // > 10 LU below loud → gated out
        for i in 0..<96000 { m.process(loud  * sinf(2 * Float.pi * 1000 * Float(i) / 48000)) }
        for i in 0..<96000 { m.process(quiet * sinf(2 * Float.pi * 1000 * Float(i) / 48000)) }
        let plainAverageWouldBe: Float = -20  // rough midpoint if NOT gated
        XCTAssertGreaterThan(m.integratedLUFS, plainAverageWouldBe,
                             "relative gate must drop the quiet blocks, keeping the level near the loud passage")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter LoudnessMeterTests`
Expected: the three new tests FAIL (integrated currently just mirrors momentary — `testIntegratedGatesOutSilence` and `testIntegratedIsGatedNotPlainAverage` fail).

- [ ] **Step 3: Add gated integration** to `LoudnessMeter`

> **CRITICAL real-time-safety rule (do not violate):** block finalization runs inside `process(_:)` on the render thread. It must be **allocation-free** — NEVER `append`/`removeFirst`/grow any array. The per-block mean-square values for the relative gate are stored in a **pre-allocated fixed-size ring** written by index with wraparound. The ring is a bounded rolling window (the last `maxBlocks` absolute-gated blocks) — long past any realtime session — so memory is fixed and the relative gate stays accurate for the whole program. This mirrors the momentary ring; no unbounded history, no render-path allocation.

Add block-accumulation state (alongside the momentary state). The `blockMSRing` is **pre-allocated once in `init`** and written by index — exactly like `momentaryRing`:

```swift
    // Integrated (gated) state — per 400 ms block. Running sums + a fixed-size ring
    // of absolute-gated block mean-squares for the relative gate. NO growth: the ring
    // is pre-allocated and written by index (wraparound), so process() never allocates.
    private var blockLen = 0                    // samples per 400 ms block (set in init)
    private var blockMeanSquareSum: Float = 0   // Σ mean-square accumulated in the current block
    private var blockSamples = 0                // samples seen in the current block
    // Absolute-gate-passing blocks: count + Σ mean-square (for the relative gate's threshold).
    private var absGatedCount = 0
    private var absGatedMSSum: Float = 0
    // Fixed-size ring of absolute-gated block mean-squares (the relative-gate input).
    // Pre-allocated; write-by-index with wraparound — NEVER appended to on the render path.
    private static let maxBlocks = 9000         // 9000 × 400 ms = 1 h rolling window (bounded)
    private var blockMSRing: [Float]            // count == maxBlocks (allocated in init)
    private var blockMSRingHead = 0             // next write slot (wraps at maxBlocks)
    private var blockMSRingFilled = 0           // how many slots hold real data (≤ maxBlocks)
```

In `init`, set `blockLen = max(1, Int(0.4 * sampleRate))` and pre-allocate the ring:

```swift
        blockLen = max(1, Int(0.4 * sampleRate))
        blockMSRing = [Float](repeating: 0, count: Self.maxBlocks)
```

> **Note:** because a stored property (`blockMSRing`) is referenced before all stored properties are initialized in some orderings, declare `blockMSRing` with a default empty-but-replaced value is NOT allowed for a `let`; keep it a `var` and assign the full-size buffer in `init` before first use (the `momentaryRing` pattern). The 1 h window is far longer than any realtime session, so the rolling cap never affects a real measurement; it only bounds memory.

Implement block finalization inside `process(_:)` (after the momentary update) — **allocation-free, write-by-index only**:

```swift
        // Integrated (gated) block accumulation — runs on the render thread, no alloc.
        blockMeanSquareSum += sq
        blockSamples += 1
        if blockSamples >= blockLen {
            let blockMS = blockMeanSquareSum / Float(blockSamples)
            // Absolute gate: keep only blocks louder than the −70 LUFS floor.
            if Self.loudness(meanSquare: blockMS) > -70 {
                absGatedCount += 1
                absGatedMSSum += blockMS
                // Write into the fixed ring by index (wraparound) — never append.
                blockMSRing[blockMSRingHead] = blockMS
                blockMSRingHead += 1
                if blockMSRingHead == Self.maxBlocks { blockMSRingHead = 0 }
                if blockMSRingFilled < Self.maxBlocks { blockMSRingFilled += 1 }
            }
            blockMeanSquareSum = 0
            blockSamples = 0
        }
```

Compute `integratedLUFS` from the relative-gated set (iterates the fixed ring — no allocation):

```swift
    public var integratedLUFS: Float {
        guard blockMSRingFilled > 0, absGatedCount > 0 else { return Self.silenceLUFS }
        // Relative gate: −10 LU below the mean loudness of absolute-gated blocks.
        // (Mean uses the running absGatedMSSum/absGatedCount; the ring bounds memory.)
        let absMeanMS = absGatedMSSum / Float(absGatedCount)
        let relThresholdMS = absMeanMS * powf(10, -10.0 / 10.0)   // −10 LU in the power domain
        var count = 0
        var msSum: Float = 0
        for i in 0..<blockMSRingFilled where blockMSRing[i] >= relThresholdMS {
            count += 1; msSum += blockMSRing[i]
        }
        guard count > 0 else { return Self.loudness(meanSquare: absMeanMS) }
        return Self.loudness(meanSquare: msSum / Float(count))
    }
```

Update `reset()` to clear the new block state (`blockMeanSquareSum = 0; blockSamples = 0; absGatedCount = 0; absGatedMSSum = 0; blockMSRingHead = 0; blockMSRingFilled = 0` and zero `blockMSRing`). (Remove the temporary `integratedLUFS { momentaryLUFS }` from Task 1.)

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter LoudnessMeterTests`
Expected: all 8 `LoudnessMeterTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/LoudnessMeter.swift Tests/NoNoiseMacTests/LoudnessMeterTests.swift
git commit -m "feat(dsp): add gated integrated LUFS (BS.1770 absolute + relative gating)"
```

---

## Task 3: Loudness normalization gain — pure helper — TDD

The math that maps measured loudness + target → a slew-limited make-up gain (toward target, no pumping, clamped). Pure static helper so it is testable without `AudioModel`/CoreAudio (mirrors `minGain` / `resolveOutputBin`).

**Files:**
- Modify: `Sources/Core/AudioProcessing/LoudnessMeter.swift` (add static helper)
- Modify: `Tests/NoNoiseMacTests/LoudnessMeterTests.swift` (add tests)

- [ ] **Step 1: Write the failing tests** — add inside `LoudnessMeterTests`

```swift
    // MARK: - Normalization gain

    /// Quiet program (below target) ⇒ make-up gain > 1 (boost toward target).
    func testNormGainBoostsQuietProgram() {
        let g = LoudnessMeter.normalizationGain(measuredLUFS: -23, targetLUFS: -14,
                                                currentGain: 1, maxDb: 12, slewDb: 12)
        XCTAssertGreaterThan(g, 1.0)
    }

    /// Loud program (above target) ⇒ gain < 1 (pull down toward target).
    func testNormGainAttenuatesLoudProgram() {
        let g = LoudnessMeter.normalizationGain(measuredLUFS: -8, targetLUFS: -14,
                                                currentGain: 1, maxDb: 12, slewDb: 12)
        XCTAssertLessThan(g, 1.0)
    }

    /// The make-up gain is clamped to ±maxDb so a near-silent meter can't blow up.
    func testNormGainIsClampedToMaxDb() {
        let g = LoudnessMeter.normalizationGain(measuredLUFS: -90, targetLUFS: -14,
                                                currentGain: 1, maxDb: 12, slewDb: 100)
        XCTAssertLessThanOrEqual(g, powf(10, 12.0 / 20.0) + 1e-4, "gain capped at +12 dB")
    }

    /// Silence (below the absolute gate) holds the current gain — no gain-pumping on gaps.
    func testNormGainHoldsOnSilence() {
        let g = LoudnessMeter.normalizationGain(measuredLUFS: LoudnessMeter.silenceLUFS,
                                                targetLUFS: -14, currentGain: 1.7, maxDb: 12, slewDb: 12)
        XCTAssertEqual(g, 1.7, accuracy: 1e-6, "no measurement → hold gain (no pumping)")
    }

    /// Per-update change is slew-limited (can't jump the full distance in one tick).
    func testNormGainIsSlewLimited() {
        // Target needs +9 dB but slew caps the per-tick move at +3 dB from unity.
        let g = LoudnessMeter.normalizationGain(measuredLUFS: -23, targetLUFS: -14,
                                                currentGain: 1, maxDb: 12, slewDb: 3)
        XCTAssertLessThanOrEqual(g, powf(10, 3.0 / 20.0) + 1e-4, "slew caps the step")
        XCTAssertGreaterThan(g, 1.0)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter LoudnessMeterTests`
Expected: compile error — `type 'LoudnessMeter' has no member 'normalizationGain'`.

- [ ] **Step 3: Add the static helper** to `LoudnessMeter`

```swift
    /// Slew-limited make-up gain toward a loudness target. Returns a LINEAR gain
    /// to multiply the signal by. Holds `currentGain` when there is no measurement
    /// (silence below the absolute gate) so silent gaps never cause pumping.
    /// `maxDb` clamps the absolute make-up; `slewDb` caps the per-update change.
    static func normalizationGain(measuredLUFS: Float, targetLUFS: Float,
                                  currentGain: Float, maxDb: Float, slewDb: Float) -> Float {
        guard measuredLUFS > silenceLUFS else { return currentGain }   // no data → hold
        let neededDb = targetLUFS - measuredLUFS                       // + = boost, − = cut
        let clampedTargetDb = min(max(neededDb, -abs(maxDb)), abs(maxDb))
        let targetGain = powf(10, clampedTargetDb / 20)
        // Slew toward targetGain in the dB domain so steps are perceptually even.
        let currentDb = 20 * log10f(max(currentGain, 1e-6))
        let targetGainDb = 20 * log10f(max(targetGain, 1e-6))
        let stepDb = min(max(targetGainDb - currentDb, -abs(slewDb)), abs(slewDb))
        return powf(10, (currentDb + stepDb) / 20)
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter LoudnessMeterTests`
Expected: all `LoudnessMeterTests` PASS (8 + 5 = 13).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/LoudnessMeter.swift Tests/NoNoiseMacTests/LoudnessMeterTests.swift
git commit -m "feat(dsp): add slew-limited loudness normalization gain helper"
```

---

## Task 4: AI-activity signal from the DSP blend — TDD

Expose a smoothed "AI working hard" scalar derived from the per-bin gain reduction the blend already computes. The math is a pure static helper; the accumulation hooks into `processHop`.

**Files:**
- Modify: `Sources/Core/AudioProcessing/DeepFilterNetDSP.swift` (static helper + accumulator + lock-free scalar)
- Modify: `Tests/NoNoiseMacTests/NoNoiseMacDSPTests.swift` (add tests)

- [ ] **Step 1: Write the failing tests** — add inside `NoNoiseMacDSPTests`

```swift
    // MARK: - AI activity (suppression confidence)

    /// No reduction (wet == dry magnitude) ⇒ activity 0 ("AI doing nothing").
    func testAIActivityZeroWhenWetEqualsDry() {
        let a = DeepFilterNetDSP.binActivity(dryMag: 0.5, wetMag: 0.5)
        XCTAssertEqual(a, 0, accuracy: 1e-6)
    }

    /// Full suppression (wet ~0 against real dry) ⇒ activity ~1 ("AI working hard").
    func testAIActivityOneWhenFullySuppressed() {
        let a = DeepFilterNetDSP.binActivity(dryMag: 0.5, wetMag: 0.0)
        XCTAssertEqual(a, 1, accuracy: 1e-6)
    }

    /// Half suppression ⇒ ~0.5.
    func testAIActivityHalfWhenHalfSuppressed() {
        let a = DeepFilterNetDSP.binActivity(dryMag: 1.0, wetMag: 0.5)
        XCTAssertEqual(a, 0.5, accuracy: 1e-6)
    }

    /// Silence (dry ~0) ⇒ activity 0 (no division blow-up; nothing to suppress).
    func testAIActivityZeroOnSilentDry() {
        let a = DeepFilterNetDSP.binActivity(dryMag: 0.0, wetMag: 0.0)
        XCTAssertEqual(a, 0, accuracy: 1e-6)
    }

    /// Wet louder than dry (the model added energy) clamps to 0, never negative.
    func testAIActivityClampsWhenWetExceedsDry() {
        let a = DeepFilterNetDSP.binActivity(dryMag: 0.2, wetMag: 0.5)
        XCTAssertEqual(a, 0, accuracy: 1e-6)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter NoNoiseMacDSPTests`
Expected: compile error — `type 'DeepFilterNetDSP' has no member 'binActivity'`.

- [ ] **Step 3: Add the helper + scalar + accumulation** to `DeepFilterNetDSP`

Add the pure helper (place it next to `minGain` / `resolveOutputBin`):

```swift
    /// Per-bin suppression "activity": how much the enhanced (wet) magnitude was
    /// reduced relative to the dry magnitude, clamped to [0, 1]. 0 = no reduction
    /// (or silence / wet ≥ dry), 1 = fully suppressed. Pure → unit-testable.
    static func binActivity(dryMag: Float, wetMag: Float) -> Float {
        guard dryMag > 1e-9 else { return 0 }
        let reduction = 1 - wetMag / dryMag
        return min(max(reduction, 0), 1)
    }
```

Add a lock-free telemetry scalar (mirroring `outputGain` — written on the DSP/render side, read on main):

```swift
    /// Smoothed "AI working hard" signal in [0, 1] — the energy-weighted average
    /// per-bin suppression applied last hop, one-pole smoothed. Written on the DSP
    /// thread, read from main (lock-free scalar; atomic on arm64 — same pattern as
    /// `outputGain`). UX hint only; NOT a model-quality guarantee.
    public var aiActivity: Float = 0
```

In `processHop`, inside the existing blend loop (lines ~498–509), accumulate energy-weighted reduction using the dry/wet magnitudes (compute them once per bin — `dryMag` is already available where `minGain > 0`; compute both unconditionally here since the loop already reads `wetR/wetI` and `rawSpecScratch`). After the loop, fold into the smoothed scalar:

```swift
        // (declare before the loop)
        var actWeightSum: Float = 0     // Σ dryMag (energy weight)
        var actValueSum: Float = 0      // Σ dryMag · binActivity
        // (inside the loop, after computing outR/outI for bin i)
        let dMag = sqrtf(rawSpecScratch[i*2] * rawSpecScratch[i*2] + rawSpecScratch[i*2+1] * rawSpecScratch[i*2+1])
        let wMag = sqrtf(wetR * wetR + wetI * wetI)
        let act = Self.binActivity(dryMag: dMag, wetMag: wMag)
        actWeightSum += dMag
        actValueSum += dMag * act
        // (after the loop)
        let hopActivity = actWeightSum > 1e-9 ? actValueSum / actWeightSum : 0
        let smooth: Float = 0.85   // one-pole smoothing across hops
        aiActivity = smooth * aiActivity + (1 - smooth) * hopActivity
```

> **Perf note for the executor:** `binActivity` and the two `sqrtf`s run 481×/hop. This is scalar arithmetic on data already in registers/L1 from the blend; it does NOT allocate. The smoothing fold is O(1). Keep it inside the `if isModelLoaded` block (only meaningful when the model ran). When the model is loading / AI off, leave `aiActivity` decaying toward 0 (optional: in the `else` branch set `aiActivity *= smooth`).

- [ ] **Step 4: Run to verify pass + full suite**

Run: `swift test`
Expected: the 5 new activity tests PASS; all existing tests still PASS (no behavior change to the blend output — `aiActivity` is read-only telemetry).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/DeepFilterNetDSP.swift Tests/NoNoiseMacTests/NoNoiseMacDSPTests.swift
git commit -m "feat(dsp): derive AI-activity telemetry from per-bin suppression"
```

---

## Task 5: Loudness normalization gain + activation in `VoiceChain` — TDD

Carry a `loudnessGain` lock-free scalar on `VoiceChain`, applied as a pre-limiter make-up multiply (default 1.0 / no-op; the limiter — already last — is the ceiling guard), AND add a `loudnessActive` activation reason to `VoiceChainSettings` so the limiter + make-up run even when polish and clarity are both off. The activation predicate and its test live together here (the contract); `AudioModel.applyVoiceChain()` sets `s.loudnessActive = loudnessNormEnabled` in Task 6 — they move as a pair.

**Files:**
- Modify: `Sources/Core/AudioProcessing/VoiceChain.swift` (scalar + apply before limiter + `loudnessActive` activation)
- Modify: `Tests/NoNoiseMacTests/VoiceChainTests.swift` (add tests)

- [ ] **Step 1: Write the failing tests** — add inside `VoiceChainTests`

```swift
    // MARK: - Loudness normalization gain

    /// Default loudnessGain (1.0) is a no-op: disabled chain still passes through.
    func testLoudnessGainDefaultIsNoOp() {
        let chain = VoiceChain()
        chain.configure(.disabled)               // polish off, clarity off
        var buf: [Float] = [0.1, -0.2, 0.3, -0.4]
        let copy = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(buf, copy, "default loudnessGain must not alter samples")
    }

    /// A loudnessGain > 1 boosts the signal (still within the limiter ceiling).
    /// TWO separately-configured chains: one at gain 2.0, one at gain 1.0, fed
    /// IDENTICAL input. The 2.0 chain must end louder. (The earlier version mutated
    /// the gain back to 1.0 on the same chain before processing — a no-op test.)
    func testLoudnessGainBoostsWhenActive() {
        let boosted = VoiceChain(); boosted.configure(VoicePreset.podcast.voiceChain)
        boosted.setLoudnessGain(2.0)
        let unity = VoiceChain(); unity.configure(VoicePreset.podcast.voiceChain)
        unity.setLoudnessGain(1.0)
        // Low-level input so neither chain hits the limiter ceiling (isolate the gain).
        var loud  = [Float](repeating: 0.02, count: 4800)
        var quiet = [Float](repeating: 0.02, count: 4800)
        loud.withUnsafeMutableBufferPointer  { boosted.process($0.baseAddress!, count: $0.count) }
        quiet.withUnsafeMutableBufferPointer { unity.process($0.baseAddress!,   count: $0.count) }
        let rmsLoud  = sqrtf(loud.reduce(0)  { $0 + $1*$1 } / Float(loud.count))
        let rmsQuiet = sqrtf(quiet.reduce(0) { $0 + $1*$1 } / Float(quiet.count))
        XCTAssertGreaterThan(rmsLoud, rmsQuiet,
                             "the 2.0-gain chain must end louder than the 1.0-gain chain")
    }

    /// Even with a large loudnessGain, the limiter still caps output at the ceiling.
    func testLoudnessGainStillRespectsLimiterCeiling() {
        let chain = VoiceChain()
        chain.configure(VoicePreset.podcast.voiceChain)
        chain.setLoudnessGain(8.0)               // extreme boost
        var buf = [Float](repeating: 0.5, count: 4800)
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        let ceiling = powf(10, -1.0 / 20.0)      // podcast limiter ceiling
        XCTAssertTrue(buf.allSatisfy { abs($0) <= ceiling + 1e-3 }, "limiter must still hold the ceiling")
    }

    // MARK: - loudnessActive activation (polish + clarity both off)

    /// `loudnessActive == true` ALONE activates the chain (limiter + make-up gain)
    /// even when polish and clarity are off — so normalization works in Meeting mode.
    func testLoudnessActiveAloneActivatesGainAndLimiter() {
        var s = VoiceChainSettings.disabled        // polish off, clarity off
        s.loudnessActive = true
        let chain = VoiceChain()
        chain.configure(s)
        XCTAssertTrue(chain.isActive, "loudnessActive alone must activate the chain")
        chain.setLoudnessGain(2.0)
        var buf = [Float](repeating: 0.02, count: 4800)
        let input = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        let rmsOut = sqrtf(buf.reduce(0)  { $0 + $1*$1 } / Float(buf.count))
        let rmsIn  = sqrtf(input.reduce(0) { $0 + $1*$1 } / Float(input.count))
        XCTAssertGreaterThan(rmsOut, rmsIn, "make-up gain must apply when loudnessActive activates the chain")
    }

    /// With every feature off (polish off, clarity off, loudnessActive false), output
    /// is byte-for-byte unchanged — the chain is inactive and never touches samples.
    func testDisabledChainWithLoudnessInactiveIsUnchanged() {
        var s = VoiceChainSettings.disabled
        s.loudnessActive = false
        let chain = VoiceChain()
        chain.configure(s)
        XCTAssertFalse(chain.isActive, "no active reason ⇒ inactive chain")
        chain.setLoudnessGain(2.0)                 // set, but inactive chain must ignore it
        var buf: [Float] = [0.1, -0.2, 0.3, -0.4]
        let copy = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(buf, copy, "feature-off output must be unchanged even with loudnessGain set")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter VoiceChainTests`
Expected: compile error — `value of type 'VoiceChain' has no member 'setLoudnessGain'`.

- [ ] **Step 3: Add the `loudnessActive` field, the scalar, and the apply** in `VoiceChain`

First add the `loudnessActive` activation reason to `VoiceChainSettings` (memberwise-default `false` keeps every existing call site source-compatible; `.disabled` inherits the default):

```swift
    public var clarity: ClarityLevel = .off
    /// Loudness normalization is on. An independent activation reason: when true the
    /// chain runs (limiter + pre-limiter make-up gain) even with polish and clarity
    /// off, so normalization works in Meeting mode. Default false → no behavior change.
    public var loudnessActive: Bool = false
```

OR `loudnessActive` into the `active` predicate in `configure`:

```swift
        active = s.enabled || s.clarity != .off || s.loudnessActive
```

Add the stored scalar next to the stages:

```swift
    /// Loudness-normalization make-up gain (linear). Written from main (lock-free
    /// scalar; atomic on arm64), read on the render thread. 1.0 = no-op. Applied
    /// just BEFORE the limiter so the ceiling still bounds the boosted signal.
    private var loudnessGain: Float = 1
```

Add the setter (coefficient-free, so it is safe from main without a full reconfigure):

```swift
    /// Set the loudness make-up gain. Plain scalar store — cheaper than a full
    /// configure; called from the main-thread loudness timer.
    public func setLoudnessGain(_ g: Float) { loudnessGain = g }
```

In `process(_:count:)`, multiply by `loudnessGain` immediately before `limiter.process(x)`:

```swift
            if doPolish { x = comp.process(x) }
            x *= loudnessGain               // loudness normalization make-up (pre-limiter)
            x = limiter.process(x)
            buffer[i] = x
```

> **Why the field lives here (the contract):** the activation predicate (`active = … || s.loudnessActive`) and the make-up multiply must move together — the limiter MUST run to guard the boost. So normalization activation is part of `VoiceChain`, tested here (`testLoudnessActiveAloneActivatesGainAndLimiter`). `AudioModel.applyVoiceChain()` simply sets `s.loudnessActive = loudnessNormEnabled` (Task 6 Step 9). The limiter is already configured unconditionally while `active`, so a loudnessActive-only chain still has a valid ceiling. Polish/clarity stages stay bypassed (set in `init`) when their flags are off, so the loudnessActive-only path is gain → limiter only.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: all tests PASS (new loudness + activation tests + existing `VoiceChainTests` + `BroadcastVoiceTests` regression — `loudnessGain` defaults to 1.0 and `loudnessActive` defaults to `false`, so every existing test is unchanged).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/VoiceChain.swift Tests/NoNoiseMacTests/VoiceChainTests.swift
git commit -m "feat(dsp): pre-limiter loudness make-up gain + loudnessActive activation in VoiceChain"
```

---

## Task 6: Telemetry + loudness wiring in `AudioModel`

Add the telemetry scalars, the `LoudnessMeter`, the ~25 Hz UI snapshot timer, the normalization controls, and persistence. **No XCTest:** `AudioModel` depends on CoreAudio/AVCapture and is not unit-testable in the headless suite. Verification is `swift build` + the green Core suite + the manual smoke test.

**Files:**
- Modify: `Sources/Core/AudioModel.swift`

- [ ] **Step 1: Add `@Published` HUD properties** (after `inputLevel`, line ~24)

```swift
    /// Live HUD telemetry, refreshed ~25 Hz from lock-free scalars (not per buffer).
    @Published public var outputLevel: Float = 0.0
    @Published public var outputPeak: Float = 0.0
    @Published public var isClipping: Bool = false
    @Published public var aiActivity: Float = 0.0        // "AI working hard" 0…1
    @Published public var momentaryLUFS: Float = LoudnessMeter.silenceLUFS
    @Published public var integratedLUFS: Float = LoudnessMeter.silenceLUFS
    @Published public var addedLatencyMs: Float = 0.0
```

- [ ] **Step 2: Add normalization controls + `PrefKey`s**

Add to `PrefKey` (line ~114):

```swift
        static let loudnessNorm = "mv.loudnessNorm"
        static let loudnessTarget = "mv.loudnessTarget"
```

Add `@Published` controls (after `voicePolishEnabled`, ~line 110):

```swift
    /// Loudness normalization (gentle auto-gain toward target). OFF by default —
    /// default behavior is byte-for-byte unchanged. Guarded like the other knobs.
    @Published public var loudnessNormEnabled: Bool = false {
        didSet {
            guard !isApplyingPreset else { return }
            if !loudnessNormEnabled { voiceChain.setLoudnessGain(1.0) }  // reset to unity when off
            applyVoiceChain()                                            // (re)activate chain if needed
            persistSettings()
        }
    }
    /// Target integrated loudness in LUFS (e.g. −14 YouTube/Spotify, −16 Apple Podcasts).
    @Published public var loudnessTargetLUFS: Float = -14 {
        didSet { guard !isApplyingPreset else { return }; persistSettings() }
    }
```

- [ ] **Step 3: Add the lock-free telemetry scalars + the `LoudnessMeter`** (near the processing modules, ~line 143)

```swift
    // The loudness meter is a value-type struct mutated ONLY on the render thread
    // (process() mutates it). It must be `var`, not `let`. It is NEVER read from the
    // main thread — the render callback copies its getters into the LUFS snapshot
    // scalars below; the UI timer reads only those scalars (no cross-thread struct access).
    private var loudnessMeter = LoudnessMeter()
    // Render-thread → main lock-free scalars (atomic on arm64). Written in the
    // render callback / read by the UI timer. NOT @Published (no per-write churn).
    private var tInputLevel: Float = 0
    private var tOutputLevel: Float = 0
    private var tOutputPeak: Float = 0
    // Latched best-effort clip flag (Int32): the render callback SETs it to 1 when a
    // sample hits the threshold; the timer reads it, surfaces CLIP, then clears it.
    // It is a latch, NOT a count — `tClipFlag &+= n` would be a non-atomic
    // read-modify-write across threads, so we only ever STORE 0 or 1 (single atomic
    // store on arm64). A missed/raced flag for one 40 ms tick is acceptable for a UX hint.
    private var tClipFlag: Int32 = 0
    // LUFS + loudness-peak snapshots: written on the render thread from the meter's
    // getters, read by the timer. Plain scalars (atomic on arm64) — the meter struct
    // itself never crosses threads.
    private var tMomentaryLUFS: Float = LoudnessMeter.silenceLUFS
    private var tIntegratedLUFS: Float = LoudnessMeter.silenceLUFS
    private var tLoudnessSamplePeak: Float = 0
    private var currentLoudnessGain: Float = 1
```

> **Why scalar snapshots, not cross-thread struct reads:** `LoudnessMeter` is a value-type struct whose getters (`momentaryLUFS`, `integratedLUFS`, `samplePeak`) read multi-field internal state (ring sums, block accumulators). Reading those from the main-thread timer while the render thread mutates them would be a data race — NOT the safe lock-free-scalar pattern. So the render callback (single-threaded with all meter mutation) reads the getters and stores them into the `t*` scalars; the timer reads only the scalars. This keeps the blessed pattern intact (only plain 32-bit scalars cross threads, atomic on arm64) and never touches the meter object from main.

- [ ] **Step 4: Write telemetry in the render callback** (the `AVAudioSourceNode` closure, after `chain.process(...)`, ~line 189)

Compute post-processing output level/peak/clip over the in-place `data` buffer (scalar loop, no allocation), feed each output sample to `loudnessMeter.process(_:)`, then snapshot the meter's getters into the LUFS/peak scalars (all on the render thread). Also store the input-level RMS (replacing the per-callback `inputLevel` main-thread hop in `captureOutput` — see Step 6). Example shape (allocation-free):

```swift
                // Telemetry (render thread → lock-free scalars). No allocation.
                var sumSq: Float = 0, peak: Float = 0
                let clipThreshold: Float = 0.999
                var didClip = false
                for i in 0..<count {
                    let s = data[i]
                    let m = abs(s)
                    sumSq += s * s
                    if m > peak { peak = m }
                    if m >= clipThreshold { didClip = true }
                    self.loudnessMeter.process(s)   // K-weighted loudness + sample-peak
                }
                self.tOutputLevel = sqrtf(sumSq / Float(max(count, 1)))
                self.tOutputPeak = peak
                // Latched best-effort flag: single atomic store of 1 (never a counter
                // read-modify-write). The timer reads it and clears it each tick.
                if didClip { self.tClipFlag = 1 }
                // Snapshot the meter getters into plain scalars (render thread only) so
                // the UI timer never touches the meter struct cross-thread.
                self.tMomentaryLUFS = self.loudnessMeter.momentaryLUFS
                self.tIntegratedLUFS = self.loudnessMeter.integratedLUFS
                self.tLoudnessSamplePeak = self.loudnessMeter.samplePeak

                // Loudness make-up is applied inside chain.process (the gain is computed
                // on main by the timer and stored via setLoudnessGain); nothing per-sample here.
```

> The DSP-side `aiActivity` is read from `dspEngine.aiActivity` by the timer (Step 5), not here. The LUFS snapshots are read by the timer from `tMomentaryLUFS` / `tIntegratedLUFS`, never from the meter object.

- [ ] **Step 5: Add the ~25 Hz UI snapshot timer**

Add a `Timer` (40 ms ≈ 25 Hz) started in `init()` (after `loadSettings()`), invalidated in `deinit`. On each tick (main thread):

```swift
    private var meterTimer: Timer?

    private func startMeterTimer() {
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Read ONLY the lock-free scalars (never the meter struct). Atomic on arm64.
            self.outputLevel = self.tOutputLevel
            self.outputPeak = self.tOutputPeak
            self.isClipping = self.tClipFlag != 0
            self.tClipFlag = 0                                   // clear the latch after surfacing
            self.aiActivity = self.dspEngine.aiActivity
            self.momentaryLUFS = self.tMomentaryLUFS
            self.integratedLUFS = self.tIntegratedLUFS
            // Loudness normalization: compute a slew-limited make-up gain on main from
            // the integrated-LUFS snapshot, push it to the chain as a lock-free scalar
            // (only when normalization is enabled). When the meter has no measurement
            // (silence below the gate), normalizationGain holds the current gain — no pumping.
            if self.loudnessNormEnabled {
                let g = LoudnessMeter.normalizationGain(
                    measuredLUFS: self.tIntegratedLUFS, targetLUFS: self.loudnessTargetLUFS,
                    currentGain: self.currentLoudnessGain, maxDb: 12, slewDb: 1)  // ~1 dB/tick → smooth
                self.currentLoudnessGain = g
                self.voiceChain.setLoudnessGain(g)
            }
        }
    }
```

> **Perf:** `slewDb: 1` per 40 ms tick = max ~25 dB/s — fast enough to track, slow enough to never pump. `addedLatencyMs` is set once (Step 7), not per tick. The timer touches NO `LoudnessMeter` struct — only `t*` scalars and `dspEngine.aiActivity`.

- [ ] **Step 6: Replace the per-callback `inputLevel` hop**

In `captureOutput(...)` (lines ~673–687), the existing block computes a strided RMS and does `DispatchQueue.main.async { self.inputLevel = rms }` **every callback**. Replace the async hop with a scalar store `self.tInputLevel = rms` (lock-free), and have the timer assign `self.inputLevel = self.tInputLevel` in `startMeterTimer`. This removes a per-buffer main-thread dispatch (perf mandate: no needless main-thread churn) while preserving the input meter.

- [ ] **Step 7: Compute `addedLatencyMs` from constants** in `init()` (after engine setup)

```swift
    // Fixed pipeline latency: ring-buffer target (2400 samples) + one STFT frame
    // (960 samples). Reported as the "added latency" readout. Not a per-sample measure.
    addedLatencyMs = Float(2400 + 960) / 48000.0 * 1000.0   // = 70 ms
```

> Extract `latencyTarget`/`frameSize` to named constants if the executor prefers; do not change the render behavior. If `latencyTarget` is later made configurable, recompute here.

- [ ] **Step 8: Persist + restore** the normalization controls

In `persistSettings()`:

```swift
        d.set(loudnessNormEnabled, forKey: PrefKey.loudnessNorm)
        d.set(loudnessTargetLUFS, forKey: PrefKey.loudnessTarget)
```

In `loadSettings()`, inside the `isApplyingPreset = true … = false` guarded region:

```swift
        loudnessNormEnabled = d.object(forKey: PrefKey.loudnessNorm) as? Bool ?? false
        loudnessTargetLUFS  = d.object(forKey: PrefKey.loudnessTarget) != nil
            ? d.float(forKey: PrefKey.loudnessTarget) : -14
```

- [ ] **Step 9: Wire `loudnessNormEnabled` into chain activation** (the other half of the Task 5 contract)

The `loudnessActive` field + activation predicate already landed in `VoiceChain` (Task 5). This step is the matching `AudioModel` half: set `s.loudnessActive = loudnessNormEnabled` in `applyVoiceChain()` so enabling normalization activates the chain (limiter + make-up) even when polish and clarity are off — keeping normalization usable in Meeting mode.

`applyVoiceChain()` currently sets `s.enabled = s.enabled && voicePolishEnabled; s.clarity = clarityLevel`. Add one line:

```swift
    private func applyVoiceChain() {
        var s = selectedPreset.voiceChain
        s.enabled = s.enabled && voicePolishEnabled
        s.clarity = clarityLevel
        s.loudnessActive = loudnessNormEnabled   // activate the chain for normalization
        voiceChain.configure(s)
    }
```

> **Contract note:** the `loudnessActive` field/predicate (Task 5) and this `applyVoiceChain()` assignment move together — neither is useful without the other. The Task 5 test `testLoudnessActiveAloneActivatesGainAndLimiter` proves the `VoiceChain` half; this step wires the `AudioModel` half. Because the field already exists, Task 6 does NOT touch `VoiceChain.swift`.

- [ ] **Step 10: Start/stop the timer**

Call `startMeterTimer()` at the end of `init()`; in `deinit`, `meterTimer?.invalidate()`.

- [ ] **Step 11: Build + regression test**

Run: `swift build && swift test`
Expected: build succeeds; all tests PASS.

- [ ] **Step 12: Commit**

```bash
git add Sources/Core/AudioModel.swift
git commit -m "feat(audio): render-thread telemetry + LUFS meter + loudness normalization wiring"
```

> Task 6 modifies ONLY `AudioModel.swift` — the `loudnessActive` field/test landed in Task 5, so there is no `VoiceChain.swift` change here.

---

## Task 7: Live HUD UI — popover + Settings

Surface the HUD: output meter, clip warning, AI-activity, latency readout (popover), and the full LUFS panel + normalization controls (Settings). **No XCTest** (SwiftUI views) — verify by build + manual.

**Files:**
- Modify: `Sources/App/ContentView.swift`
- Modify: `Sources/App/SettingsView.swift`

- [ ] **Step 1: Extend the popover `statusCard`** (`ContentView.swift`) — add an output meter row + a clip flag beneath the existing input `MeterView`:

```swift
            HStack(spacing: 8) {
                Image(systemName: "mic.fill").font(.caption2).foregroundColor(.secondary)
                MeterView(level: audioModel.inputLevel).frame(height: 6)
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").font(.caption2).foregroundColor(.secondary)
                MeterView(level: audioModel.outputLevel).frame(height: 6)
                if audioModel.isClipping {
                    Text("CLIP").font(.caption2).fontWeight(.bold).foregroundColor(.red)
                }
            }
```

- [ ] **Step 2: Add a compact `hudCard`** (`ContentView.swift`) after `modeCard` — AI-activity bar + latency + momentary LUFS:

```swift
    private var hudCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardLabel("Live", systemImage: "waveform.path.ecg")
            HStack(spacing: 8) {
                Text("AI").font(.caption2).foregroundColor(.secondary)
                MeterView(level: audioModel.aiActivity / 5).frame(height: 6)  // MeterView scales ×5 internally
            }
            HStack {
                Text(audioModel.momentaryLUFS <= LoudnessMeter.silenceLUFS + 1
                     ? "— LUFS" : String(format: "%.1f LUFS", audioModel.momentaryLUFS))
                    .font(.caption).monospacedDigit().foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f ms latency", audioModel.addedLatencyMs))
                    .font(.caption).monospacedDigit().foregroundColor(.secondary)
            }
        }
        .nnCard()
    }
```

> `MeterView` multiplies `level` by 5 internally (`CGFloat(level) * 5 * width`); `aiActivity` is already 0…1, so divide by 5 to use the full bar without a 5× over-scale. Document this in an inline comment. (If the executor prefers, add a `scaledLevel` view rather than abusing the divide — keep it minimal.)

- [ ] **Step 3: Place `hudCard`** in `ContentView.body`'s `VStack`, after `modeCard`:

```swift
            modeCard
            hudCard
            devicesCard
```

- [ ] **Step 4: Add the loudness panel to Settings** (`SettingsView.swift`) — a new `loudnessCard` in `GeneralSettingsView.body` (after `gainCard`): the integrated LUFS readout, a normalization toggle, and a target picker (−14 / −16 LUFS):

```swift
    private var loudnessCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader("Loudness", systemImage: "speaker.wave.2.circle.fill")
                Spacer()
                Text(audioModel.integratedLUFS <= LoudnessMeter.silenceLUFS + 1
                     ? "— LUFS" : String(format: "%.1f LUFS", audioModel.integratedLUFS))
                    .font(.callout).monospacedDigit().foregroundColor(.secondary)
            }
            Toggle(isOn: $audioModel.loudnessNormEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Normalize Loudness").font(.subheadline)
                    Text("Gently rides gain toward a target level so you’re consistent across calls and recordings.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            Picker("Target", selection: $audioModel.loudnessTargetLUFS) {
                Text("−14 LUFS (YouTube / Spotify)").tag(Float(-14))
                Text("−16 LUFS (Apple Podcasts)").tag(Float(-16))
            }
            .pickerStyle(.menu)
            .disabled(!audioModel.loudnessNormEnabled)
            Text("Peak-safe: output is capped ~3 dB below clipping. Loudness is K-weighted (ITU-R BS.1770); peak is sample-peak, not certified true-peak.")
                .font(.caption2).foregroundColor(.secondary)
        }
        .nnCard()
    }
```

Add `loudnessCard` to the `VStack` after `gainCard`.

- [ ] **Step 5: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 6: Commit**

```bash
git add Sources/App/ContentView.swift Sources/App/SettingsView.swift
git commit -m "feat(ui): Live HUD (levels/clip/AI/latency) + LUFS loudness panel"
```

---

## Task 8: Documentation (8-Fold Awareness Step 2 + compounding)

Every code change requires a docs pass. Update user docs, domain vocab, the architecture map, and the knowledge base.

**Files:**
- Modify: `README.md`
- Modify: `CONCEPTS.md`
- Modify: `AGENTS.md`
- Modify: `docs/knowledge/timeline1.md`
- Modify: `docs/knowledge/knowledge1.md`

- [ ] **Step 1: `README.md`** — add a feature bullet under "✨ Why NoNoise Mac":

```markdown
- **📊 Live HUD & loudness** — see your input/output levels, a clip warning, an “AI working hard” signal, and added latency at a glance; an ITU-R BS.1770 LUFS meter with optional one-tap loudness normalization (−14 / −16 LUFS) keeps you consistent across calls and recordings.
```

- [ ] **Step 2: `CONCEPTS.md`** — add a "Metering & loudness" section:

```markdown
## Metering & loudness
- **Telemetry** — lock-free scalars written on the render/DSP threads and read by a
  ~25 Hz UI timer (same atomic-scalar pattern as the suppression knobs; no locks). The
  `LoudnessMeter` struct is mutated only on the render thread and snapshotted into
  scalars — it is never read cross-thread. The clip indicator is a latched best-effort
  flag (set on the render thread, cleared each UI tick), not a counter.
- **AI activity** — a smoothed 0…1 "AI working hard" signal = energy-weighted average
  per-bin suppression (`1 − wetMag/dryMag`) from the DSP blend. A UX hint, not a model
  quality metric.
- **LUFS (`LoudnessMeter`)** — real ITU-R BS.1770 K-weighted loudness (the standard's
  published 48 kHz two-stage filter, not an approximation). Momentary (400 ms) is the
  live needle; integrated is gated (absolute −70 LUFS + relative −10 LU) using a
  fixed-size block ring (no unbounded history, no render-path allocation).
- **Loudness normalization** — optional slew-limited make-up gain toward a target
  (−14 / −16 LUFS), applied pre-limiter in the voice chain; OFF by default. Works even
  with polish/clarity off (the chain activates for `loudnessActive` so the limiter runs).
- **Peak** — v1 tracks **sample-peak** + a clip flag, NOT oversampled true-peak; the
  normalization ceiling is a peak-safe limiter (~−3 dB), not certified dBTP.
```

- [ ] **Step 3: `AGENTS.md`** — add a "Metering & loudness (Tier 2)" section after the "Voice polish chain (Tier 2)" section:

```markdown
## Metering & loudness (Tier 2)
- **Telemetry is lock-free scalars** written render→main (the reverse of the suppression
  knobs, same arm64 atomicity argument). The render callback writes output level/peak, a
  latched clip flag, and LUFS snapshots; `DeepFilterNetDSP.aiActivity` is written in the
  blend loop; a ~25 Hz `Timer` on `AudioModel` snapshots them into `@Published` props.
  NEVER add locks; NEVER push per-buffer to main (the old per-callback `inputLevel`
  dispatch was replaced by the timer snapshot).
- **The `LoudnessMeter` struct is NEVER read cross-thread.** It is a value type mutated
  ONLY on the render thread; the render callback copies its getters into the `tMomentaryLUFS`
  / `tIntegratedLUFS` / `tLoudnessSamplePeak` scalars, and the UI timer reads only those
  scalars. Only plain 32-bit scalars cross threads (the blessed pattern) — do not read the
  meter object from main.
- **The clip indicator is a latched best-effort flag (`Int32` 0/1), NOT a counter.** The
  render callback STORES 1 on a clip; the timer reads it and clears it. A counter
  (`&+=`) would be a non-atomic read-modify-write across threads — banned.
- **`LoudnessMeter` (Core/AudioProcessing)** owns all BS.1770 math (the REAL K-weighting
  biquads — published 48 kHz coefficients via `Biquad.setCoefficients`, NOT RBJ
  approximations — momentary + gated-integrated LUFS, sample-peak, and the
  `normalizationGain` helper) as a pure, headless-tested value type — same rule as
  `Biquad`/`resolveOutputBin`. Tested at multiple frequencies.
- **v1 is sample-peak, not true-peak** (oversampled dBTP deferred for perf). Do not relabel
  the peak as dBTP. Integrated LUFS uses a **fixed-size, pre-allocated block ring** (write
  by index, wraparound) — never an `append`-growing log; `process` stays allocation-free.
- **Loudness normalization** is a main-computed, slew-limited scalar `loudnessGain` applied
  pre-limiter in `VoiceChain` (limiter guards the boost). Persisted: `mv.loudnessNorm`,
  `mv.loudnessTarget`. OFF by default → default output unchanged. `VoiceChain` activates for
  `loudnessActive` even when polish/clarity are off (limiter must run); the `loudnessActive`
  field and `AudioModel.applyVoiceChain()` move together (one contract).
```

- [ ] **Step 4: `docs/knowledge/timeline1.md`** — append a dated changelog entry (match the existing format):

```markdown
## 2026-06-15 — Metering & Loudness added

Added one render-thread telemetry layer (lock-free scalars) feeding a Live HUD
(input/output level, sample-peak + a latched CLIP flag, "AI working hard" activity
derived from per-bin suppression, added-latency readout) and an ITU-R BS.1770
`LoudnessMeter` (REAL K-weighting via the published 48 kHz coefficients — a new
`Biquad.setCoefficients` direct-coefficient path — → momentary + gated-integrated
LUFS, sample-peak; validated at multiple frequencies). Integrated LUFS uses a
fixed-size pre-allocated block ring (no `append` on the render path). The
`LoudnessMeter` struct is mutated only on the render thread and snapshotted into
plain scalars; it is never read cross-thread. Added optional loudness normalization:
a slew-limited make-up gain toward −14/−16 LUFS applied pre-limiter in `VoiceChain`
(new `loudnessActive` activation reason so it works in Meeting mode; persisted
`mv.loudnessNorm` / `mv.loudnessTarget`, OFF by default). v1 ships sample-peak (not
oversampled true-peak) per the perf mandate. UI: HUD in the popover, loudness panel
in Settings. Replaced the per-callback `inputLevel` main-thread hop with a ~25 Hz
timer snapshot.
```

- [ ] **Step 5: `docs/knowledge/knowledge1.md`** — append a `[DECISION]` entry (detect username via `git config user.name`):

```markdown
## 2026-06-15 — [DECISION] Sample-peak (not true-peak) + lock-free render→main telemetry (@<username>)

**Problem**: Metering needs render-thread data (levels, peaks, suppression activity, loudness)
without locks/allocation, and a "true-peak" meter naïvely needs ≥4× oversampling on every buffer.
**Decision**: (1) Telemetry = plain `Float`/`Int32` scalars written render→main, snapshotted by a
~25 Hz timer — the suppression-knob atomic-scalar pattern, reversed; no locks, no per-buffer main hop.
The `LoudnessMeter` struct is mutated ONLY on the render thread and snapshotted into scalars; it is
NEVER read cross-thread (only plain scalars cross threads). (2) v1 ships **sample-peak + a LATCHED
best-effort clip flag** (`Int32` 0/1, not a `&+=` counter — RMW across threads isn't atomic), NOT
oversampled true-peak (too heavy for an always-on menu-bar utility); the normalization ceiling is a
peak-safe limiter labeled ~−3 dB, not certified dBTP. (3) AI "confidence" is a derived heuristic
(energy-weighted `1 − wetMag/dryMag` from the blend), a UX hint only. (4) Integrated LUFS uses a
**fixed-size, pre-allocated block ring** written by index (wraparound) — no `append`/grow on the
render path. (5) K-weighting uses the REAL published BS.1770 48 kHz coefficients (a new
`Biquad.setCoefficients` direct path), validated at multiple frequencies — not RBJ approximations.
**Rule**: Render→main telemetry must be lock-free scalars snapshotted at a modest UI rate (never read
a mutating struct cross-thread); the render path stays allocation-free (fixed rings, never `append`);
never claim certified true-peak without oversampling; keep all loudness math in the pure `LoudnessMeter`.
**Files**: `Sources/Core/AudioProcessing/Biquad.swift`, `Sources/Core/AudioProcessing/LoudnessMeter.swift`, `Sources/Core/AudioProcessing/DeepFilterNetDSP.swift`, `Sources/Core/AudioProcessing/VoiceChain.swift`, `Sources/Core/AudioModel.swift`
```

- [ ] **Step 6: Commit**

```bash
git add README.md CONCEPTS.md AGENTS.md docs/knowledge/timeline1.md docs/knowledge/knowledge1.md
git commit -m "docs: document Metering & Loudness (telemetry, LUFS, normalization)"
```

---

## Manual smoke test (after all tasks)

The headless suite cannot exercise the live audio path. After implementation, verify in the running app:

> **Canonical telemetry-update predicate (single source of truth — see Context "Telemetry update predicate"):** ALL render-side telemetry — output level, output peak, clip flag, momentary LUFS, integrated LUFS, and AI activity — updates ONLY while **Noise Cancellation is ON**, because the render callback writes it inside the `if isAIEnabled` branch (after `dsp.process` / `chain.process`). The **input meter** is the sole exception: it is written in `captureOutput` and updates whenever audio is captured, regardless of `isAIEnabled`. When AI is OFF, the LUFS/output readouts hold their last value (or read "— LUFS" / 0 after a reset) — they are NOT live. This is the same predicate used in Task 6 Step 4.

1. `./install-app.sh` (or `swift run`), open the popover.
2. Speak — confirm the **input** meter moves and the new **output** meter moves; both track your voice.
3. Speak loudly / tap the mic — confirm the **CLIP** flag flashes red, then clears when you stop.
4. With background noise present, confirm the **AI** activity bar rises (more suppression) and falls in quiet.
5. Confirm the **latency** readout shows a stable number (~70 ms) and the **LUFS** readout shows a sensible negative value while speaking, "— LUFS" in silence.
6. Open **Settings → Loudness**: confirm the integrated LUFS number tracks your speech.
7. Toggle **Normalize Loudness** ON with target −14: speak softly, then loudly — confirm the level is gently pulled toward a consistent loudness **without pumping**; confirm it never clips (limiter).
8. Set target −16, confirm the consistent level drops accordingly.
9. Turn normalization **OFF** — confirm output returns to un-normalized and is identical to before (regression by ear).
10. Quit and relaunch — confirm the normalization toggle + target are restored (persistence).
11. CPU check: with everything on, confirm Activity Monitor shows no meaningful CPU increase vs. baseline (telemetry is scalar; the timer is 25 Hz).

---

## Self-Review (completed during authoring)

- **Spec coverage:** Live HUD (#6) → telemetry scalars (Task 6) + AI-activity (Task 4) + HUD UI (Task 7) showing input/output level, sample-peak + CLIP, AI confidence, latency. LUFS meter + normalization (#2) → `LoudnessMeter` real BS.1770 K-weighting + momentary + gated-integrated (Tasks 1–2), `normalizationGain` (Task 3), pre-limiter make-up + `loudnessActive` activation in `VoiceChain` (Task 5), wiring + persistence (Task 6), Settings panel (Task 7). One shared telemetry layer → Task 6 owns the single scalar set + timer.
- **Real-time safety (reviewer fix #1):** the `LoudnessMeter` struct is mutated ONLY on the render thread (`private var`, `process` mutates) and snapshotted into the `tMomentaryLUFS`/`tIntegratedLUFS`/`tLoudnessSamplePeak` scalars there; the UI timer reads ONLY those scalars — no cross-thread struct access. Integrated LUFS uses a fixed-size, pre-allocated `blockMSRing` written by index (wraparound) — never `append`/grow in `process` (Task 2 Step 3).
- **Real BS.1770 (reviewer fix #2):** K-weighting uses the standard's published 48 kHz coefficients via the new `Biquad.setCoefficients`, validated at 1 kHz (calibration), 60 Hz (HP roll-off), and 6 kHz (shelf lift) — Task 1.
- **Test fixes (reviewer fix #3):** `testLoudnessGainBoostsWhenActive` now uses TWO separately-configured chains (gain 2.0 vs 1.0) on identical input; added `testLoudnessActiveAloneActivatesGainAndLimiter` (loudnessActive activates with polish+clarity off) and `testDisabledChainWithLoudnessInactiveIsUnchanged` (feature-off output byte-identical). The `loudnessActive` field + predicate (Task 5) and `AudioModel.applyVoiceChain()` (Task 6 Step 9) move as one contract.
- **Honesty calls stated:** sample-peak (not oversampled true-peak) for v1 — Context + Task 7 copy + docs; momentary (live) + gated-integrated LUFS, no short-term — Context; AI-confidence is a derived heuristic, not a model output — Context + Task 4 comment; the clip indicator is a latched best-effort flag, not a monotonic counter (reviewer fix #4).
- **One canonical telemetry-update predicate (reviewer fix #5):** Context "Telemetry update predicate" + the matching manual-test note — render-side telemetry is live only while AI is ON; only `inputLevel` updates whenever audio is captured.
- **Hard-constraint compliance:** render thread allocation-free + lock-free scalars (Context point 1–3, Tasks 2/4–6 perf notes); coefficient recompute on main only (`LoudnessMeter`/`VoiceChain` configured on main; gain is a scalar store); pure testable types in `Tests/NoNoiseMacTests` (Tasks 1–5); `AudioModel` verified by build + smoke (Task 6); `mv.*` persistence, no "MetalVoice"/"Ghostkwebb" in Sources, repo-relative paths only.
- **Open decisions surfaced for the executor:** (Task 7 Step 2) `MeterView` ×5 internal scale vs. a dedicated scaled meter. The `loudnessActive` field and the block-ring cap are now decided (no longer open).
- **Type consistency:** `LoudnessMeter` (`process`, `momentaryLUFS`, `integratedLUFS`, `samplePeak`, `reset`, `silenceLUFS`, `loudness(meanSquare:)`, `normalizationGain(...)`), `Biquad.setCoefficients(b0:b1:b2:a1:a2:)`, `DeepFilterNetDSP.binActivity(dryMag:wetMag:)` + `aiActivity`, `VoiceChain.setLoudnessGain(_:)` + `VoiceChainSettings.loudnessActive`, `AudioModel` telemetry `@Published`s + `t*` scalars + `mv.loudnessNorm`/`mv.loudnessTarget`, are used consistently across tasks.
- **Placeholder scan:** none — every code step shows complete code or an explicit, bounded implementation note with the test that gates it.
