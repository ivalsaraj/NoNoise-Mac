import Foundation
import Accelerate
import CoreML

class DeepFilterNetDSP {
    // Constants
    let sampleRate: Float = 48000.0
    let frameSize: Int = 960
    let hopSize: Int = 480
    let fftSize: Int = 960
    let binCount: Int = 481 // 960/2 + 1

    // DeepFilterNet analysis normalization: spec = wnorm * FFT(window * x).
    // wnorm = 1 / (window_size^2 / (2 * hop)) = 1/960 for these params.
    // spec_buf is fed to the model UN-normalized, so this absolute scale matters.
    let wnorm: Float = (2.0 * 480.0) / (960.0 * 960.0)
    
    // FFT Setup
    private var fftSetup: vDSP_DFT_Setup?
    private var fftSetupInv: vDSP_DFT_Setup?
    
    // Buffers for STFT
    private var inputBuffer: [Float] = [] // Accumulate input
    private var outputBuffer: [Float] = [] // Accumulate output (Overlap-Add)
    
    // Processing Buffers
    private var window: [Float]
    private var realIn: [Float]
    private var imaginaryIn: [Float]
    private var realOut: [Float]
    private var imaginaryOut: [Float]
    
    // AI Model
    private var model: DeepFilterNet3_Streaming?
    private var isModelLoaded = false
    
    // Normalizers
    private var erbNorm: MeanSubNormalizer?            // 32 ERB bands
    private var specUnitNorm: UnitMagNormalizer?       // first 96 complex bins (feat_spec)
    
    // ERB mean normalization, matching DeepFilterNet `band_mean_norm_erb`:
    //   state = x*(1-a) + state*a;  out = (x - state) / 40
    // State is EMA-initialized to linspace(MEAN_NORM_INIT) = linspace(-60, -90).
    class MeanSubNormalizer {
        var mean: [Float]
        let alpha: Float
        let divisor: Float
        let count: Int

        init(initMean: [Float], alpha: Float = 0.99, divisor: Float = 40) {
            self.count = initMean.count
            self.alpha = alpha
            self.divisor = divisor
            self.mean = initMean
        }

        func normalize(_ input: inout [Float]) {
            for i in 0..<count {
                let x = input[i]
                mean[i] = x * (1 - alpha) + mean[i] * alpha
                input[i] = (x - mean[i]) / divisor
            }
        }
    }

    // Complex unit normalization, matching DeepFilterNet `band_unit_norm`:
    //   state = |x|*(1-a) + state*a;  x /= sqrt(state)
    // State is EMA-initialized to linspace(UNIT_NORM_INIT) = linspace(0.001, 0.0001).
    // Input is interleaved [Re0, Im0, Re1, Im1, ...].
    class UnitMagNormalizer {
        var state: [Float]
        let alpha: Float
        let count: Int

        init(initState: [Float], alpha: Float = 0.99) {
            self.count = initState.count
            self.alpha = alpha
            self.state = initState
        }

        func normalize(_ input: inout [Float]) {
            for i in 0..<count {
                let r = input[i*2]
                let im = input[i*2+1]
                let mag = sqrt(r*r + im*im)
                state[i] = mag * (1 - alpha) + state[i] * alpha
                let denom = sqrt(state[i])
                let inv: Float = denom > 0 ? 1.0 / denom : 0
                input[i*2] = r * inv
                input[i*2+1] = im * inv
            }
        }
    }
    
    // Hidden State STORAGE (Flat Float Buffers).
    // NOTE: read from / written to the model via NSNumber. Raw Float16 buffer-pointer
    // access to CoreML *output* arrays (produced on ANE/GPU under computeUnits=.all)
    // can read back as zeros/stale and silenced all output — see AGENTS.md.
    private var h_enc_buf: [Float]
    private var h_erb_buf: [Float]
    private var h_df_buf: [Float]
    
    // Debug Counter
    private var frameCount: Int = 0
    
