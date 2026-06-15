# Hot Mic Ceiling Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make NoNoise Mac stop presenting and producing a ceiling-hit voice when the user lowers Input Volume, especially in Tutorial mode.

**Architecture:** Treat level safety as three separate points in the audio path: raw source peak (physical mic/ADC), trimmed app input level (what NoNoise actually processes), and processed output peak (what the virtual mic sends). Keep all hot-path work scalar/allocation-free, update pure tests first, and avoid hidden auto-boosts.

**Tech Stack:** Swift, AVFoundation/CoreAudio, Accelerate/vDSP, XCTest, existing `AudioModel`, `VoicePreset`, `VoiceChain`, and `SmartLevelController`.

---

## Current Diagnosis

The user reported that even with NoNoise **Input Volume** at 43%, the level still appears to hit max. The current code explains why:

- `AudioModel.captureOutput(...)` computes `rms` before applying `realtimeInputVolume`.
- `recordInputTelemetry(...)` publishes that raw pre-trim `rms` into `inputLevel`.
- Therefore the UI input meter can still read max at 43%, because it is showing the physical/source level, not the trimmed NoNoise input level.
- Raw peak telemetry is still valuable, but it should drive the source-clipping warning only. The main input meter should represent the trimmed signal that NoNoise actually processes.
- Tutorial preset also adds level twice: `outputGain = 1.2` and `compMakeupDb = 4`, then the limiter catches overload. That can sound crushed even when the signal does not numerically exceed full scale.
- Smart Level's automatic floor is 35%, while the user already needed 43% and still saw a maxed level. Protective auto-trim should be allowed to reach the same 25% floor as the manual control, with no auto-boost.

## Non-Goals

- Do not write macOS hardware input volume in this fix. Some mics expose no writable hardware gain, and changing system settings is a larger, separate feature.
- Do not add loudness normalization or auto-boosting.
- Do not add render-thread allocation, locks, polling, or per-buffer main-thread dispatch.

## Task 1: Make the input meter reflect trimmed NoNoise input

**Files:**
- Modify: `Sources/Core/AudioProcessing/SmartLevelController.swift`
- Modify: `Sources/Core/AudioModel.swift`
- Modify: `Tests/NoNoiseMacTests/SmartLevelControllerTests.swift`

**Step 1: Write failing pure tests**

Add tests for RMS/trim behavior in `Tests/NoNoiseMacTests/SmartLevelControllerTests.swift`.
Use a production helper that accepts a mutable buffer, applies NoNoise Input Volume in place, and
returns the telemetry tuple. This is the seam that stands in for `AudioModel.captureOutput(...)`
without constructing `AudioModel` (which starts CoreAudio/AVFoundation in `init`).

```swift
func testInputTelemetryMeterReflectsTrimmedSignal() {
    var samples = [Float](repeating: 0.8, count: 64)

    let t = samples.withUnsafeMutableBufferPointer {
        SmartLevelController.applyInputVolumeAndMeasure($0.baseAddress!, count: $0.count, volume: 0.5)
    }

    XCTAssertEqual(t.rawPeak, 0.8, accuracy: 1e-6)
    XCTAssertEqual(t.trimmedPeak, 0.4, accuracy: 1e-6)
    XCTAssertEqual(t.trimmedRMS, 0.4, accuracy: 1e-6)
    XCTAssertTrue(samples.allSatisfy { abs($0 - 0.4) < 1e-6 })
}

func testInputTelemetryAtFortyThreePercentFallsBelowRawLevel() {
    var samples = [Float](repeating: 0.9, count: 64)

    let t = samples.withUnsafeMutableBufferPointer {
        SmartLevelController.applyInputVolumeAndMeasure($0.baseAddress!, count: $0.count, volume: 0.43)
    }

    XCTAssertEqual(t.rawPeak, 0.9, accuracy: 1e-6)
    XCTAssertEqual(t.trimmedPeak, 0.387, accuracy: 1e-4)
    XCTAssertEqual(t.trimmedRMS, 0.387, accuracy: 1e-4)
    XCTAssertLessThan(t.trimmedRMS, t.rawPeak)
}

func testRawSourceClipAndTrimmedMeterStaySeparate() {
    var samples = [Float](repeating: 1.0, count: 64)

    let t = samples.withUnsafeMutableBufferPointer {
        SmartLevelController.applyInputVolumeAndMeasure($0.baseAddress!, count: $0.count, volume: 0.43)
    }

    XCTAssertTrue(SmartLevelController.isSourceMicClipping(
        rawPeak: t.rawPeak, rawClipSampleCount: t.rawClipSamples))
    XCTAssertFalse(SmartLevelController.isNearCeiling(t.trimmedPeak))
    XCTAssertEqual(t.trimmedRMS, 0.43, accuracy: 1e-6)
}
```

