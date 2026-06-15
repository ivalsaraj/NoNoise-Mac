import XCTest
@testable import Core

// MARK: - Realistic test signals

private let sr: Float = 48000

/// Harmonic-rich voiced vowel: sum of harmonics up to 7 kHz with a `1/h^tilt` spectral
/// rolloff, peak-normalized to `amp`. Unlike a pure sine, this has the broadband content of
/// real voicing — the de-plosive's concentration gate and the de-click's peak/background ratio
/// must both read it as voiced (NOT a transient artifact).
private func vowel(f0: Float, count: Int, amp: Float, tilt: Float = 1.3) -> [Float] {
    var out = [Float](repeating: 0, count: count)
    for i in 0..<count {
        let t = Float(i) / sr
        var v: Float = 0
        var h = 1
        while Float(h) * f0 <= 7000 { v += powf(1 / Float(h), tilt) * sinf(2 * .pi * f0 * Float(h) * t); h += 1 }
        out[i] = v
    }
    var pk: Float = 1e-9
    for v in out { pk = max(pk, abs(v)) }
    let g = amp / pk
    for i in 0..<count { out[i] *= g }
    return out
}

/// A realistic P-pop / B-thump: a low-frequency damped sinusoid (fast attack, exponential
/// decay) — exactly the transient low-band SURGE the de-plosive targets.
private func pop(count: Int, amp: Float, f: Float = 60, decayMs: Float = 60) -> [Float] {
    var out = [Float](repeating: 0, count: count)
    let tau = decayMs * 0.001
    for i in 0..<count { let t = Float(i) / sr; out[i] = amp * expf(-t / tau) * sinf(2 * .pi * f * t) }
    return out
}

final class MouthNoiseTests: XCTestCase {

    // High-level production parameters (mirror MouthNoiseProfile).
    private func makeDePlosive(enabled: Bool, maxReductionDb: Float = 20) -> DePlosive {
        var d = DePlosive()
        d.configure(splitHz: 120, surgeRatio: 2.5, dominance: 0.78, floorDb: -50,
                    maxReductionDb: maxReductionDb, attackMs: 2, releaseMs: 40,
                    sampleRate: 48000, enabled: enabled)
        return d
    }

    private func makeDeClick(enabled: Bool, gainFloor: Float = 0.25) -> DeClick {
        var d = DeClick()
        d.configure(peakReleaseMs: 1.5, slowAttackMs: 10, slowReleaseMs: 200,
                    clickRatio: 3.0, minThresholdDb: -54, holdMs: 1.5, releaseMs: 5,
                    maxClickMs: 2.0, gainFloor: gainFloor, sampleRate: 48000, enabled: enabled)
        return d
    }

    // MARK: - DePlosive

    /// Disabled de-plosive is a perfect identity for arbitrary samples.
    func testDePlosiveDisabledIsIdentity() {
        var d = makeDePlosive(enabled: false)
        for x in [Float(0.0), 0.5, -0.73, 0.99, -0.01] {
            XCTAssertEqual(d.process(x), x, accuracy: 1e-7,
                           "disabled de-plosive must not alter samples")
        }
    }

    /// Below-floor sub-bass is a perfect identity (quiet rumble never triggers).
    func testDePlosiveBelowFloorIsIdentity() {
        var d = makeDePlosive(enabled: true)
        var maxDelta: Float = 0
        for i in 0..<9600 {
            // 80 Hz sine at −60 dBFS (below the −50 dB floor) — also steady (surge ≈ 1).
            let x = 0.001 * sinf(2 * Float.pi * 80 * Float(i) / 48000)
            maxDelta = max(maxDelta, abs(d.process(x) - x))
        }
        XCTAssertLessThan(maxDelta, 1e-4,
                          "below-floor sub-bass must pass unchanged")
    }

