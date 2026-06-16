# Knowledge Log

`[GOTCHA]` / `[DECISION]` / `[PATTERN]` entries. Newest on top. See `critical-patterns.md`
for the must-read failure modes.

---

### [DECISION] 2026-06-16 — Clean Incoming rewritten to a Core Audio process tap; the 2026-06-15 BlackHole entries are SUPERSEDED (@Valsaraj)
- **Problem**: The 2026-06-15 incoming-cleanup design (entries below) used an `AVCaptureSession` on a
  user-chosen **loopback/BlackHole** source plus a user-chosen **monitor output**, with source/monitor
  pickers and a feedback guard. It required installing BlackHole and manually routing the call app's
  speaker — fragile setup, and a feedback path if the monitor was the captured loopback.
- **Decision**: Replace it with a **Core Audio process tap** (`AudioHardwareCreateProcessTap` +
  private aggregate + `AudioDeviceIOProcID`, macOS 14.4+) that captures all system audio **except
  NoNoise's own process** (global-exclude tap, originals **muted**), cleans it through the per-instance
  `DeepFilterNetDSP`, and re-renders to the **current default output** (auto-following device changes).
  No BlackHole, no source/monitor pickers — a **single toggle + status line**. The IOProc (producer)
  and `AVAudioSourceNode` (consumer) are bridged by a lock-free C11-atomics SPSC ring (`CTapRing` /
  `TapAudioRing`). Truthful lifecycle preserved (retain only a genuinely running pipeline); runtime
  self-teardown now notifies the owner so the toggle drops `.cleaning → .failed` instead of lying.
- **Rule**: The entries dated **2026-06-15** below about incoming cleanup (BlackHole capture session,
  `isSelectableIncomingSource` / `isSelectableMonitorOutput`, source/monitor pickers, `mv.incomingSource*`
  / `mv.incomingOutput*`, the "chosen REAL monitor" feedback guard, `AVCaptureDevice(uniqueID:)` capture)
  are **HISTORY** — they describe the removed design. The current design is the process tap above; see
  AGENTS.md "Incoming / guest cleanup" and `docs/superpowers/specs/2026-06-16-tap-based-clean-incoming-design.md`.
- **Files**: `Sources/Core/AudioProcessing/IncomingCleanupEngine.swift` (full rewrite),
  `Sources/CTapRing/*`, `Sources/Core/AudioProcessing/TapAudioRing.swift`,
  `Sources/Core/AudioProcessing/IncomingTapLogic.swift`, `Sources/Core/AudioModel.swift`,
  `Sources/Core/AudioProcessing/VirtualMicRouting.swift`, `Resources/Info.plist`.

### [DECISION] 2026-06-16 — Versioned-only releases; annotated-tag notes need a force-fetch (@ivalsaraj)
- **Problem**: Every push to `main` auto-published a `main-<short-sha>` "stable" release marked
  `--latest`, which stole GitHub's **Latest** badge from real versioned releases (v1.3.0) and piled up
  on the Releases page. Separately, v1.3.0 published with the DEFAULT notes footer instead of its tag
  body.
- **Root Cause**: (1) the `workflow_run` trigger fired on every successful CI run on main; stable
  builds set `--latest`, so the most recent push always won Latest. (2) On a `workflow_dispatch`
  retry the checked-out tag is peeled/lightweight, so
  `git for-each-ref --format='%(contents:body)' refs/tags/$TAG` returns the (empty) commit body →
  the step's fallback notes.
- **Fix**: Removed the `workflow_run` trigger (+ dead job `if:`) → releases are versioned-only (`v*`
  tags via `release.sh`, or a manual `stable-latest` dispatch). Force-fetch the annotated tag
  (`git fetch --force origin "refs/tags/$TAG:refs/tags/$TAG"`) before reading its body. Pruned the
  rolling releases and pinned v1.3.0 as Latest.
- **Rule**: Don't auto-publish per-push releases that set `--latest` — reserve **Latest** for
  versioned releases. Read annotated-tag notes only AFTER force-fetching the tag object; a peeled tag
  silently yields empty notes.
- **Files**: .github/workflows/release.yml

### [GOTCHA] 2026-06-16 — Versioned-release CI: tag-clobber + appcast tag-create 403 (@ivalsaraj)
- **Problem**: The 2nd versioned release (v1.3.0) failed twice. (1) "Resolve release target" died on
  `git fetch origin main --tags` with "would clobber existing tag" — v1.2.0 was the 1st release so it
  never hit this. (2) Then the appcast generated + EdDSA-signed fine but failed to PUBLISH with
  `HTTP 403: Resource not accessible by integration` while creating the new `appcast` release.
- **Root Cause**: (1) `git fetch --tags` refuses to update a tag ref CI's checkout already holds
  without `--force`. (2) Repo `default_workflow_permissions=read`; the workflow elevates
  `contents: write`, which is enough to create a release for an EXISTING tag (v1.3.0, pushed by
  release.sh) but NOT to create the brand-new `appcast` git tag → 403.
- **Fix**: (a) `git fetch --force origin main --tags` (+ the dispatch-branch fetch) — forcing also
  guarantees the ANNOTATED tag object so release notes extract. (b) Bootstrapped the `appcast`
  release+tag once with an admin token (`gh release create appcast --latest=false`); CI now only
  `gh release upload appcast --clobber` (never creates the tag). (c) Made the versioned publish
  idempotent (view → upload+edit, else create) so `workflow_dispatch` retries don't collide.
