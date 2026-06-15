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

    func testPresetTutorialDoesNotAddCompressorMakeup() {
        XCTAssertEqual(VoicePreset.tutorial.voiceChain.compMakeupDb, 0)
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
        var settings = VoiceChainSettings.disabled
        settings.loudnessActive = true

        let boosted = VoiceChain(); boosted.configure(settings)
        boosted.setLoudnessGain(2.0)
        let unity = VoiceChain(); unity.configure(settings)
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
}
