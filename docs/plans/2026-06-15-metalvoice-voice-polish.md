# MetalVoice Voice Polish (Tier 2) — Implementation Plan

**Goal:** Add a post-DeepFilterNet **voice-polish chain** — High-pass → Tone EQ (low/high shelves) → Compressor → Limiter — so cleaned speech sounds full, even, and broadcast-ready for podcasts and tutorials. The chain is **preset-driven** (Meeting = neutral/off, Podcast = warm, Tutorial = present + loud-safe, Custom = balanced) with a single master **Voice Polish** on/off toggle so it stays "just works" for a non-technical user.

**Architecture:** A standalone, allocation-free `VoiceChain` time-domain processor (Core/AudioProcessing) built from reusable `Biquad` filters plus a feed-forward `Compressor` and a peak `Limiter`. It runs on the output samples in `AudioModel`'s render callback, immediately after `dsp.process(...)`, only when AI is enabled and the chain is enabled. Chain parameters are a pure function of the selected `VoicePreset` (no new per-stage persistence); only the master toggle is persisted. All DSP math lives in pure, unit-testable types (no CoreML dependency).

**Tech Stack:** Swift 5.9, SwiftUI, Swift Package Manager, XCTest, Accelerate (scalar math; biquads are per-sample).

**Execution location:** All edits and commits go inside `/Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src/`.

---

## Context

Tier 1 added suppression presets + two intensity knobs. DeepFilterNet removes noise but does not shape the voice. Podcasts/tutorials benefit from a standard "voice chain":

1. **High-pass** (~80–90 Hz) — removes rumble, AC hum, desk thumps, plosive energy.
2. **Tone EQ** — low-shelf for warmth, high-shelf for presence/air (RBJ shelving biquads).
3. **Compressor** — evens out loud/soft so the level stays consistent.
4. **Limiter** — a ceiling so makeup gain / loud peaks never clip.

### Current code facts (verified against the repo)
- The render callback (`AudioModel.swift:75-114`) reads from the ring buffer into `data` (`count` Float samples @ 48 kHz), then `if self.isAIEnabled { dsp.process(input: data, count: count, output: data) }`. It captures `let bufferRef = ringBuffer` and `let dsp = dspEngine` as locals (`AudioModel.swift:72-73`). This closure runs on the audio render thread — **no heap allocations allowed**.
- `DeepFilterNetDSP.outputGain` is applied inside the DSP ISTFT. The voice chain runs AFTER the DSP, so the Limiter (last stage) protects against any peaks the chain or output gain introduce.
- Tier 1 established the knob/persistence patterns in `AudioModel`: `@Published` + `didSet`, `isApplyingPreset` guard, `applyPreset`, `onKnobChanged`, `persistSettings`, `loadSettings`, and a `PrefKey` enum. `selectedPreset` is already persisted under `mv.preset`.
- `VoicePreset` (Core) maps a preset to `parameters` (suppression). This plan adds a parallel `voiceChain` mapping.
- `AGENTS.md` documents the no-alloc render-thread rule and the "knobs are plain `var`, written from main, read on render thread" pattern. The voice chain follows the same discipline.

### Design decisions
- **Preset-driven, one toggle.** The non-technical ICP gets good sound automatically per mode. The only new control is a master **Voice Polish** toggle (default ON). Per-stage editing is intentionally deferred to a future Tier 3.
- **Effective enabled = `voicePolishEnabled && preset.voiceChain.enabled`.** Meeting keeps polish off (neutral calls); Podcast/Tutorial/Custom enable it. Custom keeps a balanced default chain so tuning suppression doesn't silently kill the voice tone.
- **No new per-stage persistence.** Chain params derive from `selectedPreset` (already persisted) + the one new `mv.voicePolish` bool.
- **Real-time safety:** `VoiceChain` pre-allocates nothing per-call (filter/compressor/limiter state are scalars). `configure(_:)` recomputes coefficients on the **main** thread (on preset/toggle change); the render thread only reads coefficients and runs scalar math. A coefficient read torn by a concurrent `configure` can at worst cause one brief, inaudible transient at the moment of a preset switch — acceptable and consistent with the existing `outputGain` pattern. The chain no-ops (passthrough) when disabled via an `isEnabled` flag checked first in `process`.
- **Standard, citable math:** biquads use the RBJ Audio EQ Cookbook formulas; the compressor is a log-domain feed-forward design; the limiter is a fast peak limiter with a final hard clamp to guarantee the ceiling.
- **Tuning values are starting points** (documented), tunable after listening.

