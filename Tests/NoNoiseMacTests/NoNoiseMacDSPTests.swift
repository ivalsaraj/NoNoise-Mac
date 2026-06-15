import XCTest
@testable import Core

final class NoNoiseMacDSPTests: XCTestCase {
    func testScaffolding() {
        XCTAssertTrue(true)
    }

    func testErbBandsPartition481Bins() {
        // libDF erb_fb partitions the 481 FFT bins into 32 contiguous, non-overlapping
        // bands. The sizes must sum to exactly fft_size/2 + 1 = 481.
        let bands = DeepFilterNetDSP.makeErbBands(sr: 48000, fftSize: 960, nbBands: 32, minNbFreqs: 2)
        XCTAssertEqual(bands.count, 32)
        XCTAssertEqual(bands.reduce(0, +), 481, "ERB bands must cover all 481 bins exactly")
        XCTAssertTrue(bands.allSatisfy { $0 >= 2 }, "each band must have at least min_nb_freqs bins")
    }

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

    // MARK: - Suppression knobs (Task 1)

    func testMinGainUnlimitedAtMax() {
        // At/above the max dB sentinel the floor is 0 (full suppression allowed).
        XCTAssertEqual(DeepFilterNetDSP.minGain(forAttenuationDb: DeepFilterNetDSP.maxAttenuationLimitDb), 0)
        XCTAssertEqual(DeepFilterNetDSP.minGain(forAttenuationDb: 200), 0)
    }

    func testMinGainZeroDbIsUnity() {
        // 0 dB limit = no reduction permitted → floor of 1.0.
        XCTAssertEqual(DeepFilterNetDSP.minGain(forAttenuationDb: 0), 1.0, accuracy: 1e-6)
    }

    func testMinGain20Db() {
        XCTAssertEqual(DeepFilterNetDSP.minGain(forAttenuationDb: 20), 0.1, accuracy: 1e-4)
    }

    func testResolveBinDefaultReturnsWetExactly() {
        // Non-negotiable: the default (strength=1, no attenuation floor) must be
        // byte-for-byte identical to the pre-preset path (realOut[i] = enhanced).
        // Assert EXACT equality (no tolerance) and use an extreme dry value to
        // prove the fast path ignores dry entirely and returns the wet untouched.
        let (r, i) = DeepFilterNetDSP.resolveOutputBin(dryR: 12345.6, dryI: -9876.5,
                                                       wetR: 0.1, wetI: 0.05,
                                                       strength: 1.0, minGain: 0.0)
        XCTAssertEqual(r, 0.1)
        XCTAssertEqual(i, 0.05)
    }

    func testResolveBinZeroStrengthReturnsDry() {
        // strength=0 → output equals the dry (original) value (passthrough).
        let (r, i) = DeepFilterNetDSP.resolveOutputBin(dryR: 0.8, dryI: -0.2, wetR: 0.1, wetI: 0.05,
                                                       strength: 0.0, minGain: 0.0)
        XCTAssertEqual(r, 0.8, accuracy: 1e-6)
        XCTAssertEqual(i, -0.2, accuracy: 1e-6)
    }

    func testResolveBinAttenuationFloorRaisesSuppressedBin() {
        // dry magnitude 1.0, wet fully suppressed to ~0, floor = 0.5 (minGain) →
        // output magnitude must be >= 0.5 (the floor), not 0.
        let (r, i) = DeepFilterNetDSP.resolveOutputBin(dryR: 1.0, dryI: 0.0, wetR: 0.0, wetI: 0.0,
                                                       strength: 1.0, minGain: 0.5)
        let mag = (r*r + i*i).squareRoot()
        XCTAssertEqual(mag, 0.5, accuracy: 1e-5)
    }

    // MARK: - VoicePreset (Task 2)

    func testPresetCustomHasNoParameters() {
        XCTAssertNil(VoicePreset.custom.parameters)
    }

    func testPresetMeetingIsFullSuppressionUnityGain() {
        let p = VoicePreset.meeting.parameters
        XCTAssertEqual(p?.suppressionStrength, 1.0)
        XCTAssertEqual(p?.attenuationLimitDb, VoicePreset.maxAttenuationDb)
        XCTAssertEqual(p?.outputGain, 1.0)
    }

    func testPresetPodcastKeepsNaturalFloor() {
        // Podcast must limit attenuation (natural tone), not run unlimited.
        let p = VoicePreset.podcast.parameters
        XCTAssertNotNil(p)
        XCTAssertLessThan(p!.attenuationLimitDb, VoicePreset.maxAttenuationDb)
    }

    func testPresetTutorialAddsMakeupGain() {
        XCTAssertGreaterThan(VoicePreset.tutorial.parameters!.outputGain, 1.0)
    }

    func testPresetMaxAttenuationMatchesDSPSentinel() {
        // The enum sentinel must equal the DSP sentinel or the limit never disables.
        XCTAssertEqual(VoicePreset.maxAttenuationDb, DeepFilterNetDSP.maxAttenuationLimitDb)
    }

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
}
