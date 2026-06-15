# MetalVoice Preset Modes — Implementation Plan

**Goal:** Add user-facing **preset modes** (Meeting / Podcast / Tutorial / Custom) backed by two new DSP intensity controls — **Suppression Strength** (wet/dry mix) and **Attenuation Limit** (max dB the AI may reduce) — so noise cancellation is adaptable per use case (calls, podcasts, screen-recording tutorials) instead of all-or-nothing.

**Architecture:** Add two real-time knobs to `DeepFilterNetDSP` that blend the model's enhanced spectrum against the original (dry) spectrum at the output stage, with a per-bin attenuation floor. Add a `VoicePreset` enum in `Core`. Wire presets + knobs through `AudioModel` (`@Published`, persisted to `UserDefaults`, pushed to the DSP). Surface a preset picker in the menu-bar popover (`ContentView`) and the two sliders in `SettingsView`. No CoreML model changes; no changes to capture/playback routing.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Package Manager, XCTest, CoreML, vDSP/Accelerate.

**Execution location:** All edits and commits go inside `/Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src/`.

---

## Context

After the DSP rewrite (commit `5058bda`), denoising is correct but binary — `isAIEnabled` is on/off with a single `outputGain` slider. For podcasts/tutorials/meetings the user needs to tune *how aggressive* the suppression is.

Two orthogonal intensity controls (both standard in DeepFilterNet / Krisp-class tools):

1. **Suppression Strength** `s ∈ [0,1]` — linear wet/dry blend. `s=1` → fully enhanced (current behavior). `s=0` → original passthrough.
2. **Attenuation Limit** `L` dB — caps how far below the original any bin may be pushed. `L=max` → unlimited (full suppression). `L=24dB` → at most 24 dB of reduction, keeping a natural noise floor (avoids the "gated/underwater" artifact on podcasts).

Presets bundle these two knobs plus `outputGain` into one-click profiles.

### Current code facts (verified)
- `DeepFilterNetDSP.outputGain` is a `public var` (read on render thread, written from main) — `DeepFilterNetDSP.swift:115`. The new knobs follow this exact pattern.
- The **dry** (original) complex spectrum for the current hop is already retained in `rawSpecScratch` (interleaved `[re,im]`, 481 bins, wnorm scale) and is NOT mutated between feature extraction and the output stage — `DeepFilterNetDSP.swift:126`, written in section `3c`.
- The model's **wet** output is read into `realOut[i]`/`imaginaryOut[i]` in the `if isModelLoaded` block (the enhanced-read loop), immediately before the conjugate mirror — `DeepFilterNetDSP.swift:~436-448`.
- `AudioModel.outputGainValue` is `@Published` with a `didSet` that pushes to `dspEngine.outputGain` — `AudioModel.swift:40-44`. It is currently NOT persisted.
- `ContentView` is a 280pt-wide popover with Input/Output pickers and the AI toggle — `ContentView.swift`. `SettingsView` General tab has the Output Gain slider — `SettingsView.swift:25-102`.

### Design decisions
- **Default behavior is preserved.** First launch defaults to the **Meeting** preset (`strength=1.0`, `atten=max`, `gain=1.0`) — identical to today's full-suppression output. No regression for existing users.
- **Presets set all three values** (`strength`, `attenuationLimitDb`, `outputGain`) so a mode is a complete profile. Moving any slider flips the active preset to **Custom** (no values are reset).
- **Preset values are tunable starting points** (documented as such), since perceptual tuning needs listening:

  | Preset | strength | attenuationLimitDb | outputGain | rationale |
  |---|---|---|---|---|
  | Meeting | 1.0 | `maxAttenuationDb` (unlimited) | 1.0 | Maximum noise removal for calls |
  | Podcast | 1.0 | 24 | 1.0 | Strong but natural — keeps a low floor so voice stays warm |
  | Tutorial | 1.0 | `maxAttenuationDb` (unlimited) | 1.2 | Clean + makeup gain for loud, clear screen recordings |
  | Custom | (kept) | (kept) | (kept) | Whatever the user dialed in |