| Preset | polish | HP | low-shelf | high-shelf | comp (thr/ratio/atk/rel/makeup) | ceiling |
|---|---|---|---|---|---|---|
| Meeting | off | — | — | — | — | — |
| Podcast | on | 80 Hz | +2 dB @180 Hz | +1.5 dB @9 kHz | −20/2.5/12 ms/150 ms/+3 | −1.0 dB |
| Tutorial | on | 90 Hz | 0 | +3 dB @6 kHz | −18/3.0/8 ms/120 ms/+4 | −0.5 dB |
| Custom | on | 80 Hz | +1.5 dB @180 Hz | +2 dB @8 kHz | −18/2.5/12 ms/150 ms/+3 | −1.0 dB |

---

## Task 1: `Biquad` filter — TDD

A reusable Transposed-Direct-Form-II biquad with RBJ factory methods for high-pass, low-shelf, high-shelf.

**Files:**
- Create: `MetalVoice-src/Sources/Core/AudioProcessing/Biquad.swift`
- Modify: `MetalVoice-src/Tests/MetalVoiceTests/VoiceChainTests.swift` (created here)

**Step 1: Add `.testTarget`-visible test file + create `Biquad`**

`Sources/Core/AudioProcessing/Biquad.swift`:

```swift
import Foundation

/// A normalized biquad (Transposed Direct Form II). Coefficients are computed
/// via the RBJ Audio EQ Cookbook. `process` is per-sample and allocation-free;
/// state is two scalars carried across calls.
public struct Biquad {
    // Normalized coefficients (a0 == 1).
    private var b0: Float = 1, b1: Float = 0, b2: Float = 0
    private var a1: Float = 0, a2: Float = 0
    // State.
    private var z1: Float = 0, z2: Float = 0

    public init() {}

    /// Identity (passthrough) coefficients.
    public mutating func setBypass() {
        b0 = 1; b1 = 0; b2 = 0; a1 = 0; a2 = 0
    }

    public mutating func setHighPass(freq: Float, sampleRate: Float, q: Float = 0.707) {
        let w0 = 2 * Float.pi * max(freq, 1) / sampleRate
        let cs = cosf(w0), sn = sinf(w0)
        let alpha = sn / (2 * q)
        let a0 = 1 + alpha
        b0 = (1 + cs) / 2 / a0
        b1 = -(1 + cs) / a0
        b2 = (1 + cs) / 2 / a0
        a1 = (-2 * cs) / a0
        a2 = (1 - alpha) / a0
    }

    public mutating func setLowShelf(freq: Float, gainDb: Float, sampleRate: Float) {
        setShelf(freq: freq, gainDb: gainDb, sampleRate: sampleRate, low: true)
    }

    public mutating func setHighShelf(freq: Float, gainDb: Float, sampleRate: Float) {
        setShelf(freq: freq, gainDb: gainDb, sampleRate: sampleRate, low: false)
    }

    private mutating func setShelf(freq: Float, gainDb: Float, sampleRate: Float, low: Bool) {
        let A = powf(10, gainDb / 40)
        let w0 = 2 * Float.pi * max(freq, 1) / sampleRate
        let cs = cosf(w0), sn = sinf(w0)
        let alpha = sn / 2 * sqrtf((A + 1 / A) * (1 / 1.0 - 1) + 2)  // S = 1
        let twoSqrtAalpha = 2 * sqrtf(A) * alpha
        var nb0: Float, nb1: Float, nb2: Float, na0: Float, na1: Float, na2: Float
        if low {
            nb0 = A * ((A + 1) - (A - 1) * cs + twoSqrtAalpha)
            nb1 = 2 * A * ((A - 1) - (A + 1) * cs)
            nb2 = A * ((A + 1) - (A - 1) * cs - twoSqrtAalpha)
            na0 = (A + 1) + (A - 1) * cs + twoSqrtAalpha
            na1 = -2 * ((A - 1) + (A + 1) * cs)
            na2 = (A + 1) + (A - 1) * cs - twoSqrtAalpha
        } else {
            nb0 = A * ((A + 1) + (A - 1) * cs + twoSqrtAalpha)
            nb1 = -2 * A * ((A - 1) + (A + 1) * cs)
            nb2 = A * ((A + 1) + (A - 1) * cs - twoSqrtAalpha)
            na0 = (A + 1) - (A - 1) * cs + twoSqrtAalpha
            na1 = 2 * ((A - 1) - (A + 1) * cs)
            na2 = (A + 1) - (A - 1) * cs - twoSqrtAalpha
        }
        b0 = nb0 / na0; b1 = nb1 / na0; b2 = nb2 / na0
        a1 = na1 / na0; a2 = na2 / na0
    }

    public mutating func reset() { z1 = 0; z2 = 0 }

    /// DC gain |H(1)| = (b0+b1+b2)/(1+a1+a2). Used by tests.
    public var dcGain: Float { (b0 + b1 + b2) / (1 + a1 + a2) }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}
```

