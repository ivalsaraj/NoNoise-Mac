# Input Volume & Smart Level Plan

**Goal:** Fix hot-mic distortion where normal speech sounds too loud, hits the ceiling, or becomes
harsh after NoNoise processing. Ship a macOS-familiar **Input Volume** control first, then add
low-cost clipping detection and an optional **Smart Level** mode that protects the signal by reducing
gain when the voice repeatedly approaches the ceiling.

**Naming decision:** User-facing UI says **Input Volume**, matching macOS Sound Settings language.
Internally this is an app-level pre-DSP trim, not a write to the global macOS hardware input volume.
That keeps NoNoise reversible, per-app, privacy-safe, and predictable across USB/Bluetooth/built-in
mics. If a later release adds true hardware volume writes, it should be a separate explicit option.

**Relationship to the Metering & Loudness plan:** This is the fast, protective hot-mic guard. The
larger `docs/plans/2026-06-15-metering-and-loudness.md` plan still owns full LUFS metering,
normalization targets, and the richer HUD. This plan may reuse the same telemetry shape later, but
does not require BS.1770 or LUFS work to fix clipping.

## Current Code Facts

- `SettingsView` currently exposes **Output Gain** only, with a `0.5...4.0` range.
- `AudioModel.captureOutput(...)` converts the real mic to 48 kHz mono and writes samples directly
  into `ringBuffer`.
- `DeepFilterNetDSP.outputGain` is applied inside the DSP output path.
- `VoiceChain` can add compressor makeup, presence, and limiting after DSP.
- The existing limiter prevents numeric overflow, but a hot input can still sound crushed or harsh
  because the signal is already too close to full scale before/through processing.
- `AudioModel.inputLevel` is currently an RMS-ish visual meter, not a clip detector.
- `NoNoiseMacCLI --gain` controls output gain only. Input Volume is scoped to the app UI pipeline in
  this plan; adding a CLI input-volume flag can be a follow-up if needed.

## Product Behavior

### Manual Input Volume

Add a Settings control named **Input Volume**.

- Range: `25%...100%`
- Default: `100%`
- Reset button: `Reset to 100%`
- Persisted key: `mv.inputVolume`
- Applies before writing converted mic samples into `ringBuffer`
- Does not change macOS system input volume
- Does not alter default sound when left at `100%`

Recommended UI copy:

> Lowers your mic before NoNoise processing. Use this if your voice sounds clipped, crushed, or too
> loud even when speaking normally.

### Peak & Clip Detection

Track cheap sample peaks with scalar math only.

- Raw input peak: measured after conversion and **before** Input Volume.
- Trimmed input peak: measured after Input Volume, before `ringBuffer.write`.
- Output peak: measured in the render callback after DSP + `VoiceChain`.
- Near-ceiling threshold: `0.98`
- Clip threshold: `0.999`
- Publish lightweight state:
  - `rawInputPeak`
  - `trimmedInputPeak`
  - `outputPeak`
  - `isInputNearCeiling`
  - `isOutputClipping`
- UI should surface concise warnings:
  - `Input too loud`
  - `Output clipping`

Use raw input peak for warnings: if the physical mic/ADC is already clipping, software Input Volume
cannot repair the distortion that already happened. Use trimmed input peak for ring-buffer safety and
Smart Level decisions. If raw is clipping but trimmed is safe, still show copy like:

> Source mic is clipping before NoNoise. Lower macOS/device input volume if available.

For v1, this is **sample-peak**, not oversampled true-peak. Do not label it dBTP.

### Smart Level

Add a toggle named **Smart Level**.

Smart Level is protective, not a loudness maximizer. It should reduce gain when the signal is too
hot, but it should not boost quiet users automatically in this phase.

Behavior:

- If input repeatedly exceeds the near-ceiling threshold, reduce **Input Volume** gradually.
- If output clips while input is not near ceiling, reduce **Output Gain** gradually.
- Prefer reducing Input Volume when input is hot; prefer reducing Output Gain when processing/output
  is the source of clipping.
