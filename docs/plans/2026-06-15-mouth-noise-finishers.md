# Mouth-Noise Finishers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two new "mouth-noise finisher" stages to the `VoiceChain`: a **De-plosive** and a **De-click**. Together they complete the mouth-noise suppression suite — the de-esser (sibilance, already covered in `docs/plans/2026-06-15-broadcast-voice-clarity.md`) handles "ess/sh"; the de-plosive handles P/B pops and low-frequency thumps; the de-click handles short mouth clicks and lip-smacks. Both are **identity at rest** — they produce exactly `out == in` when no artifact is present — and both live as allocation-free, per-sample scalar types in `Dynamics.swift`, wired as new `VoiceChain` stages, gated by a single `MouthNoiseLevel` enum, and persisted under `mv.*`.

**Architecture:** Two new pure DSP value types (`DePlosive`, `DeClick`) appended to `Sources/Core/AudioProcessing/Dynamics.swift`. A `MouthNoiseLevel` enum (Off/Low/Medium/High, exactly mirroring `ClarityLevel`) added to `Sources/Core/AudioProcessing/VoiceChain.swift`. Carried on `VoiceChainSettings`, injected by `AudioModel.applyVoiceChain()` (independent of the noise preset, Voice Polish, and Broadcast Voice). Chain order: HP → shelves → presence → de-esser → **de-plosive → de-click** → compressor → limiter. When `mouthNoise == .off`, both stages are perfect identity — byte-for-byte unchanged for all existing presets. A single new persist key `mv.mouthNoise`. Exposed via a segmented picker in Settings and the popover.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Package Manager, XCTest, scalar math (no Accelerate dependency in any new type).

**GitHub Issue:** #7 — https://github.com/ivalsaraj/NoNoise-Mac/issues/7

**Execution location:** Run all commands from the package root — the directory that contains `Package.swift`. All paths in this plan are relative to that root.

---

## Context

### Why these stages

The de-esser (already planned in Broadcast Voice) removes sibilant hiss on consonants. But real-world voice recordings suffer from two more categories of mouth noise that EQ and de-essing cannot reach:

1. **Plosives (P-pops / B-thumps):** A sharp wideband transient + a low-frequency pressure wave at mic impact. The signature is a brief burst of sub-100 Hz energy followed by a broadband click. Classic hardware fix is a pop filter; we replicate that logic in DSP: detect the low-band transient onset and transiently high-pass / duck the low band. The vocal mid-range (where intelligibility lives) is untouched.

2. **Mouth clicks / lip-smacks:** Very short (< 10 ms) broadband transients that are NOT sibilants — they contain significant energy below the de-esser's 6 kHz crossover. They arise from dry lips, mouth moisture, or dental contact. The fix is a short transient detector that spots an anomalously fast rise in broadband energy and applies a brief (3–8 ms) broadband gain reduction — too short to color the voice but long enough to mask the click.

Both stages share the same invariant as the de-esser: **out == in when no artifact is present**. This is enforced structurally and proven in every test.

### The non-negotiable constraint: PRESERVE THE ORIGINAL VOICE

This plan satisfies it structurally, not by taste alone:

1. **De-plosive — identity at rest.** The plosive detector watches the ratio of low-band energy to total energy (`low / total`). During normal voiced phonemes this ratio stays within a broad normal range — only a plosive transient drives it anomalously high while simultaneously above a total-energy threshold. Below threshold, `gain = 1.0` exactly — no subtraction, no filter insertion, no coloration. The gain taper (attack 0.3 ms, release 25 ms) is fast enough to catch the pop and short enough to release before the following vowel is colored.

2. **De-click — identity at rest (exact, from sample 0).** The click detector watches instantaneous broadband energy relative to a slow background RMS. **The gate never fires from cold silence:** it is armed only after the slow background has been established (above the minimum threshold) continuously for one slow-release time-constant (`warmupSamples` ≈ 200 ms); a realistic pause disarms it via an independent instantaneous-silence detector (≈75 ms of below-floor `|x|`), NOT via slow-envelope decay — so the *next* clean onset re-arms cold. Until armed, `process` returns the input **bit-for-bit** (`gain` forced to 1.0, ratio test not consulted) — so a voiced onset after silence is an EXACT identity from the very first sample, not merely a ratio-clamped near-identity. Once armed, a mouth click appears as a sudden, SHORT spike `> clickRatio × slowEnv`. The gate only attenuates while the spike is brief (`≤ maxClickSamples ≈ 1 ms`); a spike that *sustains* (a voiced phoneme onset) makes the gate latch off (`gain = 1.0`) until the ratio falls — so first syllables are never dulled. Outside a genuine click, `gain = 1.0` exactly. The hold time (≤ 5 ms) ensures even a consonant burst that triggers the detector recovers before affecting the following vowel. **Accepted tradeoff:** a click occurring from total silence (no established background) is missed — preferable to dulling clean speech, per the requirement.

3. **Conservative, capped gain reduction even at High** (de-plosive: up to 20 dB; de-click: up to 12 dB) to never destroy the transient character of voiced stops (B, D, G) that are NOT pops.

4. **`mouthNoise == .off` is a true no-op.** Both types return `x` unchanged when disabled, and both `configure` arms call `setBypass()` on any internal biquads and zero all state — so existing Meeting/Podcast/Tutorial/Custom presets behave **byte-for-byte as before**.

### Current code facts (verified against the repo)