**Step 2: Tests** — `Tests/MetalVoiceTests/VoiceChainTests.swift`:

```swift
import XCTest
@testable import Core

final class VoiceChainTests: XCTestCase {
    func testHighPassRemovesDC() {
        var hp = Biquad()
        hp.setHighPass(freq: 80, sampleRate: 48000)
        var y: Float = 0
        for _ in 0..<2000 { y = hp.process(1.0) }   // constant DC input
        XCTAssertEqual(y, 0, accuracy: 1e-3, "high-pass must reject DC")
    }

    func testLowShelfDCGainMatchesDb() {
        var sh = Biquad()
        sh.setLowShelf(freq: 200, gainDb: 6, sampleRate: 48000)
        // Low-shelf DC gain (linear) == 10^(dB/20).
        XCTAssertEqual(sh.dcGain, powf(10, 6.0 / 20.0), accuracy: 1e-3)
    }

    func testBypassIsIdentity() {
        var b = Biquad()
        b.setBypass()
        XCTAssertEqual(b.process(0.42), 0.42, accuracy: 1e-6)
    }

    func testHighPassStableImpulse() {
        var hp = Biquad()
        hp.setHighPass(freq: 90, sampleRate: 48000)
        var last: Float = 0
        _ = hp.process(1.0)
        for _ in 0..<5000 { last = hp.process(0) }
        XCTAssertEqual(last, 0, accuracy: 1e-4, "impulse response must decay (stable)")
    }
}
```

**Step 3: Build + test**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift build && swift test --filter VoiceChainTests
```

Expected: clean build, 4 tests pass.

**Step 4: Commit**

```bash
git add Sources/Core/AudioProcessing/Biquad.swift Tests/MetalVoiceTests/VoiceChainTests.swift
git commit -m "feat(dsp): add RBJ Biquad (high-pass, low/high shelf)"
```

---

## Task 2: `Compressor` + `Limiter` — TDD

**Files:**
- Create: `MetalVoice-src/Sources/Core/AudioProcessing/Dynamics.swift`
- Modify: `MetalVoice-src/Tests/MetalVoiceTests/VoiceChainTests.swift`

**Step 1: Create `Dynamics.swift`**

```swift
import Foundation

/// Feed-forward log-domain compressor. Per-sample, allocation-free.
public struct Compressor {
    private var thresholdDb: Float = 0
    private var ratio: Float = 1
    private var makeupDb: Float = 0
    private var attackCoeff: Float = 0
    private var releaseCoeff: Float = 0
    private var envDb: Float = 0          // smoothed gain-reduction (dB, >= 0)

    public init() {}

    public mutating func configure(thresholdDb: Float, ratio: Float, attackMs: Float,
                                   releaseMs: Float, makeupDb: Float, sampleRate: Float) {
        self.thresholdDb = thresholdDb
        self.ratio = max(ratio, 1)
        self.makeupDb = makeupDb
        attackCoeff = expf(-1.0 / (max(attackMs, 0.01) * 0.001 * sampleRate))
        releaseCoeff = expf(-1.0 / (max(releaseMs, 0.01) * 0.001 * sampleRate))
    }

    public mutating func reset() { envDb = 0 }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let mag = abs(x)
        let xDb = 20 * log10f(max(mag, 1e-9))
        let overDb = xDb - thresholdDb
        let targetGrDb = overDb > 0 ? overDb * (1 - 1 / ratio) : 0   // desired gain reduction (dB)
        // One-pole smoothing: attack when increasing reduction, release when decreasing.
        let coeff = targetGrDb > envDb ? attackCoeff : releaseCoeff
        envDb = coeff * envDb + (1 - coeff) * targetGrDb
        let gain = powf(10, (makeupDb - envDb) / 20)
        return x * gain
    }
}

