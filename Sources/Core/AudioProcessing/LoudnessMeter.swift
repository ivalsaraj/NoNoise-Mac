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
