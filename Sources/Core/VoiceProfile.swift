import Foundation

/// A named snapshot of all user-tunable audio settings, saved and recalled as a Voice Profile.
///
/// Schema design: every field beyond the v1 core is declared `var field: Type? = nil` so new
/// profile-captured settings can be added without a migration. The `version` Int enables a
/// breaking migration path if one is ever needed.
///
/// Decoding is tolerant of both unknown keys (future additions ignored silently) and missing optional
/// keys (default to nil). The `VoiceProfile.decoder` is the single point of configuration for both.
///
public struct VoiceProfile: Codable, Identifiable, Equatable, Sendable {

    // MARK: - Schema version

    /// Increment only on a breaking schema change (dropped required field, renamed field).
    /// Optional-field additions never require a version bump.
    public var version: Int = 1

    // MARK: - Identity

    public var id: UUID
    public var name: String

    // MARK: - v1 Core settings (all user-tunable settings as of 2026-06-15)

    public var preset: VoicePreset
    public var suppressionStrength: Float
    public var attenuationLimitDb: Float
    public var outputGainValue: Float
    public var voicePolishEnabled: Bool
    public var clarityLevel: ClarityLevel

    // MARK: - Extension points for in-flight plans

    public var mouthNoiseLevel: MouthNoiseLevel? = nil
    public var inputVolumeValue: Float? = nil
    public var smartLevelEnabled: Bool? = nil
    public var loudnessNormEnabled: Bool? = nil
    public var loudnessTargetLufs: Float? = nil

    // MARK: - Memberwise init (used by tests and AudioModel)

    public init(
        id: UUID = UUID(),
        name: String,
        preset: VoicePreset,
        suppressionStrength: Float,
        attenuationLimitDb: Float,
        outputGainValue: Float,
        voicePolishEnabled: Bool,
        clarityLevel: ClarityLevel,
        mouthNoiseLevel: MouthNoiseLevel? = nil,
        inputVolumeValue: Float? = nil,
        smartLevelEnabled: Bool? = nil,
        loudnessNormEnabled: Bool? = nil,
        loudnessTargetLUFS: Float? = nil
    ) {
        self.id = id
        self.name = name
        self.preset = preset
        self.suppressionStrength = suppressionStrength
        self.attenuationLimitDb = attenuationLimitDb
        self.outputGainValue = outputGainValue
        self.voicePolishEnabled = voicePolishEnabled
        self.clarityLevel = clarityLevel
        self.mouthNoiseLevel = mouthNoiseLevel
        self.inputVolumeValue = inputVolumeValue
        self.smartLevelEnabled = smartLevelEnabled
        self.loudnessNormEnabled = loudnessNormEnabled
        self.loudnessTargetLufs = loudnessTargetLUFS
    }

    // MARK: - Factory

    /// Produce a profile snapshot from Meeting preset defaults. Use when the user saves
    /// their first profile or when no prior settings are available.
    public static func makeDefault(name: String) -> VoiceProfile {
        VoiceProfile(
            name: name,
            preset: .meeting,
            suppressionStrength: 1.0,
            attenuationLimitDb: VoicePreset.maxAttenuationDb,
            outputGainValue: 1.0,
            voicePolishEnabled: true,
            clarityLevel: .off
        )
    }

    // MARK: - Shared encoder / decoder

    /// Single encoder instance. `convertToSnakeCase` produces stable, human-readable JSON keys.
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    /// Single decoder instance. `convertFromSnakeCase` matches the encoder; unknown keys are
    /// silently ignored by Swift's default Codable synthesis, satisfying the extensibility mandate.
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}
