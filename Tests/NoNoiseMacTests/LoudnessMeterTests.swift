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

    /// Once the bounded integration window wraps, the rolling block ring must FORGET the
    /// evicted history: a loud passage followed by enough quieter (but above-gate) audio
    /// to fully wrap the window integrates to the recent quiet level — NOT a stale
    /// lifetime average. (Regression: the relative gate previously divided lifetime sums
    /// while summing only the last `maxBlocks` ring entries, so the two windows desynced
    /// after wrap.) Uses a tiny 4-block window so the wrap is cheap.
    func testIntegratedForgetsEvictedBlocksAfterWindowWraps() {
        let blockLen = Int(0.4 * 48000)                 // samples in one 400 ms block
        let loud  = powf(10, -14.0 / 20.0)
        let quiet = powf(10, -40.0 / 20.0)              // 26 dB down, still well above the −70 gate
        func feed(_ m: inout LoudnessMeter, amp: Float, blocks: Int) {
            for i in 0..<(blocks * blockLen) {
                m.process(amp * sinf(2 * Float.pi * 1000 * Float(i) / 48000))
            }
        }
        // Window = 4 blocks. 4 loud blocks then 4 quiet blocks ⇒ ring now holds ONLY quiet.
        var wrapped = LoudnessMeter(sampleRate: 48000, integrationBlocks: 4)
        feed(&wrapped, amp: loud,  blocks: 4)
        feed(&wrapped, amp: quiet, blocks: 4)
        // Reference: a meter that only ever saw the quiet blocks.
        var quietOnly = LoudnessMeter(sampleRate: 48000, integrationBlocks: 4)
        feed(&quietOnly, amp: quiet, blocks: 4)
        XCTAssertEqual(wrapped.integratedLUFS, quietOnly.integratedLUFS, accuracy: 1.0,
                       "rolling window must forget the evicted loud blocks after it wraps")
    }

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
}
