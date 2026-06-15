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