/// Fast peak limiter with a final hard clamp that guarantees the ceiling.
public struct Limiter {
    private var ceilingLin: Float = 1
    private var releaseCoeff: Float = 0
    private var gain: Float = 1

    public init() {}

    public mutating func configure(ceilingDb: Float, releaseMs: Float, sampleRate: Float) {
        ceilingLin = powf(10, ceilingDb / 20)
        releaseCoeff = expf(-1.0 / (max(releaseMs, 0.01) * 0.001 * sampleRate))
    }

    public mutating func reset() { gain = 1 }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        let mag = abs(x)
        let desired: Float = mag > ceilingLin ? ceilingLin / mag : 1
        if desired < gain { gain = desired }                       // instant attack
        else { gain = releaseCoeff * gain + (1 - releaseCoeff) * 1 } // release toward unity
        let y = x * gain
        return max(-ceilingLin, min(ceilingLin, y))                 // safety clamp == hard ceiling
    }
}
```

**Step 2: Tests** — append to `VoiceChainTests`:

```swift
    func testCompressorReducesLoudSteadyState() {
        var c = Compressor()
        // thr -18 dB, ratio 4, fast envelope, no makeup.
        c.configure(thresholdDb: -18, ratio: 4, attackMs: 1, releaseMs: 1, makeupDb: 0, sampleRate: 48000)
        let x: Float = 0.5            // ~ -6 dBFS, 12 dB over threshold
        var y: Float = 0
        for _ in 0..<48000 { y = c.process(x) }   // settle 1 s
        // Expected output ≈ thr + over/ratio = -18 + 12/4 = -15 dB → 10^(-15/20) ≈ 0.1778
        XCTAssertEqual(abs(y), powf(10, -15.0 / 20.0), accuracy: 0.02)
    }

    func testCompressorLeavesQuietBelowThreshold() {
        var c = Compressor()
        c.configure(thresholdDb: -18, ratio: 4, attackMs: 1, releaseMs: 50, makeupDb: 0, sampleRate: 48000)
        let x: Float = 0.01           // -40 dBFS, below threshold
        var y: Float = 0
        for _ in 0..<4800 { y = c.process(x) }
        XCTAssertEqual(abs(y), 0.01, accuracy: 1e-3, "below-threshold signal must pass ~unchanged")
    }

    func testLimiterNeverExceedsCeiling() {
        var l = Limiter()
        l.configure(ceilingDb: -1, releaseMs: 50, sampleRate: 48000)
        let ceiling = powf(10, -1.0 / 20.0)
        var maxOut: Float = 0
        for n in 0..<48000 {
            let x = 1.5 * sinf(2 * Float.pi * 1000 * Float(n) / 48000)  // peaks at 1.5 (over ceiling)
            maxOut = max(maxOut, abs(l.process(x)))
        }
        XCTAssertLessThanOrEqual(maxOut, ceiling + 1e-4, "limiter output must never exceed the ceiling")
    }
```

**Step 3: Build + test**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift build && swift test --filter VoiceChainTests
```

Expected: clean build, 7 tests pass.

**Step 4: Commit**

```bash
git add Sources/Core/AudioProcessing/Dynamics.swift Tests/MetalVoiceTests/VoiceChainTests.swift
git commit -m "feat(dsp): add Compressor + peak Limiter dynamics"
```

---

## Task 3: `VoiceChainSettings` + `VoiceChain` assembly + preset mapping — TDD

**Files:**
- Create: `MetalVoice-src/Sources/Core/AudioProcessing/VoiceChain.swift`
- Modify: `MetalVoice-src/Sources/Core/VoicePreset.swift`
- Modify: `MetalVoice-src/Tests/MetalVoiceTests/VoiceChainTests.swift`

**Step 1: Create `VoiceChainSettings` + `VoiceChain`**

`Sources/Core/AudioProcessing/VoiceChain.swift`:

