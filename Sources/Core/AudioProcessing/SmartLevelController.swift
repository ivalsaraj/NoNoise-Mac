import Foundation
import Accelerate

/// Pure helpers for Input Volume trimming and Smart Level protective adjustments.
/// All logic here is allocation-free friendly and unit-testable without CoreAudio.
public enum SmartLevelController {
    public static let nearCeilingThreshold: Float = 0.98
    public static let clipThreshold: Float = 0.999
    public static let minInputVolume: Float = 0.25
    /// Protective auto-trim may reach the same floor as the manual control (no auto-boost).
    public static let minAutoInputVolume: Float = minInputVolume
    public static let minOutputGain: Float = 0.25
    public static let defaultInputVolume: Float = 1.0
    /// Consecutive hot meter ticks before Smart Level acts (~120 ms at 25 Hz).
    public static let hotTickThreshold: Int = 3

    public static func clampInputVolume(_ volume: Float) -> Float {
        min(max(volume, minInputVolume), 1.0)
    }

    public static func dbToLinear(_ db: Float) -> Float {
        powf(10, db / 20)
    }

    /// Apply pre-DSP input trim in place. No-op at unity.
    public static func applyInputVolume(_ samples: inout [Float], volume: Float) {
        let v = clampInputVolume(volume)
        guard v != 1 else { return }
        var scalar = v
        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            vDSP_vsmul(base, 1, &scalar, base, 1, vDSP_Length(buf.count))
        }
    }

    /// Telemetry captured around the in-place Input Volume trim.
    /// `rawPeak`/`rawClipSamples` describe the physical/source signal (drives the
    /// source-clipping warning); `trimmedPeak`/`trimmedRMS`/`trimmedHotSamples`
    /// describe the signal NoNoise actually processes (drives the input meter + guard).
    public struct InputTelemetry: Equatable {
        public let rawPeak: Float
        public let trimmedPeak: Float
        public let trimmedRMS: Float
        public let rawClipSamples: Int
        public let trimmedHotSamples: Int
    }

    /// Input-side guard contract published by `AudioModel.publishMeterTelemetry()`.
    /// `inputLevel` is the trimmed meter value; the source warning and the trimmed
    /// near-ceiling decision are kept separate so raw source clipping alone never
    /// forces Smart Level to lower a trimmed signal that is already safe.
    public struct InputGuardDecision: Equatable {
        public let inputLevel: Float
        public let isSourceMicClipping: Bool
        public let isInputNearCeiling: Bool
        public let consecutiveTrimmedHotTicks: Int
        public let suggestedInputVolume: Float?
    }

    /// Measure raw source levels, apply Input Volume in place, then measure the trimmed
    /// signal. Allocation-free: scalar loops + an optional in-place vDSP multiply only.
    /// This is the production telemetry seam shared by `AudioModel.captureOutput(...)`.
    public static func applyInputVolumeAndMeasure(_ samples: UnsafeMutablePointer<Float>,
                                                  count: Int, volume: Float) -> InputTelemetry {
        guard count > 0 else {
            return InputTelemetry(rawPeak: 0, trimmedPeak: 0, trimmedRMS: 0,
                                  rawClipSamples: 0, trimmedHotSamples: 0)
        }

        var rawPeak: Float = 0
        var rawClipSamples = 0
        for i in 0..<count {
            let mag = abs(samples[i])
            rawPeak = max(rawPeak, mag)
            if mag >= clipThreshold { rawClipSamples += 1 }
        }

        var scalar = clampInputVolume(volume)
        if scalar != 1 {
            vDSP_vsmul(samples, 1, &scalar, samples, 1, vDSP_Length(count))
        }

        var trimmedPeak: Float = 0
        var trimmedHotSamples = 0
        var sum: Float = 0
        for i in 0..<count {
            let x = samples[i]
            let mag = abs(x)
            trimmedPeak = max(trimmedPeak, mag)
            sum += x * x
            if mag >= nearCeilingThreshold { trimmedHotSamples += 1 }
        }

        return InputTelemetry(rawPeak: rawPeak, trimmedPeak: trimmedPeak,
                              trimmedRMS: sqrt(sum / Float(count)),
                              rawClipSamples: rawClipSamples,
                              trimmedHotSamples: trimmedHotSamples)
    }

    /// Pure mirror of AudioModel's input-side meter + Smart Level decision. Lets the raw
    /// vs trimmed contract be unit-tested without constructing `AudioModel`. UI pacing
    /// (date/rate-limit) stays in `AudioModel.updateSmartLevel()`.
    public static func evaluateInputGuard(telemetry: InputTelemetry,
                                          currentHotTicks: Int,
                                          currentInputVolume: Float,
                                          smartLevelEnabled: Bool) -> InputGuardDecision {
        let sourceClipping = isSourceMicClipping(rawPeak: telemetry.rawPeak,
                                                rawClipSampleCount: telemetry.rawClipSamples)
        let inputNearCeiling = isNearCeiling(telemetry.trimmedPeak)
        let trimmedWasHot = inputNearCeiling || telemetry.trimmedHotSamples > 0
        let nextTicks = advanceHotTicks(current: currentHotTicks, wasHot: trimmedWasHot)

        return InputGuardDecision(
            inputLevel: telemetry.trimmedRMS,
            isSourceMicClipping: sourceClipping,
            isInputNearCeiling: inputNearCeiling,
            consecutiveTrimmedHotTicks: nextTicks,
            suggestedInputVolume: nextInputVolume(
                current: currentInputVolume, hotTicks: nextTicks, enabled: smartLevelEnabled))
    }

    public static func measurePeak(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var peak: Float = 0
        for s in samples { peak = max(peak, abs(s)) }
        return peak
    }

    /// Latch the highest peak seen in the current meter window.
    public static func latchPeak(existing: Float, bufferPeak: Float) -> Float {
        max(existing, bufferPeak)
    }

    public static func isNearCeiling(_ peak: Float) -> Bool {
        peak >= nearCeilingThreshold
    }

    public static func isClipping(_ peak: Float) -> Bool {
        peak >= clipThreshold
    }

    /// Count samples at/above clip threshold in a buffer.
    public static func clipSampleCount(_ samples: [Float]) -> Int {
        samples.reduce(0) { $0 + (abs($1) >= clipThreshold ? 1 : 0) }
    }

    /// Advance a consecutive-hot counter; reset when the window was not hot.
    public static func advanceHotTicks(current: Int, wasHot: Bool) -> Int {
        wasHot ? current + 1 : 0
    }

    /// Reduce Input Volume by ~1 dB when repeatedly hot. Never boosts.
    public static func nextInputVolume(current: Float, hotTicks: Int, enabled: Bool) -> Float? {
        guard enabled, hotTicks >= hotTickThreshold else { return nil }
        let reduced = current * dbToLinear(-1)
        let clamped = max(reduced, minAutoInputVolume)
        guard clamped < current - 1e-6 else { return nil }
        return clamped
    }

    /// Reduce Output Gain when output clips but trimmed input is not repeatedly hot.
    public static func nextOutputGain(current: Float, outputClipTicks: Int, inputHotTicks: Int,
                                      enabled: Bool) -> Float? {
        guard enabled, inputHotTicks < hotTickThreshold, outputClipTicks >= hotTickThreshold else { return nil }
        let reduced = current * dbToLinear(-1)
        let clamped = max(reduced, minOutputGain)
        guard clamped < current - 1e-6 else { return nil }
        return clamped
    }

    /// Mirror UI value into the runtime scalar the capture path reads.
    public static func runtimeInputVolume(for uiValue: Float) -> Float {
        clampInputVolume(uiValue)
    }

    /// Raw-side source clipping: ADC/mic already distorted before NoNoise trim can help.
    public static func isSourceMicClipping(rawPeak: Float, rawClipSampleCount: Int) -> Bool {
        isClipping(rawPeak) || rawClipSampleCount > 0
    }
}