- `Biquad` (`Sources/Core/AudioProcessing/Biquad.swift`): `setBypass / setHighPass / setLowShelf / setHighShelf / setPeaking`, per-sample `process`, `dcGain` test helper, `reset()`. Already fully sufficient; no new methods needed.
- `Dynamics.swift` has `Compressor`, `Limiter`, and `DeEsser` (added by the Broadcast Voice plan). **No de-plosive or de-click** — this plan adds both.
- `VoiceChain.swift`: `VoiceChainSettings` (value struct, `Sendable, Equatable`), `ClarityLevel` (Off/Low/Medium/High), `ClarityProfile` constants, and the `VoiceChain` class. Current chain order (after Broadcast Voice): HP → lowShelf → highShelf → presence → de-esser → compressor → limiter. This plan inserts de-plosive and de-click between de-esser and compressor.
- `AudioModel.swift` (`Sources/Core/AudioModel.swift`): `@Published var clarityLevel` (persisted `mv.clarity`), injected via `applyVoiceChain()`. The `PrefKey` enum, `persistSettings()`, and `loadSettings()` are the persistence triad — one new key and one new property follows the exact same pattern.
- `VoiceChainSettings`: value struct; adding a new `var mouthNoiseLevel: MouthNoiseLevel = .off` with a default keeps the synthesized memberwise initializer backward-compatible (existing callers don't name `mouthNoiseLevel`).
- Tests: `Tests/NoNoiseMacTests/BroadcastVoiceTests.swift` is the style reference for the new test class (`Tests/NoNoiseMacTests/MouthNoiseTests.swift`). Headless XCTest, `@testable import Core`.
- UI: `SettingsView.swift` → `GeneralSettingsView.suppressionCard` has the Voice Polish toggle and the Broadcast Voice picker. The new control goes below Broadcast Voice, following the same `Divider / VStack / Picker / Text(caption)` pattern. `ContentView.swift` has `clarityCard` (added by Broadcast Voice plan). A new `mouthNoiseCard` follows it with the same `cardLabel / Picker / nnCard()` pattern.

### Design decisions

- **`MouthNoiseLevel` mirrors `ClarityLevel` exactly.** Same four cases (Off/Low/Medium/High), same `label`, `id`, `allCases`. This keeps the Settings and popover UI consistent and avoids a special-cased on/off toggle.
- **Chain position: after de-esser, before compressor.** The de-esser has already removed sibilance; de-plosive and de-click operate on what's left. Running before the compressor means a plosive thump doesn't pump the compressor's envelope, and the compressor's makeup gain doesn't re-amplify a click artifact.
- **Single persisted key** (`mv.mouthNoise`); no other persistence changes.
- **One new file** for tests (`Tests/NoNoiseMacTests/MouthNoiseTests.swift`); all new DSP appended to `Dynamics.swift`.
- **`MouthNoiseProfile`** (internal `enum` in `VoiceChain.swift`) holds all fixed band/timing constants, following the `ClarityProfile` pattern.

### DSP design

#### De-plosive

A plosive is a wideband transient where the sub-100 Hz band is disproportionately energetic (the pressure wave). Detection strategy:

1. A **low-band signal** isolated as `lowSig = x - hp.process(x)`, where `hp` is a single 120 Hz high-pass biquad. **`hp.process` is called EXACTLY ONCE per input sample** — `Biquad.process` advances filter state on every call (`Biquad.swift:88`), so a second "peek" call (e.g. `hp.process(0)`) would corrupt the high-pass state on the render path. Detection therefore reads ONLY the already-computed scalar envelopes — never a second filter call.
2. A **low-band energy follower** tracking `|lowSig|` via one-pole smoothing, and a **total-energy follower** tracking `|x|` via the same attack/release.
3. **Plosive condition**: `totalEnv > plosThreshold && (lowEnv / totalEnv) >= plosRatioGuard`. The ratio `lowEnv / max(totalEnv, 1e-12)` is computed purely from the two scalar envelopes (NO extra filter advance). It distinguishes a plosive (bottom-heavy) from a uniform transient (click or consonant burst).
4. When condition fires: apply a gain ramp to the **low-band signal** only — subtract `frac × lowSig` from `x`, exactly like the de-esser's subtractive pattern: `out = x - frac * lowSig`. `frac` ramps from 0 at threshold to `maxPlosReduction` above it, via the same `1 - 1/over` shape.

This is subtractive and identity at rest: when `totalEnv <= plosThreshold` (or the ratio gate fails), `frac = 0`, `out = x` exactly. The 120 Hz high-pass advances once per sample whether or not the gate fires, so detection state and render output stay coherent.

#### De-click

A mouth click is a very short broadband transient — sharp rise in ALL frequency bands simultaneously. Detection:

1. A **fast envelope** tracking `|x|` with attack 0.05 ms, release 2 ms (near-instantaneous).
2. A **slow background RMS** tracking `|x|` with attack 50 ms, release 200 ms (tracks the speech body, not transients).
3. **Established-background arming (the identity-at-rest guard).** A click is only meaningful *relative to an established speech background*. The gate is **armed** only after the slow background has stayed above `minClickThreshold` continuously for `warmupSamples` (one slow-release time-constant, ≈200 ms). A `warmupCounter` increments while `slowEnv > minClickThreshold`. **Until the gate is armed, `process` returns `x` BIT-EXACTLY** (gain forced to 1.0; the ratio test is not even consulted). This is what makes a voiced onset after silence an *exact* identity from sample 0 — there is no near-zero `slowEnv` to fabricate a huge ratio, because the gate is simply not armed yet.

   **Disarm on actual silence, NOT on slow-envelope decay (the critical detail).** The gate must DISARM on a real pause so the *next* voiced onset is again exact identity — but the slow background uses a ~200 ms release, so after established speech a realistic short pause (200–300 ms) leaves `slowEnv` still above `minClickThreshold`, i.e. it has NOT decayed enough to disarm. Relying on `slowEnv` for disarm therefore leaves the gate armed through normal pauses, and the next clean voiced onset can be mistaken for an armed transient and attenuated — a hard identity-at-rest violation. Disarm is therefore driven by an **independent instantaneous-silence detector**: a `silenceCounter` counts consecutive samples whose *instantaneous* level (`|x|`) stays below the silence floor (`minThresholdLin`); the instant it reaches `silenceSamples` (≈75 ms) the gate force-disarms (`warmupCounter = 0`). Any single above-floor sample resets `silenceCounter` to 0, so the per-cycle zero-crossings of normal voiced audio never accumulate enough below-floor samples to disarm mid-speech. `slowEnv` is used ONLY for the ratio test, never for disarm.
4. **Ratio test (only once armed)**: `fastEnv > clickRatio × slowEnv && fastEnv > minClickThreshold`. No "warm-up floor" division trick is needed anymore — the arming guard replaces it, and is stronger (it yields true identity, not merely a clamped ratio).
5. **Click vs. onset by duration**: a click is a *few-sample* spike; a voiced onset is a spike that *sustains*. The gate counts consecutive tripped samples (`tripRun`). It only attenuates while `tripRun ≤ maxClickSamples` (~1 ms). Once `tripRun` exceeds that, the rise is voiced content — the gate **latches off** (snaps `gain` to 1.0) until the ratio falls back, so ordinary phoneme attacks and the voiced body are never dulled.
6. When a click fires: set `gain` toward `gainFloor` (instantaneous attack); after the hold, `gain` releases back to 1.0 over `holdReleaseMs` (3–5 ms). Apply: `out = x × gain`.

Identity at rest: before the gate is armed (cold start) and after the gate disarms (≈75 ms of instantaneous silence following a pause) `gain = 1.0` and `out = x` **bit-for-bit**; once armed, when the ratio is not tripped (or it is tripped but latched as voiced content) `gain = 1.0`, `out = x` exactly. `slowEnv` starts at 0 and feeds ONLY the ratio test; the arming counter — not a floored ratio — guards against div-by-near-zero, and the instantaneous-silence detector (not the slow envelope) drives disarm so a clean onset after any realistic pause is again exact identity from sample 0.

**Documented tradeoff (accepted, per the requirement).** Because the gate never arms from cold silence, a click that occurs from *total* silence — with no preceding speech to establish a background — is intentionally **missed**. This is strictly preferable to dulling a clean voiced onset, which is the overwhelmingly common case and a hard "identity at rest" violation. Clicks that occur *during or after* speech (the realistic mouth-noise scenario) still have an established background and are caught.

### Level → DSP mapping (the whole feature in one table)

| Level | De-plosive max reduction | De-click max gain floor |
|---|---|---|
| **Off** | 0 (identity) | 1.0 (identity) |
| **Low** | 8 dB | 0.50 (−6 dB) |
| **Medium** | 14 dB | 0.35 (−9 dB) |
| **High** | 20 dB | 0.25 (−12 dB) |

Fixed constants (`MouthNoiseProfile`): plosive LP/split 120 Hz; plosive threshold −42 dBFS; plosive low-ratio guard 0.60; plosive attack 0.3 ms, release 25 ms. Click fast-attack 0.05 ms, fast-release 2 ms; click slow-attack 50 ms, slow-release 200 ms; click ratio 6.0×; click min-threshold −54 dBFS; click hold-release 4 ms; **click silence-disarm 75 ms** (consecutive instantaneous-silence samples that force the gate to disarm — short enough that a realistic 200–300 ms pause re-arms cold, long enough that voiced zero-crossings never disarm mid-speech).

---

## Task 0: Branch

- [ ] **Step 1: Create a feature branch**

```bash
git checkout -b feat/mouth-noise-finishers
```

Expected: `Switched to a new branch 'feat/mouth-noise-finishers'`. Throughout this plan, `git add` **only the specific files named in each task** — never `git add -A`/`.`.

---

## Task 1: `DePlosive` — subtractive low-band plosive gate — TDD

A per-sample, allocation-free plosive suppressor. Below threshold (and when disabled) it is a perfect identity. The test suite proves: disabled identity, below-threshold identity, plosive reduction, and that normal voiced mid-band content is untouched.

**Files:**
- Modify: `Sources/Core/AudioProcessing/Dynamics.swift` (append `DePlosive`)
- Create: `Tests/NoNoiseMacTests/MouthNoiseTests.swift`

### Step 1: Write the failing tests — create `Tests/NoNoiseMacTests/MouthNoiseTests.swift`

- [ ] Create `Tests/NoNoiseMacTests/MouthNoiseTests.swift` with the following content:

```swift
import XCTest
@testable import Core

final class MouthNoiseTests: XCTestCase {

    // MARK: - DePlosive

    /// Disabled de-plosive is a perfect identity for arbitrary samples.
    func testDePlosiveDisabledIsIdentity() {
        var d = DePlosive()
        d.configure(splitHz: 120, thresholdDb: -42, lowRatioGuard: 0.60,
                    maxReductionDb: 20, attackMs: 0.3, releaseMs: 25,
                    sampleRate: 48000, enabled: false)
        for x in [Float(0.0), 0.5, -0.73, 0.99, -0.01] {
            XCTAssertEqual(d.process(x), x, accuracy: 1e-7,
                           "disabled de-plosive must not alter samples")
        }
    }

    /// Below-threshold sub-bass is a perfect identity (quiet hum does not trigger).
    func testDePlosiveBelowThresholdIsIdentity() {
        var d = DePlosive()
        d.configure(splitHz: 120, thresholdDb: -42, lowRatioGuard: 0.60,
                    maxReductionDb: 20, attackMs: 0.3, releaseMs: 25,
                    sampleRate: 48000, enabled: true)
        var maxDelta: Float = 0
        for i in 0..<9600 {
            // 80 Hz sine at −54 dBFS (well below the −42 dB threshold)
            let x = 0.002 * sinf(2 * Float.pi * 80 * Float(i) / 48000)
            maxDelta = max(maxDelta, abs(d.process(x) - x))
        }
        XCTAssertLessThan(maxDelta, 1e-4,
                          "below-threshold sub-bass must pass unchanged")
    }

    /// A loud, bottom-heavy low-band burst (simulating a P-pop) is attenuated.
    func testDePlosiveReducesLoudLowBandBurst() {
        var d = DePlosive()
        d.configure(splitHz: 120, thresholdDb: -42, lowRatioGuard: 0.60,
                    maxReductionDb: 20, attackMs: 0.3, releaseMs: 25,
                    sampleRate: 48000, enabled: true)
        var inSq: Float = 0, outSq: Float = 0
        let n = 9600, half = 2400   // measure 2nd half (settled detection)
        for i in 0..<n {
            // 60 Hz dominant + tiny 500 Hz harmonic → strong low-ratio bias
            let x = 0.7 * sinf(2 * Float.pi * 60  * Float(i) / 48000)
                  + 0.05 * sinf(2 * Float.pi * 500 * Float(i) / 48000)
            let y = d.process(x)
            if i >= half { inSq += x * x; outSq += y * y }
        }
        let measured = n - half
        XCTAssertLessThan(sqrtf(outSq / Float(measured)),
                          sqrtf(inSq / Float(measured)) * 0.80,
                          "loud plosive-shaped signal must be attenuated by at least 2 dB")
    }

    /// Mid-frequency voiced content (500 Hz, loud) is NOT suppressed — the de-plosive
    /// must leave normal speech energy intact even when `enabled`.
    func testDePlosivePreservesMidBandVoice() {
        var d = DePlosive()
        d.configure(splitHz: 120, thresholdDb: -42, lowRatioGuard: 0.60,
                    maxReductionDb: 20, attackMs: 0.3, releaseMs: 25,
                    sampleRate: 48000, enabled: true)
        var maxDelta: Float = 0
        for i in 0..<9600 {
            // 500 Hz sine at 0.5 amplitude — clear speech energy, not a plosive
            let x = 0.5 * sinf(2 * Float.pi * 500 * Float(i) / 48000)
            maxDelta = max(maxDelta, abs(d.process(x) - x))
        }
        XCTAssertLessThan(maxDelta, 0.05,
                          "mid-band voice must not be significantly altered by the de-plosive")
    }

    /// REGRESSION (state corruption): `DePlosive` must advance its internal high-pass
    /// EXACTLY ONCE per input sample. `Biquad.process` mutates filter state on every
    /// call, so a stray "peek" (e.g. `hp.process(0)`) would double-advance the filter
    /// and desync detection from output. We prove single-advance by reconstructing the
    /// same algorithm with our OWN single-advance high-pass and asserting byte-identical
    /// output on a plosive-triggering signal (if the production code double-advanced, its
    /// internal `lowSig` — and thus the subtracted output — would diverge from this
    /// one-pass reference).
    func testDePlosiveAdvancesFilterExactlyOncePerSample() {
        let splitHz: Float = 120, thrDb: Float = -42, guardRatio: Float = 0.60
        let maxRedDb: Float = 20, atkMs: Float = 0.3, relMs: Float = 25, sr: Float = 48000

        var d = DePlosive()
        d.configure(splitHz: splitHz, thresholdDb: thrDb, lowRatioGuard: guardRatio,
                    maxReductionDb: maxRedDb, attackMs: atkMs, releaseMs: relMs,
                    sampleRate: sr, enabled: true)

        // One-pass reference: mirror DePlosive.process with a single hp.process(x) per sample.
        var refHp = Biquad()
        refHp.setHighPass(freq: splitHz, sampleRate: sr, q: 0.707)
        let thrLin = powf(10, thrDb / 20)
        let maxRed = min(1, 1 - powf(10, -abs(maxRedDb) / 20))
        let atkC = expf(-1.0 / (max(atkMs, 0.01) * 0.001 * sr))
        let relC = expf(-1.0 / (max(relMs, 0.01) * 0.001 * sr))
        var refTotalEnv: Float = 0, refLowEnv: Float = 0

        var maxDelta: Float = 0
        for i in 0..<9600 {
            // Plosive-shaped: strong 60 Hz + weak 500 Hz → triggers the gate so the
            // subtractive branch (where any state desync would show up) is exercised.
            let x = 0.7 * sinf(2 * Float.pi * 60  * Float(i) / sr)
                  + 0.05 * sinf(2 * Float.pi * 500 * Float(i) / sr)

            let y = d.process(x)

            // Reference (single advance).
            let hiSig = refHp.process(x)
            let lowSig = x - hiSig
            let totalMag = abs(x), lowMag = abs(lowSig)
            let tC = totalMag > refTotalEnv ? atkC : relC
            let lC = lowMag   > refLowEnv   ? atkC : relC
            refTotalEnv = tC * refTotalEnv + (1 - tC) * totalMag
            refLowEnv   = lC * refLowEnv   + (1 - lC) * lowMag
            var ref = x
            if refTotalEnv > thrLin {
                let ratio = refLowEnv / max(refTotalEnv, 1e-12)
                if ratio >= guardRatio {
                    let over = refTotalEnv / thrLin
                    let frac = maxRed * (1 - 1 / over)
                    ref = x - frac * lowSig
                }
            }
            maxDelta = max(maxDelta, abs(y - ref))
        }
        XCTAssertLessThan(maxDelta, 1e-6,
                          "DePlosive must advance its high-pass exactly once per sample")
    }

    // MARK: - DeClick

    /// Disabled de-click is a perfect identity.
    func testDeClickDisabledIsIdentity() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: false)
        for x in [Float(0.0), 0.5, -0.73, 0.99] {
            XCTAssertEqual(d.process(x), x, accuracy: 1e-7,
                           "disabled de-click must not alter samples")
        }
    }

    /// Steady speech (not a click) — ratio never trips — passes through unchanged.
    func testDeClickSteadySpeechIsIdentity() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: true)
        // Run a 200 Hz sine for 1 s so the slow background settles.
        var maxDelta: Float = 0
        let settleSamples = 48000
        for i in 0..<settleSamples {
            let x = 0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000)
            let y = d.process(x)
            // Measure only after settling (second half)
            if i >= settleSamples / 2 {
                maxDelta = max(maxDelta, abs(y - x))
            }
        }
        XCTAssertLessThan(maxDelta, 0.01,
                          "steady speech must not be attenuated by the de-click")
    }

    /// A short spike (simulating a lip-smack) is attenuated while the steady
    /// background preceding/following it is untouched.
    func testDeClickReducesShortSpike() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: true)
        // Settle the slow background with quiet speech for 0.5 s
        for i in 0..<24000 {
            _ = d.process(0.05 * sinf(2 * Float.pi * 200 * Float(i) / 48000))
        }
        // Inject a single-sample spike at 10× background (well past clickRatio × slow)
        let spikeSample: Float = 0.5   // >> 6 × 0.05
        let spikeOut = d.process(spikeSample)
        // The output must be significantly below the input spike
        XCTAssertLessThan(abs(spikeOut), abs(spikeSample) * 0.7,
                          "de-click must attenuate a short spike above the ratio threshold")
    }

    /// After the spike, the hold-release window expires and `gain` returns to ≥ 0.95
    /// within 20 ms — proving the de-click does NOT color normal speech that follows.
    func testDeClickReleasesQuickly() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: true)
        // Settle background
        for i in 0..<24000 {
            _ = d.process(0.05 * sinf(2 * Float.pi * 200 * Float(i) / 48000))
        }
        // Spike
        _ = d.process(0.5)
        // 20 ms of silence (960 samples) — gain must recover
        let releaseWindow = 960
        var finalGain: Float = 0
        for _ in 0..<releaseWindow {
            let x: Float = 0.05
            let y = d.process(x)
            finalGain = y / x   // gain = out/in when in != 0
        }
        XCTAssertGreaterThan(finalGain, 0.95,
                             "de-click gain must recover to near-unity within 20 ms after spike")
    }

    /// IDENTITY AT REST (non-negotiable): a normal VOICED ONSET after silence must be
    /// EXACT identity — `out == in` for EVERY sample, with NO samples skipped. The gate
    /// must never arm from cold silence (no established background), so it cannot touch
    /// even the first sample of clean speech. A previous design skipped the first ~1 ms
    /// and only checked an RMS ratio > 0.97, which permitted attenuating the onset's first
    /// millisecond — a real identity violation. This asserts bit-level identity from
    /// sample 0 across the full onset.
    func testDeClickVoicedOnsetAfterSilenceIsIdentity() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: true)
        // 200 ms of digital silence (slow background settles to ~0, like a real pause).
        for _ in 0..<9600 { _ = d.process(0) }
        // A voiced onset: a 200 Hz tone at speech level starting cold after the silence.
        // Every sample of the first 50 ms must be untouched — NO skipped samples.
        for i in 0..<2400 {
            let x = 0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000)
            let y = d.process(x)
            XCTAssertEqual(y, x, accuracy: 1e-6,
                           "voiced onset after silence must be exact identity @\(i)")
        }
    }

    /// IDENTITY AT REST (non-negotiable, the realistic case): SPEECH → PAUSE → ONSET.
    /// After established speech ARMS the gate, a realistic short pause (~250 ms) must
    /// DISARM it so the NEXT clean voiced onset is again EXACT identity from sample 0.
    /// This is the case the cold-silence test never exercises: the disarm must be driven
    /// by ACTUAL instantaneous silence, NOT by the slow envelope. `slowEnv` releases over
    /// ~200 ms, so after speech it is STILL above the floor through a 250 ms pause — a
    /// slowEnv-based disarm would leave the gate ARMED and attenuate this onset (the round-4
    /// bug). The instantaneous-silence detector disarms after ~75 ms of silence, well inside
    /// the pause, so the onset re-arms cold and passes untouched.
    func testDeClickOnsetAfterSpeechThenPauseIsIdentity() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: true)
        // 1) Establish speech long enough to ARM the gate (≥ warmupSamples ≈ 200 ms).
        //    Run 400 ms so the gate is unambiguously armed.
        for i in 0..<19200 {
            _ = d.process(0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000))
        }
        // 2) A realistic 250 ms pause of digital silence. slowEnv (200 ms release) is STILL
        //    above the floor here, so a slowEnv-based disarm would NOT fire — but the
        //    instantaneous-silence detector disarms after ~75 ms.
        for _ in 0..<12000 { _ = d.process(0) }
        // 3) The next voiced onset must be EXACT identity for every sample of the first 50 ms.
        for i in 0..<2400 {
            let x = 0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000)
            let y = d.process(x)
            XCTAssertEqual(y, x, accuracy: 1e-6,
                           "voiced onset after speech+pause must be exact identity @\(i)")
        }
    }

    /// REGRESSION (false positive): the steady VOICED BODY (sustained loud speech)
    /// must be a perfect passthrough — the click gate must never engage on it.
    func testDeClickVoicedBodyUntouched() {
        var d = DeClick()
        d.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                    slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                    holdReleaseMs: 4, gainFloor: 0.25,
                    sampleRate: 48000, enabled: true)
        // Loud sustained voiced tone for 1 s.
        var maxDelta: Float = 0
        let n = 48000
        for i in 0..<n {
            let x = 0.6 * sinf(2 * Float.pi * 220 * Float(i) / 48000)
            let y = d.process(x)
            if i >= n / 4 { maxDelta = max(maxDelta, abs(y - x)) }   // measure after settle
        }
        XCTAssertLessThan(maxDelta, 1e-4,
                          "sustained voiced body must pass through the de-click unchanged")
    }

    // MARK: - MouthNoiseLevel

    func testMouthNoiseLevelOffIsZero() {
        XCTAssertEqual(MouthNoiseLevel.off.maxPlosReductionDb, 0)
        XCTAssertEqual(MouthNoiseLevel.off.clickGainFloor, 1.0, accuracy: 1e-6)
    }

    func testMouthNoiseLevelIsMonotonic() {
        XCTAssertLessThan(MouthNoiseLevel.low.maxPlosReductionDb,
                          MouthNoiseLevel.medium.maxPlosReductionDb)
        XCTAssertLessThan(MouthNoiseLevel.medium.maxPlosReductionDb,
                          MouthNoiseLevel.high.maxPlosReductionDb)
        XCTAssertGreaterThan(MouthNoiseLevel.low.clickGainFloor,
                             MouthNoiseLevel.medium.clickGainFloor)
        XCTAssertGreaterThan(MouthNoiseLevel.medium.clickGainFloor,
                             MouthNoiseLevel.high.clickGainFloor)
    }

    func testMouthNoiseLevelCasesAndLabels() {
        XCTAssertEqual(MouthNoiseLevel.allCases, [.off, .low, .medium, .high])
        XCTAssertEqual(MouthNoiseLevel.off.label, "Off")
        XCTAssertEqual(MouthNoiseLevel.high.label, "High")
    }

    func testMouthNoiseLevelHighCapped() {
        // High must not exceed 24 dB plosive reduction — aggressive defaults harm
        // voiced stops (B, D, G) that are NOT plosives.
        XCTAssertLessThanOrEqual(MouthNoiseLevel.high.maxPlosReductionDb, 24,
                                 "de-plosive must stay conservative to preserve voiced stops")
        // High gain floor must not go below −15 dB (= 0.177) — click suppression
        // this aggressive would also attenuate consonant bursts.
        XCTAssertGreaterThan(MouthNoiseLevel.high.clickGainFloor, 0.17,
                             "de-click floor must stay within safe range")
    }

    // MARK: - VoiceChain integration

    /// mouthNoise == .off + disabled chain == passthrough (regression guard).
    func testChainMouthNoiseOffIsPassthrough() {
        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.mouthNoiseLevel = .off
        chain.configure(s)
        var buf: [Float] = [0.1, -0.2, 0.3, -0.4]
        let copy = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(buf, copy, "off+off must not modify samples")
    }

    /// mouthNoise active with polish OFF still runs (de-plosive and de-click engage).
    func testMouthNoiseActiveWithPolishOff() {
        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.mouthNoiseLevel = .high
        chain.configure(s)
        XCTAssertTrue(chain.isActive)
    }

    /// IDENTITY AT REST (limiter must not run in mouth-noise-only mode): with polish and
    /// clarity OFF and mouthNoise = .high, a LOUD (> −1 dBFS) clean mid-band sine — NOT a
    /// click or plosive — must pass through unchanged in steady state. The de-plosive/
    /// de-click stages are attenuation-only and never raise level, so no limiter is needed;
    /// running the limiter here would clamp a loud clean sample purely because the feature
    /// is on (an identity violation). Probe at 1 kHz (above the 120 Hz plosive split) at
    /// 0.95 amplitude (≈ −0.45 dBFS, above the −1 dBFS ceiling). We measure the SETTLED
    /// second half: the de-click's sub-millisecond onset gate may briefly act on the cold
    /// start (legitimate), but once the background settles the loud steady tone must pass
    /// untouched — if the limiter were running it would clamp every sample above the ceiling.
    func testMouthNoiseOnlyPreservesLoudCleanSignal() {
        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled   // polish OFF, clarity OFF
        s.mouthNoiseLevel = .high
        chain.configure(s)
        let n = 9600
        var buf = [Float](repeating: 0, count: n)
        for i in 0..<n { buf[i] = 0.95 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
        let ref = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        var maxDelta: Float = 0
        for i in (n / 2)..<n { maxDelta = max(maxDelta, abs(buf[i] - ref[i])) }   // settled half
        XCTAssertLessThan(maxDelta, 1e-4,
                          "mouth-noise-only mode must not limit a loud clean non-artifact signal")
    }

    /// Higher level produces more reduction on a plosive-shaped signal (monotonic).
    func testHigherMouthNoiseLevelReducesMoreOnPlosive() {
        func plosiveRMS(_ level: MouthNoiseLevel) -> Float {
            let chain = VoiceChain()
            var s = VoiceChainSettings.disabled
            s.mouthNoiseLevel = level
            chain.configure(s)
            // Plosive signal: strong 60 Hz + weak 500 Hz
            var buf = [Float](repeating: 0, count: 9600)
            for i in 0..<buf.count {
                buf[i] = 0.7 * sinf(2 * Float.pi * 60  * Float(i) / 48000)
                       + 0.05 * sinf(2 * Float.pi * 500 * Float(i) / 48000)
            }
            buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
            var sq: Float = 0
            for i in 4800..<buf.count { sq += buf[i] * buf[i] }
            return sqrtf(sq / 4800)
        }
        // Higher level → more reduction → lower output RMS on a plosive-shaped signal
        XCTAssertGreaterThan(plosiveRMS(.low),  plosiveRMS(.medium))
        XCTAssertGreaterThan(plosiveRMS(.medium), plosiveRMS(.high))
    }

    /// Changing mouthNoiseLevel while the chain stays active must reset the mouth-noise
    /// stages — verified on the NEXT NON-SILENT sample (a silence-only probe passes even
    /// with stale state, because silence × a stale `DeClick.gain` is still silence and a
    /// stale plosive high-pass rings out in microseconds). We drive the chain with a
    /// click+plosive burst that engages BOTH stages (DeClick.gain → floor, plosive
    /// envelopes/HP charged), switch level, then feed a steady CLEAN probe and require it
    /// to equal a freshly-configured chain that never saw the burst. Any leftover
    /// `DeClick.gain < 1` (un-reset) would attenuate the probe and fail the match.
    func testMouthNoiseLevelChangeResetsStages() {
        func freshProbeOutput(_ level: MouthNoiseLevel) -> [Float] {
            let chain = VoiceChain()
            var s = VoiceChainSettings.disabled
            s.mouthNoiseLevel = level
            chain.configure(s)
            // Clean, steady, non-silent probe (no artifact) — identity at rest under mouth-noise-only.
            var probe = [Float](repeating: 0, count: 256)
            for i in 0..<probe.count { probe[i] = 0.2 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
            probe.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
            return probe
        }

        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.mouthNoiseLevel = .high
        chain.configure(s)
        // Energize BOTH stages: a low-band plosive bias + a hard click transient.
        var burst = [Float](repeating: 0, count: 4800)
        for i in 0..<burst.count {
            burst[i] = 0.9 * sinf(2 * Float.pi * 60 * Float(i) / 48000)
        }
        burst[2400] = 0.99   // sharp click → drives DeClick.gain toward the floor
        burst.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }

        // Switch level while still active → must reset DePlosive + DeClick.
        s.mouthNoiseLevel = .low
        chain.configure(s)

        // Probe with a clean steady signal; compare to a chain that never saw the burst.
        var probe = [Float](repeating: 0, count: 256)
        for i in 0..<probe.count { probe[i] = 0.2 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
        probe.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }

        let fresh = freshProbeOutput(.low)
        var maxDelta: Float = 0
        for i in 0..<probe.count { maxDelta = max(maxDelta, abs(probe[i] - fresh[i])) }
        XCTAssertLessThan(maxDelta, 1e-5,
                          "mouth-noise stages must fully reset on level change — no stale gain/state")
    }

    /// REGRESSION (bumpless carry-state contract): reconfiguring on an UNRELATED setting
    /// change (here, `clarity`) while `mouthNoiseLevel` stays the SAME must NOT cold-reset
    /// the mouth-noise detector state. `VoiceChain.configure` only calls `deClick.reset()` /
    /// `dePlosive.reset()` when `mouthNoiseLevel` itself changes; and `DeClick.configure(enabled:
    /// true)` (mirroring `DeEsser`) updates coefficients only — it must not clear runtime state.
    /// We energize the de-click (drive its gain below unity near the end of a burst), then
    /// reconfigure with the SAME mouthNoise but a CHANGED clarity, and require the next probe
    /// to DIFFER from a freshly-cold chain. If either layer wrongly cleared state, the carried
    /// chain would equal the cold chain (a cold-restart of mouth-noise on an unrelated change).
    func testUnrelatedConfigChangeDoesNotResetMouthNoise() {
        // Reference: a chain that has NEVER seen the burst (cold mouth-noise state),
        // configured at the post-change settings (clarity .low, mouthNoise .high).
        func coldChain() -> [Float] {
            let chain = VoiceChain()
            var s = VoiceChainSettings.disabled
            s.clarity = .low
            s.mouthNoiseLevel = .high
            chain.configure(s)
            var probe = [Float](repeating: 0, count: 256)
            for i in 0..<probe.count { probe[i] = 0.2 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
            probe.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
            return probe
        }

        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.clarity = .off            // clarity starts OFF
        s.mouthNoiseLevel = .high
        chain.configure(s)
        // Establish a background, then a hard click near the END so the de-click gain is
        // still below unity (mid hold/release) when the burst finishes.
        var burst = [Float](repeating: 0, count: 12000)   // 250 ms ≥ warmup → gate armed
        for i in 0..<burst.count { burst[i] = 0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000) }
        burst[11990] = 0.99   // sharp click at the very end → gain driven toward the floor
        burst.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }

        // Change ONLY clarity (.off → .low); mouthNoise stays .high → mouth-noise must NOT reset.
        s.clarity = .low
        chain.configure(s)

        // Probe: a clean steady signal. The CARRIED de-click (armed, gain mid-release, slowEnv
        // charged) shapes the first samples differently than a cold chain would.
        var probe = [Float](repeating: 0, count: 256)
        for i in 0..<probe.count { probe[i] = 0.2 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
        probe.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }

        let cold = coldChain()
        var maxDelta: Float = 0
        for i in 0..<probe.count { maxDelta = max(maxDelta, abs(probe[i] - cold[i])) }
        XCTAssertGreaterThan(maxDelta, 1e-4,
                             "unrelated config change must NOT cold-reset mouth-noise state (state must carry)")
    }

    /// A simultaneous clarity + mouthNoise level change (while the chain stays active) must
    /// reset BOTH stage groups, not just one. The level-change reset uses INDEPENDENT `if`
    /// checks (not `else if`), so a single configure call that changes both clarity and
    /// mouthNoise resets clarity AND mouth-noise. Probe on the next non-silent sample.
    func testSimultaneousClarityAndMouthNoiseChangeResetsBoth() {
        // Reference: a fresh chain configured directly at the target levels.
        func freshOutput() -> [Float] {
            let chain = VoiceChain()
            var s = VoiceChainSettings.disabled
            s.clarity = .low
            s.mouthNoiseLevel = .low
            chain.configure(s)
            var probe = [Float](repeating: 0, count: 256)
            for i in 0..<probe.count { probe[i] = 0.2 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
            probe.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
            return probe
        }

        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.clarity = .high
        s.mouthNoiseLevel = .high
        chain.configure(s)
        // Energize clarity (sibilant burst) AND mouth-noise (plosive + click) stages.
        var burst = [Float](repeating: 0, count: 4800)
        for i in 0..<burst.count {
            burst[i] = 0.9 * sinf(2 * Float.pi * 60 * Float(i) / 48000)
                     + 0.4 * sinf(2 * Float.pi * 7000 * Float(i) / 48000)
        }
        burst[2400] = 0.99
        burst.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }

        // Change BOTH levels in one configure call.
        s.clarity = .low
        s.mouthNoiseLevel = .low
        chain.configure(s)

        var probe = [Float](repeating: 0, count: 256)
        for i in 0..<probe.count { probe[i] = 0.2 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
        probe.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }

        let fresh = freshOutput()
        var maxDelta: Float = 0
        for i in 0..<probe.count { maxDelta = max(maxDelta, abs(probe[i] - fresh[i])) }
        XCTAssertLessThan(maxDelta, 1e-5,
                          "simultaneous clarity+mouthNoise change must reset both stage groups")
    }

    /// mouthNoise == .off with an enabled (polish-on) preset must be bit-identical
    /// to the chain without the mouth-noise stages — proving Off is a true no-op.
    func testMouthNoiseOffMatchesLegacyChain() {
        // Use podcast preset — polish ON, mouthNoiseLevel defaults to .off.
        let s = VoicePreset.podcast.voiceChain
        XCTAssertEqual(s.mouthNoiseLevel, .off,
                       "preset voiceChain must default mouthNoiseLevel to .off")
        let chain = VoiceChain()
        chain.configure(s)

        // Reference: canonical chain without de-plosive/de-click stages.
        var hp = Biquad(), lo = Biquad(), hi = Biquad(), pres = Biquad()
        var deEss = DeEsser()
        var comp = Compressor(); var lim = Limiter()
        hp.setHighPass(freq: s.highPassHz, sampleRate: 48000)
        lo.setLowShelf(freq: s.lowShelfHz, gainDb: s.lowShelfDb, sampleRate: 48000)
        hi.setHighShelf(freq: s.highShelfHz, gainDb: s.highShelfDb, sampleRate: 48000)
        // clarity is .off on the podcast preset (Broadcast Voice is orthogonal)
        pres.setBypass()
        deEss.configure(crossoverHz: 6000, thresholdDb: -28, maxReductionDb: 0,
                        attackMs: 1, releaseMs: 80, sampleRate: 48000, enabled: false)
        comp.configure(thresholdDb: s.compThresholdDb, ratio: s.compRatio,
                       attackMs: s.compAttackMs, releaseMs: s.compReleaseMs,
                       makeupDb: s.compMakeupDb, sampleRate: 48000)
        lim.configure(ceilingDb: s.limiterCeilingDb, releaseMs: 50, sampleRate: 48000)

        var buf = [Float](repeating: 0, count: 4800)
        for i in 0..<buf.count { buf[i] = 0.3 * sinf(2 * Float.pi * 220 * Float(i) / 48000) }
        var ref = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        for i in 0..<ref.count {
            var x = ref[i]
            x = hp.process(x); x = lo.process(x); x = hi.process(x)
            x = pres.process(x); x = deEss.process(x)
            x = comp.process(x); x = lim.process(x)
            ref[i] = x
        }
        for i in 0..<buf.count {
            XCTAssertEqual(buf[i], ref[i], accuracy: 1e-6,
                           "mouthNoise Off must equal canonical chain @\(i)")
        }
    }
}
```

### Step 2: Run tests to verify failure

- [ ] Run: `swift test --filter MouthNoiseTests`
  - Expected: compile error — `cannot find 'DePlosive' in scope`, `cannot find 'DeClick' in scope`, `cannot find 'MouthNoiseLevel' in scope`.

### Step 3: Implement `DePlosive` — append to `Sources/Core/AudioProcessing/Dynamics.swift`

- [ ] Append to `Sources/Core/AudioProcessing/Dynamics.swift`:

```swift
/// Subtractive low-band de-plosive. Detects P-pop / B-thump transients by
/// tracking the ratio of low-band energy (< `splitHz`) to total energy, and
/// subtractively removes a fraction of the low band when both the total energy
/// and the low-band ratio exceed their respective thresholds:
///   `out = x - frac·lowSig`
/// Below threshold (and when disabled) `frac = 0`, so `out = x` exactly —
/// the mid-range voice body and consonant bursts pass through untouched.
public struct DePlosive {
    // Low-band split: the "low" signal is `x - hp(x)`.
    private var hp = Biquad()           // high-pass at `splitHz` to isolate lo band
    private var enabled = false
    private var thresholdLin: Float = 1 // total-energy threshold (linear amplitude)
    private var lowRatioGuard: Float = 0.60  // lo/(lo+hi) must exceed this to flag plosive
    private var maxReduction: Float = 0      // max fraction of lowSig to subtract (0…1)
    private var attackCoeff: Float = 0
    private var releaseCoeff: Float = 0
    private var totalEnv: Float = 0     // smoothed |x| total-energy envelope
    private var lowEnv: Float = 0       // smoothed |lowSig| envelope

