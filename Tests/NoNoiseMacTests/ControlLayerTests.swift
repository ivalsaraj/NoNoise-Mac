import XCTest
@testable import Core

/// Tests the PURE control layer: ControlAction parsers, HotkeyBinding persistence,
/// HotkeyActionID defaults, and the ControlReducer state machine (incl. A/B bypass
/// desired-vs-effective AI state). None of this touches AudioModel, so it runs headless.
final class ControlLayerTests: XCTestCase {

    // MARK: - URL parsing

    func testToggleURLParsed() {
        XCTAssertEqual(ControlAction.from(url: URL(string: "nonoisemac://toggle")!), .toggleAI)
    }

    func testBypassURLParsed() {
        XCTAssertEqual(ControlAction.from(url: URL(string: "nonoisemac://bypass")!), .bypassToggle)
    }

    func testPresetNextURLParsed() {
        XCTAssertEqual(ControlAction.from(url: URL(string: "nonoisemac://preset/next")!), .presetNext)
    }

    func testPresetPrevURLParsed() {
        XCTAssertEqual(ControlAction.from(url: URL(string: "nonoisemac://preset/prev")!), .presetPrev)
    }

    func testClarityNextURLParsed() {
        XCTAssertEqual(ControlAction.from(url: URL(string: "nonoisemac://clarity/next")!), .clarityNext)
    }

    func testGainUpURLParsed() {
        XCTAssertEqual(ControlAction.from(url: URL(string: "nonoisemac://gain/up")!), .gainUp)
    }

    func testGainDownURLParsed() {
        XCTAssertEqual(ControlAction.from(url: URL(string: "nonoisemac://gain/down")!), .gainDown)
    }

    func testUnknownURLReturnsNil() {
        XCTAssertNil(ControlAction.from(url: URL(string: "nonoisemac://unknown/verb")!))
    }

    func testWrongSchemeReturnsNil() {
        XCTAssertNil(ControlAction.from(url: URL(string: "https://example.com/toggle")!))
    }

    // MARK: - CLI verb parsing

    func testCLIVerbToggle()       { XCTAssertEqual(ControlAction.from(cliVerb: "toggle"), .toggleAI) }
    func testCLIVerbBypass()       { XCTAssertEqual(ControlAction.from(cliVerb: "bypass"), .bypassToggle) }
    func testCLIVerbPresetNext()   { XCTAssertEqual(ControlAction.from(cliVerb: "preset-next"), .presetNext) }
    func testCLIVerbPresetPrev()   { XCTAssertEqual(ControlAction.from(cliVerb: "preset-prev"), .presetPrev) }
    func testCLIVerbClarityNext()  { XCTAssertEqual(ControlAction.from(cliVerb: "clarity-next"), .clarityNext) }
    func testCLIVerbGainUp()       { XCTAssertEqual(ControlAction.from(cliVerb: "gain-up"), .gainUp) }
    func testCLIVerbGainDown()     { XCTAssertEqual(ControlAction.from(cliVerb: "gain-down"), .gainDown) }
    func testCLIVerbUnknownNil()   { XCTAssertNil(ControlAction.from(cliVerb: "explode")) }

    // MARK: - Gain clamping constants (must match the Settings slider range 0.5...4.0)

    func testGainStepIsPositive() {
        XCTAssertGreaterThan(ControlAction.gainStep, 0)
    }

    func testGainBoundsMatchSlider() {
        XCTAssertEqual(ControlAction.gainMin, 0.5)
        XCTAssertEqual(ControlAction.gainMax, 4.0)
    }

    // MARK: - HotkeyBinding (pure model, plain UInt32 modifier mask)

    /// A binding round-trips through its UserDefaults string representation.
    func testHotkeyBindingRoundTrip() {
        let b = HotkeyBinding(keyCode: 0x00, modifiers: HotkeyModifier.command.rawValue | HotkeyModifier.shift.rawValue)
        let decoded = HotkeyBinding(encoded: b.encoded)
        XCTAssertEqual(decoded?.keyCode, b.keyCode)
        XCTAssertEqual(decoded?.modifiers, b.modifiers)
    }

    /// A binding with no modifiers still round-trips.
    func testHotkeyBindingNoModifiersRoundTrip() {
        let b = HotkeyBinding(keyCode: 0x24, modifiers: 0)
        XCTAssertNotNil(HotkeyBinding(encoded: b.encoded))
    }

    /// Malformed encodings return nil rather than crashing.
    func testHotkeyBindingMalformedReturnsNil() {
        XCTAssertNil(HotkeyBinding(encoded: "not-a-binding"))
        XCTAssertNil(HotkeyBinding(encoded: "12"))
        XCTAssertNil(HotkeyBinding(encoded: "a:b"))
    }

