import Foundation

public struct AudioDenoiseOptions: Equatable {
    public let inputPath: String
    public let outputPath: String
    public let preset: VoicePreset
    public let gain: Float
    public let strength: Float
    public let attenuationDb: Float
    public let shouldOverwrite: Bool

    public init(inputPath: String,
                outputPath: String,
                preset: VoicePreset = .meeting,
                gain: Float = 1.0,
                strength: Float = 1.0,
                attenuationDb: Float = VoicePreset.maxAttenuationDb,
                shouldOverwrite: Bool = false) {
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.preset = preset
        self.gain = gain
        self.strength = strength
        self.attenuationDb = attenuationDb
        self.shouldOverwrite = shouldOverwrite
    }
}

public enum CLIMode: Equatable {
    case help
    case live(input: String, output: String, gain: Float)
    case action(String)
    case denoise(AudioDenoiseOptions)
}

public enum CLIArguments {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingValue(String)
        case unknownOption(String)
        case invalidFloat(String, String)
        case invalidPreset(String)
        case mixedModes
        case missingLiveDevice

        public var description: String {
            switch self {
            case .missingValue(let flag): return "Missing value for \(flag)."
            case .unknownOption(let option): return "Unknown option \(option)."
            case .invalidFloat(let flag, let value): return "Invalid numeric value for \(flag): \(value)."
            case .invalidPreset(let value): return "Unknown preset \(value)."
            case .mixedModes: return "Choose exactly one mode: live device pipeline, --action, or --denoise."
            case .missingLiveDevice: return "Missing --in or --out."
            }
        }
    }

    public static func parse(_ arguments: [String]) throws -> CLIMode {
        var inputName: String?
        var outputName: String?
        var liveGain: Float = 1.0
        var denoiseGainOverride: Float?
        var actionVerb: String?
        var denoiseInput: String?
        var denoiseOutput: String?
        var preset: VoicePreset = .meeting
        var strengthOverride: Float?
        var attenuationDbOverride: Float?
        var shouldOverwrite = false

        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--help", "-h":
                return .help
            case "--in":
                inputName = try value(after: arg, in: arguments, index: &index)
            case "--out":
                outputName = try value(after: arg, in: arguments, index: &index)
            case "--gain":
                let parsedGain = try floatValue(after: arg, in: arguments, index: &index)
                liveGain = parsedGain
                denoiseGainOverride = parsedGain
            case "--action":
                actionVerb = try value(after: arg, in: arguments, index: &index)
            case "--denoise":
                denoiseInput = try value(after: arg, in: arguments, index: &index)
            case "--output":
                denoiseOutput = try value(after: arg, in: arguments, index: &index)
            case "--preset":
                let rawPreset = try value(after: arg, in: arguments, index: &index)
                guard let parsed = VoicePreset.allCases.first(where: { $0.rawValue == rawPreset.lowercased() }) else {
                    throw ParseError.invalidPreset(rawPreset)
                }
                preset = parsed
            case "--strength":
                strengthOverride = try floatValue(after: arg, in: arguments, index: &index)
            case "--attenuation-db":
                attenuationDbOverride = try floatValue(after: arg, in: arguments, index: &index)
            case "--overwrite":
                shouldOverwrite = true
            default:
                throw ParseError.unknownOption(arg)
            }
            index += 1
        }

        let hasLiveMode = inputName != nil || outputName != nil
        let hasActionMode = actionVerb != nil
        let hasDenoiseMode = denoiseInput != nil || denoiseOutput != nil
        if [hasLiveMode, hasActionMode, hasDenoiseMode].filter({ $0 }).count > 1 {
            throw ParseError.mixedModes
        }

        if denoiseOutput != nil, denoiseInput == nil {
            throw ParseError.missingValue("--denoise")
        }

        if let actionVerb { return .action(actionVerb) }
        if let denoiseInput {
            guard let denoiseOutput else { throw ParseError.missingValue("--output") }
            let presetDefaults = preset.parameters ?? (suppressionStrength: Float(1.0),
                                                       attenuationLimitDb: VoicePreset.maxAttenuationDb,
                                                       outputGain: Float(1.0))
            return .denoise(AudioDenoiseOptions(
                inputPath: denoiseInput,
                outputPath: denoiseOutput,
                preset: preset,
                gain: denoiseGainOverride ?? presetDefaults.outputGain,
                strength: strengthOverride ?? presetDefaults.suppressionStrength,
                attenuationDb: attenuationDbOverride ?? presetDefaults.attenuationLimitDb,
                shouldOverwrite: shouldOverwrite
            ))
        }
        guard let inputName, let outputName else { throw ParseError.missingLiveDevice }
        return .live(input: inputName, output: outputName, gain: liveGain)
    }

    private static func value(after flag: String, in arguments: [String], index: inout Int) throws -> String {
        guard index + 1 < arguments.count else { throw ParseError.missingValue(flag) }
        index += 1
        return arguments[index]
    }

    private static func floatValue(after flag: String, in arguments: [String], index: inout Int) throws -> Float {
        let rawValue = try value(after: flag, in: arguments, index: &index)
        guard let value = Float(rawValue) else { throw ParseError.invalidFloat(flag, rawValue) }
        return value
    }
}