    public init() {}

    public mutating func configure(splitHz: Float, thresholdDb: Float, lowRatioGuard: Float,
                                   maxReductionDb: Float, attackMs: Float, releaseMs: Float,
                                   sampleRate: Float, enabled: Bool) {
        self.enabled = enabled
        guard enabled else { hp.setBypass(); totalEnv = 0; lowEnv = 0; return }
        hp.setHighPass(freq: splitHz, sampleRate: sampleRate, q: 0.707)
        thresholdLin = powf(10, thresholdDb / 20)
        self.lowRatioGuard = max(0, min(1, lowRatioGuard))
        maxReduction = min(1, 1 - powf(10, -abs(maxReductionDb) / 20))
        attackCoeff  = expf(-1.0 / (max(attackMs,  0.01) * 0.001 * sampleRate))
        releaseCoeff = expf(-1.0 / (max(releaseMs, 0.01) * 0.001 * sampleRate))
    }

    public mutating func reset() { totalEnv = 0; lowEnv = 0; hp.reset() }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }
        // EXACTLY ONE filter advance per input sample. `Biquad.process` mutates z1/z2
        // on every call, so a second "peek" (e.g. `hp.process(0)`) would corrupt the
        // high-pass state and desync detection from the render output. Detection below
        // reads ONLY the scalar envelopes — never a second filter call.
        let hiSig = hp.process(x)
        let lowSig = x - hiSig          // low-band component (below splitHz)

        // Update envelope followers.
        let totalMag = abs(x)
        let lowMag   = abs(lowSig)
        let tCoeff = totalMag > totalEnv ? attackCoeff : releaseCoeff
        let lCoeff = lowMag   > lowEnv   ? attackCoeff : releaseCoeff
        totalEnv = tCoeff * totalEnv + (1 - tCoeff) * totalMag
        lowEnv   = lCoeff * lowEnv   + (1 - lCoeff) * lowMag

        // Detect plosive: total energy must exceed threshold AND the low band must
        // dominate (lowEnv / totalEnv >= lowRatioGuard) to avoid suppressing consonant bursts.
        guard totalEnv > thresholdLin else { return x }
        let ratio = lowEnv / max(totalEnv, 1e-12)   // scalar-only ratio; no extra filter advance
        guard ratio >= lowRatioGuard else { return x }

        // Subtractive low-band reduction (same shape as DeEsser.process).
        let over = totalEnv / thresholdLin   // > 1
        let frac = maxReduction * (1 - 1 / over)
        return x - frac * lowSig
    }
}

