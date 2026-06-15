import Foundation

/// ITU-R BS.1770 (K-weighted) loudness meter — a pure, allocation-free value type.
/// Stage 1 = the "pre-filter" head high-shelf (≈ +4 dB above ~1.5 kHz); stage 2 =
/// the RLB high-pass (≈ −3 dB at ~38 Hz). Both use the STANDARD's published 48 kHz
/// biquad coefficients (not RBJ approximations) so the meter reads true BS.1770
/// loudness across the spectrum. Then: K-weighted mean-square over a sliding
/// momentary window (400 ms). Mono measurement applies the standard −0.691 dB
/// calibration offset. Integrated loudness is gated (absolute −70 LUFS + relative
/// −10 LU) over a fixed-size, pre-allocated block ring (no render-path allocation).
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

    // Integrated (gated) state — per 400 ms block. Running sums + a fixed-size ring
    // of absolute-gated block mean-squares for the relative gate. NO growth: the ring
    // is pre-allocated and written by index (wraparound), so process() never allocates.
    private var blockLen = 0                    // samples per 400 ms block (set in init)
    private var blockMeanSquareSum: Float = 0   // Σ mean-square accumulated in the current block
    private var blockSamples = 0                // samples seen in the current block
    // Σ mean-square of the absolute-gated blocks CURRENTLY in the ring. Kept in lock-step
    // with the ring (evict-on-overwrite below) so the relative gate's mean and gated set
    // use the SAME bounded window — they must not desync after the ring wraps.
    private var absGatedMSSum: Float = 0
    // Fixed-size ring of absolute-gated block mean-squares (the relative-gate input).
    // Pre-allocated; write-by-index with wraparound — NEVER appended to on the render path.
    private let maxBlocks: Int                  // rolling-window length in 400 ms blocks
    private var blockMSRing: [Float]            // count == maxBlocks (allocated in init)
    private var blockMSRingHead = 0             // next write slot (wraps at maxBlocks)
    private var blockMSRingFilled = 0           // how many slots hold real data (≤ maxBlocks)

    /// Default rolling integration window: 9000 × 400 ms = 1 h (bounded memory).
    static let defaultIntegrationBlocks = 9000

    public init(sampleRate: Float = 48000) {
        self.init(sampleRate: sampleRate, integrationBlocks: Self.defaultIntegrationBlocks)
    }

    /// Designated initializer with a configurable integration-window length (in 400 ms
    /// blocks). `internal` so unit tests can force ring wraparound cheaply; production
    /// always uses the 1-hour default via `init(sampleRate:)`.
    init(sampleRate: Float, integrationBlocks: Int) {
        self.sampleRate = sampleRate
        self.maxBlocks = max(1, integrationBlocks)
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
        blockLen = max(1, Int(0.4 * sampleRate))         // 400 ms integration block
        blockMSRing = [Float](repeating: 0, count: maxBlocks)
    }

    public mutating func reset() {
        shelf.reset(); hp.reset()
        for i in 0..<momentaryRing.count { momentaryRing[i] = 0 }
        momentaryHead = 0; momentaryFilled = 0; momentarySum = 0
        samplePeak = 0
        // Integrated (gated) state.
        blockMeanSquareSum = 0; blockSamples = 0
        absGatedMSSum = 0
        for i in 0..<blockMSRing.count { blockMSRing[i] = 0 }
        blockMSRingHead = 0; blockMSRingFilled = 0
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

        // Integrated (gated) block accumulation — runs on the render thread, no alloc.
        blockMeanSquareSum += sq
        blockSamples += 1
        if blockSamples >= blockLen {
            let blockMS = blockMeanSquareSum / Float(blockSamples)
            // Absolute gate: keep only blocks louder than the −70 LUFS floor.
            if Self.loudness(meanSquare: blockMS) > -70 {
                // Keep absGatedMSSum equal to the SUM of the ring's live entries: when the
                // ring is full the write below evicts the oldest block, so subtract its
                // energy first. Otherwise the relative-gate mean would drift on lifetime
                // history while the gated loop only sees the last `maxBlocks` blocks.
                if blockMSRingFilled == maxBlocks { absGatedMSSum -= blockMSRing[blockMSRingHead] }
                absGatedMSSum += blockMS
                // Write into the fixed ring by index (wraparound) — never append.
                blockMSRing[blockMSRingHead] = blockMS
                blockMSRingHead += 1
                if blockMSRingHead == maxBlocks { blockMSRingHead = 0 }
                if blockMSRingFilled < maxBlocks { blockMSRingFilled += 1 }
            }
            blockMeanSquareSum = 0
            blockSamples = 0
        }
    }

    /// Loudness of the current momentary (400 ms) window, in LUFS. Returns the
    /// silence sentinel until the window has any energy.
    public var momentaryLUFS: Float {
        Self.loudness(meanSquare: momentaryFilled > 0 ? momentarySum / Float(momentaryFilled) : 0)
    }

    /// Integrated (gated) loudness in LUFS — BS.1770 absolute (−70 LUFS) + relative
    /// (−10 LU) gating over the absolute-gated block set. Returns the silence
    /// sentinel until at least one block passes the absolute gate.
    public var integratedLUFS: Float {
        guard blockMSRingFilled > 0 else { return Self.silenceLUFS }
        // Relative gate: −10 LU below the mean loudness of the absolute-gated blocks in
        // the ring. absGatedMSSum and blockMSRingFilled describe the SAME bounded window
        // (the relative loop below also reads only blockMSRing[0..<blockMSRingFilled]), so
        // the threshold and the gated set stay consistent even after the ring wraps.
        let absMeanMS = absGatedMSSum / Float(blockMSRingFilled)
        let relThresholdMS = absMeanMS * powf(10, -10.0 / 10.0)   // −10 LU in the power domain
        var count = 0
        var msSum: Float = 0
        for i in 0..<blockMSRingFilled where blockMSRing[i] >= relThresholdMS {
            count += 1; msSum += blockMSRing[i]
        }
        guard count > 0 else { return Self.loudness(meanSquare: absMeanMS) }
        return Self.loudness(meanSquare: msSum / Float(count))
    }

    /// LUFS from a K-weighted mean-square value, with the BS.1770 −0.691 dB offset.
    /// Returns the silence sentinel for non-positive energy.
    static func loudness(meanSquare ms: Float) -> Float {
        guard ms > 0 else { return silenceLUFS }
        return -0.691 + 10 * log10f(ms)
    }

    /// Slew-limited make-up gain toward a loudness target. Returns a LINEAR gain
    /// to multiply the signal by. Holds `currentGain` when there is no measurement
    /// (silence below the absolute gate) so silent gaps never cause pumping.
    /// `maxDb` clamps the absolute make-up; `slewDb` caps the per-update change.
    static func normalizationGain(measuredLUFS: Float, targetLUFS: Float,
                                  currentGain: Float, maxDb: Float, slewDb: Float) -> Float {
        guard measuredLUFS > silenceLUFS else { return currentGain }   // no data → hold
        let neededDb = targetLUFS - measuredLUFS                       // + = boost, − = cut
        let clampedTargetDb = min(max(neededDb, -abs(maxDb)), abs(maxDb))
        let targetGain = powf(10, clampedTargetDb / 20)
        // Slew toward targetGain in the dB domain so steps are perceptually even.
        let currentDb = 20 * log10f(max(currentGain, 1e-6))
        let targetGainDb = 20 * log10f(max(targetGain, 1e-6))
        let stepDb = min(max(targetGainDb - currentDb, -abs(slewDb)), abs(slewDb))
        return powf(10, (currentDb + stepDb) / 20)
    }
}
