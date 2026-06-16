import Foundation

/// User-facing noise-suppression profiles. Each non-custom preset maps to a
/// complete set of DSP parameters; `.custom` carries no parameters (the user's
/// dialed-in values are kept).
public enum VoicePreset: String, CaseIterable, Identifiable, Codable, Sendable {
    case meeting
    case podcast
    case tutorial
    case custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .meeting:  return "Meeting"
        case .podcast:  return "Podcast"
        case .tutorial: return "Tutorial"
        case .custom:   return "Custom"
        }
    }

    public var iconName: String {
        switch self {
        case .meeting:  return "person.2.wave.2.fill"
        case .podcast:  return "mic.fill"
        case .tutorial: return "play.rectangle.fill"
        case .custom:   return "slider.horizontal.3"
        }
    }

    public static let maxAttenuationDb: Float = 100.0  // "unlimited" sentinel (matches DSP)
    public static let minAttenuationDb: Float = 6.0

    /// DSP parameters applied when this preset is selected. `nil` for `.custom`.
    /// Values are tunable starting points (perceptual tuning needs listening).
    public var parameters: (suppressionStrength: Float, attenuationLimitDb: Float, outputGain: Float)? {
        switch self {
        case .meeting:  return (1.0, VoicePreset.maxAttenuationDb, 1.0)
        case .podcast:  return (1.0, 24.0, 1.0)
        case .tutorial: return (1.0, 70.0, 1.0)
        case .custom:   return nil
        }
    }

    /// App-level input volume applied when this preset is selected.
    /// `nil` means "leave the user's current input volume unchanged".
    public var defaultInputVolume: Float? {
        switch self {
        case .tutorial: return 0.70
        default:        return nil
        }
    }

    /// Voice-polish chain settings for this preset (independent of `parameters`).
    /// Values are tunable starting points.
    public var voiceChain: VoiceChainSettings {
        switch self {
        case .meeting:
            return .disabled
        case .podcast:
            return VoiceChainSettings(enabled: true, highPassHz: 80, lowShelfHz: 180, lowShelfDb: 2,
                                      highShelfHz: 9000, highShelfDb: 1.5, compThresholdDb: -20, compRatio: 2.5,
                                      compAttackMs: 12, compReleaseMs: 150, compMakeupDb: 3, limiterCeilingDb: -1)
        case .tutorial:
            return VoiceChainSettings(enabled: true, highPassHz: 90, lowShelfHz: 180, lowShelfDb: 0,
                                      highShelfHz: 6000, highShelfDb: 3, compThresholdDb: -18, compRatio: 3,
                                      compAttackMs: 8, compReleaseMs: 120, compMakeupDb: 0, limiterCeilingDb: -0.5)
        case .custom:
            return VoiceChainSettings(enabled: true, highPassHz: 80, lowShelfHz: 180, lowShelfDb: 1.5,
                                      highShelfHz: 8000, highShelfDb: 2, compThresholdDb: -18, compRatio: 2.5,
                                      compAttackMs: 12, compReleaseMs: 150, compMakeupDb: 3, limiterCeilingDb: -1)
        }
    }
}