    // Ring buffers for ML feature history (O(chunk.count) per append; chunk is 962, capacity 9620)
    private let specHistory = SpecHistoryRingBuffer(capacity: 9620)
    private let erbHistory = SpecHistoryRingBuffer(capacity: 320)
    private let featSpecHistory = SpecHistoryRingBuffer(capacity: 1920)
    
    // ERB band sizes (contiguous, non-overlapping; sums to 481), like libDF erb_fb.
    private var erbBands: [Int] = []
    
    // Parameters
    public var outputGain: Float = 1.0 // User adjustable gain

    /// Wet/dry mix for the enhanced spectrum. 1.0 = fully enhanced (default),
    /// 0.0 = original passthrough. Read on the render thread, written from main
    /// (same pattern as `outputGain`).
    public var suppressionStrength: Float = 1.0

    /// Maximum reduction (in dB) the model may apply to any bin. At/above
    /// `Self.maxAttenuationLimitDb` the limit is disabled (full suppression).
    public var attenuationLimitDb: Float = DeepFilterNetDSP.maxAttenuationLimitDb

    /// Smoothed "AI working hard" signal in [0, 1] — the energy-weighted average
    /// per-bin suppression applied last hop, one-pole smoothed. Written on the DSP
    /// thread, read from main (lock-free scalar; atomic on arm64 — same pattern as
    /// `outputGain`). UX hint only; NOT a model-quality guarantee.
    public var aiActivity: Float = 0

    /// At/above this dB value the attenuation limit is treated as "unlimited"
    /// (minGain = 0 → the model may fully suppress a bin).
    static let maxAttenuationLimitDb: Float = 100.0
    
    // OLA Accumulator (Strict Alignment)
    private var olaBuffer: [Float] = []

    // Pre-allocated scratch (reused every hop; never realloc in hot path).
    // The empty default + init() allocation lets us allocate them before
    // any other use of `self`.
    private var windowedInput: [Float] = []
    private var magSqScratch: [Float] = []
    private var erbFeatScratch: [Float] = []
    private var rawSpecScratch: [Float] = []   // interleaved raw complex spec (481*2), for spec_buf
    private var recoveredRealScratch: [Float] = []
    private var recoveredImagScratch: [Float] = []
    private var specScratch: [Float] = []
    private var erbScratch: [Float] = []
    private var featScratch: [Float] = []
    private var featSliceScratch: [Float] = []  // holds first 96 complex bins of fullCompressed
    private var zeroHopScratch: [Float] = []    // reusable zero buffer of size `hopSize` for OLA tail-fill

    // Pre-allocated input MLMultiArrays (allocated once, rewritten in-place each hop).
    // `MLMultiArray` is a class, so `let` is fine — and required here so we can
    // allocate at init() time.
    private let specBufIn: MLMultiArray
    private let erbBufIn: MLMultiArray
    private let featSpecBufIn: MLMultiArray
    private let hEncIn: MLMultiArray
    private let hErbIn: MLMultiArray
    private let hDfIn: MLMultiArray
    
