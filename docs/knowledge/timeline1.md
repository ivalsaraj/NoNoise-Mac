# Timeline

Chronological log of notable changes. Newest on top.

### 2026-06-15 — Settings reset added
- Added a destructive-confirmed **Reset Settings** card in Settings → General. It restores
  audio/device settings to defaults (Meeting preset, full suppression, unity input/output gain,
  Voice Polish on, Broadcast Voice/Mouth Noise/Smart Level/Loudness/Incoming cleanup off, LUFS
  target −14) while preserving saved Voice Profiles and custom Hotkeys.
- Added `SettingsResetPolicy` as the single resettable-key list, with a headless XCTest proving
  reset removes app/audio keys but preserves `mv.profiles` and `mv.hotkey.*`.
- `Sources/App/SettingsView.swift`, `Sources/Core/AudioModel.swift`,
  `Sources/Core/SettingsResetPolicy.swift`, `Tests/NoNoiseMacTests/SettingsResetPolicyTests.swift`.

### 2026-06-15 — Fix: loudness peak-safe copy now states the real limiter ceiling
- Code review (Codex, MINOR) flagged that the Settings loudness caption and `CONCEPTS.md`
  claimed normalization is capped "~3 dB below clipping", but the actual `VoiceChain`
  limiter ceiling is −1 dBFS (−0.5 in Tutorial). Corrected the user-facing copy to "just
  below clipping (≈ −1 dBFS)" so the peak-safety claim is accurate.
- `Sources/App/SettingsView.swift`, `CONCEPTS.md`.

### 2026-06-15 — Fix: integrated-LUFS rolling window desynced after the block ring wrapped
- Code review (Codex) caught that `LoudnessMeter.integratedLUFS` divided **lifetime** sums
  (`absGatedCount` / `absGatedMSSum`, incremented forever) to set the relative-gate
  threshold, while the gated loop only summed the last `maxBlocks` entries actually in the
  fixed ring. After the 1 h ring wrapped the two windows desynced, so a long-gone loud
  passage could pin the headline LUFS ~20 LU too high.
- Fix: keep `absGatedMSSum` in lock-step with the ring (subtract the evicted block before
  overwriting a full slot), drop the lifetime `absGatedCount`, and divide by
  `blockMSRingFilled` (the relative loop already reads only those entries). Added a
  regression test that forces a wrap via a small `internal init(sampleRate:integrationBlocks:)`.
- `Sources/Core/AudioProcessing/LoudnessMeter.swift`, `Tests/NoNoiseMacTests/LoudnessMeterTests.swift`.

### 2026-06-15 — Metering & Loudness added
- Added an ITU-R BS.1770 `LoudnessMeter` (REAL K-weighting via the published 48 kHz
  coefficients — a new `Biquad.setCoefficients` direct-coefficient path — → momentary +
  gated-integrated LUFS, sample-peak; validated at 1 kHz / 60 Hz / 6 kHz). Integrated
  LUFS uses a fixed-size pre-allocated block ring (no `append` on the render path). The
  meter is mutated only on the render thread and snapshotted into plain scalars
  (`tMomentaryLUFS` / `tIntegratedLUFS`); it is never read cross-thread.
- Added a derived **AI-activity** signal (`DeepFilterNetDSP.aiActivity` = energy-weighted
  per-bin `1 − wetMag/dryMag` from the blend, one-pole smoothed) — a UX hint, 0 when AI off.
- Added optional **loudness normalization**: a slew-limited make-up gain toward −14/−16
  LUFS applied pre-limiter in `VoiceChain` (new `loudnessActive` activation reason so it
  works in Meeting mode; persisted `mv.loudnessNorm` / `mv.loudnessTarget`, OFF by default).
- **Reused the Smart Level telemetry layer** (the existing ~25 Hz `meterTimer` /
  `publishMeterTelemetry` and `recordOutputTelemetry`, `tOutputPeak` / `isOutputClipping`)
  rather than adding a parallel path — extended them with output RMS level + LUFS snapshots
  and the normalization-gain computation. v1 ships sample-peak (not oversampled true-peak)
  per the perf mandate. UI: Live HUD in the popover (input/output meters, CLIP, AI bar,
  momentary LUFS, latency); loudness panel in Settings (integrated LUFS + normalize toggle
  + −14/−16 target).

