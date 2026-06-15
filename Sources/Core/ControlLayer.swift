import Foundation

// MARK: - ControlAction

/// Every user-facing action the control layer can fire. Pure value type — no AppKit,
/// no Carbon, no AudioModel. Safe to construct from hotkey callbacks, URL opens, or
/// CLI verbs. Lives in Core so the test target can exercise the parsers + reducer.
public enum ControlAction: Equatable, Sendable {
    case toggleAI
    case bypassMomentaryDown   // hotkey held — activate momentary bypass
    case bypassMomentaryUp     // hotkey released — deactivate momentary bypass
    case bypassToggle          // URL/CLI/latching hotkey — flip the latched bypass
    case presetNext
    case presetPrev
    case clarityNext
    case gainUp
    case gainDown

    // Gain nudge + clamp values. These MUST match the Settings → General "Output Gain"
    // slider range (0.5...4.0 in SettingsView.gainCard) so a nudge never lands outside
    // what the slider can show.
    public static let gainStep: Float = 0.1
    public static let gainMin: Float = 0.5
    public static let gainMax: Float = 4.0

    // MARK: URL parsing

    /// Parse a `nonoisemac://` URL into a `ControlAction`. Returns nil for unknown
    /// schemes or verbs so callers can silently ignore unrecognised links.
    public static func from(url: URL) -> ControlAction? {
        guard url.scheme?.lowercased() == "nonoisemac" else { return nil }
        // In custom-scheme URLs the verb is the host; sub-verb is the first path component.
        // e.g. nonoisemac://preset/next → host="preset", sub="next".
        let host = url.host?.lowercased() ?? ""
        let sub = url.pathComponents.dropFirst().first?.lowercased() ?? ""
        switch (host, sub) {
        case ("toggle", _):       return .toggleAI
        case ("bypass", _):       return .bypassToggle
        case ("preset", "next"):  return .presetNext
        case ("preset", "prev"):  return .presetPrev
        case ("clarity", "next"): return .clarityNext
        case ("gain", "up"):      return .gainUp
        case ("gain", "down"):    return .gainDown
        default:                  return nil
        }
    }

    // MARK: CLI verb parsing

    /// Parse a CLI verb string (e.g. "preset-next") into a `ControlAction`.
    public static func from(cliVerb verb: String) -> ControlAction? {
        switch verb.lowercased() {
        case "toggle":       return .toggleAI
        case "bypass":       return .bypassToggle
        case "preset-next":  return .presetNext
        case "preset-prev":  return .presetPrev
        case "clarity-next": return .clarityNext
        case "gain-up":      return .gainUp
        case "gain-down":    return .gainDown
        default:             return nil
        }
    }
}

// MARK: - HotkeyModifier

/// Modifier flags stored in a `HotkeyBinding`. Raw bit values are chosen to match the
/// AppKit `NSEvent.ModifierFlags` device-independent bits (command 1<<20, shift 1<<17,
/// option 1<<19, control 1<<18) so the App-boundary adapter is a no-op cast. Core itself
/// never imports AppKit — the mask is a plain `UInt32`.
public enum HotkeyModifier: UInt32, Sendable {
    case capsLock = 0x010000   // 1 << 16
    case shift    = 0x020000   // 1 << 17
    case control  = 0x040000   // 1 << 18
    case option   = 0x080000   // 1 << 19
    case command  = 0x100000   // 1 << 20
}

// MARK: - HotkeyActionID

/// The set of actions that can have a hotkey. Raw value is the UserDefaults key
/// (under the mv.* namespace to match existing persistence conventions).
public enum HotkeyActionID: String, CaseIterable, Sendable {
    case toggleAI        = "mv.hotkey.toggleAI"
    case bypassMomentary = "mv.hotkey.bypassMomentary"
    case bypassToggle    = "mv.hotkey.bypassToggle"
    case presetNext      = "mv.hotkey.presetNext"
    case presetPrev      = "mv.hotkey.presetPrev"
    case clarityNext     = "mv.hotkey.clarityNext"
    case gainUp          = "mv.hotkey.gainUp"
    case gainDown        = "mv.hotkey.gainDown"

    /// UserDefaults key for this binding.
    public var prefKey: String { rawValue }

    /// Map a Carbon press/release event for this action ID to a `ControlAction`.
    /// Only momentary bypass cares about release; all other actions fire on press only.
    public func action(pressed: Bool) -> ControlAction? {
        switch self {
        case .bypassMomentary:
            return pressed ? .bypassMomentaryDown : .bypassMomentaryUp
        case .toggleAI:     return pressed ? .toggleAI : nil
        case .bypassToggle: return pressed ? .bypassToggle : nil
        case .presetNext:   return pressed ? .presetNext : nil
        case .presetPrev:   return pressed ? .presetPrev : nil
        case .clarityNext:  return pressed ? .clarityNext : nil
        case .gainUp:       return pressed ? .gainUp : nil
        case .gainDown:     return pressed ? .gainDown : nil
        }
    }
}

