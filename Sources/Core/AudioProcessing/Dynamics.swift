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

/// Subtractive low-band de-plosive — a TRANSIENT detector, NOT a steady-state ducker.
/// A P-pop / B-thump is a brief low-frequency SURGE: low-band energy that (a) rises sharply
/// above its own recent background AND (b) is spectrally concentrated in the low band. Steady
/// voiced energy (even a sustained low note) is NOT a plosive and MUST pass untouched. The
/// previous single-ratio design ducked ANY low-dominant signal, so it attenuated the low-mids
/// of ordinary voiced speech continuously — the muffled/dull artifact this redesign fixes.
///
/// Detection uses TWO clean filters, each advanced EXACTLY ONCE per sample:
///   • `lp` (low-pass @ `splitHz`) → the low band: both the detection magnitude and the
///     reduction TARGET. A clean LPF (not `x - hp(x)`) avoids leaking phase-shifted high-band
///     energy into the "low" signal and biasing the detector.
///   • `hp` (high-pass @ `splitHz`) → the high band, used only for the concentration gate.
/// Two gates must BOTH fire (plus an absolute floor so quiet rumble never triggers):
///   • surge       = fastLow / slowLow              ≥ `surgeRatio`  (a transient rise)
///   • concentration = fastLow / (fastLow + fastHigh) ≥ `dominance`  (energy is low-band)
///
/// When gated, the reduction amount `frac` ramps toward `maxReduction` (fast attack) and
/// releases toward 0 (slow release); output is `x - frac·low`. Off / below-gate → `frac = 0`
/// → `out = x` exactly, so the mid voice body, consonant bursts, and steady low notes pass through.
///
/// **Carry-state contract (mirrors `DeEsser`/`DeClick`):** `configure(enabled: true)` updates
/// coefficients ONLY — it never clears runtime detector state (envelopes, `frac`, filter
/// memory). Only `reset()` and the disabled arm clear it, so an unrelated reconfigure is bumpless.
public struct DePlosive {
    private var lp = Biquad()            // clean low band: detection magnitude + reduction target
    private var hp = Biquad()            // clean high band: concentration gate only
    private var enabled = false
    private var floorLin: Float = 0      // absolute low-band floor to arm detection
    private var surgeRatio: Float = 2.5  // fastLow/slowLow rise that flags a transient
    private var dominance: Float = 0.78  // fastLow/(fastLow+fastHigh) concentration gate
    private var maxReduction: Float = 0  // max fraction of the low band to subtract (0…1)
    private var fastLow: Float = 0       // fast follower of |low|
    private var slowLow: Float = 0       // slow follower of |low| (the low-band background)
    private var fastHigh: Float = 0      // fast follower of |high| (matched TC) for the gate
    private var frac: Float = 0          // smoothed reduction amount

    private var fastAttackCoeff: Float = 0, fastReleaseCoeff: Float = 0
    private var slowAttackCoeff: Float = 0, slowReleaseCoeff: Float = 0
    private var fracAttackCoeff: Float = 0, fracReleaseCoeff: Float = 0

    // Fixed detector time-constants (ms). These shape the surge/concentration analysis and are
    // NOT user knobs: a ~1 ms fast attack resolves a pop's leading edge; the 100/300 ms slow
    // follower is the low-band background a transient must rise above.
    private static let fastAttackMs: Float = 1,   fastReleaseMs: Float = 30
    private static let slowAttackMs: Float = 100, slowReleaseMs: Float = 300

    public init() {}

    public mutating func configure(splitHz: Float, surgeRatio: Float, dominance: Float,
                                   floorDb: Float, maxReductionDb: Float,
                                   attackMs: Float, releaseMs: Float,
                                   sampleRate: Float, enabled: Bool) {
        self.enabled = enabled
        guard enabled else {
            lp.setBypass(); hp.setBypass()
            fastLow = 0; slowLow = 0; fastHigh = 0; frac = 0
            return
        }
        lp.setLowPass(freq: splitHz, sampleRate: sampleRate, q: 0.707)
        hp.setHighPass(freq: splitHz, sampleRate: sampleRate, q: 0.707)
        self.surgeRatio = max(1, surgeRatio)
        self.dominance = max(0, min(1, dominance))
        floorLin = powf(10, floorDb / 20)
        maxReduction = min(1, 1 - powf(10, -abs(maxReductionDb) / 20))
        fracAttackCoeff  = expf(-1.0 / (max(attackMs,  0.01) * 0.001 * sampleRate))
        fracReleaseCoeff = expf(-1.0 / (max(releaseMs, 0.01) * 0.001 * sampleRate))
        fastAttackCoeff  = expf(-1.0 / (DePlosive.fastAttackMs  * 0.001 * sampleRate))
        fastReleaseCoeff = expf(-1.0 / (DePlosive.fastReleaseMs * 0.001 * sampleRate))
        slowAttackCoeff  = expf(-1.0 / (DePlosive.slowAttackMs  * 0.001 * sampleRate))
        slowReleaseCoeff = expf(-1.0 / (DePlosive.slowReleaseMs * 0.001 * sampleRate))
        // NOTE: runtime detector state is intentionally NOT cleared here (bumpless on unrelated
        // reconfigures). Clearing happens only in reset() / the disabled arm.
    }

