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
  - `AudioProcessing/VoiceChain` + `Biquad` + `Dynamics` — post-DSP "voice polish" (high-pass → shelves → compressor → limiter).
  - `AudioProcessing/RingBuffer`, `SpecHistoryRingBuffer`, `AudioUtils` — buffers + helpers.
  - `VoicePreset` — preset → DSP params + voice-chain settings (single source of truth).
- `Sources/App` — SwiftUI menu-bar app: `NoNoiseMacApp`, `ContentView` (popover), `SettingsView`.
- `Sources/CLI` — `NoNoiseMacCLI`, a headless input→output pipeline.
- `Resources` — `DeepFilterNet3_Streaming.mlmodelc`, `AppIcon.icns`, `NoNoiseMacLogo.png`, `Info.plist`, `NoNoiseMac.entitlements`.
- `Tests/NoNoiseMacTests` — pure DSP / preset / voice-chain unit tests (run headless).

## Build, run, test
```bash
swift build                 # debug
swift build -c release      # release (bundle.sh prerequisite)
swift test                  # 30 pure tests — no mic/CoreML runtime needed
./bundle.sh                 # → NoNoiseMac.app + NoNoiseMacCLI (codesigned w/ entitlements)
```
The app is a menu-bar utility (`LSUIElement`); **AI noise cancellation is ON by default**
(`AudioModel.isAIEnabled = true`).

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
- `VoiceChain` (Core/AudioProcessing) runs AFTER `DeepFilterNetDSP` on the time-domain output, inside `AudioModel`'s render callback, only when `isAIEnabled`. Order: high-pass → low-shelf → high-shelf → compressor → limiter. The Limiter is last and hard-clamps to the ceiling — it is the final overflow guard.
- Built from pure, unit-tested value types: `Biquad` (RBJ cookbook coefficients, TDF-II), `Compressor` (log-domain feed-forward), `Limiter` (fast peak + hard clamp). Keep all DSP math here, testable, with no CoreML dependency.
- **Real-time rule**: `VoiceChain.process` is allocation-free and per-sample; `configure(_:)` (coefficient recompute) runs on main only. State (`Biquad.z1/z2`, `Compressor.envDb`, `Limiter.gain`) carries across render buffers — never reset per buffer. `configure` resets state ONLY on the disabled→enabled transition (clean start); enabled→enabled preset switches are intentionally bumpless.
- Chain params are a pure function of `VoicePreset.voiceChain` (NOT persisted per-stage). Effective enabled = `voicePolishEnabled && preset.voiceChain.enabled`. Meeting = off; Podcast/Tutorial/Custom = on. Only the `mv.voicePolish` master toggle is persisted (plus the Tier 1 `mv.preset`).
- `applyVoiceChain()` reconfigures the chain on every preset transition (explicit pick AND the auto-flip to Custom) and on toggle/load — never from the per-tick knob path more than once per transition. `voicePolishEnabled.didSet` is guarded by `!isApplyingPreset` exactly like the Tier 1 knobs.

## NoNoise Mic virtual driver (Tier 3, Spec A) — `Driver/`
- **What:** a userspace CoreAudio **AudioServerPlugIn** (`Driver/NoNoiseMic/NoNoiseMic.c`) that publishes a **visible input-only** device "NoNoise Mic" + a **hidden output-only** device "NoNoise Mic Engine". The app renders cleaned audio to the engine device; consumer apps pick "NoNoise Mic" as their microphone. Phase A1 = in-driver **loopback**; Phase A2 (gated) adds an XPC/shared-memory path.
- **Shared contract (a mismatch fails SILENTLY — keep C and Swift identical):** visible name `NoNoise Mic` / UID `NoNoiseMic:visible:48k2ch`; engine name `NoNoise Mic Engine` / UID `NoNoiseMic:engine:48k2ch`; bundle id `com.ivalsaraj.NoNoiseMic`; 48000 Hz, 2ch. Swift mirror: `Sources/Core/AudioProcessing/VirtualMicRouting.swift`.
- **Canonical layout (one layout, every layer):** Float32 **interleaved** stereo `[L,R,L,R…]`, ASBD flags `kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked` (NEVER `…IsNonInterleaved`), `mBytesPerFrame = 8`. `ioMainBuffer` is passed straight into `nn_ring` (`channels=2`) — no de/interleave anywhere.
- **`sourceMode` (`'srcm'`, FourCharCode `0x7372636D`):** `0` = loopback (A1 default), `1` = xpc (A2). Use the char literal `'srcm'` in C — never hand-type the hex (a transposed digit fails silently). Cross-process Set needs `kAudioObjectPropertyCustomPropertyInfoList` registration — deferred to A2; A1 only relies on the default `0`.
- **Topology + timing:** ONE shared loopback ring (`nn_ring`) + a per-device zero-timestamp clock (`nn_clock`), both anchored to a SINGLE host time captured on the first `StartIO`, so the engine's write axis and the mic's read axis coincide. The engine device returns `0` for `…CanBeDefaultDevice`/`…CanBeDefaultSystemDevice` and `1` for `kAudioDevicePropertyIsHidden`.
- **Pure testable math:** the only risky logic (wraparound + zero-timestamp) lives in CoreAudio-free C (`Driver/NoNoiseMic/nn_ring.{c,h}`, `nn_clock.{c,h}`) and is host-unit-tested via `Driver/tests/run-tests.sh` (mirrors the repo's "keep DSP math in testable statics" rule). `DoIOOperation` stays allocation/lock/syscall-free.
- **Signing rule:** ad-hoc sign the bundle **AFTER** full assembly; any post-sign edit invalidates the signature and the plug-in **silently fails to load**. `install-driver.sh` verifies the device actually appeared. Distinguish app Gatekeeper (right-click → Open) from driver load (coreaudiod signature check).
- **Licensing:** original implementation against the public API (MIT) — NOT Apple sample source, NOT derived from BlackHole (GPL-3.0).