- **Threading:** the two knobs are plain `var Float` on the DSP, written from the main thread, read on the render thread — identical to the existing `outputGain`. 32-bit aligned scalar loads/stores are atomic on arm64; this matches the established pattern and needs no lock.
- **No magic numbers:** `maxAttenuationDb`, `minAttenuationDb` live as named `static let`s on `VoicePreset`. The dB→gain math and the per-bin blend live in tested `static` helpers on `DeepFilterNetDSP`.

---

## Task 1: DSP intensity knobs + testable helpers + output blend — TDD

Add the two knobs and two pure `static` helpers (so the math is unit-testable without the CoreML model), then wire the helpers into the output stage.

**Files:**
- Modify: `MetalVoice-src/Sources/Core/AudioProcessing/DeepFilterNetDSP.swift`
- Modify: `MetalVoice-src/Tests/MetalVoiceTests/MetalVoiceDSPTests.swift`

**Step 1: Add knobs + named constants + static helpers**

In `DeepFilterNetDSP`, next to `public var outputGain` (line 115), add:

```swift
    /// Wet/dry mix for the enhanced spectrum. 1.0 = fully enhanced (default),
    /// 0.0 = original passthrough. Read on the render thread, written from main
    /// (same pattern as `outputGain`).
    public var suppressionStrength: Float = 1.0

    /// Maximum reduction (in dB) the model may apply to any bin. At
    /// `Self.maxAttenuationLimitDb` the limit is disabled (full suppression).
    public var attenuationLimitDb: Float = DeepFilterNetDSP.maxAttenuationLimitDb

    /// At/above this dB value the attenuation limit is treated as "unlimited"
    /// (minGain = 0 → the model may fully suppress a bin).
    static let maxAttenuationLimitDb: Float = 100.0
```

Add the two pure helpers (place near `makeErbBands`):

```swift
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
```

**Step 2: Wire the helpers into the output stage**

Replace the enhanced-read loop (`DeepFilterNetDSP.swift:~436-442`):

```swift
                for i in 0..<481 {
                    let iNum = NSNumber(value: i)
                    // enhanced is 5D [1,1,1,481,2] — enhanced complex spec.
                    realOut[i]      = enhanced[[zero, zero, zero, iNum, zero] as [NSNumber]].floatValue
                    imaginaryOut[i] = enhanced[[zero, zero, zero, iNum, one]  as [NSNumber]].floatValue
                }
```

with (read wet, blend against dry from `rawSpecScratch`, write back):

```swift
                let strength = suppressionStrength
                let minG = Self.minGain(forAttenuationDb: attenuationLimitDb)
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
                }
```

(The conjugate mirror immediately below is unchanged. `zero`/`one` constants are still used.)

**Step 3: Add failing tests** — append to `MetalVoiceDSPTests`:

```swift
    func testMinGainUnlimitedAtMax() {
        // At/above the max dB sentinel the floor is 0 (full suppression allowed).
        XCTAssertEqual(DeepFilterNetDSP.minGain(forAttenuationDb: DeepFilterNetDSP.maxAttenuationLimitDb), 0)
        XCTAssertEqual(DeepFilterNetDSP.minGain(forAttenuationDb: 200), 0)
    }

    func testMinGainZeroDbIsUnity() {
        // 0 dB limit = no reduction permitted → floor of 1.0.
        XCTAssertEqual(DeepFilterNetDSP.minGain(forAttenuationDb: 0), 1.0, accuracy: 1e-6)
    }

    func testMinGain20Db() {
        XCTAssertEqual(DeepFilterNetDSP.minGain(forAttenuationDb: 20), 0.1, accuracy: 1e-4)
    }

    func testResolveBinDefaultReturnsWetExactly() {
        // Non-negotiable: the default (strength=1, no attenuation floor) must be
        // byte-for-byte identical to the pre-preset path (realOut[i] = enhanced).
        // Assert EXACT equality (no tolerance) and use an extreme dry value to
        // prove the fast path ignores dry entirely and returns the wet untouched.
        let (r, i) = DeepFilterNetDSP.resolveOutputBin(dryR: 12345.6, dryI: -9876.5,
                                                       wetR: 0.1, wetI: 0.05,
                                                       strength: 1.0, minGain: 0.0)
        XCTAssertEqual(r, 0.1)
        XCTAssertEqual(i, 0.05)
    }

    func testResolveBinZeroStrengthReturnsDry() {
        // strength=0 → output equals the dry (original) value (passthrough).
        let (r, i) = DeepFilterNetDSP.resolveOutputBin(dryR: 0.8, dryI: -0.2, wetR: 0.1, wetI: 0.05,
                                                       strength: 0.0, minGain: 0.0)
        XCTAssertEqual(r, 0.8, accuracy: 1e-6)
        XCTAssertEqual(i, -0.2, accuracy: 1e-6)
    }

    func testResolveBinAttenuationFloorRaisesSuppressedBin() {
        // dry magnitude 1.0, wet fully suppressed to ~0, floor = 0.5 (minGain) →
        // output magnitude must be >= 0.5 (the floor), not 0.
        let (r, i) = DeepFilterNetDSP.resolveOutputBin(dryR: 1.0, dryI: 0.0, wetR: 0.0, wetI: 0.0,
                                                       strength: 1.0, minGain: 0.5)
        let mag = (r*r + i*i).squareRoot()
        XCTAssertEqual(mag, 0.5, accuracy: 1e-5)
    }
```

**Step 4: Run tests** — `swift test --filter MetalVoiceDSPTests` (first run FAILS to compile until Step 1/2 land; after edits all PASS).

**Step 5: Build + full test**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift build && swift test
```

Expected: clean build, all tests pass (7 existing + 6 new = 13).

**Step 6: Commit**

```bash
git add Sources/Core/AudioProcessing/DeepFilterNetDSP.swift Tests/MetalVoiceTests/MetalVoiceDSPTests.swift
git commit -m "feat(dsp): add suppression-strength + attenuation-limit output blend"
```

---

## Task 2: `VoicePreset` enum — TDD

**Files:**
- Create: `MetalVoice-src/Sources/Core/VoicePreset.swift`
- Modify: `MetalVoice-src/Tests/MetalVoiceTests/MetalVoiceDSPTests.swift`

**Step 1: Create the enum**

`Sources/Core/VoicePreset.swift`:

```swift
import Foundation

/// User-facing noise-suppression profiles. Each non-custom preset maps to a
/// complete set of DSP parameters; `.custom` carries no parameters (the user's
/// dialed-in values are kept).
public enum VoicePreset: String, CaseIterable, Identifiable, Sendable {
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
        case .tutorial: return (1.0, VoicePreset.maxAttenuationDb, 1.2)
        case .custom:   return nil
        }
    }
}
```

**Step 2: Add tests** — append to `MetalVoiceDSPTests`:

```swift
    func testPresetCustomHasNoParameters() {
        XCTAssertNil(VoicePreset.custom.parameters)
    }

    func testPresetMeetingIsFullSuppressionUnityGain() {
        let p = VoicePreset.meeting.parameters
        XCTAssertEqual(p?.suppressionStrength, 1.0)
        XCTAssertEqual(p?.attenuationLimitDb, VoicePreset.maxAttenuationDb)
        XCTAssertEqual(p?.outputGain, 1.0)
    }

    func testPresetPodcastKeepsNaturalFloor() {
        // Podcast must limit attenuation (natural tone), not run unlimited.
        let p = VoicePreset.podcast.parameters
        XCTAssertNotNil(p)
        XCTAssertLessThan(p!.attenuationLimitDb, VoicePreset.maxAttenuationDb)
    }

    func testPresetTutorialAddsMakeupGain() {
        XCTAssertGreaterThan(VoicePreset.tutorial.parameters!.outputGain, 1.0)
    }

    func testPresetMaxAttenuationMatchesDSPSentinel() {
        // The enum sentinel must equal the DSP sentinel or the limit never disables.
        XCTAssertEqual(VoicePreset.maxAttenuationDb, DeepFilterNetDSP.maxAttenuationLimitDb)
    }