- **Rule**: The `appcast` release must be bootstrapped once by a repo admin — CI's `GITHUB_TOKEN`
  can upload to it but cannot create its tag. Re-trigger a stuck versioned release with
  `gh workflow run release.yml -f tag=vX.Y.Z` (runs the fixed workflow from main, builds the tag's
  source via the dispatch branch's `git checkout "$TAG"`).
- **Files**: .github/workflows/release.yml

### [DECISION] 2026-06-15 — Sparkle auto-updater + monotonic CFBundleVersion (@ivalsaraj)
- **Problem**: No update mechanism; wanted Voquill-style "update available" for a native Swift menu-bar app.
- **Root Cause**: Voquill is Tauri (plugin-updater) — not portable; the native macOS equivalent is Sparkle. Also: release.sh's CFBundleVersion formula (MAJOR.MINOR digits) ignored PATCH and wasn't monotonic, which breaks Sparkle's version comparison.
- **Fix**: Sparkle 2 via SwiftPM; EdDSA-signed appcast on a fixed `appcast` GitHub release tag; ad-hoc app + Library-Validation-off EdDSA trust path; inside-out signing (no `--deep`). release.sh now stamps a MONOTONIC CFBundleVersion via scripts/version-from-tag.sh; CI asserts plist↔tag↔appcast↔asset. See docs/plans/2026-06-15-sparkle-auto-updater.md.
- **Rule**: Sparkle's CFBundleVersion must be a monotonic integer that exceeds every previously shipped value; never reuse a dotted semver or the MAJOR.MINOR-digits formula for it.
- **Files**: Package.swift, Resources/Info.plist, Sources/App/UpdaterController.swift, NoNoiseMacApp.swift, ContentView.swift, release.sh, bundle.sh, .github/workflows/release.yml, scripts/version-from-tag.sh

### [DECISION] 2026-06-15 — Live meters: always-on control pump + popover-gated UI publish, isolated on MeterModel (@Valsaraj)
- **Problem:** The menu-bar popover opened slowly and the AI toggle felt delayed by ~seconds. The single ~25 Hz meter timer wrote ~11 `@Published` fields on `AudioModel` every 40 ms; the `MenuBarExtra` label and the whole `ContentView` observe `AudioModel`, so every tick re-evaluated the Scene (re-rendering the status-bar `NSImage` via `lockFocus` even while CLOSED) and re-diffed the entire popover — pure main-thread contention, not toggle work.
- **Decision:** (1) Move the high-frequency meter fields off `AudioModel` onto a dedicated `MeterModel: ObservableObject` (`Sources/Core/MeterModel.swift`) so `AudioModel.objectWillChange` no longer fires on telemetry ticks. (2) Split the one timer into an ALWAYS-ON ~25 Hz **control pump** (`runControlPump`) — the SOLE owner of the `t*` read-and-reset, running BOTH control loops (Smart Level + loudness normalization), writing only a plain `MeterSnapshot` struct (NEVER `@Published`) — and a **popover-gated** UI-publish timer (`begin/endMeterObservation(_:)`, tracked per source via a `Set<MeterObserver>` so popover + Settings share ONE timer idempotently — duplicate/missed begins/ends can't leak or double-start it) that copies the snapshot into `MeterModel`. (3) Keep the control pump at 25 Hz (cadence parity) so the loudness slew (`slewDb:1`/tick) and Smart Level tick thresholds keep their tuned timing — a naïve rate drop would slow make-up gain 6–12×. (4) Seed `MeterModel` from the latest snapshot on `begin` (before the first timed publish) so the first frame after a closed interval isn't stale. (5) Only scoped subviews (`StatusMeters`/`LiveHUDCard`, `GeneralSettingsView`) observe `MeterModel`.
- **Rule:** A high-frequency (>~10 Hz) telemetry stream gets its OWN `ObservableObject` observed only by the leaf views that display it — never the app-wide model that also drives the `MenuBarExtra` label / Scene. Audio-control loops stay on an always-on, NON-publishing main-thread pump (the single `t*` owner); the UI publish loop is gated to view visibility and snapshot-read-only.
- **Files:** `Sources/Core/MeterModel.swift`, `Sources/Core/AudioModel.swift`, `Sources/App/ContentView.swift`, `Sources/App/SettingsView.swift`.

### [GOTCHA] 2026-06-15 — A `MenuBarExtra` label observing a 25 Hz model redraws the status icon while CLOSED (@Valsaraj)
- **Symptom:** Clicking the menu-bar icon was slow to present the popover even before any popover existed; the toggle also lagged. No crash, no log — just sluggishness.
- **Root cause:** `audioModel` is a `@StateObject` on the `App`, and the `MenuBarExtra` label reads `audioModel.isAIEnabled`. The meter timer fired `AudioModel.objectWillChange` 25×/sec, so SwiftUI re-evaluated the **Scene body** 25×/sec and re-ran `NoNoiseLogoImage.menuBar(...)` — a full offscreen `NSImage.lockFocus()` render — continuously, keeping the main run loop busy so the click→present and toggle→repaint were slow to be serviced.
- **Fix/Rule:** Two layers — (a) cache the menu-bar `NSImage` (`static let`) so the label closure is cheap even if invoked, and (b) the real fix: stop `AudioModel.objectWillChange` from firing on telemetry by moving the 25 Hz fields to `MeterModel` (see the DECISION above). NEVER let the `MenuBarExtra` label (or any always-mounted Scene view) transitively observe a high-frequency `@Published` source, and NEVER do `lockFocus`/disk I/O inside a SwiftUI `body` that can re-evaluate often.
- **Files:** `Sources/App/NoNoiseLogoMark.swift`, `Sources/App/NoNoiseMacApp.swift`, `Sources/Core/AudioModel.swift`, `Sources/Core/MeterModel.swift`.

### [DECISION] 2026-06-15 — Settings reset preserves user-created assets (@Valsaraj)
- **Problem:** A "Reset Settings" action can be interpreted as either "restore audio knobs/devices" or "delete everything under `mv.*`"; the latter would unexpectedly wipe saved Voice Profiles and custom Hotkeys.
- **Decision:** Reset only app/audio/device settings through `SettingsResetPolicy.resettableKeys`. Preserve `mv.profiles` and every `mv.hotkey.*` binding. `AudioModel.resetSettingsToDefaults()` applies live defaults under `isApplyingPreset`, reconfigures the voice chain once, tears down incoming cleanup, and persists the default state back to UserDefaults.
- **Rule:** Future app/audio settings keys that should reset belong in `SettingsResetPolicy.resettableKeys`; user-created assets such as profiles and hotkeys must stay out of that list unless product scope explicitly changes.
- **Files:** `Sources/Core/SettingsResetPolicy.swift`, `Sources/Core/AudioModel.swift`, `Sources/App/SettingsView.swift`, `Tests/NoNoiseMacTests/SettingsResetPolicyTests.swift`.

### [BUG] 2026-06-15 — Integrated LUFS desynced after the block ring wrapped (@Valsaraj)
- **Problem:** Integrated (gated) LUFS read a stale value after ~1 h of continuous audio — a long-gone loud passage could keep the headline number ~20 LU too high (e.g. −20 LUFS reported for what was actually a −43 LUFS quiet program).
- **Root cause:** `LoudnessMeter.integratedLUFS` computed the relative-gate threshold from **lifetime** running sums (`absGatedMSSum / absGatedCount`, incremented on every gated block and never decremented) but then summed only the last `maxBlocks` entries actually present in the fixed ring. Once the ring wrapped (9000 blocks × 400 ms = 1 h), the threshold reflected all-time history while the gated set was only the last hour — two different windows.
- **Fix:** Maintain `absGatedMSSum` as the sum of the ring's LIVE entries only — subtract the evicted block's mean-square before overwriting a full slot — drop the lifetime `absGatedCount`, and divide by `blockMSRingFilled` (the relative loop already iterates exactly those entries). Threshold and gated set now share one bounded window. Added `testIntegratedForgetsEvictedBlocksAfterWindowWraps`, which forces a wrap cheaply via a test-only `internal init(sampleRate:integrationBlocks:)`.
- **Rule:** When a fixed-size ring backs a statistic, every running aggregate over it must be evicted in lock-step with overwrites — never pair a lifetime accumulator with a windowed read.
- **Files:** `Sources/Core/AudioProcessing/LoudnessMeter.swift`, `Tests/NoNoiseMacTests/LoudnessMeterTests.swift`.

### [DECISION] 2026-06-15 — Sample-peak (not true-peak) + lock-free render→main metering, reusing the Smart Level telemetry layer (@Valsaraj)
- **Problem:** Metering needs render-thread data (levels, peaks, suppression activity, loudness) without locks/allocation, and a naïve "true-peak" meter needs ≥4× oversampling on every buffer. A second telemetry path would also duplicate the unsafe main↔render plumbing the Smart Level feature already built.
- **Decision:** (1) **Reuse the Smart Level telemetry layer** — the existing ~25 Hz `meterTimer` / `publishMeterTelemetry`, `recordOutputTelemetry`, `tOutputPeak` / `tOutputClipCount` / `isOutputClipping` — and extend it with output RMS level, LUFS snapshots, AI-activity, and the normalization-gain step, instead of adding a parallel set of scalars/timer. (2) The `LoudnessMeter` struct is mutated ONLY on the render thread (inside `recordOutputTelemetry`) and snapshotted into `tMomentaryLUFS` / `tIntegratedLUFS` scalars; it is NEVER read cross-thread (only plain scalars cross threads). (3) v1 ships **sample-peak** + the existing output-clip warning, NOT oversampled true-peak (too heavy for an always-on menu-bar utility); the normalization ceiling is a peak-safe limiter labeled ~−3 dB, not certified dBTP. (4) AI "confidence" is a derived heuristic (energy-weighted `1 − wetMag/dryMag` from the blend), a UX hint only, gated to AI-on. (5) Integrated LUFS uses a **fixed-size, pre-allocated block ring** written by index (wraparound) — no `append`/grow on the render path. (6) K-weighting uses the REAL published BS.1770 48 kHz coefficients (a new `Biquad.setCoefficients` direct path), validated at multiple frequencies — not RBJ approximations.
- **Divergence from the plan (intentional):** the plan assumed metering created a fresh telemetry layer with a separate latched `tClipFlag` and `tLoudnessSamplePeak`, and that all render telemetry sat inside the `if isAIEnabled` branch. The branch already had the Smart Level layer, so we reused `isOutputClipping` (peak-threshold + clip-count) for the CLIP indicator and reused `outputPeak` for the peak readout; output telemetry stays live in passthrough (AI off), and only AI-activity is AI-gated.
- **Rule:** Render→main telemetry must be lock-free scalars snapshotted at a modest UI rate (never read a mutating struct cross-thread); the render path stays allocation-free (fixed rings, never `append`); never claim certified true-peak without oversampling; keep all loudness math in the pure `LoudnessMeter`. Before adding a metering path, check whether the Smart Level layer already carries it.
- **Files:** `Sources/Core/AudioProcessing/Biquad.swift`, `Sources/Core/AudioProcessing/LoudnessMeter.swift`, `Sources/Core/AudioProcessing/DeepFilterNetDSP.swift`, `Sources/Core/AudioProcessing/VoiceChain.swift`, `Sources/Core/AudioModel.swift`.

### [GOTCHA] 2026-06-15 — Input meter must publish the TRIMMED signal, not the pre-trim source RMS (@Valsaraj)
- **Symptom:** With Input Volume at 43% the input meter still read near max, so the trim looked broken — worst in Tutorial mode, which also double-boosted (`outputGain 1.2` + `compMakeupDb 4`) and leaned on the limiter, sounding crushed.
- **Root cause:** RMS was computed in the *pre-trim* loop and published into `inputLevel`; the trim (`vDSP_vsmul`) ran afterward, so the meter never reflected what NoNoise actually processes.
- **Fix/Rule:** Measure raw + trimmed in one allocation-free helper (`SmartLevelController.applyInputVolumeAndMeasure` — raw scan → in-place trim → trimmed scan) and publish `trimmedRMS` as the meter; keep raw peak/clip for the separate source-clip warning. A meter must reflect the signal at the stage it claims to represent. The raw-vs-trimmed contract is a pure helper (`evaluateInputGuard`) so it is unit-tested without constructing `AudioModel`.
- **Files:** `Sources/Core/AudioModel.swift`, `Sources/Core/AudioProcessing/SmartLevelController.swift`.

### [DECISION] 2026-06-15 — Incoming engine lifecycle is truthful: retain ONLY a genuinely-running pipeline (@Valsaraj)
- **Problem:** A `start()` that returned `Void` (or always "succeeded") let `AudioModel` retain the engine even when capture attach failed, when the monitor couldn't be pinned, or when `AVAudioEngine.start()` threw (the error was swallowed). Result: the SECOND `DeepFilterNetDSP` (CoreML) pipeline stayed resident — burning ANE/CPU/memory — while producing NO audible output (a false-positive "started"), breaking the zero-cost-when-off mandate. Separately, a hardware change (unplugging the loopback/monitor) left a stale engine running against a vanished device because the refresh path never re-validated it.
- **Decision:** `IncomingCleanupEngine.start()` returns `Bool` and is truthful — `true` ONLY after capture attaches AND the monitor pins (`AudioUnitSetProperty(...CurrentDevice) == noErr`) AND `engine.start()` succeeds; capture is kicked off only AFTER playback is confirmed live; any failure calls `stop()` and returns `false`. `applyIncomingCleanup()` assigns `incomingEngine = engine` ONLY on a `true` start (else `stop()` + `nil`). `refreshDevicesAfterHardwareChange()` re-runs `applyIncomingCleanup()` (HAL-direct validation, independent of the async-published picker arrays) to tear down vanished selections or restart recovered ones. `stop()`'s guard also covers the attached-but-idle state (`!captureSession.inputs.isEmpty`) so the playback-failure path tears down deterministically instead of relying on dealloc.
- **Rule:** A lazily-owned heavy engine must report start success truthfully (graph actually live, not merely constructed); the owner must retain it ONLY on a `true` start AND re-validate on hardware changes — otherwise a half-open pipeline silently leaks ANE/CPU/memory.
- **Files:** `Sources/Core/AudioProcessing/IncomingCleanupEngine.swift` (`start`, `stop`, `configureCapture`, `configurePlayback`), `Sources/Core/AudioModel.swift` (`applyIncomingCleanup`, `refreshDevicesAfterHardwareChange`).

### [GOTCHA] 2026-06-15 — CoreAudio channel capability must be SUMMED, not inferred from data size (@Valsaraj)
- **Symptom:** With the incoming/guest picker, an input-only mic could be offered as a "monitor output" (and an output-only device as an incoming source); pure predicate tests still passed because they inject `hasInput`/`hasOutput` directly.
- **Root Cause:** `deviceInfo(for:)` detected capability with `AudioObjectGetPropertyDataSize(kAudioDevicePropertyStreamConfiguration) > 0`. That property returns a non-empty `AudioBufferList` header even when a scope has ZERO streams (`mNumberBuffers == 0`), so `size > 0` reports phantom channels. (The pre-existing `fetchOutputDevices` used the same shortcut; promoting it to shared input+output classification made it load-bearing and wrong.)
- **Fix/Rule:** Read the full `AudioBufferList` and SUM `mBuffers[*].mNumberChannels`; treat a scope as capable only when the sum is `> 0`. Never use the property data size as a channel-count proxy. This can only *fix* classification — a real device always has ≥1 channel in its scope.
- **Files:** `Sources/Core/AudioModel.swift` (`deviceInfo(for:)` → `channelCount(scope:)`).

### [DECISION] 2026-06-15 — Incoming cleanup refuses to run without a chosen REAL monitor (feedback guard) (@Valsaraj)
- **Problem:** If the engine started with no monitor selected (`incomingOutputDeviceID == 0`), `configurePlayback` fell through to AVAudioEngine's system DEFAULT output. The setup instructs users to point the call app's speaker at a loopback (BlackHole) — which is often the system default — so cleaned audio replayed to the default could loop straight back into the captured source: a feedback path.
- **Decision:** `applyIncomingCleanup()` constructs/starts the engine ONLY when enabled with BOTH a source AND a monitor that each re-pass the canonical predicates (`isSelectableIncomingSource` / `isSelectableMonitorOutput`) and `incomingOutputDeviceID != 0`; otherwise it tears down to `nil`. "No valid monitor" means "do not run" — never "fall back to default". `IncomingCleanupEngine.start()` also bails (no playback graph) if the source can't be attached. UI: the "Hear on" picker has an explicit "Select…" (`tag(0)`) state.
- **Rule:** A render path that plays to a user-chosen device must validate that device (and refuse to run) rather than silently falling back to the system default — especially when a loopback is in the signal chain.
- **Files:** `Sources/Core/AudioModel.swift` (`applyIncomingCleanup`), `Sources/Core/AudioProcessing/IncomingCleanupEngine.swift` (`start`, `configureCapture`), `Sources/App/SettingsView.swift`, `Sources/App/ContentView.swift`.

### [DECISION] 2026-06-15 — Incoming/guest cleanup is a SEPARATE engine, not a second AudioModel (@Valsaraj)
- **Problem:** Cleaning the *other* side of a call (a noisy guest) is the mirror of mic cleaning, so it's tempting to reuse `AudioModel` or its render path.
- **Decision:** Ship a standalone `IncomingCleanupEngine` that owns its OWN `AVCaptureSession`, `AVAudioEngine`, `RingBuffer`, and `DeepFilterNetDSP`. It must NOT touch the mic path or the NoNoise Mic sink, and it runs DeepFilterNet **only** — no `VoiceChain`/Broadcast Voice (that polish is voice-shaping for the outgoing mic, wrong for arbitrary guest audio). Keeps the two pipelines independently startable and avoids coupling render-thread state.
- **Rule:** A second cleaning pipeline gets its own engine + its own DSP instance (own recurrent state). Never share DeepFilterNet streaming state between the mic and incoming paths.
- **Files:** `Sources/Core/AudioProcessing/IncomingCleanupEngine.swift`, `Sources/Core/AudioModel.swift`.

### [DECISION] 2026-06-15 — Incoming engine is a lazy-OWNED optional, off by default (zero-cost when off) (@Valsaraj)
- **Problem:** `DeepFilterNetDSP.init()` allocates ML buffers and async-loads the CoreML model. A stored `let` incoming engine would pay that cost at launch even for users who never clean incoming audio.
- **Decision:** `AudioModel` holds `IncomingCleanupEngine?` (OPTIONAL, never a stored `let`). `applyIncomingCleanup()` CREATES it on the enabled transition and releases it to `nil` when disabled. Feature is OFF by default; the second AI stream only runs while enabled. Persisted via `mv.incomingEnabled` / `mv.incomingSourceUID` / `mv.incomingOutputUID` and re-applied after `loadSettings()`.
- **Rule:** Any heavy, optional audio engine (ML model load) must be lazily created on enable and torn down to `nil` on disable — never instantiated at launch.
- **Files:** `Sources/Core/AudioModel.swift` (`applyIncomingCleanup`, `persistIncomingSettings`, `loadSettings`).

### [GOTCHA] 2026-06-15 — Incoming SOURCE is input-scope (reject physical mics); MONITOR is output-scope (@Valsaraj)
- **Symptom:** A naïve device list either offers the user's physical mic as an "incoming source" (nonsense) or persists the wrong monitor device.
- **Root cause:** Source and monitor come from DIFFERENT HAL scopes and DIFFERENT maps. Conflating them surfaces physical mics as sources or saves a source UID where a monitor UID belongs.
- **Fix/Rule:** Enumerate sources on the **INPUT** scope (`fetchIncomingDevices`) and filter with `VirtualMicRouting.isSelectableIncomingSource`, which REJECTS physical mics via `DeviceInfo.transportType` (virtual/aggregate) + `hasInput` — only loopback/aggregate inputs qualify. Enumerate monitors on the **OUTPUT** scan (`isSelectableMonitorOutput`) and ALWAYS persist the monitor UID from `monitorOutputUIDByID` (the output map), never from the input-source map.
- **Files:** `Sources/Core/AudioProcessing/VirtualMicRouting.swift`, `Sources/Core/AudioModel.swift` (`fetchIncomingDevices`, `fetchOutputDevices`, `persistIncomingSettings`).

### [GOTCHA] 2026-06-15 — Capture a HAL device by UID via AVCaptureDevice(uniqueID:); live buffers are TCC-gated (@Valsaraj)
- **Symptom:** Spike captured nothing from BlackHole at first; easy to misread as "AVCapture can't see virtual devices."
- **Root cause:** `AVCaptureDevice(uniqueID:)` DOES resolve a CoreAudio device's real `kAudioDevicePropertyDeviceUID` and attaches to an `AVCaptureSession` — but live sample-buffer delivery requires microphone (TCC) permission, which a bare spike binary lacks.
- **Fix/Rule:** Resolve the incoming source by its real HAL UID (not name) through `AVCaptureDevice(uniqueID:)`; match the Task-S spike. If buffers don't arrive, suspect TCC/mic permission of the host process FIRST — the resolution + attach path is proven sound.
- **Files:** `Sources/Core/AudioProcessing/IncomingCleanupEngine.swift` (`configureCapture`).

### [DECISION] 2026-06-15 — Carbon RegisterEventHotKey over NSEvent global monitors (@Valsaraj)
- **Problem:** System-wide hotkeys for a backgrounded menu-bar app.
- **Decision:** Use Carbon `RegisterEventHotKey` + `InstallEventHandler`. It works under the
  hardened runtime with the existing two entitlements (no new entitlement, no Accessibility prompt).
  `NSEvent.addGlobalMonitorForEvents` is the SwiftUI-friendly alternative but requires Accessibility
  permission — violating the minimal-entitlement policy.
- **Rule:** Never add Accessibility permission for hotkey capture in this app. If global key
  monitoring is ever needed beyond registered combos, revisit and document the permission impact.
- **Files:** `Sources/App/HotkeyManager.swift`, `Resources/NoNoiseMac.entitlements`

### [PATTERN] 2026-06-15 — Pure reducer in Core makes the control layer testable (@Valsaraj)
- **Problem:** The test target depends on `Core` only; `AudioModel.init()` starts CoreAudio so it
  is not headless-testable. Putting control logic in `Sources/App` (consumed via `@testable import
  Core`) would be untestable and would not even compile from tests.
- **Decision:** Keep the PURE models + a `ControlReducer` over a value-type `ControlState` in
  `Sources/Core/ControlLayer.swift`. `ActionDispatcher` (App) is a thin adapter (read state from
  `AudioModel` → reduce → write back). Tests exercise the reducer directly — no test-only branches.
- **Rule:** Any control/state logic that must be tested goes in `Core` as a pure function over a
  value type; the App layer only adapts it onto live objects. Never put testable logic in `App`.
- **Files:** `Sources/Core/ControlLayer.swift`, `Sources/App/ActionDispatcher.swift`,
  `Tests/NoNoiseMacTests/ControlLayerTests.swift`

### [GOTCHA] 2026-06-15 — A/B bypass needs desired-vs-effective AI state (@Valsaraj)
- **Problem:** Naïvely saving `isAIEnabled` on bypass entry and restoring on exit breaks if the user
  toggles AI WHILE bypassed: the toggle flips the forced-off live value, then bypass exit clobbers it
  back to the pre-bypass value — the toggle is lost.
- **Root Cause:** A single `isAIEnabled` field conflated "what the user wants" with "what's playing".
- **Fix:** Separate `desiredAI` (what the user wants, flipped by `.toggleAI` always) from effective AI
  (`desiredAI && !bypassed`, written to `AudioModel.isAIEnabled`). Bypass exit recomputes effective
  from the CURRENT desired value. See `ControlReducer` + the bypass-sequence tests.
- **Rule:** When a transient override (bypass) suppresses a user-settable flag, store the user's
  desired value separately and recompute the effective value — don't save/restore the live value.
- **Files:** `Sources/Core/ControlLayer.swift`, `Tests/NoNoiseMacTests/ControlLayerTests.swift`

### [GOTCHA] 2026-06-15 — Carbon EventHotKeyID must be deterministic, not hashValue (@Valsaraj)
- **Problem:** Building `EventHotKeyID.id` from `action.rawValue.hashValue` makes the fired hotkey
  ID un-matchable: Swift's `String.hashValue` is randomized per process, so the value used at
  registration differs from naive reconstruction and the event can't be routed back to its action.
- **Fix:** Derive the numeric ID from the action's index in `HotkeyActionID.allCases` (+1, never 0).
  Also: the Carbon C callback must not call a `@MainActor` method synchronously — extract the
  `EventHotKeyID` in the callback, then hop via `Task { @MainActor in … }`.
- **Rule:** Carbon `EventHotKeyID`s must be stable, deterministic small integers; bridge C callbacks
  to the main actor explicitly instead of assuming the calling thread.
- **Files:** `Sources/App/HotkeyManager.swift`

### [GOTCHA] 2026-06-15 — Dispatcher must apply explicit mutations, never blanket-write AudioModel (@Valsaraj)
- **Problem:** An `ActionDispatcher` that pushed the whole reduced state back onto `AudioModel` every
  dispatch (`model.outputGainValue = state.gain`, `model.selectedPreset = state.preset`, …) corrupted
  preset state. `AudioModel.outputGainValue.didSet` calls `onKnobChanged()`, which flips a non-`.custom`
  preset to `.custom` — so even `.toggleAI` (which never touches gain) demoted Meeting/Podcast/Tutorial
  to Custom. Worse, `.presetNext` wrote `selectedPreset` (whose `didSet` → `applyPreset` sets the
  preset's gain/atten) and THEN wrote the pre-change `state.gain` back, overriding the preset gain and
  re-flipping to Custom.
- **Root Cause:** `AudioModel`'s `@Published` knobs are NOT inert setters — their `didSet`s mutate
  preset state. Writing an unchanged field is not a no-op.
- **Fix:** `ControlReducer.reduce` returns `(ControlState, [ControlMutation])`. Each mutation
  (`.setAIEffective`/`.setPreset`/`.setClarity`/`.setGain`) names exactly one changed field; the adapter
  applies ONLY those. `.toggleAI`/bypass → `.setAIEffective` only; `.presetNext/prev` → `.setPreset`
  only (no trailing gain write — the preset owns its gain); `.gainUp/down` → `.setGain` (the
  `onKnobChanged()` → `.custom` flip is the intended manual-edit behavior).
- **Rule:** When adapting a pure reducer onto a stateful object whose setters have side effects, emit
  an explicit list of changed fields and write only those — never blanket-write the full snapshot.
- **Files:** `Sources/Core/ControlLayer.swift`, `Sources/App/ActionDispatcher.swift`,
  `Tests/NoNoiseMacTests/ControlLayerTests.swift`

### [GOTCHA] 2026-06-15 — Bypass-safe AI must gate the UI toggle, not just the dispatcher (@Valsaraj)
- **Problem:** The desired-vs-effective AI rule is only canonical for dispatcher actions. The popover
  master toggle bound directly to `$audioModel.isAIEnabled`, so during bypass a user could flip the UI
  toggle and write `isAIEnabled = true` straight onto the model — re-enabling AI processing while
  `isBypassed == true`, defeating the bypass.
- **Fix:** Bind the toggle to `dispatcher.aiToggleBinding` (routes through `.toggleAI`) and
  `.disabled(dispatcher.isBypassed)`. Desired AI is still changeable by hotkey while bypassed.
- **Rule:** Any UI control that writes a field also owned by a transient-override state machine must go
  through that machine (or be disabled while the override is active) — a direct binding is a back door.
- **Files:** `Sources/App/ContentView.swift`, `Sources/App/ActionDispatcher.swift`
### [DECISION] 2026-06-15 — Input Volume is app-level pre-DSP trim, not hardware volume (@Valsaraj)
- **Problem:** Hot mics clip or sound crushed/harsh after NoNoise processing; users expect a macOS-like "Input Volume" control.
- **Decision:** Ship **Input Volume** as an app-level scalar applied after conversion and before the ring buffer (`mv.inputVolume`). Do not write macOS system/hardware input volume — keeps behavior reversible, per-app, and consistent across USB/BT/built-in mics. Pair with optional **Smart Level** that only *reduces* gain when trimmed peaks repeatedly hit ~0.98; never auto-boosts. The visible input meter shows trimmed NoNoise input RMS, while raw peak remains a source-clipping warning.
- **Rule:** Audio capture/render paths read a plain `realtimeInputVolume` scalar mirrored from UI state; publish peaks via lock-free scalars + main timer, never `@Published` from realtime threads.
- **Files:** `Sources/Core/AudioModel.swift`, `Sources/Core/AudioProcessing/SmartLevelController.swift`, `Sources/App/SettingsView.swift`.

### [GOTCHA] 2026-06-15 — `loadSettings()` early-return skipped Voice Profiles decode

- **Symptom**: A first-launch user who saved a Voice Profile from the default state saw it vanish
  after relaunch (data was still in `UserDefaults`, just not loaded into the UI).
- **Root cause**: `saveCurrentAsProfile` persists ONLY `mv.profiles` (via `persistProfiles()`),
  never `mv.preset`. `loadSettings()` decoded `mv.profiles` at the END of the method, AFTER the
  `guard let raw = d.string(forKey: PrefKey.preset) else { … return }` early-return for absent
  `mv.preset`. So `mv.profiles`-without-`mv.preset` hit the early return and never loaded profiles.
- **Rule**: Load independently-persisted collections (`mv.profiles`) at the TOP of `loadSettings()`,
  BEFORE any preset/settings early-return. Persistence keys that are written by different code paths
  must be read on every launch path, not gated behind another key's presence.
- **Files**: `Sources/Core/AudioModel.swift` (`loadSettings`).

---

### [DECISION] 2026-06-15 — Voice Profiles: extensible versioned schema via optional Codable fields

**Problem**: Adding new user-tunable settings (Mouth Noise, Input Volume, Smart Level, future
Metering & Loudness) would break saved profiles if the schema required all fields to be present.
**Decision**: Declare all extension-point fields as `var field: Type? = nil` in `VoiceProfile`.
Swift's Codable synthesis silently ignores unknown JSON keys (forward-compat) and decodes missing
optional keys as `nil` (backward-compat). A `version: Int = 1` field provides a hook for future
breaking migrations without coupling to optional-field additions. The `VoiceProfile.decoder` is
the single configuration point (`keyDecodingStrategy = .convertFromSnakeCase`); callers never
build their own decoder.
**Rule**: Any new user-tunable setting added to the app MUST be added to `VoiceProfile` as an
optional field at the same time. Mandatory fields (non-optional) require a version bump and a
migration in `VoiceProfileStore.decode(from:)`.
**Files**: `Sources/Core/VoiceProfile.swift`, `Sources/Core/VoiceProfileStore.swift`,
`Tests/NoNoiseMacTests/VoiceProfileTests.swift`.

---

### [DECISION] 2026-06-15 — Broadcast Voice preserves voice identity by construction
- **Problem:** A "crispiness"/clarity control naïvely implemented as a high-shelf boost amplifies
  sibilance, mouth noise, and residual hiss (the classic "ice-pick" voice).
- **Decision:** Implement clarity as (1) a wide-Q **peaking bell** at ~4.5 kHz with **unity gain at
  DC/Nyquist** (cannot alter the vocal fundamental/body) and (2) a **subtractive split-band
  de-esser** `out = x − frac·sib` that is a **perfect identity below threshold** and only removes a
  capped fraction of the sibilant band. De-ess scales WITH the presence lift so "crisp" is always
  paired with sibilance control.
- **Rule:** Any future "voice enhancement" must default to a verifiable null/identity at rest and
  must not color the low/mid band — prove it with a unity-DC-gain test and a below-threshold
  identity test.
- **Files:** `Sources/Core/AudioProcessing/Biquad.swift`,
  `Sources/Core/AudioProcessing/Dynamics.swift`, `Sources/Core/AudioProcessing/VoiceChain.swift`.

### [PATTERN] 2026-06-15 — Device lists refresh from HAL notifications, not polling or relaunch
- **Symptom:** macOS showed a newly plugged microphone immediately, but NoNoise Mac's input picker
  stayed stale until the app was relaunched.
- **Root cause:** `AudioModel.fetchInputDevices` and `fetchOutputDevices` ran on launch only. There
  was no listener for `kAudioHardwarePropertyDevices`, so the SwiftUI picker never received a new
  published device list after hot-plug events.
- **Fix/Rule:** observe `kAudioHardwarePropertyDevices` on the system object with
  `AudioObjectAddPropertyListenerBlock`, debounce the refresh on the main queue, and refresh both
  AVCapture inputs and CoreAudio outputs. Preserve the selected input if it is still connected; only
  fall back to the system default or first device when the selected mic disappears. Re-resolve the
  NoNoise Mic lifecycle on the same refresh so installing/removing the virtual driver while the app
  is open updates routing and on-demand capture.
- **Files:** `Sources/Core/AudioModel.swift` (`installHardwareDeviceListener`,
  `refreshDevicesAfterHardwareChange`, `fetchInputDevices`).

### [GOTCHA] 2026-06-15 — Swift 5.10 CI cannot type-check `MLShapedArray<Float16>` on macOS
- **Symptom:** GitHub Actions failed in `swift build` on macos-14 / Swift 5.10 with
  `conformance of 'Float16' to 'MLShapedArrayScalar' is unavailable in macOS`, while local Swift 6.3
  builds were green.
- **Root cause:** the generated CoreML wrapper exposed unused `MLShapedArray<Float16>` convenience
  initializers/properties. Even with `@available(macOS 15.0, *)`, Swift 5.10 still type-checks the
  signature and rejects the unavailable Float16 conformance.
- **Fix/Rule:** keep runtime DSP on the `MLMultiArray` path and gate the shaped-array conveniences
  behind `#if compiler(>=6.0)` in `Sources/Core/AudioProcessing/DeepFilterNet3_Streaming.swift`.
  If the wrapper is regenerated, preserve that gate or delete those conveniences.

### [GOTCHA] 2026-06-15 — A hidden device is NOT in `kAudioHardwarePropertyDevices`; route to it by UID translate
- **Symptom (first on-device test):** "NoNoise Mic" appeared in recorders but produced **silence**. The
  app was rendering cleaned audio to **BlackHole** instead of the NoNoise engine.
- **Root cause:** the engine device sets `kAudioDevicePropertyIsHidden = 1` (so it stays out of every
  app's picker). But hidden ALSO removes it from the `kAudioHardwarePropertyDevices` enumeration —
  proven by a probe: `engine UID -> id 120, enumerated=false`, while UID-translate still resolves it.
  `AudioModel.fetchOutputDevices` only iterated the enumeration, never saw the engine, and
  `preferredOutputUID` fell back to BlackHole. With the round-1 silence guard, the un-fed mic ring
  correctly returned silence — so the routing miss surfaced as "no audio" rather than garbage.
- **Fix/Rule:** resolve the hidden engine with `kAudioHardwarePropertyTranslateUIDToDevice` (same call
  already used for `driverInstalled`) and INJECT it into the route set; never rely on enumeration to
  find a hidden device. The engine still never enters the user-facing picker.
- **Files:** `Sources/Core/AudioModel.swift` (`fetchOutputDevices`). Probe lives at `/tmp/probe.swift`.

### [DECISION] 2026-06-15 — On-demand capture: hold the real mic only while "NoNoise Mic" is in use
- **Why:** users (rightly) expect the macOS orange mic indicator to be ON only when something is
  actually listening — Krisp behaves this way. Capturing the real mic continuously from app launch
  pins the indicator the whole time the app is open.
- **How:** when the driver is installed, observe `kAudioDevicePropertyDeviceIsRunningSomewhere` on the
  visible "NoNoise Mic" via `AudioObjectAddPropertyListenerBlock`. Start the `AVCaptureSession` only
  when it flips to running; stop it when it flips off. The render engine to the hidden sink stays
  warm (low-latency start; outputs silence while idle). Keyed to the MIC device (id 118), which the
  app never does IO on, so the signal reflects external consumers only — not our own engine IO (120).
- **Fallback:** without the driver (BlackHole), there's no per-use signal (the app's own output IO
  would make BlackHole's running-state circular), so capture stays always-on.
- **Files:** `Sources/Core/AudioModel.swift` (`resolveVirtualMicLifecycle`, `refreshVirtualMicUsage`,
  `startCapture`/`stopCapture`, gated `setupCaptureSession`).

### [GOTCHA] 2026-06-15 — Loopback ring replays stale speech unless reads are window-guarded (privacy)
- **Symptom (caught in Codex code review):** a modulo ring (`nn_ring_read_at` reading `storage[pos & mask]`)
  keeps returning the LAST ~1.3 s of cleaned audio after the writer stops — because the mic-read device
  and the engine-write device are SEPARATE objects with separate `StartIO`/`StopIO`. App quits / toggles
  off → engine stops writing, but Slack still captures "NoNoise Mic" → it hears a loop of your last words.
- **Root cause:** modulo indexing has no notion of "this frame was never written" — old slot contents alias
  back. Two-device topology makes the writer-stops-while-reader-runs case routine, not exotic.
- **Fix/Rule:** the ring tracks a `writeEnd` watermark (publish release after the slot writes, read acquire
  before). `nn_ring_read_at` zeroes any frame `>= writeEnd` (unwritten) or `< writeEnd - capacity`
  (overwritten). Reads outside the valid window are SILENCE. Host tests assert read-before-write,
  writer-stopped, and partial-straddle silence. Same rule for the `sourceMode==1` mic branch (A2 stub):
  `memset` silence, never serve whatever's lying around.
- **Files:** `Driver/NoNoiseMic/nn_ring.{c,h}`, `Driver/tests/test_nn_ring.c`, `Driver/NoNoiseMic/NoNoiseMic.c`.

### [GOTCHA] 2026-06-15 — HAL driver must size-check every `GetPropertyData` write & validate the FULL ASBD
- **Symptom (Codex review):** scalar/CFString property branches wrote `*(UInt32*)outData = …` /
  `*(CFStringRef*)outData = …` with no `inDataSize` check, and the stream format setter accepted a format
  on rate/id/channels/bits alone — ignoring `mFormatFlags`/`mBytesPerFrame`.
- **Root cause:** a short caller buffer corrupts `coreaudiod`'s heap; a partial ASBD check lets a client
  negotiate a NON-interleaved/repacked layout that `DoIOOperation` (packed-interleaved-only) then
  silently corrupts or channel-swaps. Apple's NullAudio guards every branch for exactly this reason.
- **Fix/Rule:** `PUT_SCALAR`/`PUT_CFSTRING` macros return `kAudioHardwareBadPropertySizeError` before any
  write; the format setter compares the FULL canonical `MakeASBD()` (flags + bytes/frame + bytes/packet +
  frames/packet too) and rejects anything else with `kAudioHardwareIllegalOperationError`.
- **Files:** `Driver/NoNoiseMic/NoNoiseMic.c` (`NoNoiseMic_GetPropertyData`, `NoNoiseMic_SetPropertyData`).

### [DECISION] 2026-06-15 — NoNoise Mic driver: two-device loopback topology, one canonical layout
- **Topology:** a VISIBLE input-only device + a HIDDEN output-only "engine" device (NOT one duplex
  device). The app renders cleaned audio to the engine; consumer apps pick the visible mic. Both
  share ONE `nn_ring` + a per-device `nn_clock` anchored to a SINGLE host time captured on the first
  `StartIO`, so the engine write axis and the mic read axis coincide.
- **One canonical layout everywhere:** 48 kHz, 2ch, **interleaved** Float32 (`kAudioFormatFlagIsFloat
  | kAudioFormatFlagIsPacked`). The HAL's `ioMainBuffer` is passed straight into `nn_ring`
  (`channels=2`) — no de/interleave at any layer. `test_stereo_channels_preserved` guards L/R order
  across a wrap.
- **Phasing:** A1 = in-driver loopback (`sourceMode 0`, default, shipped); A2 = XPC + shared memory
  (`sourceMode 1`) gated behind a coreaudiod-reachability spike. Cross-ref the silent-non-load
  GOTCHA below.
- **Why two devices, not duplex:** keeps the visible mic free of any output stream (clean picker
  semantics) and the engine hidden + non-default-eligible. Full contract in `AGENTS.md` → driver section.

### [GOTCHA] 2026-06-15 — AudioServerPlugIn silently fails to load (signature / CFPlugIn keys)
- **Symptom:** `NoNoiseMic.driver` installed to `/Library/Audio/Plug-Ins/HAL` but "NoNoise Mic"
  never appears as a device — and `coreaudiod` logs nothing obvious.
- **Root cause:** `coreaudiod` **silently ignores** a HAL plug-in whose code signature is invalid
  or whose `Info.plist` `CFPlugInFactories` / `CFPlugInTypes` keys are wrong (the type UUID must be
  `443ABAB8-E7B3-491A-B985-BEB9187030DB` and the factory string must match the exported
  `NoNoiseMic_Create` symbol). Editing the bundle **after** `codesign` also invalidates the
  signature → silent non-load.
- **Fix/Rule:** `build-driver.sh` signs **after** full assembly; `install-driver.sh` verifies via
  `system_profiler SPAudioDataType | grep "NoNoise Mic"` and the app re-confirms by translating the
  visible UID (`kAudioHardwarePropertyTranslateUIDToDevice`). Never edit a signed `.driver`; rebuild.
- **Files:** `Driver/NoNoiseMic/NoNoiseMic.c`, `Driver/NoNoiseMic/Info.plist`, `build-driver.sh`,
  `install-driver.sh`.

### [GOTCHA] 2026-06-15 — `allow-jit` entitlement is required for CoreML/Metal
- `Resources/NoNoiseMac.entitlements` carries two keys: `com.apple.security.device.audio-input`
  (mic) and `com.apple.security.cs.allow-jit`. The latter is needed because DeepFilterNet3 runs on
  GPU/ANE and Metal shader compilation JITs under the hardened runtime — removing it can break
  inference at runtime. It was inherited from the original app (kept byte-identical); justification
  now lives in `AGENTS.md` → Entitlements & signing. Do not strip it without on-device verification.

### [DECISION] 2026-06-15 — Docs must match the real CLI contract
- `NoNoiseMacCLI` with no `--in`/`--out` prints an error and exits 1; `--help` exits 0; device names
  are echoed only after a valid launch (`Sources/CLI/main.swift:21-23,30-34,42,51`). README must
  describe this exactly — a marketing page that advertises a non-existent mode erodes first-release
  trust. Caught by the pre-publish Codex code review.

### [DECISION] 2026-06-15 — AI noise cancellation defaults ON
- `AudioModel.isAIEnabled` defaults to `true` so suppression is active on first launch
  (product decision for NoNoise Mac). The Meeting preset remains the default profile.
- Implication: the model is exercised immediately; keep the CoreML init path healthy.

### [DECISION] 2026-06-15 — Rebrand to NoNoise Mac; internal `mv.*` keys kept
- Renamed display/identifier/bundle to NoNoise Mac / `NoNoiseMac` / `com.ivalsaraj.NoNoiseMac`.
- `UserDefaults` keys intentionally **kept** in the legacy `mv.*` namespace — invisible to
  users, renaming would only add migration risk. See `AGENTS.md` → Branding conventions.

### [GOTCHA] CoreML Float16 outputs read back as zeros on ANE/GPU
- See `critical-patterns.md`. Read model outputs via `NSNumber`, not raw Float16 buffers.

### [GOTCHA] Inventing a spectral compression exponent muffles speech
- Stock DeepFilterNet has none; do not add `c=0.5/0.6` or de-normalize the output.

### [PATTERN] Keep DSP math in pure, testable statics
- `minGain(forAttenuationDb:)`, `resolveOutputBin(...)`, and the `VoiceChain` value types
  (`Biquad`/`Compressor`/`Limiter`) are unit-tested without CoreML. New DSP math should
  follow the same shape (30 tests currently cover this).

### [DECISION] 2026-06-15 — Mouth-noise finishers: subtractive detection preserves voice character
- **Problem**: P-pops and mouth clicks cannot be removed by EQ or de-essing alone — they
  span the wrong frequency bands and timescales.
- **Decision**: (1) `DePlosive` uses a dual-threshold detector (total energy AND low/total
  ratio) to distinguish plosive thumps from voiced stops (B, D, G). Only when BOTH gates
  fire does it subtractively duck the low band (`out = x − frac·lowSig`) — leaving the
  mid-range voice body untouched. (2) `DeClick` uses a fast/slow envelope ratio — a click
  appears as an anomalous spike relative to the speech background — and applies a hold-and-
  release gain only for a few milliseconds, too brief to affect any voiced phoneme.
- **Rule**: Any transient-targeted artifact suppressor must have a dual-gate (absolute
  threshold + relative detection) and be tested for identity below threshold AND
  preservation of the nearest voiced phoneme (voiced stop at the same level as the
  artifact). Single-threshold detection is prone to false positives on consonant bursts.
- **Files**: `Sources/Core/AudioProcessing/Dynamics.swift`,
  `Sources/Core/AudioProcessing/VoiceChain.swift`,
  `Tests/NoNoiseMacTests/MouthNoiseTests.swift`

### [CORRECTION] 2026-06-15 — Mouth-noise finishers must detect TRANSIENTS, not steady low-band energy (@Valsaraj)
**Supersedes**: docs/knowledge/knowledge1.md, 2026-06-15 — Mouth-noise finishers: subtractive detection preserves voice character
- **Problem**: With Mouth Noise enabled, voiced speech sounded muffled on the highs with faint
  distortion. The earlier "dual-threshold" `DePlosive` (total energy AND low/total ratio) is a
  STEADY-STATE detector: `lowEnv/totalEnv ≥ 0.60` holds for essentially ALL voiced speech (vowels
  are low-dominant), so it ducked the low band continuously.
- **Root Cause**: (1) A low/total ratio is NOT a plosive discriminator — sustained voicing is also
  low-dominant. (2) The subtractive form `out = x − frac·lowSig` with `lowSig = x − hp(x)` re-injects
  a phase-shifted high-passed copy, so steady firing both dulls the low-mids AND intermodulates the
  highs. (3) The old `DeClick` ratio (6.0) with an attack/release fast envelope never tripped on
  real few-sample clicks → inert.
- **Fix**: Detect the two things that actually distinguish the artifacts from voicing.
  - De-plosive: a TRANSIENT SURGE (`fastLow/slowLow ≥ surgeRatio`) that is spectrally CONCENTRATED
    in the low band (`fastLow/(fastLow+fastHigh) ≥ dominance`), above an absolute floor, ducking a
    CLEAN low-pass band (new `Biquad.setLowPass`) with a smoothed `frac`. Steady voicing → surge ≈ 1
    → never gates. (`Dynamics.swift` `DePlosive`)
  - De-click: an instant-attack PEAK follower vs a slow background with a WALL-CLOCK event latch —
    a click is a short event (fully ducked); a sustained rise latches off within `maxClickMs`. (`DeClick`)
- **Rule**: A transient-artifact suppressor must gate on a TIME-LOCAL change (surge / peak-vs-background)
  AND a spectral signature — NEVER on a steady band-ratio, because voiced speech occupies the same
  bands. Always validate against sustained harmonic-rich voicing AND voiced onsets, not just pure sines.
- **Files**: `Sources/Core/AudioProcessing/Dynamics.swift`, `Sources/Core/AudioProcessing/Biquad.swift`,
  `Sources/Core/AudioProcessing/VoiceChain.swift`, `Tests/NoNoiseMacTests/MouthNoiseTests.swift`