**Step 2: Run red test**

Run:

```bash
swift test --filter SmartLevelControllerTests
```

Expected: fails because `InputTelemetry` / `applyInputVolumeAndMeasure(...)` do not exist yet.

**Step 3: Add allocation-free input telemetry helper**

Add to `SmartLevelController`:

```swift
public struct InputTelemetry: Equatable {
    public let rawPeak: Float
    public let trimmedPeak: Float
    public let trimmedRMS: Float
    public let rawClipSamples: Int
    public let trimmedHotSamples: Int
}

public static func applyInputVolumeAndMeasure(_ samples: UnsafeMutablePointer<Float>,
                                              count: Int, volume: Float) -> InputTelemetry {
    guard count > 0 else {
        return InputTelemetry(rawPeak: 0, trimmedPeak: 0, trimmedRMS: 0,
                              rawClipSamples: 0, trimmedHotSamples: 0)
    }
    var rawPeak: Float = 0
    var rawClipSamples = 0
    for i in 0..<count {
        let mag = abs(samples[i])
        rawPeak = max(rawPeak, mag)
        if mag >= clipThreshold { rawClipSamples += 1 }
    }

    var scalar = clampInputVolume(volume)
    if scalar != 1 {
        vDSP_vsmul(samples, 1, &scalar, samples, 1, vDSP_Length(count))
    }

    var trimmedPeak: Float = 0
    var trimmedHotSamples = 0
    var sum: Float = 0
    for i in 0..<count {
        let x = samples[i]
        let mag = abs(x)
        trimmedPeak = max(trimmedPeak, mag)
        sum += x * x
        if mag >= nearCeilingThreshold { trimmedHotSamples += 1 }
    }

    return InputTelemetry(rawPeak: rawPeak, trimmedPeak: trimmedPeak,
                          trimmedRMS: sqrt(sum / Float(count)),
                          rawClipSamples: rawClipSamples,
                          trimmedHotSamples: trimmedHotSamples)
}
```

`applyInputVolume(...)` already exists; keep it for simple tests/callers. The new helper is the
production telemetry path and is also allocation-free: scalar loops + optional in-place vDSP only.

**Step 3b: Add a pure equivalent of AudioModel's input guard decision**

Add a small pure helper that mirrors the input side of `AudioModel.publishMeterTelemetry()` and
`updateSmartLevel()` without constructing `AudioModel`:

```swift
public struct InputGuardDecision: Equatable {
    public let inputLevel: Float
    public let isSourceMicClipping: Bool
    public let isInputNearCeiling: Bool
    public let consecutiveTrimmedHotTicks: Int
    public let suggestedInputVolume: Float?
}

public static func evaluateInputGuard(telemetry: InputTelemetry,
                                      currentHotTicks: Int,
                                      currentInputVolume: Float,
                                      smartLevelEnabled: Bool) -> InputGuardDecision {
    let sourceClipping = isSourceMicClipping(rawPeak: telemetry.rawPeak,
                                            rawClipSampleCount: telemetry.rawClipSamples)
    let inputNearCeiling = isNearCeiling(telemetry.trimmedPeak)
    let trimmedWasHot = inputNearCeiling || telemetry.trimmedHotSamples > 0
    let nextTicks = advanceHotTicks(current: currentHotTicks, wasHot: trimmedWasHot)
    return InputGuardDecision(
        inputLevel: telemetry.trimmedRMS,
        isSourceMicClipping: sourceClipping,
        isInputNearCeiling: inputNearCeiling,
        consecutiveTrimmedHotTicks: nextTicks,
        suggestedInputVolume: nextInputVolume(
            current: currentInputVolume, hotTicks: nextTicks, enabled: smartLevelEnabled))
}
```

Add tests:

```swift
func testInputGuardContractPublishesTrimmedInputLevelRawSourceWarningAndTrimmedHotTicks() {
    var samples = [Float](repeating: 1.0, count: 64)
    let telemetry = samples.withUnsafeMutableBufferPointer {
        SmartLevelController.applyInputVolumeAndMeasure($0.baseAddress!, count: $0.count, volume: 0.43)
    }

    let decision = SmartLevelController.evaluateInputGuard(
        telemetry: telemetry,
        currentHotTicks: SmartLevelController.hotTickThreshold - 1,
        currentInputVolume: 0.43,
        smartLevelEnabled: true)

    XCTAssertTrue(decision.isSourceMicClipping)
    XCTAssertFalse(decision.isInputNearCeiling)
    XCTAssertEqual(decision.inputLevel, 0.43, accuracy: 1e-6)
    XCTAssertEqual(decision.consecutiveTrimmedHotTicks, 0)
    XCTAssertNil(decision.suggestedInputVolume,
                 "raw source clipping alone must not force Smart Level lower when trimmed input is safe")
}

func testInputGuardSuggestsLowerVolumeWhenTrimmedInputIsStillHotAtFortyThreePercent() {
    var samples = [Float](repeating: 2.4, count: 64)
    let telemetry = samples.withUnsafeMutableBufferPointer {
        SmartLevelController.applyInputVolumeAndMeasure($0.baseAddress!, count: $0.count, volume: 0.43)
    }

    let decision = SmartLevelController.evaluateInputGuard(
        telemetry: telemetry,
        currentHotTicks: SmartLevelController.hotTickThreshold - 1,
        currentInputVolume: 0.43,
        smartLevelEnabled: true)

    XCTAssertTrue(decision.isSourceMicClipping)
    XCTAssertTrue(decision.isInputNearCeiling)
    XCTAssertEqual(decision.inputLevel, 1.032, accuracy: 1e-4)
    XCTAssertEqual(decision.consecutiveTrimmedHotTicks, SmartLevelController.hotTickThreshold)
    XCTAssertNotNil(decision.suggestedInputVolume)
    XCTAssertLessThan(decision.suggestedInputVolume!, 0.43)
}
```

Then use `evaluateInputGuard(...)` in `AudioModel.publishMeterTelemetry()` for the same input-side
fields AudioModel publishes/uses: `inputLevel`, `isSourceMicClipping`, `isInputNearCeiling`, and
`consecutiveTrimmedHotTicks`. Keep the date/rate-limit decision in
`AudioModel.updateSmartLevel()` so UI pacing stays unchanged; the pure helper proves the same raw vs
trimmed decision contract.

**Step 4: Wire `AudioModel.captureOutput` meter to trimmed RMS**

In `captureOutput(...)`:

- Replace the ad-hoc raw/trimmed loops with `SmartLevelController.applyInputVolumeAndMeasure(...)`.
- Pass `t.trimmedRMS` to `recordInputTelemetry(...)`, so `publishMeterTelemetry()` assigns a trimmed
  meter value into `inputLevel`.
- Keep `t.rawPeak` and `t.rawClipSamples` flowing into `isSourceMicClipping`.

This keeps the UI meter aligned with the signal entering `ringBuffer.write(...)`, while `rawInputPeak` and `isSourceMicClipping` still report physical/source clipping.

**Step 5: Verify**

Run:

```bash
swift test --filter SmartLevelControllerTests
swift test
```

Expected: all tests pass.

## Task 2: Remove Tutorial preset's hidden boost

**Files:**
- Modify: `Sources/Core/VoicePreset.swift`
- Modify: `Tests/NoNoiseMacTests/NoNoiseMacDSPTests.swift`
- Modify: `Tests/NoNoiseMacTests/VoiceChainTests.swift`
- Modify: `README.md`

**Step 1: Write failing tests**

Replace the old Tutorial makeup test in `NoNoiseMacDSPTests.swift`:

```swift
func testPresetTutorialUsesUnityOutputGain() {
    XCTAssertEqual(VoicePreset.tutorial.parameters!.outputGain, 1.0)
}
```

Add to `VoiceChainTests.swift`:

```swift
func testPresetTutorialDoesNotAddCompressorMakeup() {
    XCTAssertEqual(VoicePreset.tutorial.voiceChain.compMakeupDb, 0)
}
```