    public mutating func reset() {
        fastLow = 0; slowLow = 0; fastHigh = 0; frac = 0
        lp.reset(); hp.reset()
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }
        // EXACTLY ONE advance per filter per sample (`Biquad.process` mutates z1/z2 on every
        // call; a stray second call would desync detection from the render output).
        let low = lp.process(x)
        let high = hp.process(x)
        let lowMag = abs(low), highMag = abs(high)

        let fL = lowMag  > fastLow  ? fastAttackCoeff : fastReleaseCoeff
        let sL = lowMag  > slowLow  ? slowAttackCoeff : slowReleaseCoeff
        let fH = highMag > fastHigh ? fastAttackCoeff : fastReleaseCoeff
        fastLow  = fL * fastLow  + (1 - fL) * lowMag
        slowLow  = sL * slowLow  + (1 - sL) * lowMag
        fastHigh = fH * fastHigh + (1 - fH) * highMag

        // Transient (surge) AND low-band concentration gate, above an absolute floor.
        let surge = fastLow / max(slowLow, 1e-9)
        let conc  = fastLow / max(fastLow + fastHigh, 1e-9)
        let gated = fastLow > floorLin && surge >= surgeRatio && conc >= dominance

        // Smooth the reduction amount: fast attack to maxReduction, slow release to 0.
        let target: Float = gated ? maxReduction : 0
        let c = target > frac ? fracAttackCoeff : fracReleaseCoeff
        frac = c * frac + (1 - c) * target
        if frac < 1e-5 { return x }   // identity when no reduction is active
        return x - frac * low
    }
}

/// Broadband transient gate for mouth clicks and lip-smacks. A click is an INSTANTANEOUS
/// peak that towers over the established speech background; a voiced onset or the voiced
/// body is a level change that SUSTAINS. The gate tracks an instant-attack PEAK follower
/// against a slow background and ducks only a SHORT event:
///   • `peak`    — instant attack, fast release (`peakReleaseMs`): catches a 1-sample spike.
///   • `slowEnv` — the speech background (slow attack/release).
///   • trip when `peak > clickRatio · slowEnv`.
/// A wall-clock EVENT LATCH separates clicks from sustained content: a trip starts an event
/// and refreshes a hold that bridges sub-pitch-period gaps (so a periodic loud passage reads
/// as ONE event, not a train of clicks). If the event outlasts `maxClickMs` it LATCHES OFF —
/// the rise is voiced content, gain snaps to unity and stays there until a real quiet gap ends
/// the event. So even an extreme instantaneous level jump only ducks for ≈`maxClickMs`, while a
/// genuine click (a shorter event) is fully ducked. Attack to the floor is instantaneous (the
/// step is masked by the click transient); release is a smooth ramp (`releaseMs`) — no zipper.
///
/// **Identity at rest is non-negotiable: the gate NEVER fires from cold silence, and re-disarms
/// on any realistic pause.** A click is only meaningful relative to an ESTABLISHED background, so
/// the gate arms only after the slow background has stayed above `minThresholdLin` continuously for
/// `warmupSamples` (one slow-release time-constant). Disarm is driven by an INDEPENDENT
/// instantaneous-silence detector, NOT by `slowEnv`: `slowEnv` releases over ~200 ms, so a realistic
/// 200–300 ms pause leaves it above the floor (it must NOT gate disarm). A `silenceCounter` counts
/// consecutive samples whose instantaneous level `|x|` is below the floor; after `silenceSamples`
/// (≈75 ms) the gate force-disarms (`warmupCounter = 0`). Any above-floor sample resets it, so voiced
/// zero-crossings never disarm mid-speech. While unarmed, `process` returns `x` BIT-EXACTLY (`gain`
/// held at 1.0; the ratio is never even consulted), so a voiced onset after silence is exact identity
/// from sample 0 — at cold start AND after every realistic pause.
///
/// **Documented tradeoff:** a click occurring from *total* silence (no preceding speech to establish
/// a background) is intentionally MISSED — missing a from-silence click is strictly preferable to
/// dulling a clean voiced onset. Clicks during or after speech (the realistic case) still have an
/// established background and are caught.
///
/// Below the ratio (and when disabled) `gain = 1.0` exactly.
///
/// **State-carry contract (mirrors `DeEsser`):** `configure(enabled: true)` updates
/// parameters/coefficients ONLY — it MUST NOT clear the runtime detector state (`peak`, `slowEnv`,
/// `gain`, `holdCounter`, `eventLen`, `elevatedHold`, `latched`, `warmupCounter`, `silenceCounter`).
/// Runtime state is cleared ONLY by `reset()` and by the disabled arm. `VoiceChain` decides when to
/// reset (full reset on inactive→active; mouth-noise stages reset when `MouthNoiseLevel` itself
/// changes), so reconfiguring on an UNRELATED setting change (clarity, voice polish) is bumpless.
public struct DeClick {
    private var enabled = false
    private var clickRatio: Float = 3.0       // peak/slow ratio to flag a click
    private var minThresholdLin: Float = 1e-6 // absolute floor: arms the warm-up + ratio test
    private var gainFloor: Float = 0.25       // gain during a click event
    private var peakReleaseCoeff: Float = 0   // peak follower release (attack is instantaneous)
    private var slowAttackCoeff: Float = 0
    private var slowReleaseCoeff: Float = 0
    private var releaseCoeff: Float = 0       // gain release ramp back to unity
    private var holdSamples: Int = 0
    private var holdCounter: Int = 0
    private var maxClickSamples: Int = 0      // longest event still treated as a click
    private var eventResetSamples: Int = 0    // quiet gap that ends a transient event
    private var warmupSamples: Int = 0        // background must be established this long before arming
    private var warmupCounter: Int = 0        // consecutive samples slowEnv has been above the floor
    private var silenceSamples: Int = 0       // consecutive instantaneous-silence samples that force a disarm (≈75 ms)
    private var silenceCounter: Int = 0       // consecutive samples |x| has stayed below the silence floor
    private var eventLen: Int = 0             // wall-clock samples the current event has lasted
    private var elevatedHold: Int = 0         // bridges sub-pitch-period gaps within one event
    private var latched = false               // true = event outlasted maxClick; pass as voiced
    private var peak: Float = 0               // instant-attack peak follower
    private var slowEnv: Float = 0            // starts at 0; gate stays disarmed until background established
    private var gain: Float = 1.0

