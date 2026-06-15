# NoNoise Mac — Agent Operating Guide

> **Provenance:** NoNoise Mac is a rebrand + AI-native restructuring of the MIT-licensed
> **MetalVoice** project by **Ghostkwebb** (https://github.com/Ghostkwebb/MetalVoice).
> The audio/DSP core is functionally unchanged; this fork adds branding, an AI-native
> knowledge base, an agent catalog, a polished UI, and an on-by-default experience.

This file is the entry point for any AI agent (or human) working in this repo. Read it
first, then the linked knowledge base before touching audio code.

## What this is
NoNoise Mac is a macOS (Apple Silicon) **menu-bar app** that removes background noise and
room reverb from your microphone **in real time, 100% on-device**, using **DeepFilterNet3**
on **CoreML + Metal / Accelerate**. It routes the cleaned voice through a virtual audio
cable so any app (Zoom, Meet, Discord, OBS, …) receives studio-clean audio.

## ICP / Who We Build For
- macOS **Apple-Silicon** users on calls, podcasts, livestreams, and screen recordings who
  need clean voice **without** cloud processing or a subscription.
- **Privacy-conscious** users — no audio ever leaves the machine.
- Creators who want light studio polish (EQ + leveling) without opening a DAW.
- **Not** for: Windows/Linux, Intel Macs, or multi-channel music mastering.

## Architecture map
- `Sources/Core` — engine, no UI:
  - `AudioModel` — CoreAudio/AVFoundation capture + playback, ring buffer, render callback, preset/knob state + persistence.
  - `AudioProcessing/DeepFilterNetDSP` — STFT → DeepFilterNet feature pipeline → CoreML call → ISTFT → wet/dry blend.
  - `AudioProcessing/DeepFilterNet3_Streaming` — generated CoreML model wrapper.
  - `AudioProcessing/VoiceChain` + `Biquad` + `Dynamics` — post-DSP "voice polish" (high-pass → shelves → compressor → limiter) plus the optional **Broadcast Voice** clarity stages (presence peaking bell → subtractive `DeEsser`) and optional **Mouth Noise** finisher stages (subtractive `DePlosive` → broadband-gate `DeClick`). Driven by `ClarityLevel` + `MouthNoiseLevel`, each is gated independently of the noise preset.
  - `AudioProcessing/IncomingCleanupEngine` — a SECOND, independent capture→clean→play pipeline ("clean the other side"). Captures a loopback/aggregate **INPUT** device, runs its OWN `DeepFilterNetDSP` instance (DFN only — **no** `VoiceChain`), plays to the user's monitor output. NOT an `AudioModel` (no mic coupling, no auto-route to the NoNoise Mic sink). Held by `AudioModel` as an OPTIONAL (`IncomingCleanupEngine?`) and created ONLY while enabled. See "Incoming / guest cleanup" below.
  - `AudioProcessing/RingBuffer`, `SpecHistoryRingBuffer`, `AudioUtils` — buffers + helpers.
  - `VoicePreset` — preset → DSP params + voice-chain settings (single source of truth).
- `Sources/App` — SwiftUI menu-bar app: `NoNoiseMacApp`, `ContentView` (popover), `SettingsView`.
- `Sources/CLI` — `NoNoiseMacCLI`, a headless input→output pipeline.
- `Resources` — `DeepFilterNet3_Streaming.mlmodelc`, `AppIcon.icns`, `NoNoiseMacLogo.png`, `Info.plist`, `NoNoiseMac.entitlements`.
- `Tests/NoNoiseMacTests` — pure DSP / preset / voice-chain unit tests (run headless).

## Build, run, test
```bash
swift build                 # debug
swift build -c release --arch arm64  # optimized Apple Silicon release (bundle.sh prerequisite)
swift test                  # 30 pure tests — no mic/CoreML runtime needed
./bundle.sh                 # → NoNoiseMac.app + NoNoiseMacCLI (codesigned w/ entitlements)
./bundle.sh --with-driver   # also builds NoNoiseMic.driver and stages it NEXT TO the app
./install-app.sh            # arm64 release build + bundle + install to /Applications
./install-app.sh --with-driver # same, also stages NoNoiseMic.driver next to the app
```
The virtual mic has its own scripts: `./build-driver.sh`, `sudo ./install-driver.sh`,
`sudo ./uninstall-driver.sh` (see "NoNoise Mic virtual driver" below). The driver is staged as a
sibling of the app, never nested inside the signed `.app`.
Release installs MUST build with `--arch arm64`; NoNoise Mac is Apple-Silicon-only, and release
builds are the optimized path for M-series chips.
The app is a menu-bar utility (`LSUIElement`); **AI noise cancellation is ON by default**
(`AudioModel.isAIEnabled = true`).

## Apple Silicon performance mandate
NoNoise Mac is an always-available menu-bar audio utility for M-series Macs. Every implementation
decision MUST preserve that feel: low CPU, low memory churn, low latency, and no avoidable battery
drain. Optimize for Apple Silicon first (`arm64`, CoreML/Metal/Accelerate where appropriate), and
write high-performance code by default. Never introduce work that can noticeably slow down the
user's Mac, pin the CPU/GPU, allocate in hot paths, poll unnecessarily, or keep hardware active
without a measured reason.

Performance does not outrank correctness, privacy, or audio quality. If a faster approach would
reduce output quality, weaken privacy, or make behavior harder to reason about, do not take it.
Instead, keep the quality bar and find a measured, maintainable optimization. Any non-trivial
performance-sensitive change should be verified with the closest available signal: tests,
Instruments/profiling, allocation checks, or an explicit before/after explanation.

## CI & releases
`.github/workflows/ci.yml` runs on pushes to `main` and pull requests targeting `main`; it only
builds and tests. `.github/workflows/release.yml` automatically updates the `stable` GitHub Release
after CI succeeds on `main`, and also publishes versioned release assets for `v*` tags whose commit
is contained in `origin/main` (or manual dispatch with such a tag). Stable assets use fixed names
(`NoNoiseMac.app.zip`, `NoNoiseMacCLI`, `NoNoiseMic.driver.zip`, `SHA256SUMS`) so the release page
always points at the latest successful `main` build; versioned releases use tag-specific filenames.

## Entitlements & signing
`bundle.sh` codesigns with `Resources/NoNoiseMac.entitlements`, kept **intentionally minimal** —
exactly two keys:
- `com.apple.security.device.audio-input` — the app captures the microphone.
- `com.apple.security.cs.allow-jit` — required by the CoreML/Metal backend: DeepFilterNet3 runs on
  the GPU/Neural Engine and Metal shader compilation JITs under the hardened runtime, so removing
  this can break model inference at runtime.

Do not add entitlements beyond these two without a measured, documented need.

## Branding & identifier conventions (do not regress)
- Display name: **NoNoise Mac**. Code identifier: **NoNoiseMac** (executable, SwiftPM
  package + targets, class prefix, asset filenames). Bundle id: **com.ivalsaraj.NoNoiseMac**.
  CLI binary: **NoNoiseMacCLI**.
- The old names **MetalVoice / Ghostkwebb** may appear **only** in credit/provenance:
  `README.md` credits, `LICENSE` original copyright, this provenance note, and `docs/`
  history. **Never** in `Sources/`, `Package.swift`, `Resources/`, `bundle.sh`,
  `CONCEPTS.md`, `CONTRIBUTING.md`, or `.github/`.
- Internal `UserDefaults` keys use the legacy `mv.*` namespace — they are invisible to users
  and intentionally left unchanged to avoid migration churn. Do not "rebrand" them.

## Agent store & knowledge base (AI-native)
- **Agent catalog** — who to invoke for what: [`docs/agents/README.md`](docs/agents/README.md).
- **Compounding knowledge** — gotchas, decisions, timeline: [`docs/knowledge/INDEX.md`](docs/knowledge/INDEX.md).
- **Domain glossary**: [`CONCEPTS.md`](CONCEPTS.md).
- ⚠️ Read [`docs/knowledge/critical-patterns.md`](docs/knowledge/critical-patterns.md)
  **before** modifying the CoreML call or the render thread — both have shipped-and-broke
  failure modes.

---

## DSP architecture invariants
- The CoreML model is **stock DeepFilterNet3** (sr 48000, fft 960, hop 480, 481 bins, 32 ERB bands, nb_df 96). The caller MUST reproduce libDF's feature pipeline exactly (`libDF/src/lib.rs` / `transforms.rs`). The three model inputs map to DFN's `spec` / `feat_erb` / `feat_spec`:
  - **spec_buf** = RAW complex spectrum `wnorm * FFT(window * x)`, `wnorm = 1/960`, **un-normalized, no compression**. Absolute scale matters — it is fed raw.
  - **feat_erb** = contiguous mean-power ERB bands (`erb_fb` partition, `k = 1/band_size`) → `10*log10(p + 1e-10)` → `(x - mean)/40`, mean EMA init `linspace(-60, -90, 32)`.
  - **feat_spec** = first 96 complex bins, unit-normed `x / sqrt(state)`, state EMA init `linspace(0.001, 0.0001, 96)`. **No power compression** anywhere.
  - **window** = Vorbis `sin(π/2 · sin²(π(n+0.5)/N))` for both analysis & synthesis (Princen-Bradley → unity OLA).
  - **enhanced_spec output** = RAW enhanced complex spec in the same wnorm scale → ISTFT directly. **Do NOT de-normalize or de-compress** the output (doing so attenuates highs and muffles the voice). Synthesis uses NO `1/N` (analysis `wnorm` + unnormalized inverse DFT already give unity).
  - There is **no spectral compression exponent** in DFN's feature path. A prior reimplementation invented one (`c=0.5/0.6`) plus an output de-normalization; both were bugs that muffled speech. Don't reintroduce them.
- **CoreML I/O dtype boundary — READ THIS BEFORE TOUCHING THE MODEL CALL:**
  - The model runs `computeUnits = .all` (Neural Engine / GPU). Its outputs (`enhanced_spec`, `h_enc_out`, `h_erb_out`, `h_df_out`) are Float16 `MLMultiArray`s produced off-CPU.
  - **NEVER read those output arrays with raw `withUnsafeBufferPointer(ofType: Float16.self)`.** On ANE/GPU outputs this reads back as **zeros** → `realOut`/`imaginaryOut` go silent → **the app produces no audio when AI is on**. This actually shipped and broke playback. Read outputs via the `NSNumber` subscript (`enhanced[[...] as [NSNumber]].floatValue`, `oEnc[i].floatValue`) which forces correct CPU materialization.
  - Writing to **input** arrays we allocate ourselves (`specBufIn`, `erbBufIn`, `featSpecBufIn`) via `withUnsafeMutableBufferPointer(ofType: Float.self)` IS safe — those are plain CPU-backed buffers. Hidden-state inputs (`hEncIn`/`hErbIn`/`hDfIn`, `.float16`) are written via `NSNumber(value:)`.
  - Bottom line: buffer pointers are fine for arrays WE allocate and fill; `NSNumber` is mandatory for arrays the MODEL fills.
- `Sources/Core/AudioProcessing/DeepFilterNet3_Streaming.swift` is generated, but its unused
  `MLShapedArray<Float16>` conveniences are intentionally gated behind `#if compiler(>=6.0)`.
  GitHub Actions currently builds with Swift 5.10, where that Float16 conformance is unavailable on
  macOS. If the wrapper is regenerated, preserve the gate or remove the shaped-array conveniences.
- Hidden state (`h_enc_buf`, `h_erb_buf`, `h_df_buf`) is stored as `[Float]` and bridged to/from the model via `NSNumber`. Do not "optimize" to `[Float16]` + raw buffer reads — the read-back comes from a model output array (see above).

## Real-time audio rules
- `processHop` runs on the AVAudioEngine render thread. **No avoidable heap allocations in `processHop`**: all hop-local scratch (`windowedInput`, `magSqScratch`, `erbFeatScratch`, `rawSpecScratch`, `recoveredRealScratch`, `recoveredImagScratch`, `featSliceScratch`, `zeroHopScratch`) and all input `MLMultiArray`s (`specBufIn`, `erbBufIn`, `featSpecBufIn`, `hEncIn`, `hErbIn`, `hDfIn`) are stored on the class and pre-allocated in `init()`. **Mutate them directly** (e.g. `magSqScratch[i] = ...`) — do NOT bind them to a local `let`/`var` first; Swift arrays COW-copy on first mutation through a local binding, defeating the purpose. For vDSP-style inout pointer APIs (`vDSP_DFT_Execute`, `vDSP_vmul`, `vDSP_vsmul`, `vDSP_vadd`), use `withUnsafeMutableBufferPointer` on the stored property and pass `baseAddress!`.
- All ML feature history (spec / erb / feat-spec) goes through `SpecHistoryRingBuffer` — never use Swift `Array.removeFirst` on a long-lived feature buffer.
- `process(input:count:output:)` (the outer entry point, not `processHop`) **does** still allocate an `Array(...)` for the input chunk. That is acceptable; the render callback runs on a background queue and the cost is bounded by `count`. Do not "fix" this without first measuring.
- The ML model produces **fresh** output `MLMultiArray`s each prediction (CoreML's API contract). Only the *input* `MLMultiArray`s are pre-allocated and reused; output arrays are not.
- Pre-allocated `MLMultiArray`s are safe to reuse because `prediction(input:)` is synchronous and the DSP is single-threaded.

## Presets & intensity knobs
- `DeepFilterNetDSP.suppressionStrength` (wet/dry mix, 0..1) and `attenuationLimitDb` (max reduction; `>= maxAttenuationLimitDb` disables the floor) are read on the render thread, written from main — **same plain-`var Float` pattern as `outputGain`**. Do NOT add locks; 32-bit aligned scalar stores/loads are atomic on arm64.
- The output blend lives in pure static helpers `minGain(forAttenuationDb:)` and `resolveOutputBin(...)` so the math is unit-testable WITHOUT the CoreML model. The default case (`strength >= 1 && minGain <= 0`) takes a fast path returning the enhanced value unchanged — this keeps the default **byte-for-byte identical** to the pre-preset output. Keep new DSP math in testable statics, not inline-only.
- The blend reads the dry spectrum from `rawSpecScratch` (the raw wnorm-scaled complex spec retained in feature extraction). Wet (`enhanced`) and dry are in the SAME wnorm domain — do not blend across scales.
- `VoicePreset` (Core) is the single source of preset values; `maxAttenuationDb` MUST equal `DeepFilterNetDSP.maxAttenuationLimitDb` (a test enforces this). UI binds to `AudioModel.selectedPreset`; manual knob moves flip it to `.custom` via `onKnobChanged()`. The `isApplyingPreset` flag prevents the apply→didSet→custom feedback loop — never remove it. A direct `.custom` selection is persisted by `selectedPreset.didSet` (NOT `applyPreset`).
- Preset + knob state persists in `UserDefaults` under `mv.*` keys; first launch defaults to the Meeting preset (= pre-preset full-suppression behavior). `AudioModel` itself is not unit-tested (its `init()` starts CoreAudio/AVFoundation) — the pure logic is unit-tested and the orchestration is smoke-tested.

## Voice polish chain (Tier 2)
- `VoiceChain` (Core/AudioProcessing) runs AFTER `DeepFilterNetDSP` on the time-domain output, inside `AudioModel`'s render callback, only when `isAIEnabled`. Order: high-pass → low-shelf → high-shelf → **presence (peaking bell) → de-esser → de-plosive → de-click** → compressor → limiter. The Limiter is last and hard-clamps to the ceiling — it is the final overflow guard.
- Built from pure, unit-tested value types: `Biquad` (RBJ cookbook coefficients, TDF-II), `Compressor` (log-domain feed-forward), `Limiter` (fast peak + hard clamp). Keep all DSP math here, testable, with no CoreML dependency.
- **Real-time rule**: `VoiceChain.process` is allocation-free and per-sample; `configure(_:)` (coefficient recompute) runs on main only. State (`Biquad.z1/z2` for the high-pass, shelves, and presence bell; `Compressor.envDb`; `Limiter.gain`; `DeEsser` envelope + HP state; `DePlosive` envelope pair + HP state; `DeClick` fast/slow envelopes, gain, hold counter) carries across render buffers — never reset per buffer. `configure` resets state in exactly three cases: FULL reset on inactive→active (clean start); clarity-stages-only reset (`presence` + `DeEsser`) when `ClarityLevel` changes while active; mouth-noise-stages-only reset (`DePlosive` + `DeClick`) when `MouthNoiseLevel` changes while active. All other active→active switches are intentionally bumpless.
- Chain params are a pure function of `VoicePreset.voiceChain` (NOT persisted per-stage) plus the orthogonal **Broadcast Voice** `ClarityLevel` and **Mouth Noise** `MouthNoiseLevel`. The chain runs when `(voicePolishEnabled && preset.voiceChain.enabled) || clarity != .off || mouthNoise != .off`. Meeting polish = off; Podcast/Tutorial/Custom = on; Broadcast Voice (presence + de-esser) and Mouth Noise (de-plosive + de-click) layer on any mode independently. Persisted: `mv.voicePolish`, `mv.clarity`, `mv.mouthNoise` (plus the Tier 1 `mv.preset`). `configure` resets ALL stage state on inactive→active; resets ONLY clarity stages when `clarity` changes while active; resets ONLY mouth-noise stages when `mouthNoiseLevel` changes while active (bumpless otherwise).
- `applyVoiceChain()` reconfigures the chain on every preset transition (explicit pick AND the auto-flip to Custom) and on toggle/load — never from the per-tick knob path more than once per transition. `voicePolishEnabled.didSet` is guarded by `!isApplyingPreset` exactly like the Tier 1 knobs.
- A **Voice Profile** is a named snapshot of ALL user-tunable settings (`selectedPreset`, `suppressionStrength`, `attenuationLimitDb`, `outputGainValue`, `voicePolishEnabled`, `clarityLevel`) persisted as a JSON array under `mv.profiles`. Applying a profile goes through the same `isApplyingPreset` guard as `applyPreset` + `applyVoiceChain` — all `@Published` properties are set inside `isApplyingPreset = true … = false`, then a single `applyVoiceChain()` and `persistSettings()` are called after. This prevents spurious `onKnobChanged` → `.custom` flips or redundant persists mid-apply. Future settings fields must be added to `VoiceProfile` as optionals (schema version stays at 1) so old profiles survive without migration.

## Control layer (Tier 4) — `Sources/Core/ControlLayer.swift`, `Sources/App/ActionDispatcher.swift`, `Sources/App/HotkeyManager.swift`

- **Core/App split (so it stays testable):** the PURE models — `ControlAction` (URL/CLI parsers
  + gain constants), `HotkeyActionID`, `HotkeyBinding`, `HotkeyModifier`, `ControlState`, and the
  `ControlReducer` state machine — live in `Sources/Core/ControlLayer.swift` and import only
  `Foundation`. The test target depends on `Core` only, so the REAL dispatch logic (bypass
  transitions, desired-vs-effective AI, gain clamping, cycling) is unit-tested via `ControlReducer`
  (`Tests/NoNoiseMacTests/ControlLayerTests.swift`) WITHOUT constructing `AudioModel`.
- `ActionDispatcher` (@MainActor, App) is a thin adapter: it reads a `ControlState` snapshot from
  `AudioModel`, runs `ControlReducer.reduce`, and applies the returned `[ControlMutation]`. It is the
  single dispatch point for all control actions. It is NOT headless-testable (depends on `AudioModel`
  → CoreAudio).
- **NEVER blanket-write AudioModel fields from the dispatcher.** The reducer returns an explicit
  `[ControlMutation]` (`.setAIEffective` / `.setPreset` / `.setClarity` / `.setGain`) naming EXACTLY
  what the action changed; the adapter applies ONLY those. This is load-bearing: `AudioModel`'s knob
  `didSet`s have side effects — writing `outputGainValue` (or suppression/atten) calls
  `onKnobChanged()` which flips a non-`.custom` preset to `.custom`; writing `selectedPreset` re-applies
  the preset's own gain/atten via `applyPreset`. A blanket "write every field back" would (a) demote
  the active preset to Custom on `.toggleAI`, and (b) override a just-applied preset's gain with the
  pre-change value on `.presetNext`. So `.toggleAI`/bypass emit only `.setAIEffective`; `.presetNext/
  prev` emit only `.setPreset` (no trailing gain write); `.gainUp/down` emit `.setGain` (the
  `onKnobChanged()` → `.custom` flip is the INTENDED manual-edit behavior).
- **A/B bypass = desired-vs-effective AI.** `desiredAIEnabled` is the user's intended AI on/off
  ignoring bypass; effective = `desiredAI && !(momentary || toggle bypass)`. `.toggleAI` ALWAYS
  flips `desiredAI` (even while bypassed); on bypass exit, `AudioModel.isAIEnabled` follows the
  current desired value. Firing toggle-AI mid-bypass therefore does NOT turn AI back on against the
  bypass. Bypass state is session-only (never persisted); `desiredAI` mirrors the persisted
  `isAIEnabled`. This is the only place `isAIEnabled` is written from outside its `didSet` path.
- **The popover master toggle binds to `dispatcher.aiToggleBinding`, NOT `$audioModel.isAIEnabled`,
  and is `.disabled(dispatcher.isBypassed)`.** A direct binding would let the user flip the UI toggle
  during bypass and write `isAIEnabled = true` straight onto the model, re-enabling AI against an
  active bypass (the desired-vs-effective rule's state hole). Routing through the dispatcher uses the
  same `.toggleAI` path; disabling it during bypass closes the hole (desired AI is still changeable by
  hotkey while bypassed).
- `HotkeyManager` (@MainActor, App) uses Carbon `RegisterEventHotKey` + `InstallEventHandler`.
  **Do NOT switch to `NSEvent.addGlobalMonitorForEvents`** — that requires Accessibility permission,
  violating the minimal-entitlement policy (AGENTS.md "Entitlements & signing"). Carbon hotkeys work
  with the existing two entitlements and no permission prompt.
- **Hotkeys register at app launch**, in `NoNoiseMacApp.init()` (HotkeyManager held on `@StateObject`),
  NOT in `ContentView.onAppear` — a `MenuBarExtra`'s content view isn't instantiated until the
  popover opens, so onAppear-registration would leave hotkeys dead until first click.
- **`appDelegate.dispatcher` is wired in `NoNoiseMacApp.init()`, NOT `ContentView.onAppear`** (same
  MenuBarExtra timing reason). The `@NSApplicationDelegateAdaptor` wrapped value exists before the
  `init()` body runs, so the assignment is valid there. Wiring in `onAppear` would leave the
  AppDelegate's `application(_:open:)` URL fallback with a nil dispatcher until the popover first
  opened — a bundled `.app` would drop `open nonoisemac://…` fired before any popover open.
- **`EventHotKeyID.id` is deterministic** (`HotkeyActionID.allCases` index + 1), NOT
  `rawValue.hashValue` — Swift's `hashValue` is randomized per process and would make the fired ID
  un-matchable back to its action.
- The Carbon C callback extracts the `EventHotKeyID` synchronously, then hops to the main actor via
  `Task { @MainActor in … }` before touching `HotkeyManager`/`ActionDispatcher` (both `@MainActor`).
- `HotkeyBinding` stores a plain `UInt32` modifier mask (Core `HotkeyModifier` bits, which equal the
  AppKit `NSEvent.ModifierFlags` device-independent bits). Core never imports AppKit; `HotkeyManager`
  / `KeyCaptureView` adapt `NSEvent.ModifierFlags` ↔ `UInt32` at the App boundary. Encodes as
  `"<keyCode>:<modifierMask>"`.
- Bindings persist under `mv.hotkey.*` keys (consistent with the existing `mv.*` namespace).
- If `RegisterEventHotKey` returns `eventHotKeyExistsErr` (-9878), the slot is left unregistered and
  surfaced in `conflictedActions` (shown in Settings → Hotkeys). Never crash.
- Gain nudge clamps to `0.5...4.0` — the SAME range as the Settings → General "Output Gain" slider
  (`SettingsView.gainCard`). Keep these in sync if the slider range ever changes.
- `nonoisemac://` URL scheme is registered in `Resources/Info.plist` (`CFBundleURLTypes`).
  **This only works in a bundled `.app`** — `swift run` / `swift build` do not register URL schemes.
  Test via `./bundle.sh` + opening `NoNoiseMac.app`.

## Metering & loudness (Tier 2)
- **Telemetry is lock-free scalars** written render→main (the reverse of the suppression knobs, same arm64 atomicity argument). This **reuses the Smart Level telemetry layer**: the render callback writes output level/peak/clip + LUFS snapshots via `recordOutputTelemetry(_:count:)`, `DeepFilterNetDSP.aiActivity` is written in the blend loop, and the single ~25 Hz `Timer` (`startMeterTimer`/`publishMeterTelemetry`) snapshots them into `@Published` props. NEVER add locks; NEVER push per-buffer to main (the per-callback `inputLevel` dispatch was already replaced by the timer snapshot).
- **The `LoudnessMeter` struct is NEVER read cross-thread.** It is a value type mutated ONLY on the render thread (inside `recordOutputTelemetry`); the render thread copies its getters into the `tMomentaryLUFS` / `tIntegratedLUFS` scalars, and the UI timer reads only those scalars. Only plain 32-bit scalars cross threads (the blessed pattern) — do not read the meter object from main.
- **Output telemetry (level/peak/clip/LUFS) updates whenever audio flows** (`recordOutputTelemetry` runs unconditionally, like Smart Level's peak/clip), so the output meter is live in passthrough too. **AI activity** (`aiActivity`) is the one AI-gated readout — it reads 0 when `isAIEnabled` is false (no `processHop` runs). The **clip warning reuses Smart Level's `isOutputClipping`** (peak-threshold + clip-count), not a separate flag.
- **`LoudnessMeter` (Core/AudioProcessing)** owns all BS.1770 math (the REAL K-weighting biquads — published 48 kHz coefficients via `Biquad.setCoefficients`, NOT RBJ approximations — momentary + gated-integrated LUFS, sample-peak, and the `normalizationGain` helper) as a pure, headless-tested value type — same rule as `Biquad`/`resolveOutputBin`. Tested at multiple frequencies.
- **v1 is sample-peak, not true-peak** (oversampled dBTP deferred for perf). Do not relabel the peak as dBTP. Integrated LUFS uses a **fixed-size, pre-allocated block ring** (write by index, wraparound) — never an `append`-growing log; `process` stays allocation-free.
- **Loudness normalization** is a main-computed, slew-limited scalar `loudnessGain` applied pre-limiter in `VoiceChain` (limiter guards the boost). Persisted: `mv.loudnessNorm`, `mv.loudnessTarget`. OFF by default → default output unchanged. `VoiceChain` activates for `loudnessActive` even when polish/clarity are off (limiter must run); the `loudnessActive` field and `AudioModel.applyVoiceChain()` move together (one contract).

## Input Volume & Smart Level (hot-mic guard)
- **Input Volume** is an app-level pre-DSP trim (`inputVolumeValue`, persisted `mv.inputVolume`, range 25%…100%, default 100%). Applied in `captureOutput(...)` after 48 kHz conversion and **before** `ringBuffer.write`. Does **not** write macOS hardware input volume.
- **Runtime scalar:** capture/render paths read `realtimeInputVolume` (mirrored from `inputVolumeValue` in `didSet`), never the `@Published` wrapper directly.
- **Telemetry:** scalar peaks written on capture/render threads (`tRawInputPeak`, `tTrimmedInputPeak`, `tOutputPeak`, clip/hot counters); a ~25 Hz main `Timer` snapshots them into `@Published` state and runs Smart Level. No `DispatchQueue.main.async` from audio paths for metering.
- **Input meter = trimmed signal:** the published `inputLevel` is the **trimmed** RMS NoNoise actually processes, not the raw source level. `captureOutput` measures raw + trimmed in one allocation-free helper (`SmartLevelController.applyInputVolumeAndMeasure` — raw scan → in-place trim → trimmed scan), and `publishMeterTelemetry` derives the input-side fields (`inputLevel`, `isInputNearCeiling`, `isSourceMicClipping`, `consecutiveTrimmedHotTicks`) from `SmartLevelController.evaluateInputGuard`. Raw peak still drives the source-clip warning separately.
- **Smart Level** (`smartLevelEnabled`, `mv.smartLevel`) is protective only — gradually reduces Input Volume when trimmed input is repeatedly near ceiling (≥0.98), or Output Gain when output clips but input is not hot. Never auto-boosts. Floor: 25% input (`minAutoInputVolume = minInputVolume`, same as the manual control) / 25% output gain. Logic lives in `SmartLevelController` (unit-tested); orchestration in `AudioModel.updateSmartLevel()`.
- **Warnings:** raw input peak before trim detects source/ADC clipping that software trim cannot repair; trimmed peak drives "Input too loud" and Smart Level input decisions.

## NoNoise Mic virtual driver (Tier 3, Spec A) — `Driver/`
- **What:** a userspace CoreAudio **AudioServerPlugIn** (`Driver/NoNoiseMic/NoNoiseMic.c`) that publishes a **visible input-only** device "NoNoise Mic" + a **hidden output-only** device "NoNoise Mic Engine". The app renders cleaned audio to the engine device; consumer apps pick "NoNoise Mic" as their microphone. Phase A1 = in-driver **loopback**; Phase A2 (gated) adds an XPC/shared-memory path.
- **Shared contract (a mismatch fails SILENTLY — keep C and Swift identical):** visible name `NoNoise Mic` / UID `NoNoiseMic:visible:48k2ch`; engine name `NoNoise Mic Engine` / UID `NoNoiseMic:engine:48k2ch`; bundle id `com.ivalsaraj.NoNoiseMic`; 48000 Hz, 2ch. Swift mirror: `Sources/Core/AudioProcessing/VirtualMicRouting.swift`.
- **Canonical layout (one layout, every layer):** Float32 **interleaved** stereo `[L,R,L,R…]`, ASBD flags `kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked` (NEVER `…IsNonInterleaved`), `mBytesPerFrame = 8`. `ioMainBuffer` is passed straight into `nn_ring` (`channels=2`) — no de/interleave anywhere.
- **`sourceMode` (`'srcm'`, FourCharCode `0x7372636D`):** `0` = loopback (A1 default), `1` = xpc (A2). Use the char literal `'srcm'` in C — never hand-type the hex (a transposed digit fails silently). Cross-process Set needs `kAudioObjectPropertyCustomPropertyInfoList` registration — deferred to A2; A1 only relies on the default `0`.
- **Topology + timing:** ONE shared loopback ring (`nn_ring`) + a per-device zero-timestamp clock (`nn_clock`), both anchored to a SINGLE host time captured on the first `StartIO`, so the engine's write axis and the mic's read axis coincide. The engine device returns `0` for `…CanBeDefaultDevice`/`…CanBeDefaultSystemDevice` and `1` for `kAudioDevicePropertyIsHidden`.
- **Ring serves SILENCE, never stale speech (privacy-critical):** `nn_ring` tracks a `writeEnd` watermark (published release / read acquire). `nn_ring_read_at` zeroes any frame at/after `writeEnd` (not yet produced) or older than one capacity (overwritten/wrapped) — so if the engine writer stops while the mic keeps running, the consumer app gets silence, NOT a modulo-aliased loop of the last ~1.3 s of cleaned audio. The mic-read `else` branch (`sourceMode==1`, A2-not-yet-wired) likewise `memset`s silence.
- **Pure testable math:** the only risky logic (wraparound + zero-timestamp + the silence window) lives in CoreAudio-free C (`Driver/NoNoiseMic/nn_ring.{c,h}`, `nn_clock.{c,h}`) and is host-unit-tested via `Driver/tests/run-tests.sh` (mirrors the repo's "keep DSP math in testable statics" rule) — including read-before-write, writer-stopped, and partial-straddle silence cases. `DoIOOperation` stays allocation/lock/syscall-free; `GetPropertyData` validates `inDataSize` on every scalar/CFString branch (a short buffer must never corrupt `coreaudiod`), and the stream format setter accepts ONLY the full canonical ASBD (rejecting non-interleaved/repacked layouts).
- **Signing rule:** ad-hoc sign the bundle **AFTER** full assembly; any post-sign edit invalidates the signature and the plug-in **silently fails to load**. `install-driver.sh` verifies the device actually appeared. Distinguish app Gatekeeper (right-click → Open) from driver load (coreaudiod signature check).
- **Licensing:** original implementation against the public API (MIT) — NOT Apple sample source, NOT derived from BlackHole (GPL-3.0).
- **App-side routing (`AudioModel.fetchOutputDevices`):** auto-routes the engine's output to the hidden "NoNoise Mic Engine" via `VirtualMicRouting.preferredOutputUID` (engine → BlackHole fallback → else leave unset; never auto-route to a physical output). Devices are matched by **real UID** (`kAudioDevicePropertyDeviceUID`), not name — only a UID translates to an `AudioObjectID`. **The hidden engine (`kAudioDevicePropertyIsHidden=1`) is EXCLUDED from `kAudioHardwarePropertyDevices` enumeration**, so it must be resolved by UID translate (`kAudioHardwarePropertyTranslateUIDToDevice`) and injected into the route set — the enumeration loop will never see it. (Same translate path resolves `driverInstalled` from the input-only visible mic.) The engine + any hidden device are filtered from the app's own pickers via `isSelectableOutput`, and "NoNoise Mic" is filtered from the input list to prevent a loopback echo.
- **On-demand capture (`AudioModel`, Krisp-like):** when the driver is installed, the app holds the **real mic** (and the macOS orange indicator) ONLY while some app is actually using "NoNoise Mic" — observed via a `kAudioDevicePropertyDeviceIsRunningSomewhere` listener on the visible mic. The render engine to the hidden sink stays warm; only the `AVCaptureSession` is gated. Without the driver (BlackHole fallback) there's no per-use signal, so capture stays always-on.

## Incoming / guest cleanup (clean the other side) — `IncomingCleanupEngine`
- **What:** a SECOND, independent capture→clean→play pipeline that de-noises the audio the user *hears* (a noisy guest/caller). It owns its own `AVCaptureSession`, `AVAudioEngine`, `RingBuffer`, and `DeepFilterNetDSP`. It is **not** an `AudioModel` and never touches the mic path or the NoNoise Mic sink.
- **Off by default + lazy lifecycle (zero-cost when off):** `AudioModel` holds it as `IncomingCleanupEngine?` (OPTIONAL, never a stored `let`). `applyIncomingCleanup()` CREATES it on the enabled transition and tears it down to `nil` when disabled. Rationale: `DeepFilterNetDSP.init()` allocates ML buffers + async-loads the CoreML model — it must NOT run at launch. Each fresh engine instance therefore gets its OWN DeepFilterNet recurrent state (correct — a new stream starts clean).
- **Refuses to run without a valid REAL monitor (feedback guard):** `applyIncomingCleanup()` re-validates BOTH the source (`isSelectableIncomingSource`) and the monitor (`isSelectableMonitorOutput`) via a fresh `deviceInfo(for:)` read AND requires `incomingOutputDeviceID != 0` before constructing/starting the engine; otherwise it tears down to `nil`. It NEVER routes to the system default output — if the default happened to be the captured loopback (the setup points the call app's speaker there), that would feed back. `IncomingCleanupEngine.start()` likewise bails (opens no playback graph, `running` stays false) if the source can't be resolved/attached.
- **`start()` is truthful; the owner retains ONLY a genuinely-running engine:** `IncomingCleanupEngine.start()` returns `Bool` — `true` ONLY after capture attaches AND the monitor is pinned (`AudioUnitSetProperty(...CurrentDevice) == noErr`) AND `AVAudioEngine.start()` actually succeeds; it returns `false` (fully torn down) on any of those failures. Capture is kicked off only AFTER playback is confirmed live, so a failure never leaves a running half-open pipeline. `applyIncomingCleanup()` assigns `incomingEngine = engine` ONLY when `start()` returns `true` (else `stop()` + `nil`), and `refreshDevicesAfterHardwareChange()` re-runs `applyIncomingCleanup()` so unplugging the source/monitor tears the engine down (and a recovered selection restarts it). `stop()`'s guard also covers the attached-but-idle state (`!captureSession.inputs.isEmpty`) so the playback-failure teardown is deterministic. Net: the second CoreML pipeline is resident ONLY while it is truly capturing+cleaning+playing.
- **DFN-only:** the incoming path runs DeepFilterNet **only** — no `VoiceChain`/Broadcast Voice (that polish is voice-shaping for the *outgoing* mic, inappropriate for arbitrary guest audio).
- **Source enumeration is INPUT-scope (`fetchIncomingDevices`):** HAL enumeration on the input scope. The selectable-source predicate `VirtualMicRouting.isSelectableIncomingSource` REJECTS physical mics — it keys off `DeviceInfo.transportType` (virtual/aggregate) + `hasInput`, so only loopback/aggregate inputs (BlackHole, Loopback, etc.) qualify. Physical mics are intentionally excluded.
- **Capability (`hasInput`/`hasOutput`) is the SUMMED channel count, not the data size:** `deviceInfo(for:)` reads `kAudioDevicePropertyStreamConfiguration` and sums `AudioBufferList.mBuffers[*].mNumberChannels`. Do NOT use `AudioObjectGetPropertyDataSize > 0` — that header is non-zero even for a scope with ZERO channels, so a size check reports phantom channels and misclassifies devices (an input-only mic as a monitor output, or an output-only device as an incoming source).
- **Monitor output is OUTPUT-scope:** the "Hear on" device list comes from the output scan (`fetchOutputDevices` → `isSelectableMonitorOutput`) and its UID is persisted from `monitorOutputUIDByID` (the OUTPUT map) — **never** from the input-source map. Mixing the two maps would persist the wrong device.
- **Capture by UID (proven):** capture resolves the source via `AVCaptureDevice(uniqueID:)` from the device's real `kAudioDevicePropertyDeviceUID`. The Task-S spike PROVED HAL→`AVCaptureDevice(uniqueID:)` resolution + session attach for BlackHole; live sample-buffer delivery is gated only by on-device TCC (mic permission), not by the design.
- **Persistence:** keys are `mv.incomingEnabled` / `mv.incomingSourceUID` / `mv.incomingOutputUID` (source persisted by UID string; monitor persisted as UID then translated back to a live `AudioObjectID` on load). Re-applied via `applyIncomingCleanup()` after `loadSettings()`.