```swift
import Foundation

public struct VoiceChainSettings: Sendable, Equatable {
    public var enabled: Bool
    public var highPassHz: Float
    public var lowShelfHz: Float
    public var lowShelfDb: Float
    public var highShelfHz: Float
    public var highShelfDb: Float
    public var compThresholdDb: Float
    public var compRatio: Float
    public var compAttackMs: Float
    public var compReleaseMs: Float
    public var compMakeupDb: Float
    public var limiterCeilingDb: Float

    public static let disabled = VoiceChainSettings(
        enabled: false, highPassHz: 80, lowShelfHz: 180, lowShelfDb: 0,
        highShelfHz: 8000, highShelfDb: 0, compThresholdDb: 0, compRatio: 1,
        compAttackMs: 10, compReleaseMs: 120, compMakeupDb: 0, limiterCeilingDb: -1)
}

/// Time-domain voice-shaping chain: high-pass → low-shelf → high-shelf →
/// compressor → limiter. Per-sample, allocation-free. `configure` runs on main;
/// `process` runs on the render thread and no-ops when disabled.
public final class VoiceChain {
    private let sampleRate: Float
    private var hp = Biquad()
    private var lowShelf = Biquad()
    private var highShelf = Biquad()
    private var comp = Compressor()
    private var limiter = Limiter()
    private var enabled = false

    public init(sampleRate: Float = 48000) {
        self.sampleRate = sampleRate
        hp.setBypass(); lowShelf.setBypass(); highShelf.setBypass()
    }

    public func configure(_ s: VoiceChainSettings) {
        let wasEnabled = enabled
        enabled = s.enabled
        guard s.enabled else { return }
        // Clean start when polish turns ON (don't inherit frozen state from a
        // long-disabled period). Switching between two *enabled* presets is
        // intentionally bumpless — keeping z-state/envelopes avoids a click.
        if !wasEnabled { reset() }
        hp.setHighPass(freq: s.highPassHz, sampleRate: sampleRate)
        lowShelf.setLowShelf(freq: s.lowShelfHz, gainDb: s.lowShelfDb, sampleRate: sampleRate)
        highShelf.setHighShelf(freq: s.highShelfHz, gainDb: s.highShelfDb, sampleRate: sampleRate)
        comp.configure(thresholdDb: s.compThresholdDb, ratio: s.compRatio,
                       attackMs: s.compAttackMs, releaseMs: s.compReleaseMs,
                       makeupDb: s.compMakeupDb, sampleRate: sampleRate)
        limiter.configure(ceilingDb: s.limiterCeilingDb, releaseMs: 50, sampleRate: sampleRate)
    }

    /// Clear all filter/dynamics state. Called on the disabled→enabled
    /// transition (and available for engine restart). Never called per buffer.
    public func reset() {
        hp.reset(); lowShelf.reset(); highShelf.reset(); comp.reset(); limiter.reset()
    }

    public var isEnabled: Bool { enabled }

    /// Process `count` samples in place. No-op when disabled.
    public func process(_ buffer: UnsafeMutablePointer<Float>, count: Int) {
        guard enabled else { return }
        for i in 0..<count {
            var x = buffer[i]
            x = hp.process(x)
            x = lowShelf.process(x)
            x = highShelf.process(x)
            x = comp.process(x)
            x = limiter.process(x)
            buffer[i] = x
        }
    }
}
```

**Step 2: Add `voiceChain` mapping to `VoicePreset`** — append to `VoicePreset`:

```swift
    /// Voice-polish chain settings for this preset (independent of `parameters`).
    /// Values are tunable starting points.
    public var voiceChain: VoiceChainSettings {
        switch self {
        case .meeting:
            return .disabled
        case .podcast:
            return VoiceChainSettings(enabled: true, highPassHz: 80, lowShelfHz: 180, lowShelfDb: 2,
                                      highShelfHz: 9000, highShelfDb: 1.5, compThresholdDb: -20, compRatio: 2.5,
                                      compAttackMs: 12, compReleaseMs: 150, compMakeupDb: 3, limiterCeilingDb: -1)
        case .tutorial:
            return VoiceChainSettings(enabled: true, highPassHz: 90, lowShelfHz: 180, lowShelfDb: 0,
                                      highShelfHz: 6000, highShelfDb: 3, compThresholdDb: -18, compRatio: 3,
                                      compAttackMs: 8, compReleaseMs: 120, compMakeupDb: 4, limiterCeilingDb: -0.5)
        case .custom:
            return VoiceChainSettings(enabled: true, highPassHz: 80, lowShelfHz: 180, lowShelfDb: 1.5,
                                      highShelfHz: 8000, highShelfDb: 2, compThresholdDb: -18, compRatio: 2.5,
                                      compAttackMs: 12, compReleaseMs: 150, compMakeupDb: 3, limiterCeilingDb: -1)
        }
    }
```

**Step 3: Tests** — append to `VoiceChainTests`:

```swift
    func testVoiceChainDisabledIsPassthrough() {
        let chain = VoiceChain()
        chain.configure(.disabled)
        var buf: [Float] = [0.1, -0.2, 0.3, -0.4]
        let copy = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        XCTAssertEqual(buf, copy, "disabled chain must not modify samples")
    }

    func testVoiceChainEnabledChangesSignal() {
        let chain = VoiceChain()
        chain.configure(VoicePreset.podcast.voiceChain)
        XCTAssertTrue(chain.isEnabled)
        var buf = [Float](repeating: 0.5, count: 4800)
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        XCTAssertFalse(buf.allSatisfy { $0 == 0.5 }, "enabled chain must shape the signal")
        XCTAssertTrue(buf.allSatisfy { abs($0) <= powf(10, -1.0/20.0) + 1e-3 }, "output within ceiling")
    }

    func testPresetMeetingHasPolishOff() {
        XCTAssertFalse(VoicePreset.meeting.voiceChain.enabled)
    }

    func testPresetPodcastAndTutorialHavePolishOn() {
        XCTAssertTrue(VoicePreset.podcast.voiceChain.enabled)
        XCTAssertTrue(VoicePreset.tutorial.voiceChain.enabled)
    }

    func testVoiceChainResetsStateOnReEnable() {
        let chain = VoiceChain()
        chain.configure(VoicePreset.podcast.voiceChain)
        // Drive a loud burst so the high-pass z-state is energized.
        var loud = [Float](repeating: 0.9, count: 4800)
        loud.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        chain.configure(.disabled)                       // polish OFF (state frozen)
        chain.configure(VoicePreset.podcast.voiceChain)  // back ON → reset() runs
        // Silence in must yield silence out: stale ringing would leak otherwise.
        var quiet = [Float](repeating: 0.0, count: 64)
        quiet.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        XCTAssertTrue(quiet.allSatisfy { abs($0) < 1e-3 }, "re-enable must start from clean state")
    }
```

**Step 4: Build + test**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift build && swift test
```

Expected: clean build, all tests pass (18 from Tier 1 + 12 voice-chain = 30).

**Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/VoiceChain.swift Sources/Core/VoicePreset.swift Tests/MetalVoiceTests/VoiceChainTests.swift
git commit -m "feat(dsp): assemble VoiceChain + per-preset voice profiles"
```

---

## Task 4: Wire `VoiceChain` into `AudioModel` (render call + master toggle + persistence)

**Files:**
- Modify: `MetalVoice-src/Sources/Core/AudioModel.swift`

**Step 1: Add the chain instance, master toggle, and pref key**

Near `private let dspEngine = DeepFilterNetDSP()` (`AudioModel.swift:67`):

```swift
    private let voiceChain = VoiceChain()
```

Add the published toggle next to the Tier 1 knobs (after `attenuationLimitDb`):

```swift
    @Published public var voicePolishEnabled: Bool = true {
        didSet {
            guard !isApplyingPreset else { return }   // skip during loadSettings
            applyVoiceChain()
            persistSettings()
        }
    }
```

Add a pref key to `PrefKey`:

```swift
        static let voicePolish = "mv.voicePolish"
```

**Step 2: Capture the chain in the render closure and call it after the DSP**

In `init()`, alongside `let dsp = dspEngine` (`AudioModel.swift:73`), add:

```swift
        let chain = voiceChain
```

In the render closure, change the AI block (`AudioModel.swift:108-111`):

```swift
            if let self = self, self.isAIEnabled {
                // DSP STFT Pipeline
                dsp.process(input: data, count: count, output: data)
            }
```

to:

```swift
            if let self = self, self.isAIEnabled {
                // DSP STFT Pipeline, then voice-polish chain (no-op when disabled).
                dsp.process(input: data, count: count, output: data)
                chain.process(data, count: count)
            }
```

**Step 3: Add `applyVoiceChain()` and call it on every preset transition + load**

Add the method (next to `applyPreset`):

```swift
    /// Configure the voice chain from the active preset, gated by the master
    /// toggle. Runs on the main thread (recomputes filter coefficients).
    private func applyVoiceChain() {
        var s = selectedPreset.voiceChain
        s.enabled = s.enabled && voicePolishEnabled
        voiceChain.configure(s)
    }
```

Call it from `selectedPreset.didSet` (explicit selection) — after `applyPreset(selectedPreset)`:

```swift
    @Published public var selectedPreset: VoicePreset = .meeting {
        didSet {
            guard !isApplyingPreset else { return }
            applyPreset(selectedPreset)   // no-op for .custom (keeps current knobs)
            applyVoiceChain()             // reconfigure voice chain for the new preset
            persistSettings()
        }
    }
```

