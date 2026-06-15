# Broadcast Voice (Clarity) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a **Broadcast Voice** control (Off / Low / Medium / High) that makes the voice sound clearer and more "present/broadcast" — a gentle presence lift coupled with an automatic de-esser — **without changing the identity of the original voice**.

**Architecture:** Two new allocation-free DSP stages added to the existing `VoiceChain`: a wide-Q **presence** peaking bell (`Biquad.setPeaking`) and a **subtractive split-band `DeEsser`** (`Dynamics.swift`). They are driven by a single `ClarityLevel` enum carried on `VoiceChainSettings` and injected by `AudioModel` on top of the active preset (independent of the noise preset and of Voice Polish). The presence boost is followed by the de-esser so added "air" can never become harsh sibilance; the existing limiter (already last in the chain) catches any peaks. When `clarity == .off`, presence is bypass and the de-esser is a perfect identity, so every existing preset behaves **byte-for-byte as before**.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Package Manager, XCTest, Accelerate (per-sample scalar/biquad math; no CoreML dependency in any new type).

**GitHub Issue:** #1 — https://github.com/ivalsaraj/NoNoise-Mac/issues/1

**Execution location:** Run all commands from the package root — the directory that contains `Package.swift`. All paths in this plan are relative to that root.

---

## Context

### Why this feature
DeepFilterNet removes *noise*; the Voice Polish chain (HP → shelves → compressor → limiter) shapes *tone*. Neither makes a voice sound "broadcast-crisp/present" on demand — and a naïve high-shelf "crispiness" boost amplifies sibilance, mouth noise, and residual hiss (the classic "ice-pick" failure). Persona research (YouTuber, podcaster, streamer, VO/course creator) unanimously asked for **one intelligent clarity control with de-essing baked in**, exposed as a named preset, never a raw EQ slider.

### The non-negotiable constraint: "must feel like the original voice"
This plan satisfies it structurally, not by taste alone:

1. **Subtractive de-esser, identity at rest.** `out = x − frac·sib`, where `sib` is the high-passed sibilant band and `frac ∈ [0, maxReduction]`. Below the detector threshold `frac = 0` → `out = x` *exactly*. The de-esser only acts on genuine "ess"/"sh" transients; it never touches the vocal body.
2. **Presence = wide-Q peaking bell with unity DC gain.** A peaking biquad has `|H(DC)| = 1` and `|H(Nyquist)| = 1` analytically (proven in Task 1's test). Low/mid frequencies — the part of the spectrum that carries vocal identity — pass through at unity. A *wide* Q (~0.7) means a broad, musical lift, not a resonant "processed" coloration.
3. **Conservative, capped gains even at High** (+1.5 / +3 / +4.5 dB) and de-ess that **scales with** the presence lift, so "crisp" is always paired with sibilance control.
4. **`clarity == .off` is a true no-op.** Existing Meeting/Podcast/Tutorial/Custom output is unchanged when Broadcast Voice is Off (the default).

### Current code facts (verified against the repo)
- `Biquad` (`Sources/Core/AudioProcessing/Biquad.swift`) is a TDF-II RBJ biquad with `setBypass / setHighPass / setLowShelf / setHighShelf`, per-sample `process`, and a `dcGain` test helper. **It has no peaking/bell factory** — Task 1 adds one.
- `Dynamics.swift` has `Compressor` and `Limiter` only. **There is no de-esser** — Task 2 adds one.
- `VoiceChain` (`Sources/Core/AudioProcessing/VoiceChain.swift`) runs `hp → lowShelf → highShelf → comp → limiter` per sample, gated by `enabled`; `configure(_:)` recomputes coefficients on **main**, `process(_:count:)` runs on the **render thread** and must stay allocation-free (`docs/knowledge/critical-patterns.md` → "render thread is allocation-free").
- `VoiceChainSettings` is a `Sendable, Equatable` value struct; presets map to it via `VoicePreset.voiceChain`. `VoicePreset.parameters` is suppression-only.
- `AudioModel` owns the live knobs as `@Published` + `didSet`, guarded by `isApplyingPreset`, persisted under the `mv.*` namespace via `PrefKey`. `applyVoiceChain()` (lines 219–223) computes `s.enabled = s.enabled && voicePolishEnabled` then `voiceChain.configure(s)`. `persistSettings()` (238–245) and `loadSettings()` (247–276) are the persistence pair. The render callback calls `chain.process(data, count: count)` after `dsp.process(...)` (lines 178–182).
- Tests live in `Tests/NoNoiseMacTests/` (`@testable import Core`), run headless with `swift test` (no mic/CoreML needed). `VoiceChainTests.swift` is the style reference.
- UI: `ContentView.swift` (menu-bar popover, has the segmented **Mode** picker) and `SettingsView.swift` → `GeneralSettingsView` (has the **Voice Polish** toggle inside `suppressionCard`). Cards use the shared `nnCard()` modifier; sliders use `sliderRow(...)`.

### Design decisions
- **Broadcast Voice is orthogonal to the noise preset and to Voice Polish.** It is its own `ClarityLevel` control. It is injected by `AudioModel.applyVoiceChain()` on top of whatever preset is active, so it works in any mode (including Meeting). Rationale: it's a first-class creator feature, not a sub-setting of one mode.
- **The chain runs when `enabled || clarity != .off`.** When polish is off but clarity is on, only `presence → deEsser → limiter` run (the limiter is the safety net for the presence boost). When clarity is off, the new stages are bypass/identity, preserving existing behavior exactly.
- **Single source of truth for level → DSP mapping** lives on `ClarityLevel` (mirroring how `VoicePreset` owns its `parameters`). Fixed band/threshold constants live in a `ClarityProfile` enum.
- **Tuning values are documented starting points**, tunable after listening (same convention as the existing presets).
- **One new persisted key** (`mv.clarity`); no other persistence churn.

### Level → DSP mapping (the whole feature in one table)

| Level | Presence lift (peaking @ 4.5 kHz, Q 0.7) | De-ess max reduction (split-band @ 6 kHz) |
|---|---|---|
| **Off** | 0 dB (bypass) | 0 dB (identity) |
| **Low** | +1.5 dB | up to 4 dB |
| **Medium** | +3 dB | up to 6 dB |
| **High** | +4.5 dB | up to 8 dB |

Fixed constants (`ClarityProfile`): presence `4500 Hz` / `Q 0.7`; de-ess crossover `6000 Hz`, threshold `−28 dB`, attack `1 ms`, release `80 ms`.

---

## Task 0: Branch

- [ ] **Step 1: Create a feature branch** (repo is on `main` with unrelated working-tree changes — do NOT stage those)

```bash
# Run from the package root (the directory that contains Package.swift)
git checkout -b feat/broadcast-voice-clarity
```

Expected: `Switched to a new branch 'feat/broadcast-voice-clarity'`. Throughout this plan, `git add` **only the specific files named in each task** — never `git add -A`/`.` (the working tree has unrelated modified files).

---

## Task 1: `Biquad.setPeaking` — presence bell — TDD

A wide-Q RBJ peaking EQ for the presence lift. The test proves the identity-preserving property: a peaking bell has **unity gain at DC and Nyquist** (it cannot alter the vocal fundamental/body or the spectral extremes), boosts at its center, and leaves a low tone unchanged.

**Files:**
- Modify: `Sources/Core/AudioProcessing/Biquad.swift` (add one method)
- Create: `Tests/NoNoiseMacTests/BroadcastVoiceTests.swift`

- [ ] **Step 1: Write the failing tests** — create `Tests/NoNoiseMacTests/BroadcastVoiceTests.swift`

```swift
import XCTest
@testable import Core

final class BroadcastVoiceTests: XCTestCase {

    // MARK: - Biquad peaking (presence bell)

    /// A peaking bell must leave DC (and thus the low-frequency vocal body) at unity gain.
    func testPeakingHasUnityDCGain() {
        var b = Biquad()
        b.setPeaking(freq: 4500, gainDb: 6, sampleRate: 48000, q: 0.7)
        XCTAssertEqual(b.dcGain, 1.0, accuracy: 1e-3, "presence bell must not change DC/low end")
    }

    /// At the center frequency, a +6 dB bell must audibly boost (output RMS > input RMS).
    func testPeakingBoostsCenterFrequency() {
        var b = Biquad()
        b.setPeaking(freq: 4500, gainDb: 6, sampleRate: 48000, q: 0.7)
        let inRMS = sineRMS(freq: 4500, amp: 0.3, n: 9600, through: &b)
        XCTAssertGreaterThan(inRMS.outRMS / inRMS.inRMS, 1.3, "center frequency must be lifted")
    }

    /// A low tone (vocal body) must pass a presence bell ~unchanged — identity of the voice.
    func testPeakingPreservesLowEnd() {
        var b = Biquad()
        b.setPeaking(freq: 4500, gainDb: 6, sampleRate: 48000, q: 0.7)
        let r = sineRMS(freq: 180, amp: 0.3, n: 9600, through: &b)
        XCTAssertEqual(r.outRMS / r.inRMS, 1.0, accuracy: 0.05, "low end must be essentially untouched")
    }

    /// The bell must also leave Nyquist (Fs/2) at unity gain — a peaking EQ only shapes the
    /// band around its center, never the spectral extremes. A sine at exactly Nyquist is
    /// `cos(πn) = (-1)^n`, so probe with an alternating ±amp signal (a `sinf` Nyquist tone
    /// would be identically zero). Measured over the second half to skip the settling transient.
    func testPeakingHasUnityNyquistGain() {
        var b = Biquad()
        b.setPeaking(freq: 4500, gainDb: 6, sampleRate: 48000, q: 0.7)
        let amp: Float = 0.3
        let n = 9600, half = 4800
        var inSq: Float = 0, outSq: Float = 0
        for i in 0..<n {
            let x: Float = (i % 2 == 0) ? amp : -amp
            let y = b.process(x)
            if i >= half { inSq += x * x; outSq += y * y }
        }
        XCTAssertEqual(sqrtf(outSq / Float(half)), sqrtf(inSq / Float(half)), accuracy: 1e-3,
                       "presence bell must not change the Nyquist/high extreme")
    }

    // MARK: - Helpers

    /// Drive a steady sine through a biquad; return input/steady-state output RMS
    /// (measured over the second half to skip the filter's settling transient).
    private func sineRMS(freq: Float, amp: Float, n: Int, through b: inout Biquad)
        -> (inRMS: Float, outRMS: Float) {
        var inSq: Float = 0, outSq: Float = 0
        let half = n / 2
        for i in 0..<n {
            let x = amp * sinf(2 * Float.pi * freq * Float(i) / 48000)
            let y = b.process(x)
            if i >= half { inSq += x * x; outSq += y * y }
        }
        let denom = Float(n - half)
        return (sqrtf(inSq / denom), sqrtf(outSq / denom))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter BroadcastVoiceTests`
Expected: compile error — `value of type 'Biquad' has no member 'setPeaking'`.

- [ ] **Step 3: Add the peaking factory to `Biquad`**

In `Sources/Core/AudioProcessing/Biquad.swift`, add this method immediately after `setHighShelf(...)` (before the private `setShelf`):

```swift
    /// RBJ peaking EQ (bell). Unity gain at DC and Nyquist; boosts/cuts `gainDb`
    /// around `freq`. A wide `q` (~0.7) gives a broad, musical lift that adds
    /// presence without coloring the voice's identity.
    public mutating func setPeaking(freq: Float, gainDb: Float, sampleRate: Float, q: Float = 0.707) {
        let A = powf(10, gainDb / 40)
        let w0 = 2 * Float.pi * max(freq, 1) / sampleRate
        let cs = cosf(w0), sn = sinf(w0)
        let alpha = sn / (2 * max(q, 0.0001))
        let a0 = 1 + alpha / A
        b0 = (1 + alpha * A) / a0
        b1 = (-2 * cs) / a0
        b2 = (1 - alpha * A) / a0
        a1 = (-2 * cs) / a0
        a2 = (1 - alpha / A) / a0
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter BroadcastVoiceTests`
Expected: 4 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/Biquad.swift Tests/NoNoiseMacTests/BroadcastVoiceTests.swift
git commit -m "feat(dsp): add RBJ peaking biquad for Broadcast Voice presence lift"
```

---

## Task 2: `DeEsser` — subtractive split-band — TDD

The identity-preserving de-esser. It isolates the sibilant band, follows its envelope, and subtracts a *fraction* of that band only when it exceeds threshold. Below threshold (and when disabled) it returns the input unchanged.

**Files:**
- Modify: `Sources/Core/AudioProcessing/Dynamics.swift` (add `DeEsser`)
- Modify: `Tests/NoNoiseMacTests/BroadcastVoiceTests.swift` (add tests)

- [ ] **Step 1: Write the failing tests** — add these methods inside `BroadcastVoiceTests` (after the peaking tests, before `// MARK: - Helpers`)

```swift
    // MARK: - DeEsser

    /// Disabled de-esser is a perfect identity for any sample.
    func testDeEsserDisabledIsIdentity() {
        var d = DeEsser()
        d.configure(crossoverHz: 6000, thresholdDb: -28, maxReductionDb: 6,
                    attackMs: 1, releaseMs: 80, sampleRate: 48000, enabled: false)
        for x in [Float(0.0), 0.5, -0.73, 0.99] {
            XCTAssertEqual(d.process(x), x, accuracy: 1e-7, "disabled de-esser must not alter samples")
        }
    }

    /// Quiet sibilance (below threshold) passes through unchanged — voice stays original.
    func testDeEsserQuietSibilancePasses() {
        var d = DeEsser()
        d.configure(crossoverHz: 6000, thresholdDb: -28, maxReductionDb: 6,
                    attackMs: 1, releaseMs: 80, sampleRate: 48000, enabled: true)
        var maxDelta: Float = 0
        for i in 0..<9600 {
            let x = 0.02 * sinf(2 * Float.pi * 7000 * Float(i) / 48000) // ~ -34 dB, below -28 dB
            maxDelta = max(maxDelta, abs(d.process(x) - x))
        }
        XCTAssertLessThan(maxDelta, 1e-4, "below-threshold sibilance must pass unchanged")
    }

    /// Loud sibilance is reduced (output high-band energy < input).
    /// Probe at 10 kHz: representative of real "ess" sibilance and far enough above the
    /// 6 kHz crossover that the subtractive band (`out = x − frac·sib`) is near-in-phase,
    /// so the reduction is genuine. (A tone just above the crossover — e.g. 7.5 kHz — sees
    /// a ~70° high-pass phase shift that mathematically caps subtractive cancellation near
    /// ~6 %, so it cannot probe real attenuation regardless of `maxReductionDb`.)
    func testDeEsserReducesLoudSibilance() {
        var d = DeEsser()
        d.configure(crossoverHz: 6000, thresholdDb: -28, maxReductionDb: 8,
                    attackMs: 1, releaseMs: 80, sampleRate: 48000, enabled: true)
        var inSq: Float = 0, outSq: Float = 0
        let n = 9600, half = 4800
        for i in 0..<n {
            let x = 0.8 * sinf(2 * Float.pi * 10000 * Float(i) / 48000) // loud, well above threshold
            let y = d.process(x)
            if i >= half { inSq += x * x; outSq += y * y }
        }
        XCTAssertLessThan(sqrtf(outSq / Float(half)), sqrtf(inSq / Float(half)) * 0.85,
                          "loud sibilance must be attenuated")
    }

    /// Loud LOW-frequency content (vocal body) is untouched even with the de-esser ON.
    func testDeEsserPreservesVoiceBody() {
        var d = DeEsser()
        d.configure(crossoverHz: 6000, thresholdDb: -28, maxReductionDb: 8,
                    attackMs: 1, releaseMs: 80, sampleRate: 48000, enabled: true)
        var maxDelta: Float = 0
        for i in 0..<9600 {
            let x = 0.8 * sinf(2 * Float.pi * 200 * Float(i) / 48000) // loud, but below the sib band
            maxDelta = max(maxDelta, abs(d.process(x) - x))
        }
        XCTAssertLessThan(maxDelta, 1e-3, "the de-esser must not touch the vocal body")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter BroadcastVoiceTests`
Expected: compile error — `cannot find 'DeEsser' in scope`.

- [ ] **Step 3: Implement `DeEsser`** — append to `Sources/Core/AudioProcessing/Dynamics.swift`

```swift
/// Subtractive split-band de-esser. Isolates the sibilant band with a high-pass,
/// follows its envelope, and removes a fraction of that band when it exceeds
/// threshold: `out = x - frac·sib`. Below threshold (and when disabled) `frac = 0`,
/// so output == input **exactly** — it never colors the voice except on real
/// "ess"/"sh" transients, and it never touches the low/mid vocal body.
public struct DeEsser {
    private var sib = Biquad()           // high-pass isolating the sibilant band
    private var enabled = false
    private var thresholdLin: Float = 1  // detector threshold (linear)
    private var maxReduction: Float = 0  // max fraction of the sib band to remove (0…1)
    private var attackCoeff: Float = 0
    private var releaseCoeff: Float = 0
    private var env: Float = 0           // smoothed |sib| envelope (linear)

    public init() {}

    public mutating func configure(crossoverHz: Float, thresholdDb: Float, maxReductionDb: Float,
                                   attackMs: Float, releaseMs: Float, sampleRate: Float, enabled: Bool) {
        self.enabled = enabled
        guard enabled else { sib.setBypass(); env = 0; return }
        sib.setHighPass(freq: crossoverHz, sampleRate: sampleRate, q: 0.707)
        thresholdLin = powf(10, thresholdDb / 20)
        // Convert "max dB to pull the band down" into a max removed-fraction, so
        // out = x - frac·sib reduces the band by at most maxReductionDb and never inverts it.
        maxReduction = min(1, 1 - powf(10, -abs(maxReductionDb) / 20))
        attackCoeff = expf(-1.0 / (max(attackMs, 0.01) * 0.001 * sampleRate))
        releaseCoeff = expf(-1.0 / (max(releaseMs, 0.01) * 0.001 * sampleRate))
    }

    public mutating func reset() { env = 0; sib.reset() }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }
        let s = sib.process(x)                 // sibilant band (state advances every sample)
        let mag = abs(s)
        let coeff = mag > env ? attackCoeff : releaseCoeff
        env = coeff * env + (1 - coeff) * mag
        guard env > thresholdLin else { return x }   // below threshold → exact identity
        let over = env / thresholdLin                // > 1 here
        let frac = maxReduction * (1 - 1 / over)      // 0 at threshold → maxReduction when loud
        return x - frac * s                           // remove only the sibilant band
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter BroadcastVoiceTests`
Expected: 7 tests PASS (3 peaking + 4 de-esser).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/Dynamics.swift Tests/NoNoiseMacTests/BroadcastVoiceTests.swift
git commit -m "feat(dsp): add subtractive split-band DeEsser (identity at rest)"
```

---

## Task 3: `ClarityLevel` enum — TDD

The user-facing Off/Low/Medium/High control and its single-source-of-truth DSP mapping.

**Files:**
- Modify: `Sources/Core/AudioProcessing/VoiceChain.swift` (add enum + constants at top)
- Modify: `Tests/NoNoiseMacTests/BroadcastVoiceTests.swift` (add tests)

- [ ] **Step 1: Write the failing tests** — add inside `BroadcastVoiceTests`

```swift
    // MARK: - ClarityLevel

    func testClarityOffIsZero() {
        XCTAssertEqual(ClarityLevel.off.presenceDb, 0)
        XCTAssertEqual(ClarityLevel.off.deEssMaxReductionDb, 0)
    }

    func testClarityLevelsAreMonotonic() {
        XCTAssertLessThan(ClarityLevel.low.presenceDb, ClarityLevel.medium.presenceDb)
        XCTAssertLessThan(ClarityLevel.medium.presenceDb, ClarityLevel.high.presenceDb)
        XCTAssertLessThan(ClarityLevel.low.deEssMaxReductionDb, ClarityLevel.medium.deEssMaxReductionDb)
        XCTAssertLessThan(ClarityLevel.medium.deEssMaxReductionDb, ClarityLevel.high.deEssMaxReductionDb)
    }

    func testClarityCasesAndLabels() {
        XCTAssertEqual(ClarityLevel.allCases, [.off, .low, .medium, .high])
        XCTAssertEqual(ClarityLevel.off.label, "Off")
        XCTAssertEqual(ClarityLevel.high.label, "High")
    }

    /// Presence is capped even at High — clarity must never become an aggressive EQ.
    func testClarityPresenceIsConservativelyCapped() {
        XCTAssertLessThanOrEqual(ClarityLevel.high.presenceDb, 5,
                                 "presence lift stays gentle to preserve the original voice")
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter BroadcastVoiceTests`
Expected: compile error — `cannot find 'ClarityLevel' in scope`.

- [ ] **Step 3: Add `ClarityLevel` + `ClarityProfile`** — insert at the top of `Sources/Core/AudioProcessing/VoiceChain.swift`, immediately after `import Foundation` and before `public struct VoiceChainSettings`:

```swift
/// "Broadcast Voice" intensity. Drives a coupled presence lift + de-esser so the
/// voice sounds clearer/more present while keeping its original identity. `.off`
/// is a true no-op (presence bypassed, de-esser identity).
public enum ClarityLevel: String, CaseIterable, Identifiable, Sendable {
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

    /// Presence (peaking-bell) lift in dB. Conservative by design — a gentle,
    /// wide lift adds clarity without coloring the voice. Tunable starting points.
    public var presenceDb: Float {
        switch self {
        case .off:    return 0
        case .low:    return 1.5
        case .medium: return 3
        case .high:   return 4.5
        }
    }

    /// Maximum de-ess reduction (dB) of the sibilant band. Scales WITH the
    /// presence lift so added "air" never turns into harsh sibilance.
    public var deEssMaxReductionDb: Float {
        switch self {
        case .off:    return 0
        case .low:    return 4
        case .medium: return 6
        case .high:   return 8
        }
    }
}

/// Fixed band/timing constants for the Broadcast Voice stages (tunable starting points).
enum ClarityProfile {
    static let presenceHz: Float = 4500
    static let presenceQ: Float = 0.7
    static let deEssCrossoverHz: Float = 6000
    static let deEssThresholdDb: Float = -28
    static let deEssAttackMs: Float = 1
    static let deEssReleaseMs: Float = 80
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter BroadcastVoiceTests`
Expected: 11 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/VoiceChain.swift Tests/NoNoiseMacTests/BroadcastVoiceTests.swift
git commit -m "feat(dsp): add ClarityLevel (Broadcast Voice) with level→DSP mapping"
```

---

## Task 4: Wire presence + de-esser into `VoiceChain` — TDD

Carry `clarity` on `VoiceChainSettings`; insert the two stages into the chain; make the chain run when polish OR clarity is active; keep `clarity == .off` byte-for-byte unchanged.

**Files:**
- Modify: `Sources/Core/AudioProcessing/VoiceChain.swift` (struct field + class stages)
- Modify: `Tests/NoNoiseMacTests/BroadcastVoiceTests.swift` (add tests)

- [ ] **Step 1: Write the failing tests** — add inside `BroadcastVoiceTests`

```swift
    // MARK: - VoiceChain integration

    /// Disabled polish + clarity off = passthrough (regression: existing Meeting behavior).
    func testChainOffWithClarityOffIsPassthrough() {
        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.clarity = .off
        chain.configure(s)
        var buf: [Float] = [0.1, -0.2, 0.3, -0.4]
        let copy = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(buf, copy, "off+off must not modify samples")
    }

    /// Clarity active with polish OFF (e.g. Meeting) still processes (presence engages).
    func testClarityActiveWithPolishOff() {
        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled        // enabled == false
        s.clarity = .high
        chain.configure(s)
        XCTAssertTrue(chain.isActive)
        var buf = [Float](repeating: 0.0, count: 9600)
        for i in 0..<buf.count { buf[i] = 0.3 * sinf(2 * Float.pi * 4500 * Float(i) / 48000) }
        let before = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        XCTAssertFalse(zip(buf, before).allSatisfy { abs($0 - $1) < 1e-4 },
                       "clarity must shape a presence-band signal even with polish off")
    }

    /// Higher clarity ⇒ more presence-band energy (monotonic effect through the chain).
    func testHigherClarityLiftsPresenceBandMore() {
        func presenceRMS(_ level: ClarityLevel) -> Float {
            let chain = VoiceChain()
            var s = VoiceChainSettings.disabled
            s.clarity = level
            chain.configure(s)
            var buf = [Float](repeating: 0, count: 9600)
            for i in 0..<buf.count { buf[i] = 0.2 * sinf(2 * Float.pi * 4500 * Float(i) / 48000) }
            buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
            var sq: Float = 0
            for i in 4800..<buf.count { sq += buf[i] * buf[i] }
            return sqrtf(sq / 4800)
        }
        XCTAssertGreaterThan(presenceRMS(.high), presenceRMS(.medium))
        XCTAssertGreaterThan(presenceRMS(.medium), presenceRMS(.low))
    }

    /// Re-activation resets stage state (no stale ringing leaks in).
    func testChainResetsOnReactivateWithClarity() {
        let chain = VoiceChain()
        var on = VoiceChainSettings.disabled
        on.clarity = .high
        chain.configure(on)
        var loud = [Float](repeating: 0.9, count: 4800)
        loud.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        chain.configure(.disabled)                 // inactive (state frozen)
        chain.configure(on)                        // active again → reset()
        var quiet = [Float](repeating: 0, count: 64)
        quiet.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        XCTAssertTrue(quiet.allSatisfy { abs($0) < 1e-3 }, "re-activation must start clean")
    }

    /// Off→On (and level changes) while the chain stays active must reset the clarity stages.
    /// Isolated by keeping polish OFF (enabled=false) so only presence+de-esser+limiter run —
    /// no polish ringing to confound the silence assertion.
    func testClarityChangeResetsStagesWhileActive() {
        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled   // polish OFF; chain active via clarity only
        s.clarity = .high
        chain.configure(s)
        // Energize the clarity stages with a loud sibilant-rich burst.
        var burst = [Float](repeating: 0, count: 4800)
        for i in 0..<burst.count { burst[i] = 0.9 * sinf(2 * Float.pi * 7000 * Float(i) / 48000) }
        burst.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        // Change clarity level while still active (high→low): must reset the clarity stages.
        s.clarity = .low
        chain.configure(s)
        // Silence in → no stale presence/de-esser ringing may leak (only clarity stages run here).
        var quiet = [Float](repeating: 0, count: 128)
        quiet.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        XCTAssertTrue(quiet.allSatisfy { abs($0) < 1e-4 },
                      "clarity stages must reset on change — no stale ringing")
    }

    /// Clarity = Off must leave an enabled (polish-on) preset bit-identical to the canonical
    /// hp→lowShelf→highShelf→compressor→limiter chain — proving Broadcast Voice Off is a true no-op.
    func testClarityOffMatchesCanonicalPolishChain() {
        let s = VoicePreset.podcast.voiceChain        // clarity defaults to .off
        let chain = VoiceChain()
        chain.configure(s)
        // Reference: the same primitives in the legacy order, with NO presence/de-esser stages.
        var hp = Biquad(), lo = Biquad(), hi = Biquad()
        var comp = Compressor(); var lim = Limiter()
        hp.setHighPass(freq: s.highPassHz, sampleRate: 48000)
        lo.setLowShelf(freq: s.lowShelfHz, gainDb: s.lowShelfDb, sampleRate: 48000)
        hi.setHighShelf(freq: s.highShelfHz, gainDb: s.highShelfDb, sampleRate: 48000)
        comp.configure(thresholdDb: s.compThresholdDb, ratio: s.compRatio, attackMs: s.compAttackMs,
                       releaseMs: s.compReleaseMs, makeupDb: s.compMakeupDb, sampleRate: 48000)
        lim.configure(ceilingDb: s.limiterCeilingDb, releaseMs: 50, sampleRate: 48000)
        var buf = [Float](repeating: 0, count: 4800)
        for i in 0..<buf.count { buf[i] = 0.3 * sinf(2 * Float.pi * 220 * Float(i) / 48000) }
        var ref = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        for i in 0..<ref.count {
            var x = ref[i]
            x = hp.process(x); x = lo.process(x); x = hi.process(x); x = comp.process(x); x = lim.process(x)
            ref[i] = x
        }
        for i in 0..<buf.count {
            XCTAssertEqual(buf[i], ref[i], accuracy: 1e-6, "clarity Off must equal the canonical chain @\(i)")
        }
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter BroadcastVoiceTests`
Expected: compile errors — `value of type 'VoiceChainSettings' has no member 'clarity'` and `value of type 'VoiceChain' has no member 'isActive'`.

- [ ] **Step 3a: Add `clarity` to `VoiceChainSettings`**

In `Sources/Core/AudioProcessing/VoiceChain.swift`, add the stored property to `VoiceChainSettings` (place it as the last `var`, after `limiterCeilingDb`):

```swift
    public var limiterCeilingDb: Float
    public var clarity: ClarityLevel = .off
```

The defaulted property keeps the synthesized memberwise initializer backward-compatible — `VoicePreset.voiceChain` and `.disabled` construct settings without naming `clarity`, so they default to `.off` and need no edits.

- [ ] **Step 3b: Add the stages and active-gating to the `VoiceChain` class**

Add the two stored stages next to the existing filters:

```swift
    private var hp = Biquad()
    private var lowShelf = Biquad()
    private var highShelf = Biquad()
    private var presence = Biquad()
    private var comp = Compressor()
    private var limiter = Limiter()
    private var deEsser = DeEsser()
    private var enabled = false
    private var clarity: ClarityLevel = .off
    private var active = false
```

Replace the whole `configure(_:)` method with:

```swift
    public func configure(_ s: VoiceChainSettings) {
        let wasActive = active
        let priorClarity = clarity
        enabled = s.enabled
        clarity = s.clarity
        active = s.enabled || s.clarity != .off
        guard active else { return }
        // Clean start when the chain becomes active (don't inherit frozen state).
        // Switching between two *active* polish settings is intentionally bumpless.
        if !wasActive {
            reset()
        } else if clarity != priorClarity {
            // Clarity changed while the chain was already active (e.g. polish stays on and
            // the user toggles Broadcast Voice Off→On, or changes level). The full reset
            // above won't fire, so reset ONLY the clarity stages — otherwise stale
            // presence/de-esser state would ring on re-enable and color the voice.
            presence.reset(); deEsser.reset()
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

        // Limiter always runs while active — it is the safety net for the presence boost.
        limiter.configure(ceilingDb: s.limiterCeilingDb, releaseMs: 50, sampleRate: sampleRate)
    }
```

Replace `reset()` to include the new stages:

```swift
    public func reset() {
        hp.reset(); lowShelf.reset(); highShelf.reset()
        presence.reset(); deEsser.reset(); comp.reset(); limiter.reset()
    }
```

Replace the `isEnabled` accessor and `process(_:count:)` with:

```swift
    public var isEnabled: Bool { enabled }
    public var isActive: Bool { active }

    /// Process `count` samples in place. No-op when inactive. Order:
    /// HP → shelves → presence → de-esser → compressor → limiter. Polish stages
    /// run only when `enabled`; clarity stages run only when `clarity != .off`;
    /// the limiter always runs while active.
    public func process(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        guard active else { return }
        let doPolish = enabled
        let doClarity = clarity != .off
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
            if doPolish {
                x = comp.process(x)
            }
            x = limiter.process(x)
            buffer[i] = x
        }
    }
```

Note: the `init()` already calls `hp.setBypass(); lowShelf.setBypass(); highShelf.setBypass()`. Add `presence.setBypass()` to that line so the presence filter starts neutral:

```swift
        hp.setBypass(); lowShelf.setBypass(); highShelf.setBypass(); presence.setBypass()
```

- [ ] **Step 4: Run the full Core test suite** (the new tests AND the existing `VoiceChainTests` — the latter is the regression guard that `clarity == .off` preserves behavior)

Run: `swift test`
Expected: all tests PASS, including the existing `testVoiceChainDisabledIsPassthrough`, `testVoiceChainEnabledChangesSignal`, `testPresetMeetingHasPolishOff`, and `testVoiceChainResetsStateOnReEnable`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/VoiceChain.swift Tests/NoNoiseMacTests/BroadcastVoiceTests.swift
git commit -m "feat(dsp): run presence + de-esser in VoiceChain, gated by ClarityLevel"
```

---

## Task 5: Wire `clarityLevel` into `AudioModel`

Expose the control as a persisted `@Published` property and inject it into the chain on top of the active preset. **No XCTest:** `AudioModel` depends on CoreAudio/AVCapture and is not unit-testable in the headless suite (the existing suite has no `AudioModel` tests for the same reason). Verification is `swift build` + the green Core suite + the manual smoke test at the end.

**Files:**
- Modify: `Sources/Core/AudioModel.swift`

- [ ] **Step 1: Add the `PrefKey`**

In the `PrefKey` enum (currently lines ~106–112), add:

```swift
    private enum PrefKey {
        static let preset = "mv.preset"
        static let strength = "mv.suppressionStrength"
        static let atten = "mv.attenuationLimitDb"
        static let gain = "mv.outputGain"
        static let voicePolish = "mv.voicePolish"
        static let clarity = "mv.clarity"
    }
```

- [ ] **Step 2: Add the `@Published` property**

Immediately after the `voicePolishEnabled` property (ends ~line 102), add:

```swift
    /// "Broadcast Voice" clarity level. Layered on top of the active preset
    /// (independent of the noise preset and of Voice Polish). Guarded like the
    /// other knobs so `loadSettings` can restore it without re-persisting mid-load.
    @Published public var clarityLevel: ClarityLevel = .off {
        didSet {
            guard !isApplyingPreset else { return }
            applyVoiceChain()
            persistSettings()
        }
    }
```

- [ ] **Step 3: Inject clarity in `applyVoiceChain()`**

Modify `applyVoiceChain()` (lines ~219–223) to set `s.clarity`:

```swift
    private func applyVoiceChain() {
        var s = selectedPreset.voiceChain
        s.enabled = s.enabled && voicePolishEnabled
        s.clarity = clarityLevel
        voiceChain.configure(s)
    }
```

- [ ] **Step 4: Persist + restore**

In `persistSettings()` (ends ~line 245) add:

```swift
        d.set(voicePolishEnabled, forKey: PrefKey.voicePolish)
        d.set(clarityLevel.rawValue, forKey: PrefKey.clarity)
```

In `loadSettings()`, restore it inside the `isApplyingPreset = true ... = false` guarded region — add the line right after the `voicePolishEnabled` restore (~line 264):

```swift
        voicePolishEnabled = d.object(forKey: PrefKey.voicePolish) as? Bool ?? true
        clarityLevel = ClarityLevel(rawValue: d.string(forKey: PrefKey.clarity) ?? "") ?? .off
        selectedPreset = preset
```

The final `applyVoiceChain()` at the end of `loadSettings()` (~line 275) picks up the restored `clarityLevel`. The first-launch `guard`-else path leaves `clarityLevel` at its default `.off`, which is correct.

- [ ] **Step 5: Build + regression test**

Run: `swift build && swift test`
Expected: build succeeds; all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/AudioModel.swift
git commit -m "feat(audio): persist + apply Broadcast Voice clarity level on top of presets"
```

---

## Task 6: Settings UI — Broadcast Voice picker

Add the control to `GeneralSettingsView.suppressionCard`, directly under the Voice Polish toggle. **No XCTest** (SwiftUI view) — verify by build + manual.

**Files:**
- Modify: `Sources/App/SettingsView.swift`

- [ ] **Step 1: Add the picker** to `suppressionCard` — insert after the `Toggle(isOn: $audioModel.voicePolishEnabled) { ... }.toggleStyle(.switch)` block and before the closing `}` of the `VStack` (i.e., after the Voice Polish toggle, still inside the card):

```swift
            .toggleStyle(.switch)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Broadcast Voice").font(.subheadline)
                Picker("", selection: $audioModel.clarityLevel) {
                    ForEach(ClarityLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text("Adds studio presence and clarity while keeping your natural voice — sibilance is tamed automatically, so “crisp” never turns harsh.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/App/SettingsView.swift
git commit -m "feat(ui): add Broadcast Voice level picker to Settings"
```

---

## Task 7: Popover UI — compact Broadcast Voice control

Add a compact picker to the menu-bar popover under the Mode card so the level is reachable without opening Settings. **No XCTest** — build + manual.

**Files:**
- Modify: `Sources/App/ContentView.swift`

- [ ] **Step 1: Add a `clarityCard`** — add this computed view after `modeCard` (after line ~110, before `devicesCard`):

```swift
    // MARK: - Broadcast Voice (clarity)

    private var clarityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardLabel("Broadcast Voice", systemImage: "waveform.path.ecg")
            Picker("", selection: $audioModel.clarityLevel) {
                ForEach(ClarityLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .nnCard()
    }
```

- [ ] **Step 2: Place it in the layout** — add `clarityCard` to `body`'s `VStack`, right after `modeCard`:

```swift
        VStack(spacing: 14) {
            header
            statusCard
            modeCard
            clarityCard
            devicesCard
            driverStatusRow
            footer
        }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/App/ContentView.swift
git commit -m "feat(ui): add compact Broadcast Voice control to menu-bar popover"
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

- [ ] **Step 1: `README.md`** — add a feature bullet under "✨ Why NoNoise Mac" (after the "🎛️ One-click modes" line):

```markdown
- **🎙️ Broadcast Voice** — a one-tap clarity lift (Off / Low / Medium / High) that adds studio presence and tames sibilance, so you sound clearer and more present while still sounding like *you*.
```

And add a short subsection after the "🧩 Modes" table:

```markdown
### 🎙️ Broadcast Voice

An optional clarity enhancement layered on top of any mode. It pairs a gentle, wide presence lift with an automatic de-esser, so added "air" never becomes harsh sibilance. **Off** by default; **Low / Medium / High** increase the effect. It is designed to be transparent — a peaking bell with unity gain at the low end and a de-esser that only acts on real "ess" sounds — so it preserves the identity of your voice.
```

- [ ] **Step 2: `CONCEPTS.md`** — append to the "Voice polish (Tier 2)" section:

```markdown
- **Clarity / Broadcast Voice** — an optional, mode-independent enhancement
  (`ClarityLevel`: off/low/medium/high) layered on the voice chain. Couples a
  **presence** lift with a **de-esser** so "crisp" never becomes harsh.
- **Presence** — a wide-Q peaking biquad (~4.5 kHz) that lifts intelligibility.
  Unity gain at DC/Nyquist, so the vocal body/identity is untouched.
- **De-esser** — a subtractive split-band sibilance controller
  (`out = x − frac·sib`). Identity at rest; only acts on loud sibilant transients.
```

- [ ] **Step 3: `AGENTS.md`** — update the architecture-map bullet for the voice chain:

Find the line describing `VoiceChain` + `Biquad` + `Dynamics` and replace it with:

```markdown
  - `AudioProcessing/VoiceChain` + `Biquad` + `Dynamics` — post-DSP "voice polish" (high-pass → shelves → compressor → limiter) plus the optional **Broadcast Voice** clarity stages (presence peaking bell → subtractive `DeEsser`), driven by `ClarityLevel` and gated independently of the noise preset.
```

Also update the authoritative **"Voice polish chain (Tier 2)"** section of `AGENTS.md` — it documents the pre-feature pipeline and is now stale. Replace its order bullet and its "Chain params…" bullet:

Find:
```markdown
- `VoiceChain` (Core/AudioProcessing) runs AFTER `DeepFilterNetDSP` on the time-domain output, inside `AudioModel`'s render callback, only when `isAIEnabled`. Order: high-pass → low-shelf → high-shelf → compressor → limiter. The Limiter is last and hard-clamps to the ceiling — it is the final overflow guard.
```
Replace with:
```markdown
- `VoiceChain` (Core/AudioProcessing) runs AFTER `DeepFilterNetDSP` on the time-domain output, inside `AudioModel`'s render callback, only when `isAIEnabled`. Order: high-pass → low-shelf → high-shelf → **presence (peaking bell) → de-esser** → compressor → limiter. The Limiter is last and hard-clamps to the ceiling — it is the final overflow guard.
```

Find:
```markdown
- Chain params are a pure function of `VoicePreset.voiceChain` (NOT persisted per-stage). Effective enabled = `voicePolishEnabled && preset.voiceChain.enabled`. Meeting = off; Podcast/Tutorial/Custom = on. Only the `mv.voicePolish` master toggle is persisted (plus the Tier 1 `mv.preset`).
```
Replace with:
```markdown
- Chain params are a pure function of `VoicePreset.voiceChain` (NOT persisted per-stage) plus the orthogonal **Broadcast Voice** `ClarityLevel`. The chain runs when `(voicePolishEnabled && preset.voiceChain.enabled) || clarity != .off`. Meeting polish = off; Podcast/Tutorial/Custom = on; Broadcast Voice (presence + de-esser) layers on any mode. Persisted: `mv.voicePolish`, `mv.clarity` (plus the Tier 1 `mv.preset`). `configure` resets ALL stage state on inactive→active, and resets ONLY the clarity stages when `clarity` changes while the chain stays active (bumpless otherwise).
```

And update the **Real-time rule** bullet of the same section — it omits the new stages and still says reset happens "ONLY on the disabled→enabled transition", which is now false:

Find:
```markdown
- **Real-time rule**: `VoiceChain.process` is allocation-free and per-sample; `configure(_:)` (coefficient recompute) runs on main only. State (`Biquad.z1/z2`, `Compressor.envDb`, `Limiter.gain`) carries across render buffers — never reset per buffer. `configure` resets state ONLY on the disabled→enabled transition (clean start); enabled→enabled preset switches are intentionally bumpless.
```
Replace with:
```markdown
- **Real-time rule**: `VoiceChain.process` is allocation-free and per-sample; `configure(_:)` (coefficient recompute) runs on main only. State (`Biquad.z1/z2` for the high-pass, shelves, and the `presence` bell; `Compressor.envDb`; `Limiter.gain`; and the `DeEsser`'s detector envelope + high-pass state) carries across render buffers — never reset per buffer. `configure` resets state in exactly two cases: a FULL reset on the inactive→active transition (clean start), and a clarity-stages-only reset (`presence` + `DeEsser`) when `ClarityLevel` changes while the chain stays active. Active→active switches with unchanged clarity are intentionally bumpless.
```

- [ ] **Step 4: `docs/knowledge/timeline1.md`** — append a dated changelog entry (match the file's existing entry format):

```markdown
## 2026-06-15 — Broadcast Voice (clarity) added

Added an Off/Low/Medium/High **Broadcast Voice** control: a wide-Q presence
peaking bell (`Biquad.setPeaking`) + a subtractive split-band `DeEsser`
(`Dynamics.swift`), wired into `VoiceChain` via `ClarityLevel` on
`VoiceChainSettings` and injected by `AudioModel.applyVoiceChain()` on top of the
active preset (persisted under `mv.clarity`). UI: segmented picker in Settings and
the popover. Design constraint — preserve the original voice — enforced
structurally: de-esser is identity below threshold; presence bell has unity DC
gain; `clarity == .off` leaves existing presets byte-for-byte unchanged.
```

- [ ] **Step 5: `docs/knowledge/knowledge1.md`** — append a `[DECISION]` entry (detect username via `git config user.name`):

```markdown
## 2026-06-15 — [DECISION] Broadcast Voice preserves voice identity by construction (@<username>)

**Problem**: A "crispiness"/clarity control naïvely implemented as a high-shelf boost amplifies sibilance, mouth noise, and residual hiss ("ice-pick" voice).
**Decision**: Implement clarity as (1) a wide-Q **peaking bell** at ~4.5 kHz with **unity gain at DC/Nyquist** (cannot alter the vocal fundamental/body) and (2) a **subtractive split-band de-esser** `out = x − frac·sib` that is a **perfect identity below threshold** and only removes a capped fraction of the sibilant band. De-ess scales with the presence lift so "crisp" is always paired with sibilance control.
**Rule**: Any future "voice enhancement" must default to a verifiable null/identity at rest and must not color the low/mid band — prove it with a unity-DC-gain test and a below-threshold identity test.
**Files**: `Sources/Core/AudioProcessing/Biquad.swift`, `Sources/Core/AudioProcessing/Dynamics.swift`, `Sources/Core/AudioProcessing/VoiceChain.swift`
```

- [ ] **Step 6: Commit**

```bash
git add README.md CONCEPTS.md AGENTS.md docs/knowledge/timeline1.md docs/knowledge/knowledge1.md
git commit -m "docs: document Broadcast Voice (clarity) feature, vocab, and decision"
```

---

## Manual smoke test (after all tasks)

The headless suite cannot exercise the live audio path. After implementation, verify in the running app:

> **Note:** Broadcast Voice (like all Voice Polish) only runs while **Noise Cancellation is ON** — the render callback calls `chain.process` inside the `if isAIEnabled` branch (`Sources/Core/AudioModel.swift:178`). Keep AI enabled for steps 3–6.

1. `./install-app.sh` (or `swift run`), open the popover.
2. Set a mode (e.g. Podcast). Speak — confirm normal cleaned voice.
3. Cycle **Broadcast Voice**: Off → Low → Medium → High. Confirm: voice gets progressively more "present/clear"; sustained "sss" sounds do **not** get harsher (de-esser engaging); the voice still sounds like *the same person* (no robotic/processed character; the low/mid body is unchanged).
4. Set Broadcast Voice = Off and confirm the sound is identical to before the feature (regression by ear).
5. Quit and relaunch — confirm the chosen level is restored (persistence).
6. Try Broadcast Voice in **Meeting** mode (polish off) — confirm it still adds clarity and never clips (limiter safety).

---

## Self-Review (completed during authoring)

- **Spec coverage:** "Broadcast Voice" name → Tasks 6/7 UI + README. Off/Low/Medium/High → `ClarityLevel` (Task 3), exposed in both UIs. "Must feel like original" → subtractive de-esser identity (Task 2), unity-DC presence bell (Task 1), `clarity==.off` no-op (Task 4), explicit identity/regression tests + manual step 4. Persistence → Task 5.
- **Placeholder scan:** none — every code step shows complete code and exact commands.
- **Type consistency:** `ClarityLevel` (with `presenceDb`, `deEssMaxReductionDb`, `label`, `allCases`, `id`), `ClarityProfile` constants, `DeEsser.configure(crossoverHz:thresholdDb:maxReductionDb:attackMs:releaseMs:sampleRate:enabled:)`, `Biquad.setPeaking(freq:gainDb:sampleRate:q:)`, `VoiceChainSettings.clarity`, `VoiceChain.isActive`, and `AudioModel.clarityLevel` are used consistently across tasks.

---

## Post-Implementation Amendments

Recorded after the implementation passed Codex 5.5 code review (approved, Round 2). These document where the plan-as-written diverged from what shipped, so the plan stays a faithful learning artifact.

1. **De-esser loud-sibilance probe moved 7.5 kHz → 10 kHz (Task 2).**
   - *Root cause (plan gap):* the plan's Task 2 test asserted ≥15% subtractive reduction on a 7.5 kHz tone with a 6 kHz crossover. For a subtractive de-esser (`out = x − frac·sib`), the high-pass imposes ~70° phase shift just above its corner, which mathematically caps cancellation near ~6% there regardless of `maxReductionDb` — the assertion was unsatisfiable by construction.
   - *Fix:* kept the `DeEsser` implementation and all `ClarityProfile` tuning byte-for-byte; moved only the probe to 10 kHz (a frequency the de-esser genuinely tames), preserving the strong `≤0.85` assertion. Audio behavior is unchanged from the plan. (Maintainer-approved, Option A.)

2. **Added `testPeakingHasUnityNyquistGain` (Task 1).**
   - *Root cause (plan gap):* the design notes claimed the presence bell has "`|H(Nyquist)| = 1` ... proven in Task 1's test", but Task 1's enumerated tests only proved DC, center-boost, and low-end — the Nyquist proof was promised but never specified.
   - *Fix:* added a tests-only Nyquist-unity proof driving the real `Biquad.process` path with an alternating `(-1)^n` probe (a `sinf` Nyquist tone is identically zero). Task 1's test block and pass count were synced. No production code changed.