    /// Default bindings cover all registered action IDs and are distinct.
    func testDefaultBindingsExistAndAreDistinct() {
        let defaults = HotkeyBinding.defaults
        for id in HotkeyActionID.allCases {
            XCTAssertNotNil(defaults[id], "missing default for \(id)")
        }
        let combos = defaults.values.map { "\($0.keyCode)-\($0.modifiers)" }
        XCTAssertEqual(Set(combos).count, combos.count, "default hotkey combos must be distinct")
    }

    /// `HotkeyActionID` raw values use the `mv.hotkey.*` namespace.
    func testHotkeyActionIDNamespace() {
        for id in HotkeyActionID.allCases {
            XCTAssertTrue(id.prefKey.hasPrefix("mv.hotkey."), "pref key must be mv.hotkey.*: \(id.prefKey)")
        }
    }

    // MARK: - HotkeyActionID → ControlAction press/release mapping

    /// Momentary bypass press maps to .bypassMomentaryDown; release to .bypassMomentaryUp.
    func testBypassMomentaryPressReleaseMapping() {
        XCTAssertEqual(HotkeyActionID.bypassMomentary.action(pressed: true), .bypassMomentaryDown)
        XCTAssertEqual(HotkeyActionID.bypassMomentary.action(pressed: false), .bypassMomentaryUp)
    }

    /// Non-momentary actions fire only on press; release is ignored (nil).
    func testNonMomentaryFiresOnPressOnly() {
        XCTAssertEqual(HotkeyActionID.toggleAI.action(pressed: true), .toggleAI)
        XCTAssertNil(HotkeyActionID.toggleAI.action(pressed: false))
        XCTAssertEqual(HotkeyActionID.bypassToggle.action(pressed: true), .bypassToggle)
        XCTAssertNil(HotkeyActionID.bypassToggle.action(pressed: false))
    }

    // MARK: - ControlReducer: cycling

    func testPresetNextWraps() {
        var s = ControlState(preset: VoicePreset.allCases.last!)
        s = ControlReducer.reduce(s, .presetNext).state
        XCTAssertEqual(s.preset, VoicePreset.allCases.first!, "cycling past last preset wraps to first")
    }

    func testPresetPrevWraps() {
        var s = ControlState(preset: VoicePreset.allCases.first!)
        s = ControlReducer.reduce(s, .presetPrev).state
        XCTAssertEqual(s.preset, VoicePreset.allCases.last!, "cycling before first preset wraps to last")
    }

    func testClarityNextWraps() {
        var s = ControlState(clarity: ClarityLevel.allCases.last!)
        s = ControlReducer.reduce(s, .clarityNext).state
        XCTAssertEqual(s.clarity, ClarityLevel.allCases.first!, "cycling past last clarity wraps to first")
    }

    // MARK: - ControlReducer: gain clamping (matches the 0.5...4.0 slider)

    func testGainUpClampsToMax() {
        var s = ControlState(gain: 3.95)
        s = ControlReducer.reduce(s, .gainUp).state
        XCTAssertEqual(s.gain, 4.0, accuracy: 0.0001, "gain up clamps to slider max 4.0")
    }

    func testGainDownClampsToMin() {
        var s = ControlState(gain: 0.55)
        s = ControlReducer.reduce(s, .gainDown).state
        XCTAssertEqual(s.gain, 0.5, accuracy: 0.0001, "gain down clamps to slider min 0.5")
    }

    // MARK: - ControlReducer: desired-vs-effective AI under bypass

    /// toggleAI flips both desired and effective AI when NOT bypassed.
    func testToggleAINotBypassed() {
        var s = ControlState(desiredAI: true)
        s = ControlReducer.reduce(s, .toggleAI).state
        XCTAssertFalse(s.desiredAI)
        XCTAssertFalse(s.effectiveAI)
    }

    /// Sequence: bypass↓ → toggleAI → bypass↑. AI must come back OFF (the toggle won),
    /// NOT back ON from the pre-bypass value — this is the state hole the reducer fixes.
    func testBypassDownToggleAIBypassUpHonoursToggle() {
        var s = ControlState(desiredAI: true)
        s = ControlReducer.reduce(s, .bypassMomentaryDown).state
        XCTAssertFalse(s.effectiveAI, "bypass forces effective AI off")
        XCTAssertTrue(s.desiredAI, "desired AI unchanged by bypass")
        s = ControlReducer.reduce(s, .toggleAI).state
        XCTAssertFalse(s.desiredAI, "toggle while bypassed flips desired")
        XCTAssertFalse(s.effectiveAI, "still bypassed, effective stays off")
        s = ControlReducer.reduce(s, .bypassMomentaryUp).state
        XCTAssertFalse(s.effectiveAI, "on bypass exit, effective follows the NEW desired (off)")
        XCTAssertFalse(s.desiredAI)
    }

    /// Sequence: bypass↑ from a clean ON state restores AI ON.
    func testBypassExitRestoresDesired() {
        var s = ControlState(desiredAI: true)
        s = ControlReducer.reduce(s, .bypassToggle).state   // bypass on
        XCTAssertFalse(s.effectiveAI)
        s = ControlReducer.reduce(s, .bypassToggle).state   // bypass off
        XCTAssertTrue(s.effectiveAI, "exiting bypass restores desired AI ON")
    }