### 2026-06-15 — Clean Incoming / Guest — code-review hardening (Codex 4-round, APPROVED)
- HAL capability detection now SUMS `AudioBufferList.mBuffers[*].mNumberChannels` instead of using
  `AudioObjectGetPropertyDataSize > 0` — the latter reports phantom channels (non-zero header for a
  zero-channel scope) and could misclassify an input-only mic as a monitor output.
- Feedback guard: `applyIncomingCleanup()` refuses to run without a chosen REAL monitor
  (`incomingOutputDeviceID != 0` + both predicates re-validated); the "Hear on" picker gained an
  explicit "Select…" state. It never falls back to the system default output (which would feed back
  through the captured loopback).
- Lifecycle is now truthful + strictly zero-cost-when-off: `IncomingCleanupEngine.start()` returns
  `Bool` (true ONLY when capture attach + monitor pin + `engine.start()` all succeed; capture is
  started only after playback is live), `AudioModel` retains the engine ONLY on a true start, and
  `refreshDevicesAfterHardwareChange()` re-validates/tears-down on device add/remove. `stop()` also
  cleans up the attached-but-idle state so playback-failure teardown is deterministic.
- Verified via `swift build` + 89 unit tests green; live-audio paths remain manual smoke.

### 2026-06-15 — Mouth-Noise Finishers (de-plosive + de-click) added
- Added two new identity-at-rest `VoiceChain` stages after the de-esser: `DePlosive` (subtractive
  low-band plosive gate, `out = x - frac * lowSig`) and `DeClick` (broadband transient gate,
  `out = x * gain`). Both are pure value types in `Dynamics.swift`, gated by `MouthNoiseLevel`
  (off/low/medium/high) carried on `VoiceChainSettings` and injected by
  `AudioModel.applyVoiceChain()`. Persisted under `mv.mouthNoise`.
- UI: segmented picker in Settings and the popover. Design invariant — identity at rest — enforced
  structurally and proven by XCTest.

### 2026-06-15 — Hot-mic ceiling fix (trimmed input meter, no Tutorial boost, full Smart Level floor)
- **Input meter now reflects the trimmed signal.** `AudioModel.captureOutput` measured RMS on the
  pre-trim source, so lowering Input Volume left the meter pinned at max. Added
  `SmartLevelController.applyInputVolumeAndMeasure` (one allocation-free helper: raw scan →
  in-place trim → trimmed peak/RMS/hot) and `evaluateInputGuard` (pure mirror of the input-side
  meter + Smart Level contract).
- **Tutorial preset no longer hides a boost.** `outputGain` 1.2 → 1.0 and `compMakeupDb` 4 → 0.
- **Smart Level auto floor 35% → 25%.** `minAutoInputVolume = minInputVolume`, so protective
  auto-trim can reach the same floor as the manual Input Volume control. Still never auto-boosts.

### 2026-06-15 — Clean Incoming / Guest (Phase 1) shipped
- Added `IncomingCleanupEngine` — a SECOND, independent capture→clean→play pipeline that
  de-noises the audio the user *hears* (a noisy guest/caller). Captures a loopback/aggregate
  **INPUT** (BlackHole/Loopback) via `AVCaptureDevice(uniqueID:)`, runs its OWN `DeepFilterNetDSP`
  (DFN only, no Voice polish), and re-plays the cleaned audio to the chosen monitor output.
- `AudioModel` owns it as an OPTIONAL, created on the enabled transition and torn down to `nil`
  when off (off by default; the second AI stream only runs while enabled). New persisted keys
  `mv.incomingEnabled` / `mv.incomingSourceUID` / `mv.incomingOutputUID`.
- Source list enumerated on the INPUT scope (`fetchIncomingDevices`) with
  `VirtualMicRouting.isSelectableIncomingSource` (rejects physical mics via transport type +
  `hasInput`); monitor list comes from the OUTPUT scan (`isSelectableMonitorOutput`).
- UI: a **Clean Incoming / Guest** card in Settings (enable + *Incoming from* / *Hear on* pickers
  + no-loopback warning), a compact toggle in the popover, and two new Setup Guide steps for the
  loopback routing.