    /// REGRESSION (the muffled-voice bug): a sustained, harmonic-rich VOICED vowel — even a
    /// low-pitched one — is NOT a plosive and must pass essentially untouched. The previous
    /// single-ratio design ducked any low-dominant signal and so attenuated voiced low-mids
    /// continuously; the transient (surge) + concentration gates must leave steady voicing alone.
    func testDePlosivePreservesSustainedVowel() {
        var d = makeDePlosive(enabled: true)
        let v = vowel(f0: 110, count: 24000, amp: 0.5)   // 0.5 s, loud, low-pitched
        var inSq: Float = 0, outSq: Float = 0
        for (i, x) in v.enumerated() {
            let y = d.process(x)
            if i >= 12000 { inSq += x * x; outSq += y * y }   // settled half
        }
        let ratio = sqrtf(outSq) / max(sqrtf(inSq), 1e-9)
        XCTAssertGreaterThan(ratio, 0.97,
                             "sustained voiced vowel must not be ducked (< 0.27 dB change)")
    }

    /// A voiced ONSET (a vowel starting from silence) is broadband, so the concentration gate
    /// keeps it from being mistaken for a low-band plosive surge — it must not be ducked.
    func testDePlosivePreservesVowelOnset() {
        var d = makeDePlosive(enabled: true)
        let v = vowel(f0: 120, count: Int(0.1 * sr), amp: 0.5)   // cold onset
        var inSq: Float = 0, outSq: Float = 0
        for x in v { let y = d.process(x); inSq += x * x; outSq += y * y }
        let ratio = sqrtf(outSq) / max(sqrtf(inSq), 1e-9)
        XCTAssertGreaterThan(ratio, 0.95,
                             "voiced onset must not be ducked (broadband → low concentration)")
    }

    /// A loud, low-frequency damped thump (a realistic P-pop) IS a transient low-band surge and
    /// must be attenuated. This is the artifact the de-plosive exists to remove.
    func testDePlosiveReducesPop() {
        var d = makeDePlosive(enabled: true)   // High → 20 dB max reduction
        let p = pop(count: Int(0.08 * sr), amp: 0.8, f: 60)
        var inSq: Float = 0, outSq: Float = 0
        for x in p { let y = d.process(x); inSq += x * x; outSq += y * y }
        let n = Float(p.count)
        XCTAssertLessThan(sqrtf(outSq / n), sqrtf(inSq / n) * 0.85,
                          "a 60 Hz P-pop must be attenuated by at least ~1.4 dB")
    }

    /// Mid-frequency voiced content (500 Hz, loud) is well above the 120 Hz split, so it has no
    /// low-band energy to flag — it must pass through untouched even when `enabled`.
    func testDePlosivePreservesMidBandVoice() {
        var d = makeDePlosive(enabled: true)
        var maxDelta: Float = 0
        for i in 0..<9600 {
            let x = 0.5 * sinf(2 * Float.pi * 500 * Float(i) / 48000)
            maxDelta = max(maxDelta, abs(d.process(x) - x))
        }
        XCTAssertLessThan(maxDelta, 0.05,
                          "mid-band voice must not be significantly altered by the de-plosive")
    }