// MARK: - HotkeyBinding

/// A key-code + modifier mask pair. The modifier mask is a plain `UInt32` (HotkeyModifier
/// bits) — Core does NOT import AppKit. Stored and restored as a compact string
/// "<keyCode>:<modifierMask>" in UserDefaults so there is no JSON/Codable overhead.
public struct HotkeyBinding: Equatable, Sendable {
    /// Virtual key code (Carbon kVK_* constants, e.g. kVK_ANSI_N = 0x2D).
    public let keyCode: UInt32
    /// Modifier mask built from `HotkeyModifier` raw bits (command|shift|option|control).
    public let modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // MARK: Persistence

    /// Compact string encoding: "<keyCode>:<modifierMask>".
    public var encoded: String { "\(keyCode):\(modifiers)" }

    /// Decode from the compact string. Returns nil if malformed.
    public init?(encoded: String) {
        let parts = encoded.split(separator: ":").map(String.init)
        guard parts.count == 2,
              let kc = UInt32(parts[0]),
              let mod = UInt32(parts[1]) else { return nil }
        keyCode = kc
        modifiers = mod
    }

    // MARK: Defaults

    /// Default hotkey bindings. Sane starting combos that avoid common macOS system
    /// shortcuts. All use ⌃⌥ (Control+Option) as the base modifier. Key codes are the
    /// Carbon kVK_ANSI_* virtual key codes (named here as raw hex so Core needs no
    /// Carbon import; HotkeyManager validates them against kVK_* on registration).
    ///
    /// Written to UserDefaults on first launch; never overwritten by an update.
    public static let defaults: [HotkeyActionID: HotkeyBinding] = {
        let ctrlOpt = HotkeyModifier.control.rawValue | HotkeyModifier.option.rawValue
        let ctrlOptShift = ctrlOpt | HotkeyModifier.shift.rawValue
        return [
            // ⌃⌥N — toggle Noise Cancellation        (kVK_ANSI_N = 0x2D)
            .toggleAI:        HotkeyBinding(keyCode: 0x2D, modifiers: ctrlOpt),
            // ⌃⌥B — momentary bypass (hold for raw)   (kVK_ANSI_B = 0x0B)
            .bypassMomentary: HotkeyBinding(keyCode: 0x0B, modifiers: ctrlOpt),
            // ⌃⌥⇧B — bypass toggle (latching)         (kVK_ANSI_B = 0x0B)
            .bypassToggle:    HotkeyBinding(keyCode: 0x0B, modifiers: ctrlOptShift),
            // ⌃⌥] — next preset                       (kVK_ANSI_RightBracket = 0x1E)
            .presetNext:      HotkeyBinding(keyCode: 0x1E, modifiers: ctrlOpt),
            // ⌃⌥[ — previous preset                   (kVK_ANSI_LeftBracket = 0x21)
            .presetPrev:      HotkeyBinding(keyCode: 0x21, modifiers: ctrlOpt),
            // ⌃⌥C — cycle Broadcast Voice clarity     (kVK_ANSI_C = 0x08)
            .clarityNext:     HotkeyBinding(keyCode: 0x08, modifiers: ctrlOpt),
            // ⌃⌥= — gain up                           (kVK_ANSI_Equal = 0x18)
            .gainUp:          HotkeyBinding(keyCode: 0x18, modifiers: ctrlOpt),
            // ⌃⌥- — gain down                         (kVK_ANSI_Minus = 0x1B)
            .gainDown:        HotkeyBinding(keyCode: 0x1B, modifiers: ctrlOpt),
        ]
    }()
}

// MARK: - ControlState

/// A pure snapshot of the control-layer-relevant state. The App-side adapter reads this
/// from `AudioModel`, runs the reducer, and writes the result back. Bypass fields are
/// session-only (never persisted). `desiredAI` is the user's intended AI on/off ignoring
/// bypass; `effectiveAI` (computed) is what AudioModel.isAIEnabled is set to.
public struct ControlState: Equatable, Sendable {
    public var desiredAI: Bool
    public var isBypassedMomentary: Bool
    public var isBypassedToggle: Bool
    public var preset: VoicePreset
    public var clarity: ClarityLevel
    public var gain: Float