**Step 2: Run red tests**

Run:

```bash
swift test --filter NoNoiseMacDSPTests/testPresetTutorialUsesUnityOutputGain
swift test --filter VoiceChainTests/testPresetTutorialDoesNotAddCompressorMakeup
```

Expected: both fail against current values (`1.2` and `4`).

**Step 3: Change Tutorial preset**

In `Sources/Core/VoicePreset.swift`:

- Change Tutorial `parameters.outputGain` from `1.2` to `1.0`.
- Change Tutorial `voiceChain.compMakeupDb` from `4` to `0`.
- Keep Tutorial's high-pass, high-shelf, threshold, ratio, attack/release, and limiter ceiling unchanged so it remains present/clear without extra loudness.

**Step 4: Update docs**

Before changing behavior, run a focused search to confirm there are no other Tutorial-specific gain
paths:

```bash
rg -n "VoicePreset\\.tutorial|case \\.tutorial|Tutorial|outputGain|compMakeupDb|makeup" Sources Tests README.md docs/plans/2026-06-15-hot-mic-ceiling-fix.md
```

Expected: the only shipped Tutorial gain source is `Sources/Core/VoicePreset.swift`; generic output
gain in `DeepFilterNetDSP` and generic compressor makeup in `VoiceChain` are not Tutorial-specific.

Update directly impacted shipped-behavior docs that say Tutorial is louder or has makeup gain. New wording:

- Tutorial is clean/present for screen recordings.
- It does not add output gain by default.
- Users can manually raise Output Gain if their mic is quiet.

**Step 5: Verify**

Run:

```bash
swift test --filter NoNoiseMacDSPTests
swift test --filter VoiceChainTests
swift test
```

Expected: all tests pass.

## Task 3: Let Smart Level protect down to the manual Input Volume floor

**Files:**
- Modify: `Sources/Core/AudioProcessing/SmartLevelController.swift`
- Modify: `Tests/NoNoiseMacTests/SmartLevelControllerTests.swift`

**Step 1: Write failing tests**

Update/add tests:

```swift
func testSmartLevelCanReduceInputVolumeBelowThirtyFivePercent() {
    var ticks = 0
    for _ in 0..<SmartLevelController.hotTickThreshold { ticks += 1 }

    let next = SmartLevelController.nextInputVolume(current: 0.35, hotTicks: ticks, enabled: true)

    XCTAssertNotNil(next)
    XCTAssertLessThan(next!, 0.35)
    XCTAssertGreaterThanOrEqual(next!, SmartLevelController.minInputVolume)
}

func testSmartLevelStopsAtManualInputFloor() {
    var ticks = 0
    for _ in 0..<SmartLevelController.hotTickThreshold { ticks += 1 }

    let next = SmartLevelController.nextInputVolume(
        current: SmartLevelController.minInputVolume, hotTicks: ticks, enabled: true)

    XCTAssertNil(next)
}

func testSmartLevelFromFortyThreePercentCanKeepReducing() {
    var ticks = 0
    for _ in 0..<SmartLevelController.hotTickThreshold { ticks += 1 }

    let next = SmartLevelController.nextInputVolume(current: 0.43, hotTicks: ticks, enabled: true)

    XCTAssertNotNil(next)
    XCTAssertLessThan(next!, 0.43)
    XCTAssertGreaterThanOrEqual(next!, SmartLevelController.minInputVolume)
}
```

**Step 2: Run red tests**

Run:

```bash
swift test --filter SmartLevelControllerTests
```

Expected: the below-35% test fails because the current auto floor is 35%.

**Step 3: Change auto floor**

In `SmartLevelController`, set:

```swift
public static let minAutoInputVolume: Float = minInputVolume
```

Keep the reduction step conservative unless the approved review asks for a faster step. The primary fix is that Smart Level no longer stops above the user's proven useful range.

This directly affects `AudioModel.updateSmartLevel()` because that method already calls
`SmartLevelController.nextInputVolume(current: inputVolumeValue, ...)`; no separate floor exists in
`AudioModel`.

**Step 4: Verify**

Run:

```bash
swift test --filter SmartLevelControllerTests
swift test
```

Expected: all tests pass.

## Task 4: Documentation, release notes, and branch hygiene

