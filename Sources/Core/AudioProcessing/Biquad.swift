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

    /// Set pre-computed, already-normalized (a0 == 1) biquad coefficients directly.
    /// Used for filters whose coefficients are specified by a standard (e.g. the
    /// ITU-R BS.1770 K-weighting stages) rather than derived from an RBJ formula.
    public mutating func setCoefficients(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
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

    /// RBJ peaking EQ (bell). Unity gain at DC and Nyquist; boosts/cuts `gainDb`
    /// around `freq`. A wide `q` (~0.7) gives a broad, musical lift that adds
    /// presence without coloring the voice's identity.
    public mutating func setPeaking(freq: Float, gainDb: Float, sampleRate: Float, q: Float = 0.707) {
        let A = powf(10, gainDb / 40)
        let w0 = 2 * Float.pi * max(freq, 1) / sampleRate
        let cs = cosf(w0), sn = sinf(w0)
        let alpha = sn / (2 * max(q, 0.0001))
        let a0 = 1 + alpha / A
        b0 = (1 + alpha * A) / a0
        b1 = (-2 * cs) / a0
        b2 = (1 - alpha * A) / a0
        a1 = (-2 * cs) / a0
        a2 = (1 - alpha / A) / a0
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