Call it once on the auto-flip to Custom inside `onKnobChanged()` (runs only on the transition, since after the flip `selectedPreset == .custom`):

```swift
    private func onKnobChanged() {
        guard !isApplyingPreset else { return }
        if selectedPreset != .custom {
            isApplyingPreset = true
            selectedPreset = .custom
            isApplyingPreset = false
            applyVoiceChain()   // Custom has its own balanced chain; configure once on transition
        }
        persistSettings()
    }
```

**Step 4: Persist + load the toggle**

In `persistSettings()`, add:

```swift
        d.set(voicePolishEnabled, forKey: PrefKey.voicePolish)
```

In `loadSettings()`, load the toggle BEFORE configuring the chain, and call `applyVoiceChain()` at the end of BOTH branches:

- First-launch branch (no persisted preset):

```swift
        guard let raw = d.string(forKey: PrefKey.preset),
              let preset = VoicePreset(rawValue: raw) else {
            // First launch: keep defaults (Meeting) and push them to the DSP.
            applyPreset(.meeting)
            applyVoiceChain()
            return
        }
```

- Restored branch — set the toggle (default true when absent) **inside** the existing `isApplyingPreset = true ... = false` guarded block, so its `didSet` is skipped during load:

```swift
        voicePolishEnabled = d.object(forKey: PrefKey.voicePolish) as? Bool ?? true
```

and after the guarded block (and after the non-custom knob override) add the single explicit configure:

```swift
        applyVoiceChain()
```

> **Note:** `voicePolishEnabled.didSet` is now guarded by `!isApplyingPreset`, identical to the Tier 1 knob pattern. During `loadSettings` the assignment is wrapped by `isApplyingPreset = true/false`, so it neither persists nor reconfigures mid-load. The single explicit `applyVoiceChain()` at the end deterministically configures the chain from the final restored `selectedPreset` + `voicePolishEnabled`. No spurious `UserDefaults` write occurs during load.

**Step 5: Document the contract in `AGENTS.md`** (docs land with the behavior they describe)

Add a "Voice polish chain" section to `MetalVoice-src/AGENTS.md`:

```markdown
## Voice polish chain (Tier 2)
- `VoiceChain` (Core/AudioProcessing) runs AFTER `DeepFilterNetDSP` on the time-domain output, inside `AudioModel`'s render callback, only when `isAIEnabled`. Order: high-pass → low-shelf → high-shelf → compressor → limiter. The Limiter is last and hard-clamps to the ceiling — it is the final overflow guard.
- Built from pure, unit-tested value types: `Biquad` (RBJ cookbook coefficients, TDF-II), `Compressor` (log-domain feed-forward), `Limiter` (fast peak + hard clamp). Keep all DSP math here, testable, with no CoreML dependency.
- **Real-time rule**: `VoiceChain.process` is allocation-free and per-sample; `configure(_:)` (coefficient recompute) runs on main only. State (`Biquad.z1/z2`, `Compressor.envDb`, `Limiter.gain`) carries across render buffers — never reset per buffer. `configure` resets state only on the disabled→enabled transition (clean start); enabled→enabled preset switches are bumpless.
- Chain params are a pure function of `VoicePreset.voiceChain` (NOT persisted per-stage). Effective enabled = `voicePolishEnabled && preset.voiceChain.enabled`. Meeting = off; Podcast/Tutorial/Custom = on. Only the `mv.voicePolish` master toggle is persisted (plus the Tier 1 `mv.preset`).
- `applyVoiceChain()` reconfigures the chain on every preset transition (explicit pick AND the auto-flip to Custom) and on toggle/load — never from the per-tick knob path more than once per transition. `voicePolishEnabled.didSet` is guarded by `!isApplyingPreset` like the Tier 1 knobs.
```

