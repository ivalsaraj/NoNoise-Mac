import Foundation
import Combine

/// UI-facing live-meter state, published at ~25 Hz **only while a meter view is on screen**
/// (gated via `AudioModel.beginMeterObservation(_:)` / `endMeterObservation(_:)`).
///
/// This is the telemetry-isolation half of the menu-bar performance fix. The high-frequency
/// meter fields live here, NOT on `AudioModel`, so `AudioModel.objectWillChange` no longer fires
/// 25×/sec. That decouples the `MenuBarExtra` Scene/label (which observes `AudioModel`) from the
/// meter stream, so the menu-bar icon stops re-rendering while the popover is closed and the
/// popover/toggle stop competing with a constant invalidation storm.
///
/// `MeterModel` only ever receives ALREADY-SNAPSHOTTED scalar values, copied on the main thread
/// by `AudioModel`'s gated UI-publish loop. It never reads render-thread state and never owns any
/// audio-control decision (Smart Level + loudness normalization stay on `AudioModel`'s always-on
/// control pump). Keep it that way — see `AGENTS.md` "Metering & loudness".
public final class MeterModel: ObservableObject {
    /// Trimmed input RMS (0…~1) — the input needle.
    @Published public var inputLevel: Float = 0
    /// Post-processing output RMS (0…~1) — the output needle.
    @Published public var outputLevel: Float = 0
    /// Smoothed "AI working hard" signal 0…1 (energy-weighted per-bin suppression). UX hint.
    @Published public var aiActivity: Float = 0
    /// Momentary (400 ms) loudness in LUFS — the live needle.
    @Published public var momentaryLUFS: Float = LoudnessMeter.silenceLUFS
    /// Integrated (gated) loudness in LUFS — the headline number.
    @Published public var integratedLUFS: Float = LoudnessMeter.silenceLUFS
    /// Raw (pre-trim) input sample peak.
    @Published public var rawInputPeak: Float = 0
    /// Trimmed (post-trim) input sample peak.
    @Published public var trimmedInputPeak: Float = 0
    /// Output sample peak.
    @Published public var outputPeak: Float = 0
    /// Trimmed input repeatedly near the ceiling ("Input too loud").
    @Published public var isInputNearCeiling: Bool = false
    /// Post-processing output is clipping.
    @Published public var isOutputClipping: Bool = false
    /// Source mic clipping before NoNoise (pre-trim) — software trim cannot repair it.
    @Published public var isSourceMicClipping: Bool = false
    /// Smart Level status message (nil when inactive / cleared).
    @Published public var smartLevelMessage: String?

    public init() {}

    /// Copy a control-pump snapshot into the published fields. Called on the main thread by the
    /// gated UI-publish loop (and once on `beginMeterObservation` to seed a correct first frame).
    func apply(_ s: MeterSnapshot) {
        inputLevel = s.inputLevel
        outputLevel = s.outputLevel
        aiActivity = s.aiActivity
        momentaryLUFS = s.momentaryLUFS
        integratedLUFS = s.integratedLUFS
        rawInputPeak = s.rawInputPeak
        trimmedInputPeak = s.trimmedInputPeak
        outputPeak = s.outputPeak
        isInputNearCeiling = s.isInputNearCeiling
        isOutputClipping = s.isOutputClipping
        isSourceMicClipping = s.isSourceMicClipping
        smartLevelMessage = s.smartLevelMessage
    }
}

/// Plain (non-`@Published`) snapshot of the latest control-pump-derived meter values.
///
/// Written by `AudioModel`'s always-on control pump (main thread), read by the gated UI-publish
/// loop which copies it into `MeterModel`. Keeping it a plain struct — NEVER `@Published` — is
/// load-bearing: the control pump must trigger ZERO SwiftUI invalidation, so it writes here and
/// never touches `MeterModel`. Promoting any field to `@Published` would resurrect the 25 Hz storm.
struct MeterSnapshot {
    var inputLevel: Float = 0
    var outputLevel: Float = 0
    var aiActivity: Float = 0
    var momentaryLUFS: Float = LoudnessMeter.silenceLUFS
    var integratedLUFS: Float = LoudnessMeter.silenceLUFS
    var rawInputPeak: Float = 0
    var trimmedInputPeak: Float = 0
    var outputPeak: Float = 0
    var isInputNearCeiling: Bool = false
    var isOutputClipping: Bool = false
    var isSourceMicClipping: Bool = false
    var smartLevelMessage: String?
}
