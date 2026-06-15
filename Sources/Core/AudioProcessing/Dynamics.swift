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