    /// REGRESSION (state corruption): `DePlosive` must advance EACH of its two filters (the clean
    /// low-pass and the high-pass concentration filter) EXACTLY ONCE per input sample. We prove it
    /// by reconstructing the algorithm with our own single-advance filters and asserting byte-identical
    /// output on a pop (which exercises the gated subtractive branch where any state desync would show).
    func testDePlosiveAdvancesFiltersExactlyOncePerSample() {
        let splitHz: Float = 120, surge: Float = 2.5, dom: Float = 0.78
        let floorDb: Float = -50, maxRedDb: Float = 20, atkMs: Float = 2, relMs: Float = 40, sampleRate: Float = 48000

        var d = DePlosive()
        d.configure(splitHz: splitHz, surgeRatio: surge, dominance: dom, floorDb: floorDb,
                    maxReductionDb: maxRedDb, attackMs: atkMs, releaseMs: relMs,
                    sampleRate: sampleRate, enabled: true)

        // One-pass reference: mirror DePlosive.process with a single lp/hp advance per sample.
        var refLp = Biquad(); refLp.setLowPass(freq: splitHz, sampleRate: sampleRate, q: 0.707)
        var refHp = Biquad(); refHp.setHighPass(freq: splitHz, sampleRate: sampleRate, q: 0.707)
        let floorLin = powf(10, floorDb / 20)
        let maxRed = min(1, 1 - powf(10, -abs(maxRedDb) / 20))
        let fastA = expf(-1 / (1 * 0.001 * sampleRate)),   fastR = expf(-1 / (30 * 0.001 * sampleRate))
        let slowA = expf(-1 / (100 * 0.001 * sampleRate)), slowR = expf(-1 / (300 * 0.001 * sampleRate))
        let fracA = expf(-1 / (atkMs * 0.001 * sampleRate)), fracR = expf(-1 / (relMs * 0.001 * sampleRate))
        var fastLow: Float = 0, slowLow: Float = 0, fastHigh: Float = 0, frac: Float = 0

        let signal = pop(count: 9600, amp: 0.8, f: 60)
        var maxDelta: Float = 0
        for x in signal {
            let y = d.process(x)

            let low = refLp.process(x), high = refHp.process(x)
            let lowMag = abs(low), highMag = abs(high)
            let fL = lowMag  > fastLow  ? fastA : fastR
            let sL = lowMag  > slowLow  ? slowA : slowR
            let fH = highMag > fastHigh ? fastA : fastR
            fastLow  = fL * fastLow  + (1 - fL) * lowMag
            slowLow  = sL * slowLow  + (1 - sL) * lowMag
            fastHigh = fH * fastHigh + (1 - fH) * highMag
            let su = fastLow / max(slowLow, 1e-9)
            let cn = fastLow / max(fastLow + fastHigh, 1e-9)
            let gated = fastLow > floorLin && su >= surge && cn >= dom
            let target: Float = gated ? maxRed : 0
            let c = target > frac ? fracA : fracR
            frac = c * frac + (1 - c) * target
            let ref: Float = frac < 1e-5 ? x : x - frac * low
            maxDelta = max(maxDelta, abs(y - ref))
        }
        XCTAssertLessThan(maxDelta, 1e-6,
                          "DePlosive must advance each filter exactly once per sample")
    }

    // MARK: - DeClick

    /// Disabled de-click is a perfect identity.
    func testDeClickDisabledIsIdentity() {
        var d = makeDeClick(enabled: false)
        for x in [Float(0.0), 0.5, -0.73, 0.99] {
            XCTAssertEqual(d.process(x), x, accuracy: 1e-7,
                           "disabled de-click must not alter samples")
        }
    }