**Step 6: Build + test**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift build && swift test
```

Expected: clean build, all tests pass.

**Step 7: Commit** (behavior + its contract docs together)

```bash
git add Sources/Core/AudioModel.swift AGENTS.md
git commit -m "feat(core): run VoiceChain after DSP; master toggle + persistence"
```

---

## Task 5: "Voice Polish" toggle in Settings

**Files:**
- Modify: `MetalVoice-src/Sources/App/SettingsView.swift`

**Step 1: Add a toggle row** inside the existing "Suppression Section" card, after the Reduction Limit caption (so all enhancement controls live together):

```swift
                Divider()

                Toggle(isOn: $audioModel.voicePolishEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Voice Polish")
                            .font(.subheadline)
                        Text("Tone + leveling for podcasts & tutorials. Off in Meeting mode.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
```

**Step 2: Update `README.md`** (user-facing doc lands with the user-facing control) — extend the Modes line (Usage step 6) to mention tone/leveling:

```markdown
    *   Each Mode also applies **Voice Polish** (tone + leveling): Podcast is warm, Tutorial is bright and loud. Turn it off in Settings for a raw, uncolored sound (it is always off in Meeting mode).
```

**Step 3: Build**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift build
```

Expected: clean build.

**Step 4: Commit** (UI + its user-facing docs together)

```bash
git add Sources/App/SettingsView.swift README.md
git commit -m "feat(ui): add Voice Polish toggle to Settings"
```

---

## Task 6: Build, bundle, install, smoke test

**Files:** none (build/release only)

**Step 1: Guard + full test + release build**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
git status --short Resources/DeepFilterNet3_Streaming.mlmodelc   # expect empty
swift test && swift build -c release
```

**Step 2: Bundle, reinstall in place, re-sign, verify** (App Management TCC requires in-place sync):

```bash
osascript -e 'quit app "MetalVoice"' 2>/dev/null; sleep 1
./bundle.sh
rsync -a --delete MetalVoice.app/ /Applications/MetalVoice.app/
codesign --force --deep --sign - --entitlements Resources/MetalVoice.entitlements /Applications/MetalVoice.app
shasum -a 256 MetalVoice.app/Contents/MacOS/MetalVoice /Applications/MetalVoice.app/Contents/MacOS/MetalVoice
codesign --verify --deep --strict /Applications/MetalVoice.app && echo "signature OK"
```

Expected: hashes match; `signature OK`.

**Step 3: Manual smoke test (user)**
1. AI ON, **Meeting** → no tonal coloring (polish off) — same as Tier 1.
2. **Podcast** → fuller/warmer, level more consistent; **Tutorial** → brighter/present, louder, no clipping on peaks.
3. **Settings → Voice Polish OFF** while on Podcast → reverts to plain DFN tone; ON again restores it.
4. Loud/plosive test ("P" pops, table bumps) → reduced low-end thump (high-pass).
5. Quit + relaunch → preset and Voice Polish state persist.

---

## Done criteria

- [ ] `Biquad`, `Compressor`, `Limiter`, `VoiceChain` implemented as pure, allocation-free, unit-tested types.
- [ ] Chain runs after the DSP in the render callback, only when AI + chain enabled; no-op (passthrough) otherwise.
- [ ] Per-preset profiles (Meeting off, Podcast warm, Tutorial present, Custom balanced) + master Voice Polish toggle.
- [ ] Limiter guarantees output never exceeds the ceiling (test-proven).
- [ ] `mv.voicePolish` persists; chain params derive from the persisted preset; state restored on relaunch.
- [ ] `swift test` passes (30 tests: 18 Tier 1 + 12 voice chain). `swift build -c release` clean. Model file untouched.
- [ ] App reinstalled in place; hashes match; signature OK. `AGENTS.md` (Task 4 commit) + `README.md` (Task 5 commit) updated alongside the behavior they document.

### Test Inventory (Tier 2 additions)
| Task | Test | Asserts |
|---|---|---|
| 1 | `testHighPassRemovesDC` | high-pass rejects DC |
| 1 | `testLowShelfDCGainMatchesDb` | low-shelf DC gain == 10^(dB/20) |
| 1 | `testBypassIsIdentity` | bypass passes samples through |
| 1 | `testHighPassStableImpulse` | impulse response decays (stable) |
| 2 | `testCompressorReducesLoudSteadyState` | steady-state gain reduction matches threshold/ratio |
| 2 | `testCompressorLeavesQuietBelowThreshold` | below-threshold passes ~unchanged |
| 2 | `testLimiterNeverExceedsCeiling` | output bounded by ceiling |
| 3 | `testVoiceChainDisabledIsPassthrough` | disabled chain = identity |
| 3 | `testVoiceChainEnabledChangesSignal` | enabled chain shapes signal + within ceiling |
| 3 | `testPresetMeetingHasPolishOff` | Meeting polish off |
| 3 | `testPresetPodcastAndTutorialHavePolishOn` | Podcast + Tutorial polish on |
| 3 | `testVoiceChainResetsStateOnReEnable` | disabled→enabled clears stale state |