```

**Step 3: Build + test**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift build && swift test
```

Expected: clean build, all tests pass (13 + 5 = 18).

**Step 4: Commit**

```bash
git add Sources/Core/VoicePreset.swift Tests/MetalVoiceTests/MetalVoiceDSPTests.swift
git commit -m "feat(core): add VoicePreset profiles (meeting/podcast/tutorial/custom)"
```

---

## Task 3: Wire presets + knobs through `AudioModel` (with persistence)

**Files:**
- Modify: `MetalVoice-src/Sources/Core/AudioModel.swift`

**Step 1: Add published state + persistence keys**

Near the other `@Published` properties (after `outputGainValue`, `AudioModel.swift:40-44`), add:

```swift
    @Published public var selectedPreset: VoicePreset = .meeting {
        didSet {
            guard !isApplyingPreset else { return }
            applyPreset(selectedPreset)   // no-op for .custom (keeps current knobs)
            persistSettings()             // persist the selection itself — incl. a direct .custom pick
        }
    }

    @Published public var suppressionStrength: Float = 1.0 {
        didSet {
            dspEngine.suppressionStrength = suppressionStrength
            onKnobChanged()
        }
    }

    @Published public var attenuationLimitDb: Float = VoicePreset.maxAttenuationDb {
        didSet {
            dspEngine.attenuationLimitDb = attenuationLimitDb
            onKnobChanged()
        }
    }

    private var isApplyingPreset = false

    private enum PrefKey {
        static let preset = "mv.preset"
        static let strength = "mv.suppressionStrength"
        static let atten = "mv.attenuationLimitDb"
        static let gain = "mv.outputGain"
    }
```

**Step 2: Add preset application, knob-change, persistence, and load helpers**

Add these methods to `AudioModel`:

```swift
    /// Apply a preset's parameters to the live knobs. No-op for `.custom`.
    /// Guarded by `isApplyingPreset` so the knob `didSet`s don't flip the preset
    /// back to `.custom` while we're applying it.
    private func applyPreset(_ preset: VoicePreset) {
        guard let p = preset.parameters else { return }  // .custom keeps current knobs
        let previously = isApplyingPreset
        isApplyingPreset = true
        suppressionStrength = p.suppressionStrength
        attenuationLimitDb = p.attenuationLimitDb
        outputGainValue = p.outputGain
        isApplyingPreset = previously
        // NOTE: persistence is the caller's responsibility (selectedPreset.didSet),
        // so a direct .custom selection — which no-ops here — is still persisted.
    }

    /// Called from any knob `didSet`. When a manual change happens outside of
    /// `applyPreset`, the active preset becomes `.custom`.
    private func onKnobChanged() {
        guard !isApplyingPreset else { return }
        if selectedPreset != .custom {
            isApplyingPreset = true
            selectedPreset = .custom
            isApplyingPreset = false
        }
        persistSettings()
    }

    private func persistSettings() {
        let d = UserDefaults.standard
        d.set(selectedPreset.rawValue, forKey: PrefKey.preset)
        d.set(suppressionStrength, forKey: PrefKey.strength)
        d.set(attenuationLimitDb, forKey: PrefKey.atten)
        d.set(outputGainValue, forKey: PrefKey.gain)
    }

    private func loadSettings() {
        let d = UserDefaults.standard
        guard let raw = d.string(forKey: PrefKey.preset),
              let preset = VoicePreset(rawValue: raw) else {
            // First launch: keep defaults (Meeting) and push them to the DSP.
            applyPreset(.meeting)
            return
        }
        isApplyingPreset = true
        suppressionStrength = d.object(forKey: PrefKey.strength) as? Float ?? 1.0
        attenuationLimitDb = d.object(forKey: PrefKey.atten) as? Float ?? VoicePreset.maxAttenuationDb
        outputGainValue = d.object(forKey: PrefKey.gain) as? Float ?? 1.0
        selectedPreset = preset
        isApplyingPreset = false
        if let p = preset.parameters {  // non-custom: preset is the source of truth
            isApplyingPreset = true
            suppressionStrength = p.suppressionStrength
            attenuationLimitDb = p.attenuationLimitDb
            outputGainValue = p.outputGain
            isApplyingPreset = false
        }
    }
```