    /// Momentary + toggle overlap: effective bypass is the OR; releasing momentary while
    /// toggle is still latched keeps bypass active.
    func testMomentaryAndToggleOverlap() {
        var s = ControlState(desiredAI: true)
        s = ControlReducer.reduce(s, .bypassToggle).state        // toggle latched on
        s = ControlReducer.reduce(s, .bypassMomentaryDown).state // momentary also on
        XCTAssertFalse(s.effectiveAI)
        s = ControlReducer.reduce(s, .bypassMomentaryUp).state   // momentary released
        XCTAssertFalse(s.effectiveAI, "toggle still latched → still bypassed")
        s = ControlReducer.reduce(s, .bypassToggle).state        // toggle off
        XCTAssertTrue(s.effectiveAI, "both released → AI restored")
    }

    /// Bypass toggle then a preset change: preset cycling works while bypassed and does
    /// not disturb bypass.
    func testBypassThenPresetCycle() {
        var s = ControlState(desiredAI: true, preset: VoicePreset.allCases.first!)
        s = ControlReducer.reduce(s, .bypassToggle).state
        s = ControlReducer.reduce(s, .presetNext).state
        XCTAssertEqual(s.preset, VoicePreset.allCases[1])
        XCTAssertFalse(s.effectiveAI, "preset change does not lift bypass")
    }

    // MARK: - ControlReducer: emitted mutations (what the adapter applies — finding #1)

    /// toggleAI emits ONLY .setAIEffective — never .setPreset/.setGain/.setClarity. This is the
    /// guard against the blanket write-back that flipped the active preset to .custom.
    func testToggleAIEmitsOnlyAIEffective() {
        let s = ControlState(desiredAI: true, preset: .meeting, gain: 1.0)
        let (_, mutations) = ControlReducer.reduce(s, .toggleAI)
        XCTAssertEqual(mutations, [.setAIEffective(false)])
        // Critically: no .setPreset and no .setGain in the list.
        XCTAssertFalse(mutations.contains { if case .setPreset = $0 { return true }; return false },
                       "toggleAI must NOT write preset (would demote Meeting → Custom)")
        XCTAssertFalse(mutations.contains { if case .setGain = $0 { return true }; return false },
                       "toggleAI must NOT write gain (gain write trips onKnobChanged → Custom)")
    }

    /// presetNext emits .setPreset with the NEXT preset and NO .setGain — the preset owns its
    /// own gain via AudioModel.applyPreset, so the adapter must not write gain afterward (that
    /// would override the preset gain AND flip to .custom).
    func testPresetNextEmitsSetPresetWithoutGain() {
        let s = ControlState(desiredAI: true, preset: VoicePreset.allCases.first!, gain: 2.0)
        let (next, mutations) = ControlReducer.reduce(s, .presetNext)
        XCTAssertEqual(next.preset, VoicePreset.allCases[1])
        XCTAssertTrue(mutations.contains(.setPreset(VoicePreset.allCases[1])),
                      "presetNext emits .setPreset for the intended preset")
        XCTAssertFalse(mutations.contains { if case .setGain = $0 { return true }; return false },
                       "presetNext must NOT emit .setGain — the preset defines its own gain")
        // effectiveAI did not change (still ON, not bypassed) → no redundant AI write.
        XCTAssertFalse(mutations.contains { if case .setAIEffective = $0 { return true }; return false },
                       "presetNext does not change effective AI, so emits no .setAIEffective")
    }

    /// gainUp emits .setGain — the intended knob behavior (a manual nudge is a custom edit, just
    /// like dragging the Settings slider). AudioModel.outputGainValue.didSet flips to .custom.
    func testGainUpEmitsSetGain() {
        let s = ControlState(gain: 1.0)
        let (next, mutations) = ControlReducer.reduce(s, .gainUp)
        XCTAssertEqual(mutations, [.setGain(next.gain)])
        XCTAssertEqual(next.gain, 1.1, accuracy: 0.0001)
    }

    /// clarityNext emits .setClarity only (clarityLevel.didSet does not call onKnobChanged, so it
    /// never flips the preset).
    func testClarityNextEmitsSetClarity() {
        let s = ControlState(clarity: ClarityLevel.allCases.first!)
        let (next, mutations) = ControlReducer.reduce(s, .clarityNext)
        XCTAssertEqual(mutations, [.setClarity(next.clarity)])
    }

    /// bypassMomentaryDown emits .setAIEffective(false) only — bypass changes effective AI, not
    /// preset/gain/clarity.
    func testBypassDownEmitsOnlyAIEffective() {
        let s = ControlState(desiredAI: true)
        let (_, mutations) = ControlReducer.reduce(s, .bypassMomentaryDown)
        XCTAssertEqual(mutations, [.setAIEffective(false)])
    }
}