/// Broadband transient gate for mouth clicks and lip-smacks. Tracks a fast
/// instantaneous envelope and a slow background RMS. A click is a *few-sample*
/// spike where the fast envelope rises far above the slow background; a phoneme
/// onset is a spike that *sustains*. The gate therefore engages only when the
/// fast/slow ratio is tripped for a SHORT run (≤ `maxClickSamples`); once the
/// trip-run exceeds that, the transient is treated as voiced content, the gain
/// snaps back to unity, and the gate latches off until the ratio falls back —
/// so ordinary voiced onsets and the voiced body pass through unchanged.
///
/// **Identity at rest is non-negotiable: the gate NEVER fires from cold silence,
/// and re-disarms on any realistic pause.** A click is only meaningful *relative to
/// an established speech background*. The gate is armed only after the slow background
/// has stayed above `minThresholdLin` continuously for `warmupSamples` (one slow-release
/// time-constant). Disarm is driven by an INDEPENDENT instantaneous-silence detector,
/// NOT by `slowEnv`: because `slowEnv` releases over ~200 ms, a realistic 200–300 ms
/// pause leaves it still above `minThresholdLin` (so it must NOT gate disarm). Instead a
/// `silenceCounter` counts consecutive samples whose instantaneous level (`|x|`) is below
/// the silence floor (`minThresholdLin`); after `silenceSamples` (≈75 ms) the gate
/// force-disarms (`warmupCounter = 0`). Any above-floor sample resets `silenceCounter`,
/// so voiced zero-crossings never disarm mid-speech. While unarmed (cold start, or just
/// after a disarm) `process` returns `x` BIT-EXACTLY (`gain` held at 1.0; no envelope
/// ratio is even consulted for gating). This makes a voiced onset after silence an exact
/// identity from sample 0 — both at cold start AND after every realistic pause — instead
/// of letting a near-zero `slowEnv` fabricate a huge fast/slow ratio that clips the first
/// ~1 ms of clean speech.
///
/// **Documented tradeoff:** a click occurring from *total* silence (no preceding
/// speech to establish a background) is intentionally MISSED. Per the requirement,
/// missing a from-silence click is strictly preferable to dulling a clean voiced
/// onset — the overwhelmingly common case. Clicks during or after speech (the
/// realistic mouth-noise case) still have an established background and are caught.
///
/// Below the ratio (and when disabled) `gain = 1.0` exactly.
///
/// **State-carry contract (mirrors `DeEsser`):** `configure(enabled: true)` updates
/// parameters/coefficients ONLY — it MUST NOT clear the runtime detector state
/// (`fastEnv`, `slowEnv`, `gain`, `holdCounter`, `tripRun`, `latched`, `warmupCounter`,
/// `silenceCounter`). Runtime state is cleared ONLY by `reset()` and by the disabled arm. `VoiceChain`
/// decides when to reset (full reset on inactive→active; mouth-noise-stages reset when
/// `MouthNoiseLevel` itself changes), so reconfiguring on an UNRELATED setting change
/// (clarity, voice polish) is bumpless and never cold-restarts the gate.
public struct DeClick {
    private var enabled = false
    private var clickRatio: Float = 6.0       // fast/slow ratio to flag a click
    private var minThresholdLin: Float = 1e-6 // absolute floor: arms the warm-up + ratio test
    private var gainFloor: Float = 0.25       // minimum gain during a click event
    private var fastAttackCoeff: Float = 0
    private var fastReleaseCoeff: Float = 0
    private var slowAttackCoeff: Float = 0
    private var slowReleaseCoeff: Float = 0
    private var holdSamples: Int = 0
    private var holdCounter: Int = 0
    private var holdReleaseCoeff: Float = 0   // gain release after hold expires
    private var maxClickSamples: Int = 0      // longest trip-run still treated as a click
    private var warmupSamples: Int = 0        // background must be established this long before arming
    private var warmupCounter: Int = 0        // consecutive samples slowEnv has been above the floor
    private var silenceSamples: Int = 0       // consecutive instantaneous-silence samples that force a disarm (≈75 ms)
    private var silenceCounter: Int = 0       // consecutive samples |x| has stayed below the silence floor
    private var tripRun: Int = 0              // consecutive samples the ratio has been tripped
    private var latched = false               // true = trip-run exceeded; ignore until ratio falls
    private var fastEnv: Float = 0
    private var slowEnv: Float = 0            // starts at 0; gate stays disarmed until background established
    private var gain: Float = 1.0