> **Why the `isApplyingPreset` flag:** `applyPreset` writes the knob properties, whose `didSet`s call `onKnobChanged()`, which would otherwise flip the preset to `.custom`. The flag suppresses that during programmatic application. `applyPreset(.custom)` is a no-op, so selecting Custom never loops. Persisting a direct `.custom` pick is handled by `selectedPreset.didSet` (which always calls `persistSettings()`), NOT by `applyPreset`.

> **Why `AudioModel` has no unit tests:** `AudioModel.init()` starts an `AVCaptureSession`, builds an `AVAudioEngine`/`AVAudioSourceNode`, and queries CoreAudio devices + mic permission (`AudioModel.swift:116-120`) — side effects that cannot run headless under `swift test`. The pure decision-carrying logic (preset→params, sentinel equality, blend math) IS unit-tested in Tasks 1–2; the `AudioModel` orchestration (guard loop + persistence) is validated by the explicit smoke cases in Task 6 Step 4.

**Step 3: Make `outputGainValue.didSet` flip to Custom too**

`outputGainValue` already pushes to `dspEngine.outputGain`. Add the custom-flip + persist so the gain slider participates:

```swift
    @Published public var outputGainValue: Float = 1.0 {
        didSet {
             dspEngine.outputGain = outputGainValue
             onKnobChanged()
        }
    }
```

**Step 4: Call `loadSettings()` from `init()`**

At the END of `init()` (after `setupPlaybackEngine()`, `AudioModel.swift:120`), add:

```swift
        loadSettings()
```

`dspEngine` is initialized at its property declaration, so it is available; `loadSettings()` pushes the persisted knob values into it.