    public init(desiredAI: Bool = true,
                isBypassedMomentary: Bool = false,
                isBypassedToggle: Bool = false,
                preset: VoicePreset = .meeting,
                clarity: ClarityLevel = .off,
                gain: Float = 1.0) {
        self.desiredAI = desiredAI
        self.isBypassedMomentary = isBypassedMomentary
        self.isBypassedToggle = isBypassedToggle
        self.preset = preset
        self.clarity = clarity
        self.gain = gain
    }

    /// Effective bypass = momentary OR latched toggle.
    public var isBypassed: Bool { isBypassedMomentary || isBypassedToggle }

    /// What AudioModel.isAIEnabled should be: desired AI, suppressed while bypassed.
    public var effectiveAI: Bool { desiredAI && !isBypassed }
}

// MARK: - ControlMutation

/// One change the reducer wants applied to `AudioModel`. The adapter applies EXACTLY the
/// emitted mutations — never a blanket write of every field. This is load-bearing because
/// `AudioModel`'s knob `didSet`s have side effects (writing `outputGainValue` flips the active
/// preset to `.custom`; writing `selectedPreset` re-applies the preset's own gain/atten via
/// `applyPreset`). Writing an unchanged field would corrupt preset state. See the context
/// section "Why the reducer returns an explicit mutation list".
public enum ControlMutation: Equatable, Sendable {
    /// Write `AudioModel.isAIEnabled` (the EFFECTIVE value: desired AI suppressed by bypass).
    case setAIEffective(Bool)
    /// Write `AudioModel.selectedPreset`. AudioModel.applyPreset owns the resulting gain/atten/
    /// suppression — the adapter MUST NOT also write gain for a preset change.
    case setPreset(VoicePreset)
    /// Write `AudioModel.clarityLevel` (does NOT flip the preset to `.custom`).
    case setClarity(ClarityLevel)
    /// Write `AudioModel.outputGainValue`. The existing `onKnobChanged()` flip to `.custom` is
    /// the INTENDED behavior for a manual gain nudge (same as dragging the Settings slider).
    case setGain(Float)
}

// MARK: - ControlReducer

/// Pure state transitions for the control layer. The ONLY place the bypass + AI logic
/// lives — `ActionDispatcher` (App) is a thin adapter that reads `ControlState` from
/// `AudioModel`, calls `reduce`, and applies the returned mutations. No AudioModel, no AppKit.
///
/// `reduce` returns BOTH the next state AND the explicit list of `AudioModel` fields that
/// changed. The adapter applies ONLY those mutations (never a blanket field write-back), so an
/// action that doesn't touch gain/preset never re-trips `AudioModel`'s knob `didSet` side
/// effects (which would demote the active preset to `.custom`).
public enum ControlReducer {

    public static func reduce(_ state: ControlState,
                              _ action: ControlAction) -> (state: ControlState, mutations: [ControlMutation]) {
        var s = state
        var mutations: [ControlMutation] = []
        let beforeEffectiveAI = state.effectiveAI

        switch action {
        case .toggleAI:
            // Flip the DESIRED state regardless of bypass. effectiveAI recomputes from it.
            s.desiredAI.toggle()

        case .bypassMomentaryDown:
            s.isBypassedMomentary = true

        case .bypassMomentaryUp:
            s.isBypassedMomentary = false

        case .bypassToggle:
            s.isBypassedToggle.toggle()

        case .presetNext:
            let cases = VoicePreset.allCases
            if let idx = cases.firstIndex(of: s.preset) {
                s.preset = cases[(idx + 1) % cases.count]
                mutations.append(.setPreset(s.preset))
            }

        case .presetPrev:
            let cases = VoicePreset.allCases
            if let idx = cases.firstIndex(of: s.preset) {
                s.preset = cases[(idx - 1 + cases.count) % cases.count]
                mutations.append(.setPreset(s.preset))
            }

        case .clarityNext:
            let cases = ClarityLevel.allCases
            if let idx = cases.firstIndex(of: s.clarity) {
                s.clarity = cases[(idx + 1) % cases.count]
                mutations.append(.setClarity(s.clarity))
            }

        case .gainUp:
            s.gain = min(s.gain + ControlAction.gainStep, ControlAction.gainMax)
            mutations.append(.setGain(s.gain))

        case .gainDown:
            s.gain = max(s.gain - ControlAction.gainStep, ControlAction.gainMin)
            mutations.append(.setGain(s.gain))
        }

        // Emit an effective-AI write ONLY when it actually changed (toggle + bypass actions).
        // This keeps the AI write off the preset/gain path entirely — a preset/clarity/gain
        // action never writes isAIEnabled, and an AI/bypass action never writes preset/gain.
        if s.effectiveAI != beforeEffectiveAI {
            mutations.append(.setAIEffective(s.effectiveAI))
        }
        return (s, mutations)
    }
}