- Base automatic input reductions on trimmed input peak so Smart Level does not chase distortion that
  already happened before NoNoise. Raw clipping still raises a warning because the true fix may be
  lowering the hardware/system mic level.
- Never increase Input Volume automatically.
- Never make sudden jumps.
- Clamp automatic Input Volume reduction to a sane floor, recommended `35%`.
- Let the user manually set lower than the Smart Level floor if needed.
- Show the adjustment in UI text, e.g. `Smart Level reduced Input Volume to 78%`.

Suggested adjustment rule:

- Maintain small counters for consecutive hot windows.
- On every UI/meter tick, if a counter crosses the threshold, reduce the relevant control by about
  `1 dB`.
- Clear or decay counters when the signal returns below threshold.
- Minimum interval between automatic changes: about `300...500 ms`.

## Architecture

### AudioModel State

Add:

```swift
@Published public var inputVolumeValue: Float = 1.0
@Published public var smartLevelEnabled: Bool = false
@Published public var rawInputPeak: Float = 0.0
@Published public var trimmedInputPeak: Float = 0.0
@Published public var outputPeak: Float = 0.0
@Published public var isInputNearCeiling: Bool = false
@Published public var isOutputClipping: Bool = false
@Published public var smartLevelMessage: String?
```

Add persistence keys:

```swift
static let inputVolume = "mv.inputVolume"
static let smartLevel = "mv.smartLevel"
```

Use the existing `isApplyingPreset` guard pattern for persistence side effects. Do not read
`@Published` property-wrapper state from audio paths directly. Mirror UI values into plain runtime
scalars, and use a helper for programmatic changes so the UI value, persisted value, and runtime
scalar stay clamped together:

```swift
private var realtimeInputVolume: Float = 1.0

@Published public var inputVolumeValue: Float = 1.0 {
    didSet {
        realtimeInputVolume = min(max(inputVolumeValue, 0.25), 1.0)
        guard !isApplyingPreset else { return }
        persistSettings()
    }
}

private func setInputVolume(_ volume: Float) {
    inputVolumeValue = min(max(volume, 0.25), 1.0)
}
```

Smart Level calls `setInputVolume(...)` on the main thread; `captureOutput(...)` reads only
`realtimeInputVolume`.

### Input Volume Application

Apply Input Volume in `captureOutput(...)`, after conversion and before metering/ring write.

Implementation shape:

```swift
var inputVolume = realtimeInputVolume
if inputVolume != 1 {
    vDSP_vsmul(floatData, 1, &inputVolume, floatData, 1, vDSP_Length(convertedFrames))
}
```

The local `var` is the scalar pointer for `vDSP_vsmul`; do not pass `[inputVolume]`, because that
allocates an array in the capture path.

### Telemetry

Keep telemetry cheap:

- Scalar loop over the converted input buffer for input RMS/peak.
- Scalar loop over the render output buffer for output RMS/peak/clip.
- No Combine publishes, locks, heap allocations, or `DispatchQueue.main.async` from the render
  callback.
- Use plain scalar snapshots written by the capture/render paths and published by a modest main
  timer, around `25 Hz`.

Suggested private scalars:

```swift
private var tInputLevel: Float = 0
private var tRawInputPeak: Float = 0
private var tTrimmedInputPeak: Float = 0
private var tOutputPeak: Float = 0
private var tOutputClipCount: Int32 = 0
private var tRawInputClipCount: Int32 = 0
private var tTrimmedInputHotCount: Int32 = 0
private var meterTimer: Timer?
```

The main timer copies these into `@Published` state and then runs `updateSmartLevel()`. This is the
same directionally lock-free render/capture-to-main scalar pattern described in the larger metering
plan, but limited to the hot-mic guard.

