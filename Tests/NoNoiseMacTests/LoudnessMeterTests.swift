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
}