    // Continuous instantaneous silence (ms) that forces a disarm. Fixed: a click is meaningful
    // only against an ESTABLISHED background, and a realistic pause is ≥ 200 ms — 75 ms re-arms
    // cold well inside that window while staying immune to per-cycle voiced zero-crossings.
    private static let silenceDisarmMs: Float = 75

    public init() {}

    /// Update parameters/coefficients. Mirrors `DeEsser.configure`: the `enabled`
    /// arm does NOT touch runtime state — only `reset()` and the disabled arm clear it.
    public mutating func configure(fastAttackMs: Float, fastReleaseMs: Float,
                                   slowAttackMs: Float, slowReleaseMs: Float,
                                   clickRatio: Float, minThresholdDb: Float,
                                   holdReleaseMs: Float, gainFloor: Float,
                                   sampleRate: Float, enabled: Bool) {
        self.enabled = enabled
        guard enabled else { reset(); return }
        self.clickRatio = max(1, clickRatio)
        self.gainFloor = max(0, min(1, gainFloor))
        minThresholdLin = powf(10, minThresholdDb / 20)
        fastAttackCoeff  = expf(-1.0 / (max(fastAttackMs,  0.01) * 0.001 * sampleRate))
        fastReleaseCoeff = expf(-1.0 / (max(fastReleaseMs, 0.01) * 0.001 * sampleRate))
        slowAttackCoeff  = expf(-1.0 / (max(slowAttackMs,  0.01) * 0.001 * sampleRate))
        slowReleaseCoeff = expf(-1.0 / (max(slowReleaseMs, 0.01) * 0.001 * sampleRate))
        holdSamples = Int(max(holdReleaseMs, 0.01) * 0.001 * sampleRate)
        // A click is at most ~1 ms of anomalous rise; anything longer is voiced content.
        maxClickSamples = max(1, Int(0.001 * sampleRate))
        // Require one slow-release time-constant of established background before arming
        // the gate. From cold silence the gate stays disarmed → voiced onset is exact identity.
        warmupSamples = max(1, Int(max(slowReleaseMs, 0.01) * 0.001 * sampleRate))
        // Disarm on ACTUAL silence (instantaneous level below the floor), NOT on slowEnv
        // decay: slowEnv's ~200 ms release leaves it above the floor through a normal pause,
        // so it would keep the gate armed and let the next clean onset be attenuated. 75 ms of
        // continuous instantaneous silence is short enough to re-arm cold after a realistic
        // 200–300 ms pause, yet long enough that voiced zero-crossings never trip it mid-speech.
        silenceSamples = max(1, Int(DeClick.silenceDisarmMs * 0.001 * sampleRate))
        // Release from gainFloor → 1.0 over the same holdReleaseMs window.
        holdReleaseCoeff = expf(-1.0 / (max(holdReleaseMs, 0.01) * 0.001 * sampleRate))
        // NOTE: runtime detector state is intentionally NOT cleared here (bumpless on
        // unrelated reconfigures). Clearing happens only in reset() / the disabled arm.
    }

    public mutating func reset() {
        fastEnv = 0; slowEnv = 0; gain = 1
        holdCounter = 0; tripRun = 0; warmupCounter = 0; silenceCounter = 0; latched = false
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }
        let mag = abs(x)

        // Fast envelope: tracks instantaneous amplitude.
        let fCoeff = mag > fastEnv ? fastAttackCoeff : fastReleaseCoeff
        fastEnv = fCoeff * fastEnv + (1 - fCoeff) * mag

        // Slow envelope: tracks the speech background.
        let sCoeff = mag > slowEnv ? slowAttackCoeff : slowReleaseCoeff
        slowEnv = sCoeff * slowEnv + (1 - sCoeff) * mag

        // Instantaneous-silence disarm: count consecutive samples whose INSTANTANEOUS level
        // is below the floor. `mag` (not `slowEnv`) is the disarm signal — slowEnv's ~200 ms
        // release stays above the floor through a normal pause, so it would keep the gate
        // armed and let the next clean onset be attenuated. Any above-floor sample resets the
        // counter, so voiced zero-crossings never accumulate enough to disarm mid-speech.
        if mag <= minThresholdLin {
            if silenceCounter < silenceSamples { silenceCounter += 1 }
        } else {
            silenceCounter = 0
        }
        // After `silenceSamples` of continuous silence (≈75 ms), force a cold disarm so the
        // NEXT voiced onset re-arms from scratch and is exact identity from sample 0.
        if silenceCounter >= silenceSamples { warmupCounter = 0 }

        // Warm-up: a click is only meaningful relative to an ESTABLISHED background. Count
        // continuous samples the slow background has been above the floor; the gate is armed
        // only once it has been established for `warmupSamples`. Disarm is handled above by
        // the instantaneous-silence detector, NOT by slowEnv.
        if slowEnv > minThresholdLin {
            if warmupCounter < warmupSamples { warmupCounter += 1 }
        }
        let armed = warmupCounter >= warmupSamples

        // IDENTITY AT REST: until a background is established (e.g. a voiced onset after
        // silence), the gate cannot fire. Force gain to exactly 1.0 and return x bit-for-bit.
        guard armed else {
            gain = 1
            holdCounter = 0; tripRun = 0; latched = false
            return x
        }

        // Ratio test against the established background.
        let ratioTripped = fastEnv > clickRatio * slowEnv && fastEnv > minThresholdLin

        // Distinguish a few-sample click from a sustained voiced onset by trip-run length.
        if ratioTripped {
            tripRun += 1
            if tripRun > maxClickSamples {
                // Sustained rise → voiced content, not a click. Snap to unity and latch
                // off until the ratio falls back below threshold (prevents dulling onsets).
                latched = true
            }
        } else {
            tripRun = 0
            latched = false   // transient ended → ready to detect the next genuine click
        }

        let isClick = ratioTripped && !latched

        if isClick {
            gain = gainFloor          // instantaneous attack to floor
            holdCounter = holdSamples // arm the hold
        } else if latched {
            gain = 1                  // sustained content: force unity, no coloration
            holdCounter = 0
        } else if holdCounter > 0 {
            holdCounter -= 1
            // During hold: gain stays at floor (or wherever attack left it).
        } else {
            // Release back to unity.
            gain = holdReleaseCoeff * gain + (1 - holdReleaseCoeff) * 1.0
        }

        return x * gain
    }
}
```

### Step 4: Run tests to verify they still fail with the right error

- [ ] Run: `swift test --filter MouthNoiseTests`
  - Expected: compile error — `cannot find 'MouthNoiseLevel' in scope`. `DePlosive` and `DeClick` now exist; `MouthNoiseLevel` comes in Task 2.

### Step 5: Commit

- [ ] Stage and commit:

```bash
git add Sources/Core/AudioProcessing/Dynamics.swift Tests/NoNoiseMacTests/MouthNoiseTests.swift
git commit -m "feat(dsp): add DePlosive and DeClick DSP types (identity at rest)"
```

---

## Task 2: `MouthNoiseLevel` enum — TDD

The user-facing Off/Low/Medium/High control and its single-source-of-truth DSP mapping, plus the `MouthNoiseProfile` fixed constants.

**Files:**
- Modify: `Sources/Core/AudioProcessing/VoiceChain.swift` (add enum + constants after `ClarityProfile`)
- `Tests/NoNoiseMacTests/MouthNoiseTests.swift` (tests already written in Task 1 — they reference `MouthNoiseLevel`)

### Step 1: Run tests to verify failure

- [ ] Run: `swift test --filter MouthNoiseTests`
  - Expected: compile error — `cannot find 'MouthNoiseLevel' in scope`.

### Step 2: Add `MouthNoiseLevel` and `MouthNoiseProfile` to `VoiceChain.swift`

- [ ] In `Sources/Core/AudioProcessing/VoiceChain.swift`, insert immediately after the closing brace of `ClarityProfile`:

```swift
/// "Mouth Noise Finisher" intensity. Controls the de-plosive (P-pop/thump suppressor)
/// and de-click (lip-smack/mouth-click suppressor) stages. `.off` is a true no-op —
/// both stages return `x` unchanged, and all existing presets are unaffected.
public enum MouthNoiseLevel: String, CaseIterable, Identifiable, Sendable {
    case off
    case low
    case medium
    case high

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off:    return "Off"
        case .low:    return "Low"
        case .medium: return "Medium"
        case .high:   return "High"
        }
    }

    /// Maximum de-plosive low-band reduction in dB. Intentionally conservative —
    /// voiced stops (B, D, G) share low-band energy with plosives; excess reduction
    /// dulls them. Starting points, tunable after listening.
    public var maxPlosReductionDb: Float {
        switch self {
        case .off:    return 0
        case .low:    return 8
        case .medium: return 14
        case .high:   return 20
        }
    }

    /// De-click gain floor (linear). How far the gain drops during a click event.
    /// `.off` = 1.0 (identity); lower = more suppression.
    public var clickGainFloor: Float {
        switch self {
        case .off:    return 1.0
        case .low:    return 0.50   // −6 dB
        case .medium: return 0.35   // ~−9 dB
        case .high:   return 0.25   // −12 dB
        }
    }
}