    init() {
        // ===== allocate all stored properties first (before any `self` use) =====
        h_enc_buf = [Float](repeating: 0, count: 256)
        h_erb_buf = [Float](repeating: 0, count: 2 * 256)
        h_df_buf = [Float](repeating: 0, count: 2 * 256)

        // Pre-allocate reusable hop scratch
        windowedInput = [Float](repeating: 0, count: frameSize)
        magSqScratch = [Float](repeating: 0, count: 481)
        erbFeatScratch = [Float](repeating: 0, count: 32)
        rawSpecScratch = [Float](repeating: 0, count: 481 * 2)
        recoveredRealScratch = [Float](repeating: 0, count: frameSize)
        recoveredImagScratch = [Float](repeating: 0, count: frameSize)
        specScratch = [Float](repeating: 0, count: 9620)
        erbScratch = [Float](repeating: 0, count: 320)
        featScratch = [Float](repeating: 0, count: 1920)
        featSliceScratch = [Float](repeating: 0, count: 192)
        zeroHopScratch = [Float](repeating: 0, count: hopSize)

        // Pre-allocate input MLMultiArrays. Shapes are constants; `try!` is safe.
        specBufIn = try! MLMultiArray(shape: [1, 1, 10, 481, 2], dataType: .float32)
        erbBufIn = try! MLMultiArray(shape: [1, 1, 10, 32], dataType: .float32)
        featSpecBufIn = try! MLMultiArray(shape: [1, 1, 10, 96, 2], dataType: .float32)
        hEncIn = try! MLMultiArray(shape: [1, 1, 256], dataType: .float16)
        hErbIn = try! MLMultiArray(shape: [1, 2, 256], dataType: .float16)
        hDfIn = try! MLMultiArray(shape: [1, 2, 256], dataType: .float16)

        // ===== FFT, window, filterbank, normalizers =====
        fftSetup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(frameSize), vDSP_DFT_Direction.FORWARD)
        fftSetupInv = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(frameSize), vDSP_DFT_Direction.INVERSE)
        
        // Vorbis window (DeepFilterNet): w[n] = sin(π/2 · sin²(π·(n+0.5)/N)).
        // Used for BOTH analysis and synthesis; satisfies w²(n)+w²(n+N/2)=1 at
        // 50% overlap (Princen-Bradley), so overlap-add is unity-gain.
        window = [Float](repeating: 0, count: frameSize)
        let halfN = Float(fftSize) / 2.0
        for i in 0..<frameSize {
            let s = sinf(0.5 * Float.pi * (Float(i) + 0.5) / halfN)
            window[i] = sinf(0.5 * Float.pi * s * s)
        }
        
        // Allocate Scratch (Must be before method calls)
        realIn = [Float](repeating: 0, count: frameSize)
        imaginaryIn = [Float](repeating: 0, count: frameSize)
        realOut = [Float](repeating: 0, count: frameSize)
        imaginaryOut = [Float](repeating: 0, count: frameSize)
        
        // Init ERB band partition (contiguous, like libDF erb_fb)
        initErbBands()
        
        // Init OLA Buffer
        olaBuffer = [Float](repeating: 0, count: frameSize)
        
        // Init Normalizers with DeepFilterNet's EMA state initialization.
        // ERB mean: linspace(-60, -90) over 32 bands.
        var erbInit = [Float](repeating: 0, count: 32)
        for i in 0..<32 { erbInit[i] = -60.0 + Float(i) * ((-90.0) - (-60.0)) / Float(32 - 1) }
        erbNorm = MeanSubNormalizer(initMean: erbInit)
        // Unit-norm state: linspace(0.001, 0.0001) over 96 complex bins.
        var unitInit = [Float](repeating: 0, count: 96)
        for i in 0..<96 { unitInit[i] = 0.001 + Float(i) * (0.0001 - 0.001) / Float(96 - 1) }
        specUnitNorm = UnitMagNormalizer(initState: unitInit)

        // ===== async model load =====
        Task {
            do {
                let config = MLModelConfiguration()
                config.computeUnits = .all // Use Neural Engine
                self.model = try await DeepFilterNet3_Streaming.load(configuration: config)
                self.initHiddenStates()
                self.isModelLoaded = true
                print("DSP: DFN3 Model Loaded")
            } catch {
                print("DSP: Model Load Error: \(error)")
            }
        }
    }
    
    deinit {
        if let setup = fftSetup { vDSP_DFT_DestroySetup(setup) }
        if let setupInv = fftSetupInv { vDSP_DFT_DestroySetup(setupInv) }
    }
    
    func initErbBands() {
        // Contiguous, non-overlapping ERB band partition matching libDF `erb_fb`.
        // Returns the number of FFT bins assigned to each of the 32 bands; the
        // sizes sum to 481. ERB feature for a band = mean power over its bins.
        erbBands = Self.makeErbBands(sr: Int(sampleRate), fftSize: fftSize, nbBands: 32, minNbFreqs: 2)
    }

    // Glasberg-Moore ERB scale, matching libDF freq2erb / erb2freq.
    static func makeErbBands(sr: Int, fftSize: Int, nbBands: Int, minNbFreqs: Int) -> [Int] {
        func freq2erb(_ f: Float) -> Float { 9.265 * log1pf(f / (24.7 * 9.265)) }
        func erb2freq(_ e: Float) -> Float { 24.7 * 9.265 * (expf(e / 9.265) - 1.0) }

        let freqWidth = Float(sr) / Float(fftSize)
        let erbLow = freq2erb(0)
        let erbHigh = freq2erb(Float(sr / 2))
        let step = (erbHigh - erbLow) / Float(nbBands)

        var bands = [Int](repeating: 0, count: nbBands)
        var prevFreq = 0
        var freqOver = 0
        for i in 1...nbBands {
            let f = erb2freq(erbLow + Float(i) * step)
            let fb = Int((f / freqWidth).rounded())
            var nbFreqs = fb - prevFreq - freqOver
            if nbFreqs < minNbFreqs {
                freqOver = minNbFreqs - nbFreqs
                nbFreqs = minNbFreqs
            } else {
                freqOver = 0
            }
            bands[i - 1] = nbFreqs
            prevFreq = fb
        }
        bands[nbBands - 1] += 1 // account for the Nyquist bin (N/2 + 1 total)
        let tooLarge = bands.reduce(0, +) - (fftSize / 2 + 1)
        if tooLarge > 0 { bands[nbBands - 1] -= tooLarge }
        return bands
    }

    /// Convert an attenuation-limit dB value to a linear minimum-gain floor.
    /// Returns 0 when the limit is "unlimited" (>= maxAttenuationLimitDb), so a
    /// bin may be fully suppressed. Otherwise 10^(-dB/20), clamped to [0, 1].
    static func minGain(forAttenuationDb dB: Float) -> Float {
        if dB >= maxAttenuationLimitDb { return 0 }
        let g = powf(10.0, -dB / 20.0)
        return min(max(g, 0), 1)
    }

    /// Resolve one output bin from the dry (original) and wet (enhanced) complex
    /// values, applying the attenuation floor to the wet signal, then the
    /// wet/dry mix. `strength` is clamped to [0,1]; `minGain` is the linear floor
    /// from `minGain(forAttenuationDb:)`.
    static func resolveOutputBin(dryR: Float, dryI: Float,
                                 wetR: Float, wetI: Float,
                                 strength: Float, minGain: Float) -> (Float, Float) {
        // Fast path: default full-suppression (strength 1.0, no attenuation
        // floor) returns the enhanced value UNCHANGED — byte-for-byte identical
        // to the pre-preset path (realOut[i] = enhanced[i]). Also skips 2 muls +
        // 1 add per bin in the default case.
        if strength >= 1.0 && minGain <= 0 {
            return (wetR, wetI)
        }
        var wR = wetR
        var wI = wetI
        if minGain > 0 {
            let dryMag = sqrtf(dryR * dryR + dryI * dryI)
            let wetMag = sqrtf(wR * wR + wI * wI)
            let floorMag = dryMag * minGain
            if wetMag < floorMag {
                if wetMag > 1e-12 {
                    let scale = floorMag / wetMag        // raise wet to the floor, keep its phase
                    wR *= scale; wI *= scale
                } else {
                    wR = dryR * minGain; wI = dryI * minGain  // wet ~0 → fall back to dry phase at floor
                }
            }
        }
        let s = min(max(strength, 0), 1)
        return (dryR * (1 - s) + wR * s, dryI * (1 - s) + wI * s)
    }

    /// Per-bin suppression "activity": how much the enhanced (wet) magnitude was
    /// reduced relative to the dry magnitude, clamped to [0, 1]. 0 = no reduction
    /// (or silence / wet ≥ dry), 1 = fully suppressed. Pure → unit-testable.
    static func binActivity(dryMag: Float, wetMag: Float) -> Float {
        guard dryMag > 1e-9 else { return 0 }
        let reduction = 1 - wetMag / dryMag
        return min(max(reduction, 0), 1)
    }
    
    func initHiddenStates() {
        // No-op (handled in init)
    }
    
    // Main Process Block (called by Audio Thread)
    // Needs to be fast.
    func process(input: UnsafePointer<Float>, count: Int, output: UnsafeMutablePointer<Float>) {
        let newSamples = Array(UnsafeBufferPointer(start: input, count: count))
        inputBuffer.append(contentsOf: newSamples)
        
        // 2. Ensure Output Buffer has enough space (pad with silence if needed, though usually we produce as much as we consume)
        // We will pull from `outputBuffer`.
        
        while inputBuffer.count >= frameSize {
            let frameSlice = Array(inputBuffer[0..<frameSize])
            inputBuffer.removeFirst(hopSize)
            processHop(frame: frameSlice)
        }
        
        // 4. Fill Output
        if outputBuffer.count >= count {
            for i in 0..<count {
                output[i] = outputBuffer[i]
            }
            outputBuffer.removeFirst(count)
        } else {
            // Underrun (should not happen if latency logic works, but pad silence)
            let avail = outputBuffer.count
            for i in 0..<avail {
                output[i] = outputBuffer[i]
            }
            for i in avail..<count {
                output[i] = 0
            }
            outputBuffer.removeAll()
        }
    }
    
    private func processHop(frame: [Float]) {
        frameCount += 1
        
        // Analysis Window + Forward FFT (vDSP inout via buffer pointers on stored properties)
        for i in 0..<frameSize { windowedInput[i] = frame[i] }
        windowedInput.withUnsafeMutableBufferPointer { winPtr in
            vDSP_vmul(winPtr.baseAddress!, 1, window, 1, winPtr.baseAddress!, 1, vDSP_Length(frameSize))
            realIn.withUnsafeMutableBufferPointer { realInPtr in
                imaginaryIn.withUnsafeMutableBufferPointer { imagInPtr in
                    realOut.withUnsafeMutableBufferPointer { realOutPtr in
                        imaginaryOut.withUnsafeMutableBufferPointer { imagOutPtr in
                            for i in 0..<frameSize { realInPtr[i] = winPtr[i] }
                            vDSP_vclr(imagInPtr.baseAddress!, 1, vDSP_Length(frameSize))
                            if let setup = fftSetup {
                                vDSP_DFT_Execute(setup, realInPtr.baseAddress!, imagInPtr.baseAddress!, realOutPtr.baseAddress!, imagOutPtr.baseAddress!)
                            }
                        }
                    }
                }
            }
        }
        
        // 3. Feature Extraction (DeepFilterNet-accurate)

        // Apply analysis normalization so the spectrum matches DeepFilterNet's
        // scale: spec = wnorm * FFT(window * x). All downstream features and the
        // raw spec_buf use this scale. Scale the full spectrum (not just 0..481)
        // to preserve conjugate symmetry for the passthrough path while the model
        // is still loading (that path ISTFTs without re-mirroring).
        for i in 0..<frameSize {
            realOut[i] *= wnorm
            imaginaryOut[i] *= wnorm
        }

        // 3a. Power spectrum
        for i in 0..<481 {
            let r = realOut[i]
            let im = imaginaryOut[i]
            magSqScratch[i] = (r * r) + (im * im)
        }

        // 3b. ERB features: contiguous mean-power bands -> 10*log10 -> (x-mean)/40.
        var bcsum = 0
        for b in 0..<32 {
            let bandSize = erbBands[b]
            let k = 1.0 / Float(bandSize)
            var acc: Float = 0
            for j in 0..<bandSize { acc += magSqScratch[bcsum + j] * k }
            bcsum += bandSize
            erbFeatScratch[b] = 10.0 * log10(acc + 1e-10)
        }
        erbNorm?.normalize(&erbFeatScratch)
        erbHistory.append(erbFeatScratch)

        // 3c. Raw complex spec (DeepFilterNet feeds spec_buf UN-normalized).
        for i in 0..<481 {
            rawSpecScratch[i*2]   = realOut[i]
            rawSpecScratch[i*2+1] = imaginaryOut[i]
        }
        specHistory.append(rawSpecScratch)

        // 3d. feat_spec: unit-normalized first 96 complex bins (no compression).
        for i in 0..<96 {
            featSliceScratch[i*2]   = realOut[i]
            featSliceScratch[i*2+1] = imaginaryOut[i]
        }
        specUnitNorm?.normalize(&featSliceScratch)
        featSpecHistory.append(featSliceScratch)
        
        
        // 4. Inference
        if isModelLoaded, let model = model {
            do {
                // MLMultiArrays are pre-allocated in init() and rewritten in-place each hop.
                let specMulti = specBufIn
                let erbMulti = erbBufIn
                let featMulti = featSpecBufIn
                let hEncMulti = hEncIn
                let hErbMulti = hErbIn
                let hDfMulti = hDfIn
                
                // Copy ring-buffer history into capacity-shaped zero-padded scratch,
                // then into the per-hop MLMultiArrays.
                specHistory.copyChronological(into: &specScratch)
                erbHistory.copyChronological(into: &erbScratch)
                featSpecHistory.copyChronological(into: &featScratch)

                specMulti.withUnsafeMutableBufferPointer(ofType: Float.self) { ptr, _ in
                    for i in 0..<min(ptr.count, specScratch.count) { ptr[i] = specScratch[i] }
                }
                erbMulti.withUnsafeMutableBufferPointer(ofType: Float.self) { ptr, _ in
                    for i in 0..<min(ptr.count, erbScratch.count) { ptr[i] = erbScratch[i] }
                }
                featMulti.withUnsafeMutableBufferPointer(ofType: Float.self) { ptr, _ in
                    for i in 0..<min(ptr.count, featScratch.count) { ptr[i] = featScratch[i] }
                }
                
                // Copy States (Float -> Float16 via NSNumber; proven model-I/O path)
                for i in 0..<h_enc_buf.count { hEncMulti[i] = NSNumber(value: h_enc_buf[i]) }
                for i in 0..<h_erb_buf.count { hErbMulti[i] = NSNumber(value: h_erb_buf[i]) }
                for i in 0..<h_df_buf.count { hDfMulti[i] = NSNumber(value: h_df_buf[i]) }
                
                let input = DeepFilterNet3_StreamingInput(spec_buf: specMulti, feat_erb_buf: erbMulti, feat_spec_buf: featMulti, h_enc_in: hEncMulti, h_erb_in: hErbMulti, h_df_in: hDfMulti)
                
                let output = try model.prediction(input: input)
                
                // Copy Back States
                let oEnc = output.h_enc_out
                let oErb = output.h_erb_out
                let oDf = output.h_df_out
                
                // Copy states back via NSNumber (CoreML output arrays — proven path)
                if oEnc.count == h_enc_buf.count {
                    for i in 0..<h_enc_buf.count { h_enc_buf[i] = oEnc[i].floatValue }
                }
                if oErb.count == h_erb_buf.count {
                    for i in 0..<h_erb_buf.count { h_erb_buf[i] = oErb[i].floatValue }
                }
                if oDf.count == h_df_buf.count {
                    for i in 0..<h_df_buf.count { h_df_buf[i] = oDf[i].floatValue }
                }
                
                // enhanced_spec is the RAW enhanced complex spectrum, already in
                // DeepFilterNet's wnorm scale — use it directly. NO de-normalization
                // and NO de-compression (DFN applies neither; doing so attenuated
                // high frequencies and muffled the voice).
                // Read via NSNumber subscript: raw withUnsafeBufferPointer(ofType:
                // Float16) on this ANE/GPU output reads back as zeros (silence). See AGENTS.md.
                let enhanced = output.enhanced_spec
                let zero = NSNumber(value: 0)
                let one = NSNumber(value: 1)

                // Blend the wet (enhanced) spectrum against the dry (original)
                // spectrum held in rawSpecScratch, applying the attenuation floor
                // then the wet/dry mix. Default (strength=1, no limit) returns wet
                // unchanged (see resolveOutputBin fast path) — no regression.
                let strength = suppressionStrength
                let minG = Self.minGain(forAttenuationDb: attenuationLimitDb)
                var actWeightSum: Float = 0     // Σ dryMag (energy weight)
                var actValueSum: Float = 0      // Σ dryMag · binActivity
                for i in 0..<481 {
                    let iNum = NSNumber(value: i)
                    // enhanced is 5D [1,1,1,481,2] — enhanced complex spec (wet).
                    let wetR = enhanced[[zero, zero, zero, iNum, zero] as [NSNumber]].floatValue
                    let wetI = enhanced[[zero, zero, zero, iNum, one]  as [NSNumber]].floatValue
                    let (outR, outI) = Self.resolveOutputBin(
                        dryR: rawSpecScratch[i*2], dryI: rawSpecScratch[i*2 + 1],
                        wetR: wetR, wetI: wetI,
                        strength: strength, minGain: minG)
                    realOut[i] = outR
                    imaginaryOut[i] = outI
                    // AI-activity (telemetry only): energy-weighted per-bin reduction
                    // of the model's enhanced (wet) magnitude vs. the dry magnitude.
                    let dMag = sqrtf(rawSpecScratch[i*2] * rawSpecScratch[i*2] + rawSpecScratch[i*2+1] * rawSpecScratch[i*2+1])
                    let wMag = sqrtf(wetR * wetR + wetI * wetI)
                    let act = Self.binActivity(dryMag: dMag, wetMag: wMag)
                    actWeightSum += dMag
                    actValueSum += dMag * act
                }
                let hopActivity = actWeightSum > 1e-9 ? actValueSum / actWeightSum : 0
                let smooth: Float = 0.85   // one-pole smoothing across hops
                aiActivity = smooth * aiActivity + (1 - smooth) * hopActivity
                
                // Mirror for IFFT (conjugate-symmetric upper half)
                 for i in 1..<480 {
                     realOut[frameSize - i] = realOut[i]
                     imaginaryOut[frameSize - i] = -imaginaryOut[i]
                }
                
            } catch {
                print("DSP: Inference Error: \(error)")
            }
        } else {
            // Model not loaded yet: decay the activity readout toward 0 so the HUD
            // doesn't freeze on a stale "AI working hard" value (telemetry only).
            aiActivity *= 0.85
        }
        
        // 5. ISTFT
        // Wrap the vDSP calls in withUnsafeMutableBufferPointer so the inout
        // pointers reference the class properties' actual storage, not a
        // COW-copied local.
        recoveredRealScratch.withUnsafeMutableBufferPointer { realPtr in
            recoveredImagScratch.withUnsafeMutableBufferPointer { imagPtr in
                if let invSetup = fftSetupInv {
                    vDSP_DFT_Execute(invSetup, realOut, imaginaryOut, realPtr.baseAddress!, imagPtr.baseAddress!)
                }
                vDSP_vmul(realPtr.baseAddress!, 1, window, 1, realPtr.baseAddress!, 1, vDSP_Length(frameSize))
                // No 1/N here: analysis applied wnorm and the inverse DFT is
                // unnormalized, so wnorm * IDFT(DFT(.)) = identity. Vorbis OLA is unity.
                var scale = outputGain
                vDSP_vsmul(realPtr.baseAddress!, 1, &scale, realPtr.baseAddress!, 1, vDSP_Length(frameSize))

                // 6. Overlap-Add into olaBuffer, then emit the head of olaBuffer
                //    (post-OLA) to outputBuffer. The output slice must come from
                //    olaBuffer, not recoveredRealScratch — otherwise overlap from
                //    prior frames is bypassed and OLA continuity breaks.
                olaBuffer.withUnsafeMutableBufferPointer { olaPtr in
                    vDSP_vadd(realPtr.baseAddress!, 1, olaPtr.baseAddress!, 1, olaPtr.baseAddress!, 1, vDSP_Length(frameSize))
                    let readySlice = UnsafeBufferPointer(start: olaPtr.baseAddress, count: hopSize)
                    outputBuffer.append(contentsOf: readySlice)
                }
            }
        }

        // 7. Shift OLA state (in-place memmove + reusable zero fill)
        olaBuffer.removeFirst(hopSize)  // O(N) memmove, no allocation
        olaBuffer.append(contentsOf: zeroHopScratch)  // no allocation (capacity pre-reserved)
    }
}
