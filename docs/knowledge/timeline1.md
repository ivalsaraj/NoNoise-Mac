# Timeline

Chronological log of notable changes. Newest on top.

### 2026-06-15 — Hot mic ceiling fix
- Input metering now reflects the trimmed NoNoise input signal instead of raw pre-trim RMS, so
  lowering Input Volume visibly lowers the meter while raw mic clipping still shows a separate
  source-warning state.
- Tutorial mode no longer adds hidden loudness by default: output gain is unity and compressor
  makeup is zero. Smart Level can now protect down to the manual 25% Input Volume floor.

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