/// Fixed band/timing constants for the mouth-noise finisher stages (tunable starting points).
/// All values chosen conservatively — they target artifacts that are distinctly sharper or
/// more low-heavy than any voiced phoneme.
enum MouthNoiseProfile {
    // De-plosive
    static let plosiveSplitHz: Float   = 120    // low/high split frequency
    static let plosiveThresholdDb: Float = -42  // total-energy floor to arm detection
    static let plosiveLowRatioGuard: Float = 0.60  // low/(total) ratio gate
    static let plosiveAttackMs: Float  = 0.3
    static let plosiveReleaseMs: Float = 25

    // De-click
    static let clickFastAttackMs: Float  = 0.05
    static let clickFastReleaseMs: Float = 2.0
    static let clickSlowAttackMs: Float  = 50.0
    static let clickSlowReleaseMs: Float = 200.0
    static let clickRatio: Float         = 6.0  // fast/slow ratio to flag a click
    static let clickMinThresholdDb: Float = -54  // absolute floor (quiet rooms don't trigger)
    static let clickHoldReleaseMs: Float = 4.0  // how long to hold + release gain
}
```

### Step 3: Run tests to verify they pass

- [ ] Run: `swift test --filter MouthNoiseTests`
  - Expected: the `MouthNoiseLevel` tests pass (the chain integration tests fail because `VoiceChainSettings.mouthNoiseLevel` does not exist yet).

### Step 4: Commit

- [ ] Stage and commit:

```bash
git add Sources/Core/AudioProcessing/VoiceChain.swift Tests/NoNoiseMacTests/MouthNoiseTests.swift
git commit -m "feat(dsp): add MouthNoiseLevel enum and MouthNoiseProfile constants"
```

---

## Task 3: Wire `DePlosive` + `DeClick` into `VoiceChain` — TDD

Carry `mouthNoiseLevel` on `VoiceChainSettings`; add the two stages as stored properties; update `configure`, `reset`, and `process`; keep the chain active when only mouth-noise is on.

**Files:**
- Modify: `Sources/Core/AudioProcessing/VoiceChain.swift`
- The integration tests in `Tests/NoNoiseMacTests/MouthNoiseTests.swift` were written in Task 1 and reference `VoiceChainSettings.mouthNoiseLevel` and `VoiceChain.isActive`.

### Step 1: Run to verify failure

- [ ] Run: `swift test --filter MouthNoiseTests`
  - Expected: compile errors — `value of type 'VoiceChainSettings' has no member 'mouthNoiseLevel'`.

### Step 2a: Add `mouthNoiseLevel` to `VoiceChainSettings`

- [ ] In `Sources/Core/AudioProcessing/VoiceChain.swift`, in `VoiceChainSettings`, add after `var limiterCeilingDb: Float`:

```swift
    public var limiterCeilingDb: Float
    public var clarity: ClarityLevel = .off
    public var mouthNoiseLevel: MouthNoiseLevel = .off
```

The defaulted property keeps the synthesized memberwise initializer backward-compatible — all existing callers construct `VoiceChainSettings` without naming `mouthNoiseLevel`, so they default to `.off` and need no edits.

### Step 2b: Add stored properties to `VoiceChain`

- [ ] In the `VoiceChain` class, alongside `presence` and `deEsser`, add:

```swift
    private var dePlosive = DePlosive()
    private var deClick = DeClick()
    private var mouthNoise: MouthNoiseLevel = .off
```

### Step 2c: Update `configure(_:)` in `VoiceChain`

- [ ] Replace the whole `configure(_:)` method. Three precise changes vs. the Broadcast Voice version:
  1. **Capture `priorMouthNoise` and assign `mouthNoise = s.mouthNoiseLevel` at the TOP** (alongside `clarity`), BEFORE the reset block — otherwise the level-change comparison reads the value it is about to assign and the branch is dead.
  2. **Independent `if` checks, NOT `else if` chaining** — a single `configure` that changes BOTH clarity and mouthNoise must reset BOTH stage groups, not just the first one matched.
  3. **Extend the active gate** to include `mouthNoiseLevel`.

```swift
    public func configure(_ s: VoiceChainSettings) {
        let wasActive = active
        let priorClarity = clarity
        let priorMouthNoise = mouthNoise
        enabled = s.enabled
        clarity = s.clarity
        mouthNoise = s.mouthNoiseLevel
        active = s.enabled || s.clarity != .off || s.mouthNoiseLevel != .off
        guard active else { return }
        // Clean start when the chain becomes active (don't inherit frozen state).
        // Switching between two *active* settings is intentionally bumpless EXCEPT for the
        // stage group whose level changed — its stale envelope/gain state would ring on
        // re-enable and color the voice, so reset ONLY that group. Independent `if` checks
        // (not `else if`) so a simultaneous clarity+mouthNoise change resets BOTH groups.
        if !wasActive {
            reset()
        } else {
            if clarity != priorClarity { presence.reset(); deEsser.reset() }
            if mouthNoise != priorMouthNoise { dePlosive.reset(); deClick.reset() }
        }

        if enabled {
            hp.setHighPass(freq: s.highPassHz, sampleRate: sampleRate)
            lowShelf.setLowShelf(freq: s.lowShelfHz, gainDb: s.lowShelfDb, sampleRate: sampleRate)
            highShelf.setHighShelf(freq: s.highShelfHz, gainDb: s.highShelfDb, sampleRate: sampleRate)
            comp.configure(thresholdDb: s.compThresholdDb, ratio: s.compRatio,
                           attackMs: s.compAttackMs, releaseMs: s.compReleaseMs,
                           makeupDb: s.compMakeupDb, sampleRate: sampleRate)
        }

        if clarity != .off {
            presence.setPeaking(freq: ClarityProfile.presenceHz, gainDb: clarity.presenceDb,
                                sampleRate: sampleRate, q: ClarityProfile.presenceQ)
            deEsser.configure(crossoverHz: ClarityProfile.deEssCrossoverHz,
                              thresholdDb: ClarityProfile.deEssThresholdDb,
                              maxReductionDb: clarity.deEssMaxReductionDb,
                              attackMs: ClarityProfile.deEssAttackMs,
                              releaseMs: ClarityProfile.deEssReleaseMs,
                              sampleRate: sampleRate, enabled: true)
        } else {
            presence.setBypass()
            deEsser.configure(crossoverHz: ClarityProfile.deEssCrossoverHz,
                              thresholdDb: ClarityProfile.deEssThresholdDb, maxReductionDb: 0,
                              attackMs: ClarityProfile.deEssAttackMs,
                              releaseMs: ClarityProfile.deEssReleaseMs,
                              sampleRate: sampleRate, enabled: false)
        }

        if mouthNoise != .off {
            dePlosive.configure(
                splitHz: MouthNoiseProfile.plosiveSplitHz,
                thresholdDb: MouthNoiseProfile.plosiveThresholdDb,
                lowRatioGuard: MouthNoiseProfile.plosiveLowRatioGuard,
                maxReductionDb: mouthNoise.maxPlosReductionDb,
                attackMs: MouthNoiseProfile.plosiveAttackMs,
                releaseMs: MouthNoiseProfile.plosiveReleaseMs,
                sampleRate: sampleRate, enabled: true)
            deClick.configure(
                fastAttackMs: MouthNoiseProfile.clickFastAttackMs,
                fastReleaseMs: MouthNoiseProfile.clickFastReleaseMs,
                slowAttackMs: MouthNoiseProfile.clickSlowAttackMs,
                slowReleaseMs: MouthNoiseProfile.clickSlowReleaseMs,
                clickRatio: MouthNoiseProfile.clickRatio,
                minThresholdDb: MouthNoiseProfile.clickMinThresholdDb,
                holdReleaseMs: MouthNoiseProfile.clickHoldReleaseMs,
                gainFloor: mouthNoise.clickGainFloor,
                sampleRate: sampleRate, enabled: true)
        } else {
            dePlosive.configure(splitHz: MouthNoiseProfile.plosiveSplitHz,
                                thresholdDb: -42, lowRatioGuard: 0.60,
                                maxReductionDb: 0, attackMs: 0.3, releaseMs: 25,
                                sampleRate: sampleRate, enabled: false)
            deClick.configure(fastAttackMs: 0.05, fastReleaseMs: 2, slowAttackMs: 50,
                              slowReleaseMs: 200, clickRatio: 6.0, minThresholdDb: -54,
                              holdReleaseMs: 4, gainFloor: 1.0,
                              sampleRate: sampleRate, enabled: false)
        }

        // Limiter runs ONLY when a limiter-owning path is active (polish or clarity). The
        // de-plosive/de-click stages are attenuation-only (they never raise level), so
        // mouth-noise-only mode needs no limiter — running it would clamp a loud CLEAN
        // sample above the ceiling purely because the feature is on (an identity violation).
        if enabled || clarity != .off {
            limiter.configure(ceilingDb: s.limiterCeilingDb, releaseMs: 50, sampleRate: sampleRate)
        }
    }
```

### Step 2d: Update `reset()` in `VoiceChain`

- [ ] Extend `reset()` to include the new stages:

```swift
    public func reset() {
        hp.reset(); lowShelf.reset(); highShelf.reset()
        presence.reset(); deEsser.reset()
        dePlosive.reset(); deClick.reset()
        comp.reset(); limiter.reset()
    }
```

### Step 2e: Update `process(_:count:)` in `VoiceChain`

- [ ] Insert the two new stages between `deEsser` and `comp`. The chain order after this change is:

```
HP → lowShelf → highShelf → presence → deEsser → dePlosive → deClick → comp → limiter
```

The `process` loop becomes (replace the doc comment AND the full function body). The
Broadcast Voice doc comment said "the limiter always runs while active" — now FALSE, since
mouth-noise-only mode skips the limiter — so replace it too:

```swift
    /// Process `count` samples in place. No-op when inactive. Order:
    /// HP → shelves → presence → de-esser → de-plosive → de-click → compressor → limiter.
    /// Polish stages run only when `enabled`; clarity stages only when `clarity != .off`;
    /// mouth-noise stages only when `mouthNoise != .off`. The limiter runs only for a
    /// limiter-owning path (polish or clarity) — the attenuation-only mouth-noise stages
    /// never raise level, so mouth-noise-only mode is a true identity at rest for clean input.
    public func process(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        guard active else { return }
        let doPolish   = enabled
        let doClarity  = clarity != .off
        let doMouth    = mouthNoise != .off
        for i in 0..<count {
            var x = buffer[i]
            if doPolish {
                x = hp.process(x)
                x = lowShelf.process(x)
                x = highShelf.process(x)
            }
            if doClarity {
                x = presence.process(x)
                x = deEsser.process(x)
            }
            if doMouth {
                x = dePlosive.process(x)
                x = deClick.process(x)
            }
            if doPolish {
                x = comp.process(x)
            }
            // Limiter runs ONLY for limiter-owning paths (polish/clarity). De-plosive and
            // de-click are attenuation-only — they never raise level — so mouth-noise-only
            // mode must NOT limit (limiting a loud clean sample would break identity at rest).
            if doPolish || doClarity {
                x = limiter.process(x)
            }
            buffer[i] = x
        }
    }
```

### Step 3: Run the full test suite

- [ ] Run: `swift test`
  - Expected: ALL tests pass — the new `MouthNoiseTests` suite AND the existing `VoiceChainTests` (regression) AND `BroadcastVoiceTests` (no interaction regression).

### Step 4: Commit

- [ ] Stage and commit:

```bash
git add Sources/Core/AudioProcessing/VoiceChain.swift
git commit -m "feat(dsp): wire DePlosive + DeClick into VoiceChain, gated by MouthNoiseLevel"
```

---

## Task 4: Wire `mouthNoiseLevel` into `AudioModel`

Expose the control as a persisted `@Published` property and inject it into the chain on top of the active preset. **No XCTest:** `AudioModel` depends on CoreAudio/AVCapture and is not unit-testable in the headless suite. Verification is `swift build` + the green Core suite + the manual smoke test at the end.

**Files:**
- Modify: `Sources/Core/AudioModel.swift`

### Step 1: Add the `PrefKey`

- [ ] In the `PrefKey` enum (currently listing `preset`, `strength`, `atten`, `gain`, `voicePolish`, `clarity`), add:

```swift
        static let mouthNoise = "mv.mouthNoise"