    /// Steady speech (not a click) — the peak/background ratio never trips — passes unchanged.
    func testDeClickSteadySpeechIsIdentity() {
        var d = makeDeClick(enabled: true)
        var maxDelta: Float = 0
        let settleSamples = 48000
        for i in 0..<settleSamples {
            let x = 0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000)
            let y = d.process(x)
            if i >= settleSamples / 2 { maxDelta = max(maxDelta, abs(y - x)) }
        }
        XCTAssertLessThan(maxDelta, 0.01,
                          "steady speech must not be attenuated by the de-click")
    }

    /// REGRESSION (false positive on peaky voicing): a harmonic-rich vowel has a high crest factor
    /// (sharp per-cycle peaks), but those peaks ride WITH the background, so the peak/slow ratio
    /// stays well under the click threshold. The voiced body must pass through untouched.
    func testDeClickPreservesHighCrestVoiced() {
        var d = makeDeClick(enabled: true)
        let v = vowel(f0: 130, count: 48000, amp: 0.6)
        var maxDelta: Float = 0
        for (i, x) in v.enumerated() {
            let y = d.process(x)
            if i >= 24000 { maxDelta = max(maxDelta, abs(y - x)) }   // settled half
        }
        XCTAssertLessThan(maxDelta, 1e-3,
                          "high-crest voiced body must pass the de-click unchanged")
    }

    /// A short spike (simulating a lip-smack) is attenuated. The instant-attack peak follower
    /// catches a single anomalous sample relative to the established background.
    func testDeClickReducesShortSpike() {
        var d = makeDeClick(enabled: true)
        for i in 0..<24000 { _ = d.process(0.05 * sinf(2 * Float.pi * 200 * Float(i) / 48000)) }
        let spikeSample: Float = 0.5   // 10× the 0.05 background, well past the 3× ratio
        var minSpikeOut: Float = .greatestFiniteMagnitude
        for _ in 0..<4 { minSpikeOut = min(minSpikeOut, abs(d.process(spikeSample))) }
        XCTAssertLessThan(minSpikeOut, abs(spikeSample) * 0.7,
                          "de-click must attenuate a short spike above the ratio threshold")
    }

    /// After a spike, the gain returns to ≥ 0.95 within 20 ms — the de-click does NOT color the
    /// normal speech that follows (the event latches off / releases smoothly).
    func testDeClickReleasesQuickly() {
        var d = makeDeClick(enabled: true)
        for i in 0..<24000 { _ = d.process(0.05 * sinf(2 * Float.pi * 200 * Float(i) / 48000)) }
        _ = d.process(0.5)   // spike
        let releaseWindow = 960   // 20 ms
        var finalGain: Float = 0
        for _ in 0..<releaseWindow {
            let x: Float = 0.05
            finalGain = d.process(x) / x
        }
        XCTAssertGreaterThan(finalGain, 0.95,
                             "de-click gain must recover to near-unity within 20 ms after a spike")
    }

    /// REGRESSION (false positive on a loud onset): an in-speech level JUMP (here 2×, ≈ 6 dB) is a
    /// sustained rise, not a click. The wall-clock event latch must let it pass — after at most a
    /// couple ms the gate latches off, so the settled louder body is an exact identity.
    func testDeClickPreservesLoudOnset() {
        var d = makeDeClick(enabled: true)
        for i in 0..<19200 { _ = d.process(0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000)) }   // arm
        // 2× level jump, then measure the SETTLED region (skip the first 5 ms post-jump).
        var maxDelta: Float = 0
        for i in 0..<9600 {
            let x = 0.6 * sinf(2 * Float.pi * 200 * Float(i) / 48000)
            let y = d.process(x)
            if i >= 240 { maxDelta = max(maxDelta, abs(y - x)) }
        }
        XCTAssertLessThan(maxDelta, 1e-3,
                          "a loud voiced onset must pass once the event latch settles (no sustained duck)")
    }

    /// IDENTITY AT REST (non-negotiable): a normal VOICED ONSET after silence must be EXACT
    /// identity for EVERY sample — the gate must never arm from cold silence (no background).
    func testDeClickVoicedOnsetAfterSilenceIsIdentity() {
        var d = makeDeClick(enabled: true)
        for _ in 0..<9600 { _ = d.process(0) }   // 200 ms silence
        for i in 0..<2400 {
            let x = 0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000)
            XCTAssertEqual(d.process(x), x, accuracy: 1e-6,
                           "voiced onset after silence must be exact identity @\(i)")
        }
    }

    /// IDENTITY AT REST (the realistic case): SPEECH → PAUSE → ONSET. After established speech arms
    /// the gate, a realistic ~250 ms pause must DISARM it (via the instantaneous-silence detector,
    /// NOT slowEnv) so the NEXT clean onset is again exact identity from sample 0.
    func testDeClickOnsetAfterSpeechThenPauseIsIdentity() {
        var d = makeDeClick(enabled: true)
        for i in 0..<19200 { _ = d.process(0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000)) }   // arm
        for _ in 0..<12000 { _ = d.process(0) }   // 250 ms pause
        for i in 0..<2400 {
            let x = 0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000)
            XCTAssertEqual(d.process(x), x, accuracy: 1e-6,
                           "voiced onset after speech+pause must be exact identity @\(i)")
        }
    }

    /// REGRESSION (false positive): the steady VOICED BODY (sustained loud speech) must be a
    /// perfect passthrough — the click gate must never engage on it.
    func testDeClickVoicedBodyUntouched() {
        var d = makeDeClick(enabled: true)
        var maxDelta: Float = 0
        let n = 48000
        for i in 0..<n {
            let x = 0.6 * sinf(2 * Float.pi * 220 * Float(i) / 48000)
            let y = d.process(x)
            if i >= n / 4 { maxDelta = max(maxDelta, abs(y - x)) }
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
        XCTAssertLessThanOrEqual(MouthNoiseLevel.high.maxPlosReductionDb, 24,
                                 "de-plosive must stay conservative to preserve voiced stops")
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

    /// IDENTITY AT REST (limiter must not run in mouth-noise-only mode): a LOUD (> −1 dBFS) clean
    /// mid-band sine — NOT a click or plosive — must pass through unchanged in steady state.
    func testMouthNoiseOnlyPreservesLoudCleanSignal() {
        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.mouthNoiseLevel = .high
        chain.configure(s)
        let n = 9600
        var buf = [Float](repeating: 0, count: n)
        for i in 0..<n { buf[i] = 0.95 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
        let ref = buf
        buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
        var maxDelta: Float = 0
        for i in (n / 2)..<n { maxDelta = max(maxDelta, abs(buf[i] - ref[i])) }
        XCTAssertLessThan(maxDelta, 1e-4,
                          "mouth-noise-only mode must not limit a loud clean non-artifact signal")
    }

    /// Higher level removes more low-band energy from a transient P-pop (monotonic). The de-plosive
    /// ducks the low band `out = x − frac·low` with `frac` scaling with the level, so the faithful
    /// monotonic measure is the low-band energy removed = ‖input − output‖ over the pop.
    func testHigherMouthNoiseLevelReducesMoreOnPop() {
        func popReduction(_ level: MouthNoiseLevel) -> Float {
            let chain = VoiceChain()
            var s = VoiceChainSettings.disabled
            s.mouthNoiseLevel = level
            chain.configure(s)
            let input = pop(count: 9600, amp: 0.8, f: 60)   // de-click stays disarmed (< 200 ms warmup)
            var buf = input
            buf.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
            var sq: Float = 0
            for i in 0..<buf.count { let d = input[i] - buf[i]; sq += d * d }
            return sqrtf(sq / Float(buf.count))
        }
        XCTAssertGreaterThan(popReduction(.high),   popReduction(.medium))
        XCTAssertGreaterThan(popReduction(.medium), popReduction(.low))
    }

    /// Changing mouthNoiseLevel while the chain stays active must reset the mouth-noise stages.
    /// We arm + fire the de-click with an established background + a click so its gain is below
    /// unity, switch level, then feed a clean probe and require it to equal a freshly-configured
    /// chain. Any leftover `DeClick.gain < 1` (un-reset) would attenuate the probe and fail the match.
    func testMouthNoiseLevelChangeResetsStages() {
        func freshProbeOutput(_ level: MouthNoiseLevel) -> [Float] {
            let chain = VoiceChain()
            var s = VoiceChainSettings.disabled
            s.mouthNoiseLevel = level
            chain.configure(s)
            var probe = [Float](repeating: 0, count: 256)
            for i in 0..<probe.count { probe[i] = 0.2 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
            probe.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }
            return probe
        }

        let chain = VoiceChain()
        var s = VoiceChainSettings.disabled
        s.mouthNoiseLevel = .high
        chain.configure(s)
        // Establish a background (≥ warmup) so the de-click ARMS, then a hard click at the very end
        // drives its gain toward the floor (state that must be cleared on the level change).
        var burst = [Float](repeating: 0, count: 12000)
        for i in 0..<burst.count { burst[i] = 0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000) }
        burst[11990] = 0.99
        burst.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }

        s.mouthNoiseLevel = .low
        chain.configure(s)

        var probe = [Float](repeating: 0, count: 256)
        for i in 0..<probe.count { probe[i] = 0.2 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
        probe.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }

        let fresh = freshProbeOutput(.low)
        var maxDelta: Float = 0
        for i in 0..<probe.count { maxDelta = max(maxDelta, abs(probe[i] - fresh[i])) }
        XCTAssertLessThan(maxDelta, 1e-5,
                          "mouth-noise stages must fully reset on level change — no stale gain/state")
    }

    /// REGRESSION (bumpless carry-state contract): reconfiguring on an UNRELATED setting change
    /// (here, `clarity`) while `mouthNoiseLevel` stays the SAME must NOT cold-reset the mouth-noise
    /// detector state. We energize the de-click (drive its gain below unity at the end of a burst),
    /// reconfigure with the SAME mouthNoise but CHANGED clarity, and require the next probe to DIFFER
    /// from a freshly-cold chain. If either layer wrongly cleared state, the carried chain would match.
    func testUnrelatedConfigChangeDoesNotResetMouthNoise() {
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
        s.clarity = .off
        s.mouthNoiseLevel = .high
        chain.configure(s)
        var burst = [Float](repeating: 0, count: 12000)   // 250 ms ≥ warmup → gate armed
        for i in 0..<burst.count { burst[i] = 0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000) }
        burst[11990] = 0.99   // click at the end → gain driven toward the floor
        burst.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }

        s.clarity = .low   // change ONLY clarity; mouthNoise stays .high → must NOT reset
        chain.configure(s)

        var probe = [Float](repeating: 0, count: 256)
        for i in 0..<probe.count { probe[i] = 0.2 * sinf(2 * Float.pi * 1000 * Float(i) / 48000) }
        probe.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }

        let cold = coldChain()
        var maxDelta: Float = 0
        for i in 0..<probe.count { maxDelta = max(maxDelta, abs(probe[i] - cold[i])) }
        XCTAssertGreaterThan(maxDelta, 1e-4,
                             "unrelated config change must NOT cold-reset mouth-noise state (state must carry)")
    }

    /// A simultaneous clarity + mouthNoise level change (while active) must reset BOTH stage groups.
    /// Independent `if` checks (not `else if`) reset clarity AND mouth-noise in one configure call.
    func testSimultaneousClarityAndMouthNoiseChangeResetsBoth() {
        func freshOutput() -> [Float] {
            let chain = VoiceChain()
            var s = VoiceChainSettings.disabled
            s.clarity = .low
            s.mouthNoiseLevel = .low
            s.limiterCeilingDb = 24            // neutralize the shared limiter (not a per-level stage)
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
        s.limiterCeilingDb = 24
        chain.configure(s)
        // Established background + sibilant energy (clarity/de-esser) + a click at the end (de-click).
        var burst = [Float](repeating: 0, count: 12000)
        for i in 0..<burst.count {
            burst[i] = 0.3 * sinf(2 * Float.pi * 200 * Float(i) / 48000)
                     + 0.2 * sinf(2 * Float.pi * 7000 * Float(i) / 48000)
        }
        burst[11990] = 0.99
        burst.withUnsafeMutableBufferPointer { chain.process($0.baseAddress!, count: $0.count) }

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

    /// mouthNoise == .off with an enabled (polish-on) preset must be bit-identical to the chain
    /// without the mouth-noise stages — proving Off is a true no-op.
    func testMouthNoiseOffMatchesLegacyChain() {
        let s = VoicePreset.podcast.voiceChain
        XCTAssertEqual(s.mouthNoiseLevel, .off,
                       "preset voiceChain must default mouthNoiseLevel to .off")
        let chain = VoiceChain()
        chain.configure(s)

        var hp = Biquad(), lo = Biquad(), hi = Biquad(), pres = Biquad()
        var deEss = DeEsser()
        var comp = Compressor(); var lim = Limiter()
        hp.setHighPass(freq: s.highPassHz, sampleRate: 48000)
        lo.setLowShelf(freq: s.lowShelfHz, gainDb: s.lowShelfDb, sampleRate: 48000)
        hi.setHighShelf(freq: s.highShelfHz, gainDb: s.highShelfDb, sampleRate: 48000)
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