Peak and clip scalars are windowed between timer ticks. Capture/render writers should update peaks
with `max(existing, newPeak)` and increment clip/hot counters. The main timer snapshots those values,
publishes them, then resets or decays the private scalars. Do not let one quiet buffer overwrite a
clip before the UI/Smart Level tick observes it.

Output clipping based only on post-limiter sample peak may rarely fire because the limiter clamps.
That is acceptable for v1 as protective telemetry, not full loudness analysis. A later implementation
can expose pre-limiter peak or limiter gain reduction from `VoiceChain` if needed.

### Smart Level Adjustment

Add a main-thread method:

```swift
private func updateSmartLevel()
```

It reads the published/snapshotted peak state and adjusts controls gradually:

- Trimmed input hot repeatedly: `setInputVolume(max(inputVolumeValue * dbToLinear(-1), 0.35))`
- Output clipping repeatedly while trimmed input is not hot:
  `outputGainValue = max(outputGainValue * dbToLinear(-1), 0.25)`
- Raw input clipping: show a warning that the source is clipping before NoNoise. Optionally still
  reduce Input Volume to protect downstream processing, but do not claim software can repair already
  clipped source audio.

Do not run adjustment logic on the render thread.

## Tests

Prefer pure tests where possible.

Add a pure helper if useful:

```swift
struct SmartLevelController {
    static func nextInputVolume(...)
    static func nextOutputGain(...)
}
```

Test cases:

- Input Volume default is unity.
- Input Volume scales samples before ring write behavior is wired.
- Raw input peak reports pre-trim clipping even when Input Volume lowers the trimmed peak.
- Smart Level reduces Input Volume after repeated hot input windows.
- Smart Level does not reduce from a single isolated peak.
- Smart Level reduces Output Gain when output clips but input is not hot.
- Smart Level never boosts Input Volume automatically.
- Smart Level respects the automatic floor.
- Runtime scalar mirrors `inputVolumeValue` immediately and the audio path reads the scalar, not the
  `@Published` property.
- Peak windows latch max/count until the main timer snapshots them, so a quiet buffer cannot hide a
  preceding clip.

AudioModel orchestration remains build/manual-smoke verified because initializing it starts
CoreAudio/AVFoundation.

## Implementation Tasks

- [ ] Add `inputVolumeValue`, `smartLevelEnabled`, peak/clip published state, persistence keys.
- [ ] Apply Input Volume pre-ring-buffer in `captureOutput(...)`.
- [ ] Add a plain `realtimeInputVolume` scalar and ensure audio paths read it instead of
      `@Published` state.
- [ ] Add Settings UI: **Input Volume** and **Smart Level** near Output Gain.
- [ ] Add raw input peak and trimmed input peak detection.
- [ ] Add output peak/clip detection in the render callback using scalar snapshots only.
- [ ] Add a main timer that publishes telemetry and runs Smart Level at a modest cadence.
- [ ] Add Smart Level controller logic and tests.
- [ ] Add a concise warning/message in the popover or Settings.
- [ ] Update `AGENTS.md` with the Input Volume/Smart Level pattern if implemented.
- [ ] Update `docs/knowledge/timeline1.md` and `docs/knowledge/knowledge1.md`.
- [ ] Verify with `swift build`, `swift build -c release --arch arm64`, and `swift test` if the
      current branch's unrelated tests are green.
- [ ] Run Codex review on the implementation.

## Manual Smoke Test

1. Install/run the app.
2. Select the real mic as input and `NoNoise Mic` in the recording app.
3. Speak normally with Input Volume at `100%`; observe whether warning appears.
4. Lower Input Volume to `70...80%`; confirm the recorded voice is less crushed.
5. Turn Smart Level on and speak loudly; confirm Input Volume steps down slowly, not abruptly.
6. With input no longer hot, raise Output Gain until output clips; confirm Smart Level reduces
   Output Gain instead.
7. Quit/relaunch; confirm Input Volume and Smart Level restore.