**Files:**
- Modify: `README.md`
- Modify: `docs/plans/2026-06-15-hot-mic-ceiling-fix.md`

**Step 1: Update directly impacted docs**

Update only directly impacted current-behavior docs:

- `README.md`: remove current shipped-behavior wording that says Tutorial is louder / uses makeup
  gain; replace with clean/present screen-recording wording.
- `docs/plans/2026-06-15-hot-mic-ceiling-fix.md`: keep this plan aligned with the final code.

Do not rewrite historical implementation-plan docs merely because they mention the older proposal.

**Step 2: Search propagation**

Run:

```bash
rg -n "VoicePreset\\.tutorial|case \\.tutorial|Tutorial.*loud|makeup gain|outputGain.*1\\.2|compMakeupDb: 4|35%|Input Volume.*raw|raw.*input meter" README.md docs/plans/2026-06-15-hot-mic-ceiling-fix.md Sources Tests
```

Expected:

- no hard-coded Tutorial gain paths outside `Sources/Core/VoicePreset.swift`;
- no stale shipped-behavior references remain in README/current code/tests/this plan;
- historical planning docs outside this fix plan are intentionally excluded unless they are linked as
  current behavior docs.

**Step 3: Full verification**

Run:

```bash
swift build
swift test
swift build -c release --arch arm64
```

Expected: all pass.

**Step 4: Commit**

Stage only touched files:

```bash
git add Sources/Core/AudioModel.swift \
  Sources/Core/AudioProcessing/SmartLevelController.swift \
  Sources/Core/VoicePreset.swift \
  Tests/NoNoiseMacTests/SmartLevelControllerTests.swift \
  Tests/NoNoiseMacTests/NoNoiseMacDSPTests.swift \
  Tests/NoNoiseMacTests/VoiceChainTests.swift \
  README.md \
  docs/plans/2026-06-15-hot-mic-ceiling-fix.md
git commit -m "fix(audio): show trimmed input level and remove tutorial boost"
```

**Step 5: Push and update PR**

Run:

```bash
git push origin feat/input-volume-smart-level
```

Then update/open the relevant PR with:

- Root cause summary.
- Verification commands.
- Note that macOS hardware input volume is not changed by this fix.

## Post-Implementation Amendments

Applied during execution to keep this plan aligned with the shipped code:

- **AGENTS.md was also updated (plan gap).** Tasks 1–4 only listed `README.md` + this plan as docs,
  but `AGENTS.md` → "Input Volume & Smart Level (hot-mic guard)" stated `Floor: 35% input` and did
  not say the input meter reflects the trimmed signal. Both were stale after Tasks 1 and 3, so that
  section was updated (input meter = trimmed `inputLevel` via `applyInputVolumeAndMeasure` /
  `evaluateInputGuard`; floor now `25% input` = `minAutoInputVolume = minInputVolume`). Root cause:
  the plan's doc file lists didn't trace the behavior change into the evergreen project guide.
- **Knowledge base updated** per the compounding protocol: a `[GOTCHA]` (meter showed raw, not
  trimmed) in `docs/knowledge/knowledge1.md` and a changelog entry in `docs/knowledge/timeline1.md`.
- **Execution shape:** implemented in a dedicated worktree on branch `fix/hot-mic-ceiling` (based on
  `feat/input-volume-smart-level`) as five atomic commits (Task 1, Task 2, Task 3, docs, and a
  post-review doc-precision fix) instead of the single squashed commit in Task 4 Step 4, then Codex
  code review, then a PR to `main`.
- **Verification run:** `swift build`, `swift test` (89 pure tests green), `swift build -c release
  --arch arm64` — all green.
- **Codex code review (gpt-5.5):** APPROVED. Round 1 found 0 blocking issues and 1 MINOR — the
  phrase "one allocation-free pass" implied a single fused loop, but `applyInputVolumeAndMeasure`
  does raw scan → optional in-place vDSP trim → trimmed scan. Promoted and fixed (call-site comment +
  `AGENTS.md` + `timeline1.md` + `knowledge1.md` now say "one allocation-free helper (raw scan →
  in-place trim → trimmed scan)"); the helper docstring was already accurate. Round 2 re-review:
  APPROVED, LOW risk, no regressions. Plan gap: the plan's doc wording itself carried the imprecise
  "one pass" phrasing.
