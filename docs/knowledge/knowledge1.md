# Knowledge Log

`[GOTCHA]` / `[DECISION]` / `[PATTERN]` entries. Newest on top. See `critical-patterns.md`
for the must-read failure modes.

---

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

### [DECISION] 2026-06-15 — Input Volume is app-level pre-DSP trim, not hardware volume (@Valsaraj)
- **Problem:** Hot mics clip or sound crushed/harsh after NoNoise processing; users expect a macOS-like "Input Volume" control.
- **Decision:** Ship **Input Volume** as an app-level scalar applied after conversion and before the ring buffer (`mv.inputVolume`). Do not write macOS system/hardware input volume — keeps behavior reversible, per-app, and consistent across USB/BT/built-in mics. Pair with optional **Smart Level** that only *reduces* gain when peaks repeatedly hit ~0.98; never auto-boosts.
- **Rule:** Audio capture/render paths read a plain `realtimeInputVolume` scalar mirrored from UI state; publish peaks via lock-free scalars + main timer, never `@Published` from realtime threads.
- **Files:** `Sources/Core/AudioModel.swift`, `Sources/Core/AudioProcessing/SmartLevelController.swift`, `Sources/App/SettingsView.swift`.

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
