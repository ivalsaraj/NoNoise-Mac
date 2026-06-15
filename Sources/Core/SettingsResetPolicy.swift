import Foundation

public enum SettingsResetPolicy {
    public static let presetKey = "mv.preset"
    public static let strengthKey = "mv.suppressionStrength"
    public static let attenuationKey = "mv.attenuationLimitDb"
    public static let gainKey = "mv.outputGain"
    public static let voicePolishKey = "mv.voicePolish"
    public static let clarityKey = "mv.clarity"
    public static let mouthNoiseKey = "mv.mouthNoise"
    public static let inputVolumeKey = "mv.inputVolume"
    public static let smartLevelKey = "mv.smartLevel"
    public static let incomingEnabledKey = "mv.incomingEnabled"
    public static let incomingSourceUIDKey = "mv.incomingSourceUID"
    public static let incomingOutputUIDKey = "mv.incomingOutputUID"
    public static let profilesKey = "mv.profiles"
    public static let loudnessNormKey = "mv.loudnessNorm"
    public static let loudnessTargetKey = "mv.loudnessTarget"

    public static let resettableKeys: [String] = [
        presetKey,
        strengthKey,
        attenuationKey,
        gainKey,
        voicePolishKey,
        clarityKey,
        mouthNoiseKey,
        inputVolumeKey,
        smartLevelKey,
        incomingEnabledKey,
        incomingSourceUIDKey,
        incomingOutputUIDKey,
        loudnessNormKey,
        loudnessTargetKey
    ]

    public static func reset(defaults: UserDefaults = .standard) {
        for key in resettableKeys {
            defaults.removeObject(forKey: key)
        }
    }
}