    // Continuous instantaneous silence (ms) that forces a disarm. Fixed: a click is meaningful
    // only against an ESTABLISHED background, and a realistic pause is ≥ 200 ms — 75 ms re-arms
    // cold well inside that window while staying immune to per-cycle voiced zero-crossings.
    private static let silenceDisarmMs: Float = 75
    // Quiet gap (ms) that ends a transient event. Must exceed one pitch period of the lowest voiced
    // pitch (~80 Hz → 12.5 ms) so a periodic loud passage reads as ONE sustained event (and latches
    // off) instead of a train of clicks.
    private static let eventBridgeMs: Float = 12

    public init() {}

    /// Update parameters/coefficients. Mirrors `DeEsser.configure`: the `enabled`
    /// arm does NOT touch runtime state — only `reset()` and the disabled arm clear it.
    public mutating func configure(peakReleaseMs: Float, slowAttackMs: Float, slowReleaseMs: Float,
                                   clickRatio: Float, minThresholdDb: Float,
                                   holdMs: Float, releaseMs: Float, maxClickMs: Float,
                                   gainFloor: Float, sampleRate: Float, enabled: Bool) {
        self.enabled = enabled
        guard enabled else { reset(); return }
        self.clickRatio = max(1, clickRatio)
        self.gainFloor = max(0, min(1, gainFloor))
        minThresholdLin = powf(10, minThresholdDb / 20)
        peakReleaseCoeff = expf(-1.0 / (max(peakReleaseMs, 0.01) * 0.001 * sampleRate))
        slowAttackCoeff  = expf(-1.0 / (max(slowAttackMs,  0.01) * 0.001 * sampleRate))
        slowReleaseCoeff = expf(-1.0 / (max(slowReleaseMs, 0.01) * 0.001 * sampleRate))
        releaseCoeff     = expf(-1.0 / (max(releaseMs,     0.01) * 0.001 * sampleRate))
        holdSamples = Int(max(holdMs, 0) * 0.001 * sampleRate)
        // A click is a short event; anything longer is voiced content (latched off).
        maxClickSamples = max(1, Int(max(maxClickMs, 0.01) * 0.001 * sampleRate))
        eventResetSamples = max(1, Int(DeClick.eventBridgeMs * 0.001 * sampleRate))
        // Require one slow-release time-constant of established background before arming
        // the gate. From cold silence the gate stays disarmed → voiced onset is exact identity.
        warmupSamples = max(1, Int(max(slowReleaseMs, 0.01) * 0.001 * sampleRate))
        // Disarm on ACTUAL silence (instantaneous level below the floor), NOT on slowEnv
        // decay: slowEnv's ~200 ms release leaves it above the floor through a normal pause,
        // so it would keep the gate armed and let the next clean onset be attenuated. 75 ms of
        // continuous instantaneous silence is short enough to re-arm cold after a realistic
        // 200–300 ms pause, yet long enough that voiced zero-crossings never trip it mid-speech.
        silenceSamples = max(1, Int(DeClick.silenceDisarmMs * 0.001 * sampleRate))
        // NOTE: runtime detector state is intentionally NOT cleared here (bumpless on
        // unrelated reconfigures). Clearing happens only in reset() / the disabled arm.
    }