```

### Step 2: Add the `@Published` property

- [ ] Immediately after the `clarityLevel` property, add:

```swift
    /// Mouth-noise finisher level (de-plosive + de-click). Layered on top of the
    /// active preset, independent of the noise preset, Voice Polish, and Broadcast
    /// Voice. Guarded by `isApplyingPreset` like all other knobs.
    @Published public var mouthNoiseLevel: MouthNoiseLevel = .off {
        didSet {
            guard !isApplyingPreset else { return }
            applyVoiceChain()
            persistSettings()
        }
    }
```

### Step 3: Inject in `applyVoiceChain()`

- [ ] Modify `applyVoiceChain()`:

```swift
    private func applyVoiceChain() {
        var s = selectedPreset.voiceChain
        s.enabled = s.enabled && voicePolishEnabled
        s.clarity = clarityLevel
        s.mouthNoiseLevel = mouthNoiseLevel
        voiceChain.configure(s)
    }
```

### Step 4: Persist + restore

- [ ] In `persistSettings()`, add after the `clarityLevel` persist line:

```swift
        d.set(clarityLevel.rawValue, forKey: PrefKey.clarity)
        d.set(mouthNoiseLevel.rawValue, forKey: PrefKey.mouthNoise)
```

- [ ] In `loadSettings()`, restore inside the `isApplyingPreset = true … = false` block, right after the `clarityLevel` restore:

```swift
        clarityLevel = ClarityLevel(rawValue: d.string(forKey: PrefKey.clarity) ?? "") ?? .off
        mouthNoiseLevel = MouthNoiseLevel(rawValue: d.string(forKey: PrefKey.mouthNoise) ?? "") ?? .off
        selectedPreset = preset