- **Spike (Task S):** proved HAL enumeration surfaces BlackHole (UID + virtual transport) and that
  `AVCaptureDevice(uniqueID:)` resolves that UID and attaches to an `AVCaptureSession`. Live
  sample-buffer delivery is gated only by on-device TCC (mic permission), not by the design — so
  the AVCapture-by-UID path is sound. 14 device-classification unit tests added.

### 2026-06-15 — Control layer (global hotkeys + A/B bypass + Stream Deck) added
- Added the pure control models + `ControlReducer` to `Sources/Core/ControlLayer.swift`
  (`ControlAction`, `HotkeyActionID`, `HotkeyBinding`, `HotkeyModifier`, `ControlState`,
  `ControlMutation`) so the real dispatch logic is unit-tested headlessly without `AudioModel`.
- The reducer returns `(ControlState, [ControlMutation])`; `ActionDispatcher` (Sources/App) applies
  ONLY the emitted mutations onto a live `AudioModel` — never a blanket field write-back, which would
  re-trip the knob `didSet`s (writing `outputGainValue` flips a preset to `.custom`; writing
  `selectedPreset` re-applies the preset's own gain). So `.toggleAI` no longer demotes the active
  preset to Custom and `.presetNext` keeps the preset-defined gain.
- `HotkeyManager` (Sources/App) registers system-wide Carbon `RegisterEventHotKey` combos (default
  ⌃⌥ set, deterministic `EventHotKeyID`s) with UserDefaults persistence under `mv.hotkey.*`; created
  at app launch in `NoNoiseMacApp.init()` so hotkeys are live before the popover opens (and
  `appDelegate.dispatcher` is wired in `init()` too, so the URL fallback works pre-popover).
- `nonoisemac://` URL scheme registered in `Resources/Info.plist`.
- A/B bypass uses a desired-vs-effective AI model: while bypassed, AI is forced off and toggle-AI
  updates the DESIRED state (restored on bypass exit) — never persisted; the popover master toggle
  routes through the dispatcher and is disabled during bypass so AI can't be re-enabled against an
  active bypass.
- Gain nudge clamps to the slider's `0.5...4.0`. `NoNoiseMacCLI` extended with `--action <verb>`.
- Post-review hardening (Codex): the CLI's `--action` verbs now resolve through the canonical
  `ControlAction.from(cliVerb:)` + new `ControlAction.urlString` (single source of truth,
  round-trip tested) instead of a private verb→URL dictionary that the tests couldn't reach;
  `HotkeyManager.register` logs non-`eventHotKeyExistsErr` failures (no silent failure) while
  still surfacing them as conflicts; removed an unused `@State` in the Hotkeys settings view.
### 2026-06-15 — GitHub report action added
- Added a compact **Report** action to the menu-bar popover footer and a matching
  **Report a feature or issue** link in Settings. Both open the NoNoise Mac GitHub issue template
  chooser through a shared app support URL constant.
- Arranged the popover device rows horizontally, with each label beside its picker/status and the
  Output route on the next row.

### 2026-06-15 — Input Volume & Smart Level shipped
- Added app-level **Input Volume** (25%…100%, default 100%, `mv.inputVolume`) applied pre-ring-buffer
  in `AudioModel.captureOutput`, plus optional **Smart Level** (`mv.smartLevel`) that gradually lowers
  Input Volume or Output Gain when sample peaks repeatedly approach the ceiling.
- Cheap scalar peak/clip telemetry on capture/render threads; ~25 Hz main timer publishes warnings
  (`Input too loud`, `Output clipping`, source-mic clipping) and runs Smart Level via the pure
  `SmartLevelController` helper. UI in Settings and popover status card.

### 2026-06-15 — Voice Profiles: save/recall/rename/delete named setting snapshots

Added a **Voice Profiles** system: `VoiceProfile` (versioned `Codable` struct, extensible via
optional fields), `VoiceProfileStore` (pure CRUD + JSON serialization, headless XCTest-able),
and three new `AudioModel` methods (`saveCurrentAsProfile`, `applyProfile`, `deleteProfile`,
`renameProfile`). Profiles are persisted as a JSON array under `mv.profiles`. The `applyProfile`
path goes through `isApplyingPreset = true … = false` to prevent spurious `.custom` flips or
redundant `applyVoiceChain` / `persistSettings` calls mid-apply. UI: a Profiles card in
`GeneralSettingsView` with Save Current / Recall / Rename / Delete per row. Schema is forward-
compatible: Mouth Noise, Input Volume, and Smart Level are optional profile fields, and future
Metering & Loudness fields can be added without migration.

### 2026-06-15 — Input Volume & Smart Level plan
- Added `docs/plans/2026-06-15-input-volume-smart-level.md`, a focused plan for hot-mic protection:
  a macOS-worded **Input Volume** control applied pre-DSP, cheap input/output sample-peak detection,
  and an optional **Smart Level** mode that gradually reduces Input Volume or Output Gain when the
  voice repeatedly approaches the ceiling.

### 2026-06-15 — Broadcast Voice (clarity) added
- Added an Off/Low/Medium/High **Broadcast Voice** control: a wide-Q presence peaking bell
  (`Biquad.setPeaking`) + a subtractive split-band `DeEsser` (`Dynamics.swift`), wired into
  `VoiceChain` via `ClarityLevel` on `VoiceChainSettings` and injected by
  `AudioModel.applyVoiceChain()` on top of the active preset (persisted under `mv.clarity`).
- UI: a segmented picker in Settings and in the menu-bar popover.
- Design constraint — preserve the original voice — enforced structurally: the de-esser is an
  identity below threshold, the presence bell has unity gain at DC **and Nyquist** (both proven by
  test in `BroadcastVoiceTests`), and `clarity == .off` leaves existing presets byte-for-byte unchanged.

### 2026-06-15 — Live input-device refresh
- Added a CoreAudio hardware-device listener in `AudioModel` so newly plugged microphones refresh
  into the NoNoise Mac input picker without relaunching the app. Refreshes are debounced, preserve
  the selected mic when it is still connected, and re-resolve the NoNoise Mic lifecycle when the
  virtual driver appears or disappears.

### 2026-06-15 — Single brand logo in popover
- Kept the NoNoise PNG as the popover header logo, and changed the Noise Cancellation status-card
  badge back to a semantic SF Symbol so the widget does not show duplicate brand marks.

### 2026-06-15 — Stable release after successful main CI
- Updated `.github/workflows/release.yml` so a successful `CI` workflow on `main` automatically
  rebuilds, bundles, and uploads the latest `NoNoiseMac.app`, `NoNoiseMacCLI`, `NoNoiseMic.driver`,
  and checksums to the `stable` GitHub Release. Versioned `v*` tag releases remain supported.

### 2026-06-15 — Apple Silicon performance mandate
- Added an `AGENTS.md` rule requiring all future implementation work to optimize for M-series Macs:
  low CPU, low memory churn, low latency, no avoidable battery drain, and no hot-path allocations or
  polling without a measured reason. The rule explicitly preserves correctness, privacy, and audio
  quality as non-negotiable while requiring measured, maintainable performance work.

### 2026-06-15 — NoNoise logo in menu bar and popover
- Replaced the SF Symbol waveform used in the menu-bar item and popover status card with a shared
  NoNoise mark, so the visible app identity matches the NoNoise logo. The menu-bar variant uses a
  plain template `NSImage` for reliable `MenuBarExtra` rendering; the popover/settings variants use
  the bundled `NoNoiseMacLogo.png`.

### 2026-06-15 — CI Swift 5.10 compatibility + tag-gated release workflow
- Gated unused `MLShapedArray<Float16>` convenience APIs in the generated CoreML wrapper behind
  `#if compiler(>=6.0)` so GitHub Actions' macos-14 / Swift 5.10 runner can compile the project.
  Runtime DSP still uses the `MLMultiArray` path required by the CoreML output-readback rule.
- Added `.github/workflows/release.yml`: only `v*` tags whose commit is contained in `origin/main`
  publish zipped `NoNoiseMac.app`, `NoNoiseMacCLI`, `NoNoiseMic.driver`, and checksums.

### 2026-06-15 — Apple Silicon install script
- Added `install-app.sh`, a one-command local installer that runs `swift build -c release --arch arm64`,
  bundles/signs `NoNoiseMac.app`, installs it to `/Applications`, verifies the copied app signature,
  and optionally stages `NoNoiseMic.driver` via `--with-driver`.
- Documented the release-build rule in `AGENTS.md`: local installs MUST use the optimized arm64
  release path because NoNoise Mac is Apple-Silicon-only.

### 2026-06-15 — Tier 3 / Spec A Phase A1: NoNoise Mic virtual microphone driver
- Shipped a userspace CoreAudio **AudioServerPlugIn** (`Driver/NoNoiseMic/`) publishing a visible
  input-only **NoNoise Mic** + a hidden output-only **NoNoise Mic Engine** (48 kHz, 2ch,
  interleaved Float32). Apps select "NoNoise Mic" directly — no BlackHole, no default juggling.
- **Transport:** Phase A1 in-driver **loopback** (`sourceMode = 0`); A2 (XPC + shared memory,
  `sourceMode = 1`) is gated behind a coreaudiod-reachability spike (plan Task 12).
- **Risky math is CoreAudio-free + host-tested:** `nn_ring` (sample-time wraparound, interleaved
  L/R) and `nn_clock` (O(1) monotonic zero-timestamp) → `Driver/tests/run-tests.sh`, also wired
  into CI alongside a driver compile+sign check.
- **App wiring:** `AudioModel.fetchOutputDevices` auto-routes the engine output by **real UID**
  (`VirtualMicRouting.preferredOutputUID`: engine → BlackHole → else unset), detects install via
  `kAudioHardwarePropertyTranslateUIDToDevice`, and filters hidden/virtual devices from its
  pickers; `ContentView` shows a "NoNoise Mic ready / not installed" row; Settings guide + README
  rewritten to the new routing model (BlackHole demoted to fallback).
- **Contract/decisions** live in `AGENTS.md` → "NoNoise Mic virtual driver"; the silent-non-load
  trap is in `knowledge1.md`. Original MIT implementation — not Apple sample source, not derived
  from BlackHole (GPL-3.0).
- **Plan + review:** `docs/plans/2026-06-15-nonoise-mic-virtual-driver-plan.md` (Codex plan review
  APPROVED, 3 rounds). On-device install/verify (sudo + coreaudiod restart) is the user's manual gate.

### 2026-06-15 — NoNoise Mac v1.0.0 (initial public release)
- Rebranded the project from **MetalVoice** (by Ghostkwebb,
  https://github.com/Ghostkwebb/MetalVoice, MIT) to **NoNoise Mac**: identifiers, bundle id
  `com.ivalsaraj.NoNoiseMac`, assets, CLI (`NoNoiseMacCLI`), and all UI strings.
- Made the repo **AI-native**: this knowledge base, `CONCEPTS.md`, the agent catalog
  (`docs/agents/README.md`), an expanded `AGENTS.md` (overview + ICP + architecture +
  branding conventions), and CI.
- **UI overhaul**: polished menu-bar popover (hero status card, live meter, sectioned
  cards) and Settings (branded header, consistent cards).
- **AI noise cancellation ON by default.**
- DSP/model/audio behavior unchanged. `swift build` + 30 tests green; `swift build -c release`
  + `./bundle.sh` produce a signed `NoNoiseMac.app` + `NoNoiseMacCLI`.
- **Pre-publish Codex code review** (gpt-5.5, 2 rounds → APPROVED): fixed the README CLI section
  to match real `NoNoiseMacCLI` behavior (documented `--help`; removed a non-existent no-arg
  "list devices" mode), and documented the two signing entitlements in `AGENTS.md`.

### Pre-rebrand (inherited from MetalVoice history)
- Voice Polish chain (Biquad/Compressor/Limiter + per-preset profiles + master toggle).
- Preset modes (Meeting/Podcast/Tutorial/Custom) + suppression-strength & reduction-limit knobs.
- DSP correctness fixes: read CoreML outputs via `NSNumber`; match DeepFilterNet feature
  pipeline (no invented compression); stride-aware spectrum reads.