    public mutating func reset() {
        peak = 0; slowEnv = 0; gain = 1
        holdCounter = 0; eventLen = 0; elevatedHold = 0
        warmupCounter = 0; silenceCounter = 0; latched = false
    }

    @inline(__always)
    public mutating func process(_ x: Float) -> Float {
        guard enabled else { return x }
        let mag = abs(x)

        // Peak follower: INSTANT attack (catches a 1-sample click), exponential release.
        peak = mag > peak ? mag : peakReleaseCoeff * peak

        // Slow envelope: tracks the speech background.
        let sCoeff = mag > slowEnv ? slowAttackCoeff : slowReleaseCoeff
        slowEnv = sCoeff * slowEnv + (1 - sCoeff) * mag

        // Instantaneous-silence disarm: count consecutive samples whose INSTANTANEOUS level
        // is below the floor. `mag` (not `slowEnv`) is the disarm signal — slowEnv's ~200 ms
        // release stays above the floor through a normal pause, so it would keep the gate
        // armed and let the next clean onset be attenuated. Any above-floor sample resets the
        // counter, so voiced zero-crossings never accumulate enough to disarm mid-speech.
        if mag <= minThresholdLin {
            if silenceCounter < silenceSamples { silenceCounter += 1 }
        } else {
            silenceCounter = 0
        }
        // After `silenceSamples` of continuous silence (≈75 ms), force a cold disarm so the
        // NEXT voiced onset re-arms from scratch and is exact identity from sample 0.
        if silenceCounter >= silenceSamples { warmupCounter = 0 }

        // Warm-up: a click is only meaningful relative to an ESTABLISHED background. Count
        // continuous samples the slow background has been above the floor; the gate is armed
        // only once it has been established for `warmupSamples`. Disarm is handled above by
        // the instantaneous-silence detector, NOT by slowEnv.
        if slowEnv > minThresholdLin {
            if warmupCounter < warmupSamples { warmupCounter += 1 }
        }
        let armed = warmupCounter >= warmupSamples

        // IDENTITY AT REST: until a background is established (e.g. a voiced onset after
        // silence), the gate cannot fire. Force gain to exactly 1.0 and return x bit-for-bit.
        guard armed else {
            gain = 1
            holdCounter = 0; eventLen = 0; elevatedHold = 0; latched = false
            return x
        }

        // Ratio test: an instantaneous peak towering over the established background.
        let tripped = peak > clickRatio * slowEnv && peak > minThresholdLin

        // Wall-clock event latch: a trip starts/refreshes an event whose hold bridges
        // sub-pitch-period gaps. The event length is measured in wall-clock samples, so a
        // sustained loud passage (periodic transients) latches off within maxClickMs regardless
        // of its duty cycle, while an isolated click (event shorter than maxClickMs) is fully ducked.
        if tripped { elevatedHold = eventResetSamples }
        if elevatedHold > 0 {
            elevatedHold -= 1
            eventLen += 1
            if eventLen > maxClickSamples { latched = true }
        } else {
            eventLen = 0
            latched = false   // event ended → ready to detect the next genuine click
        }

        let isClick = tripped && !latched

        if isClick {
            gain = gainFloor          // instant attack to floor — the step is masked by the click
            holdCounter = holdSamples // arm the hold
        } else if latched {
            gain = 1                  // sustained content: force unity, no coloration
            holdCounter = 0
        } else if holdCounter > 0 {
            holdCounter -= 1
            // During hold: gain stays at floor.
        } else {
            // Smooth release back to unity (no zipper).
            gain = releaseCoeff * gain + (1 - releaseCoeff) * 1.0
        }

        return x * gain
    }
}