**Step 5: Build + test**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift build && swift test
```

Expected: clean build, all tests pass.

**Step 6: Commit**

```bash
git add Sources/Core/AudioModel.swift
git commit -m "feat(core): wire presets + suppression knobs through AudioModel with persistence"
```

---

## Task 4: Preset picker in the menu-bar popover

**Files:**
- Modify: `MetalVoice-src/Sources/App/ContentView.swift`

**Step 1: Add a preset picker** — insert between the Status `HStack` and the Devices `VStack` (`ContentView.swift:~62`):

```swift
            // Preset
            VStack(alignment: .leading, spacing: 4) {
                Label("Mode", systemImage: "wand.and.stars")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Picker("", selection: $audioModel.selectedPreset) {
                    ForEach(VoicePreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
            }
```

(`Core` is already imported in `ContentView.swift:3`, so `VoicePreset` resolves.)

**Step 2: Build + visual check**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift build
```

Expected: clean build. The segmented control shows Meeting / Podcast / Tutorial / Custom within the 280pt popover.

**Step 3: Commit**

```bash
git add Sources/App/ContentView.swift
git commit -m "feat(ui): add preset mode picker to menu-bar popover"
```

---

## Task 5: Suppression sliders in Settings

**Files:**
- Modify: `MetalVoice-src/Sources/App/SettingsView.swift`

**Step 1: Add a "Noise Suppression" section** — insert in `GeneralSettingsView` ABOVE the existing "Gain Control Section" (`SettingsView.swift:~39`):

```swift
            // Suppression Section
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Mode", systemImage: "wand.and.stars")
                        .font(.subheadline).fontWeight(.medium)
                    Spacer()
                }
                Picker("", selection: $audioModel.selectedPreset) {
                    ForEach(VoicePreset.allCases) { preset in
                        Text(preset.label).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                // Suppression Strength
                HStack {
                    Text("Suppression Strength").font(.subheadline)
                    Spacer()
                    Text("\(Int(audioModel.suppressionStrength * 100))%")
                        .font(.monospacedDigit(.body)())
                        .foregroundColor(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
                Slider(value: $audioModel.suppressionStrength, in: 0...1).tint(.accentColor)
                Text("How much noise to remove. Lower keeps more of your original sound.")
                    .font(.caption).foregroundColor(.secondary)

                // Attenuation Limit
                HStack {
                    Text("Reduction Limit").font(.subheadline)
                    Spacer()
                    Text(audioModel.attenuationLimitDb >= VoicePreset.maxAttenuationDb
                         ? "Max"
                         : "\(Int(audioModel.attenuationLimitDb)) dB")
                        .font(.monospacedDigit(.body)())
                        .foregroundColor(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
                Slider(value: $audioModel.attenuationLimitDb,
                       in: VoicePreset.minAttenuationDb...VoicePreset.maxAttenuationDb)
                    .tint(.accentColor)
                Text("Caps how much background is removed so your voice keeps a natural tone. Higher = more aggressive.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
```

(`Core` is already imported in `SettingsView.swift:2`.)

**Step 2: Build**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
swift build
```

Expected: clean build.

**Step 3: Commit**

```bash
git add Sources/App/SettingsView.swift
git commit -m "feat(ui): add suppression-strength + reduction-limit sliders to Settings"
```

---

## Task 6: Build, bundle, install, smoke test

**Files:** none (build/release only)

**Step 1: Guard — model file untouched**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
git status --short Resources/DeepFilterNet3_Streaming.mlmodelc
```

Expected: empty.

**Step 2: Full test + release build**

```bash
swift test && swift build -c release
```

Expected: all tests pass; release build succeeds.

**Step 3: Bundle + reinstall in place + re-sign + verify** (App Management TCC blocks removing the top-level bundle, so sync contents in place — the proven approach from commit `5058bda`):

```bash
osascript -e 'quit app "MetalVoice"' 2>/dev/null; sleep 1
./bundle.sh
rsync -a --delete MetalVoice.app/ /Applications/MetalVoice.app/
codesign --force --deep --sign - --entitlements Resources/MetalVoice.entitlements /Applications/MetalVoice.app
shasum -a 256 MetalVoice.app/Contents/MacOS/MetalVoice /Applications/MetalVoice.app/Contents/MacOS/MetalVoice
codesign --verify --deep --strict /Applications/MetalVoice.app && echo "signature OK"
```

Expected: both hashes identical; `signature OK`.

**Step 4: Manual smoke test (user) — covers the AudioModel guard/persistence logic that can't be unit-tested**
1. Launch `/Applications/MetalVoice.app`, AI ON. **Default is Meeting** → audio sounds exactly like the previous build (full suppression, unity gain) — no regression.
2. Popover: switch Mode between Meeting / Podcast / Tutorial — audio character changes (Podcast keeps more natural tone; Tutorial is louder).
3. Settings: drag Suppression Strength or Reduction Limit — Mode flips to **Custom**; effect audible.
4. **Persistence — preset:** pick Podcast, quit, relaunch → still Podcast.
5. **Persistence — custom via slider:** drag a slider (Mode → Custom), quit, relaunch → still Custom with the same slider values.
6. **Persistence — direct Custom pick (the IMPORTANT fix):** with Mode on Meeting, tap **Custom** in the picker WITHOUT moving any slider, quit, relaunch → Mode is still **Custom** (not reverted to Meeting).

---

## Task 7: Update docs

> Docs land in a dedicated final commit (matching this repo's prior plan precedent and keeping each feature commit atomic and revertible). The `AGENTS.md` rules below are the durable contract that prevents future agents from regressing the preset/knob invariants.

**Files:**
- Modify: `MetalVoice-src/AGENTS.md`
- Modify: `MetalVoice-src/README.md`

**Step 1: `AGENTS.md`** — add under DSP invariants:

```markdown
## Presets & intensity knobs
- **Rule**: `DeepFilterNetDSP.suppressionStrength` (wet/dry, 0..1) and `attenuationLimitDb` (max reduction; `>= maxAttenuationLimitDb` disables the floor) are read on the render thread, written from main — same pattern as `outputGain`. Do not add locks.
- **Rule**: the output blend math lives in pure static helpers `minGain(forAttenuationDb:)` and `resolveOutputBin(...)` so it stays unit-testable without the CoreML model. Keep new DSP math in testable statics, not inline-only.
- **Rule**: `VoicePreset` (Core) is the single source of preset values. UI binds to `AudioModel.selectedPreset`; manual knob moves flip it to `.custom` via `onKnobChanged()`. The `isApplyingPreset` flag prevents the apply→didSet→custom feedback loop — never remove it.
- **Rule**: knob + preset state persists in `UserDefaults` under `mv.*` keys; defaults to the Meeting preset (= pre-preset full-suppression behavior).
```

**Step 2: `README.md`** — add a "Modes" line to the Usage Guide (after step 5):

```markdown
6.  **Pick a Mode**: Choose **Meeting** (max noise removal), **Podcast** (natural tone), or **Tutorial** (clean + louder) from the menu bar — or fine-tune **Suppression Strength** and **Reduction Limit** in Settings (Mode becomes **Custom**).
```

**Step 3: Commit**

```bash
cd /Users/valsaraj/Downloads/MetalVoice_v1.1/MetalVoice-src
git add AGENTS.md README.md
git commit -m "docs: document preset modes + suppression knobs"
```

---

## Done criteria

- [ ] Two DSP knobs (`suppressionStrength`, `attenuationLimitDb`) blend wet/dry with an attenuation floor; default (Meeting) is byte-for-byte the current full-suppression behavior.
- [ ] `VoicePreset` enum drives Meeting/Podcast/Tutorial/Custom; manual knob changes flip to Custom.
- [ ] State persists across relaunch (`UserDefaults` `mv.*`).
- [ ] Preset picker in popover + two sliders in Settings.
- [ ] `swift test` passes (18 tests: 7 existing + 6 DSP-blend + 5 preset). `swift build -c release` clean.
- [ ] `git status --short Resources/DeepFilterNet3_Streaming.mlmodelc` empty.
- [ ] App reinstalled in place; hashes match; signature OK.
- [ ] `AGENTS.md` + `README.md` updated.

### Test Inventory
| Task | Test | Asserts |
|---|---|---|
| 1 | `testMinGainUnlimitedAtMax` | dB ≥ max → floor 0 |
| 1 | `testMinGainZeroDbIsUnity` | 0 dB → floor 1.0 |
| 1 | `testMinGain20Db` | 20 dB → ~0.1 |
| 1 | `testResolveBinDefaultReturnsWetExactly` | default (strength 1, no limit) → wet EXACTLY (byte-for-byte, ignores dry) |
| 1 | `testResolveBinZeroStrengthReturnsDry` | strength 0 → dry passthrough |
| 1 | `testResolveBinAttenuationFloorRaisesSuppressedBin` | floor raises a fully-suppressed bin to minGain·dry |
| 2 | `testPresetCustomHasNoParameters` | custom → nil params |
| 2 | `testPresetMeetingIsFullSuppressionUnityGain` | meeting = (1.0, max, 1.0) |
| 2 | `testPresetPodcastKeepsNaturalFloor` | podcast atten < max |
| 2 | `testPresetTutorialAddsMakeupGain` | tutorial gain > 1.0 |
| 2 | `testPresetMaxAttenuationMatchesDSPSentinel` | enum sentinel == DSP sentinel |