```

### Step 5: Build + regression test

- [ ] Run: `swift build && swift test`
  - Expected: build succeeds; all tests PASS.

### Step 6: Commit

- [ ] Stage and commit:

```bash
git add Sources/Core/AudioModel.swift
git commit -m "feat(audio): persist + apply MouthNoiseLevel (de-plosive + de-click) on top of presets"
```

---

## Task 5: Settings UI — Mouth Noise picker

Add the control to `GeneralSettingsView.suppressionCard`, directly under the Broadcast Voice picker. **No XCTest** (SwiftUI view) — verify by build + manual.

**Files:**
- Modify: `Sources/App/SettingsView.swift`

### Step 1: Add the picker

- [ ] Inside `suppressionCard`, after the closing brace of the Broadcast Voice `VStack` block (and before the closing `}` of the `suppressionCard` VStack), add:

```swift
            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Mouth Noise").font(.subheadline)
                Picker("", selection: $audioModel.mouthNoiseLevel) {
                    ForEach(MouthNoiseLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text("Tames P-pops and lip-smacks. De-plosive ducks low-band thumps; de-click masks short mouth clicks. Off = no processing added.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
```

### Step 2: Build

- [ ] Run: `swift build`
  - Expected: build succeeds.

### Step 3: Commit

- [ ] Stage and commit:

```bash
git add Sources/App/SettingsView.swift
git commit -m "feat(ui): add Mouth Noise level picker to Settings"
```

---

## Task 6: Popover UI — compact Mouth Noise card

Add a compact picker to the menu-bar popover below the Broadcast Voice card (which is below `modeCard`). **No XCTest** — build + manual.

**Files:**
- Modify: `Sources/App/ContentView.swift`

### Step 1: Add `mouthNoiseCard`

- [ ] After the `clarityCard` computed view, add:

```swift
    // MARK: - Mouth Noise finishers

    private var mouthNoiseCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardLabel("Mouth Noise", systemImage: "mouth.fill")
            Picker("", selection: $audioModel.mouthNoiseLevel) {
                ForEach(MouthNoiseLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .nnCard()
    }
```

### Step 2: Place in the layout

- [ ] In `body`'s `VStack`, add `mouthNoiseCard` after `clarityCard`:

```swift
        VStack(spacing: 14) {
            header
            statusCard
            modeCard
            clarityCard
            mouthNoiseCard
            devicesCard
            driverStatusRow
            footer
        }
```

### Step 3: Build

- [ ] Run: `swift build`
  - Expected: build succeeds.

### Step 4: Commit

- [ ] Stage and commit:

```bash
git add Sources/App/ContentView.swift
git commit -m "feat(ui): add compact Mouth Noise card to menu-bar popover"
```

---

## Task 7: Documentation (8-Fold Awareness Step 2 + compounding)

**Files:**
- Modify: `README.md`
- Modify: `CONCEPTS.md`
- Modify: `AGENTS.md`
- Modify: `docs/knowledge/timeline1.md`
- Modify: `docs/knowledge/knowledge1.md`

### Step 1: `README.md`

- [ ] Add a feature bullet under the Broadcast Voice bullet:

```markdown
- **🫦 Mouth Noise** — an optional de-plosive (P-pop / B-thump suppressor) and de-click (lip-smack / mouth-click suppressor) stage (Off / Low / Medium / High). Both are identity at rest — only the artifact is removed, never the voice.
```

- [ ] Add a short subsection after the Broadcast Voice section:

```markdown
### 🫦 Mouth Noise

Two targeted artifact suppressors that live after the de-esser in the chain:

- **De-plosive**: detects P-pop / B-thump transients by watching the ratio of low-band energy (< 120 Hz) to total energy. Only subtractively ducks the low band when both the energy level and the low-heavy ratio exceed their thresholds — so normal voiced stops (B, D, G) pass through untouched.
- **De-click**: tracks a fast envelope vs. a slow background RMS. When the fast/slow ratio spikes beyond `clickRatio` (6×), a brief (4 ms) gain reduction is applied. Normal speech never sustains this ratio.

Both stages are **Off by default** and are **identity at rest** — verified by XCTest. They are orthogonal to Broadcast Voice and the noise preset.
```

### Step 2: `CONCEPTS.md`

- [ ] Append to the voice-chain concept section:

```markdown
- **Mouth Noise Finishers** — two identity-at-rest DSP stages after the de-esser:
  - **De-plosive** (`DePlosive`): subtractive low-band gate. `out = x − frac·lowSig`
    when the low-band ratio and total energy both exceed thresholds. Identity otherwise.
  - **De-click** (`DeClick`): broadband transient gate. `out = x × gain` where
    `gain < 1` only during brief (< 5 ms) fast/slow envelope ratio spikes. Identity otherwise.
  - Controlled by `MouthNoiseLevel` (off/low/medium/high); persisted under `mv.mouthNoise`.
```

### Step 3: `AGENTS.md`

- [ ] Update the architecture-map bullet for the voice chain:

Find the line recently updated by the Broadcast Voice plan:
```
  - `AudioProcessing/VoiceChain` + `Biquad` + `Dynamics` — post-DSP "voice polish" (high-pass → shelves → compressor → limiter) plus the optional **Broadcast Voice** clarity stages (presence peaking bell → subtractive `DeEsser`), driven by `ClarityLevel` and gated independently of the noise preset.
```
Replace with:
```
  - `AudioProcessing/VoiceChain` + `Biquad` + `Dynamics` — post-DSP "voice polish" (high-pass → shelves → compressor → limiter) plus the optional **Broadcast Voice** clarity stages (presence peaking bell → subtractive `DeEsser`), and the optional **Mouth Noise** finisher stages (subtractive `DePlosive` → broadband-gate `DeClick`). Driven by `ClarityLevel` + `MouthNoiseLevel`, each gated independently of the noise preset.
```

- [ ] Update the chain-order bullet in the "Voice polish chain (Tier 2)" section:

Find:
```
- `VoiceChain` (Core/AudioProcessing) runs AFTER `DeepFilterNetDSP` on the time-domain output, inside `AudioModel`'s render callback, only when `isAIEnabled`. Order: high-pass → low-shelf → high-shelf → **presence (peaking bell) → de-esser** → compressor → limiter. The Limiter is last and hard-clamps to the ceiling — it is the final overflow guard.
```
Replace with:
```
- `VoiceChain` (Core/AudioProcessing) runs AFTER `DeepFilterNetDSP` on the time-domain output, inside `AudioModel`'s render callback, only when `isAIEnabled`. Order: high-pass → low-shelf → high-shelf → **presence (peaking bell) → de-esser → de-plosive → de-click** → compressor → limiter. The Limiter is last and hard-clamps to the ceiling — it is the final overflow guard.
```

- [ ] Update the persistence/activation bullet:

Find:
```
- Chain params are a pure function of `VoicePreset.voiceChain` (NOT persisted per-stage) plus the orthogonal **Broadcast Voice** `ClarityLevel`. The chain runs when `(voicePolishEnabled && preset.voiceChain.enabled) || clarity != .off`. Meeting polish = off; Podcast/Tutorial/Custom = on; Broadcast Voice (presence + de-esser) layers on any mode. Persisted: `mv.voicePolish`, `mv.clarity` (plus the Tier 1 `mv.preset`). `configure` resets ALL stage state on inactive→active, and resets ONLY the clarity stages when `clarity` changes while the chain stays active (bumpless otherwise).
```
Replace with:
```
- Chain params are a pure function of `VoicePreset.voiceChain` (NOT persisted per-stage) plus the orthogonal **Broadcast Voice** `ClarityLevel` and **Mouth Noise** `MouthNoiseLevel`. The chain runs when `(voicePolishEnabled && preset.voiceChain.enabled) || clarity != .off || mouthNoise != .off`. Meeting polish = off; Podcast/Tutorial/Custom = on; Broadcast Voice (presence + de-esser) and Mouth Noise (de-plosive + de-click) layer on any mode independently. Persisted: `mv.voicePolish`, `mv.clarity`, `mv.mouthNoise` (plus the Tier 1 `mv.preset`). `configure` resets ALL stage state on inactive→active; resets ONLY clarity stages when `clarity` changes while active; resets ONLY mouth-noise stages when `mouthNoiseLevel` changes while active (bumpless otherwise).
```

- [ ] Update the real-time rule bullet:

Find:
```
- **Real-time rule**: `VoiceChain.process` is allocation-free and per-sample; `configure(_:)` (coefficient recompute) runs on main only. State (`Biquad.z1/z2` for the high-pass, shelves, and the `presence` bell; `Compressor.envDb`; `Limiter.gain`; and the `DeEsser`'s detector envelope + high-pass state) carries across render buffers — never reset per buffer. `configure` resets state in exactly two cases: a FULL reset on the inactive→active transition (clean start), and a clarity-stages-only reset (`presence` + `DeEsser`) when `ClarityLevel` changes while the chain stays active. Active→active switches with unchanged clarity are intentionally bumpless.
```
Replace with:
```
- **Real-time rule**: `VoiceChain.process` is allocation-free and per-sample; `configure(_:)` (coefficient recompute) runs on main only. State (`Biquad.z1/z2` for the high-pass, shelves, and presence bell; `Compressor.envDb`; `Limiter.gain`; `DeEsser` envelope + HP state; `DePlosive` envelope pair + HP state; `DeClick` fast/slow envelopes, gain, hold counter) carries across render buffers — never reset per buffer. `configure` resets state in exactly three cases: FULL reset on inactive→active (clean start); clarity-stages-only reset (`presence` + `DeEsser`) when `ClarityLevel` changes while active; mouth-noise-stages-only reset (`DePlosive` + `DeClick`) when `MouthNoiseLevel` changes while active. All other active→active switches are intentionally bumpless.
```

### Step 4: `docs/knowledge/timeline1.md`

- [ ] Append a dated entry at the top (newest on top per the file's convention):

```markdown
### 2026-06-15 — Mouth-Noise Finishers (de-plosive + de-click) added

Added two new identity-at-rest `VoiceChain` stages after the de-esser:
`DePlosive` (subtractive low-band plosive gate, `out = x − frac·lowSig`) and
`DeClick` (broadband transient gate, `out = x × gain`). Both are pure value types
in `Dynamics.swift`, gated by `MouthNoiseLevel` (off/low/medium/high) carried on
`VoiceChainSettings` and injected by `AudioModel.applyVoiceChain()`. Persisted
under `mv.mouthNoise`. UI: segmented picker in Settings and the popover. Design
invariant — identity at rest — enforced structurally and proven by XCTest.
```

### Step 5: `docs/knowledge/knowledge1.md`

- [ ] Append a `[DECISION]` entry:

```markdown
### [DECISION] 2026-06-15 — Mouth-noise finishers: subtractive detection preserves voice character

**Problem**: P-pops and mouth clicks cannot be removed by EQ or de-essing alone — they
span the wrong frequency bands and timescales.
**Decision**: (1) `DePlosive` uses a dual-threshold detector (total energy AND low/total
ratio) to distinguish plosive thumps from voiced stops (B, D, G). Only when BOTH gates
fire does it subtractively duck the low band (`out = x − frac·lowSig`) — leaving the
mid-range voice body untouched. (2) `DeClick` uses a fast/slow envelope ratio — a click
appears as an anomalous spike relative to the speech background — and applies a hold-and-
release gain only for a few milliseconds, too brief to affect any voiced phoneme.
**Rule**: Any transient-targeted artifact suppressor must have a dual-gate (absolute
threshold + relative detection) and be tested for identity below threshold AND
preservation of the nearest voiced phoneme (voiced stop at the same level as the
artifact). Single-threshold detection is prone to false positives on consonant bursts.
**Files**: `Sources/Core/AudioProcessing/Dynamics.swift`,
`Sources/Core/AudioProcessing/VoiceChain.swift`,
`Tests/NoNoiseMacTests/MouthNoiseTests.swift`
```

### Step 6: Commit

- [ ] Stage and commit:

```bash
git add README.md CONCEPTS.md AGENTS.md docs/knowledge/timeline1.md docs/knowledge/knowledge1.md
git commit -m "docs: document Mouth Noise Finishers feature, vocab, chain order, and decision"
```

---

## Manual smoke test (after all tasks)

The headless suite cannot exercise the live audio path. After implementation, verify in the running app:

> **Note:** All voice-chain stages (including Mouth Noise) only run while **Noise Cancellation is ON** (`isAIEnabled = true`). Ensure that toggle is on for steps 3–6.

1. `./install-app.sh` (or `swift run`), open the popover.
2. Set a mode (e.g. Podcast). Speak naturally — confirm normal cleaned voice.
3. Set **Mouth Noise = Low**. Deliberately pop a few P's and B's directly into the mic. Confirm: the low-frequency thump is softened without the following vowel being colored.
4. Repeat step 3 with **Medium** and **High** — confirm increased suppression of the low-band pop while speech body is not affected.
5. Click your tongue / make a sharp lip-smack. Confirm: the click is softened at all levels, and the speech right after sounds normal.
6. Set **Mouth Noise = Off** — confirm sound is identical to before the feature (regression by ear).
7. Quit and relaunch — confirm the chosen level is restored (persistence).
8. Try Mouth Noise with **Meeting** mode (polish off) — confirm it still suppresses clicks/pops and never clips (limiter safety).
9. Enable both **Broadcast Voice = Medium** and **Mouth Noise = Medium** simultaneously. Speak, pop a few P's, make a click. Confirm: Broadcast Voice adds presence, Mouth Noise suppresses artifacts; neither stage interferes with the other audibly.

---

## Self-Review (completed during authoring)

- **Spec coverage:** "De-plosive: tame P-pops / low-frequency thumps via a transient-triggered dynamic high-pass / low-band ducking. Identity at rest." → `DePlosive` (Task 1), `MouthNoiseLevel` (Task 2), chain wiring (Task 3), AudioModel (Task 4), UI (Tasks 5–6). "De-click: suppress short mouth clicks / lip-smacks via a short-transient detector + brief targeted attenuation. Identity at rest." → `DeClick` (Task 1), same wiring path. "Identity at rest proven by tests" → `testDePlosiveDisabledIsIdentity`, `testDePlosiveBelowThresholdIsIdentity`, `testDeClickDisabledIsIdentity`, `testDeClickSteadySpeechIsIdentity`. "Only targeted artifact reduced, voice body untouched" → `testDePlosivePreservesMidBandVoice`, `testDeClickVoicedBodyUntouched`, `testDeClickReleasesQuickly`. "Identity at rest is non-negotiable (exact, from sample 0)" → `testDeClickVoicedOnsetAfterSilenceIsIdentity` (cold-silence onset, bit-level, NO skipped samples) and `testDeClickOnsetAfterSpeechThenPauseIsIdentity` (the realistic speech→pause→onset case, proving the gate DISARMS on actual silence rather than slow-envelope decay). "Bumpless carry-state across unrelated reconfigures" → `testUnrelatedConfigChangeDoesNotResetMouthNoise`. "Off = true no-op" → `testMouthNoiseOffMatchesLegacyChain`, `testMouthNoiseOnlyPreservesLoudCleanSignal`.
- **Reviewer-finding fixes (round 2):**
  1. *(State corruption)* `DePlosive.process` now advances its high-pass EXACTLY ONCE per sample — the `hp.process(0)` peek and the dead `loRatio` line are removed; detection reads the scalar envelopes only (`ratio = lowEnv / max(totalEnv, 1e-12)`). Proven by `testDePlosiveAdvancesFilterExactlyOncePerSample` (byte-identical to a single-advance one-pass reference on a gate-triggering signal).
  2. *(Dead reset predicate)* `VoiceChain.configure` now assigns `mouthNoise = s.mouthNoiseLevel` at the TOP (after capturing `priorMouthNoise`) and uses INDEPENDENT `if` checks (not `else if`) after the inactive→active full reset, so a level change actually fires and a simultaneous clarity+mouthNoise change resets BOTH groups. Proven by `testMouthNoiseLevelChangeResetsStages` (non-silent probe vs. a fresh chain) and `testSimultaneousClarityAndMouthNoiseChangeResetsBoth`.
  3. *(Identity at rest)* The limiter runs ONLY when `doPolish || doClarity`; mouth-noise-only mode (attenuation-only stages) skips it, so a loud clean sample above the ceiling is untouched. Proven by `testMouthNoiseOnlyPreservesLoudCleanSignal`.
  4. *(False positives)* `DeClick` distinguishes a few-sample click from a sustained voiced onset via a short-trip-run gate (engages only for `≤ maxClickSamples ≈ 1 ms`, latches off for sustained content) so the voiced body is not gated. Proven by `testDeClickVoicedBodyUntouched`. *(Superseded for the from-silence onset case by round-3 fix #2.)*
  5. *(Doc consistency)* High de-plosive cap is 20 dB consistently across prose, table, and `MouthNoiseLevel.high.maxPlosReductionDb`.
- **Reviewer-finding fixes (round 3):**
  1. *(Bumpless carry-state regression)* `DeClick.configure(enabled: true)` no longer clears runtime detector state on every call — it now mirrors `DeEsser` exactly: the `enabled` arm updates parameters/coefficients ONLY; runtime state (`fastEnv`, `slowEnv`, `gain`, `holdCounter`, `tripRun`, `latched`, `warmupCounter`, and `silenceCounter` per round-4 fix #1) is cleared ONLY in `reset()` and the disabled arm. `VoiceChain.configure` already decides when to reset (full reset on inactive→active; `dePlosive.reset()`/`deClick.reset()` only when `mouthNoiseLevel` changes), so reconfiguring on an UNRELATED change (clarity, voice-polish toggle) is bumpless and never cold-restarts the gate. (`DePlosive.configure` already followed this pattern — only its disabled arm zeroes envelopes — so it needed no change.) Proven by the new `testUnrelatedConfigChangeDoesNotResetMouthNoise` (energize de-click, change ONLY clarity with mouthNoise unchanged, assert carried state DIFFERS from a cold chain), with `testMouthNoiseLevelChangeResetsStages` still proving the intended reset WHEN `mouthNoiseLevel` itself changes.
  2. *(True identity at rest, not RMS-approximate)* `DeClick` no longer permits attenuating the first ~1 ms of a voiced onset after silence. The gate is now ARMED only after the slow background has been established (above `minThresholdLin`) continuously for `warmupSamples` (≈ one slow-release time-constant). Until armed, `process` returns `x` BIT-FOR-BIT (gain forced to exactly 1.0; ratio test not consulted). The old "warm-up floor on the ratio denominator" is removed in favor of this stronger arming guard. `testDeClickVoicedOnsetAfterSilenceIsIdentity` is rewritten to assert EXACT per-sample identity (`out == in` within 1e-6, NO skipped samples) across the full onset. **Accepted tradeoff (per the brief):** a click occurring from total silence (no established background) is intentionally missed — preferable to dulling clean speech. `testDeClickReducesShortSpike` still passes: it settles a background before the spike, so the gate is armed and a mid/after-speech click is still caught. *(Disarm mechanism corrected in round-4 fix #1 — the round-3 design relied on `slowEnv` for disarm, which is wrong; see below.)*
- **Reviewer-finding fixes (round 4):**
  1. *(Disarm on actual silence, not slow-envelope decay — identity-at-rest break)* The round-3 design DOCUMENTED "a return to silence resets the arming" but IMPLEMENTED it by resetting `warmupCounter` only when `slowEnv <= minThresholdLin`. Because `slowEnv` uses a ~200 ms release, after established speech a realistic 200–300 ms pause leaves `slowEnv` STILL above the floor, so the gate stays ARMED — and the next clean voiced onset is treated as an armed transient and attenuated for up to `maxClickSamples`. The existing onset-identity test only started from COLD silence (`slowEnv == 0`), so it never exercised the real "speech → pause → onset" case. **Fix:** disarm is now driven by an INDEPENDENT instantaneous-silence detector — `silenceCounter` counts consecutive samples whose instantaneous level (`|x|`) is below the silence floor (`minThresholdLin`); after `silenceSamples` (75 ms, `DeClick.silenceDisarmMs`) the gate force-disarms (`warmupCounter = 0`). Any above-floor sample resets `silenceCounter`, so voiced zero-crossings never disarm mid-speech; `slowEnv` now feeds ONLY the ratio test. `silenceCounter` joins the runtime-state contract (cleared only in `reset()` / the disabled arm). Proven by the new `testDeClickOnsetAfterSpeechThenPauseIsIdentity` (arm with 400 ms speech, feed 250 ms silence, assert EXACT per-sample identity across the next 50 ms onset). `testDeClickReducesShortSpike` still passes (settles a background then injects the spike with NO silence gap, so the gate stays armed). The 75 ms disarm window is documented in the DSP-design prose, the `MouthNoiseProfile`-constants line, and the `DeClick` doc-comment.
- **Placeholder scan:** none — every code step shows complete, copy-pasteable code.
- **Type consistency:** `MouthNoiseLevel` (with `maxPlosReductionDb`, `clickGainFloor`, `label`, `allCases`, `id`), `MouthNoiseProfile` constants, `DePlosive.configure(splitHz:thresholdDb:lowRatioGuard:maxReductionDb:attackMs:releaseMs:sampleRate:enabled:)`, `DeClick.configure(fastAttackMs:fastReleaseMs:slowAttackMs:slowReleaseMs:clickRatio:minThresholdDb:holdReleaseMs:gainFloor:sampleRate:enabled:)`, `VoiceChainSettings.mouthNoiseLevel`, and `AudioModel.mouthNoiseLevel` are used consistently across all tasks.
- **Interaction with existing stages:** chain position (de-plosive → de-click after de-esser, before compressor) prevents plosive thumps from pumping the compressor envelope. The de-esser's 6 kHz crossover is above the de-plosive's 120 Hz split — no frequency overlap; stages are independent.
- **Regression guard:** `testMouthNoiseOffMatchesLegacyChain` proves byte-for-byte identity when mouth noise is off. `testChainMouthNoiseOffIsPassthrough` proves no-op on a disabled chain. The existing `VoiceChainTests` run as part of `swift test` and catch any regressions in the polish stages.
- **No "MetalVoice"/"Ghostkwebb" in Sources/:** none introduced.
- **No absolute local paths:** all paths are repo-relative.
- **`mv.*` persistence:** `mv.mouthNoise` follows the existing pattern exactly.
