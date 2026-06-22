# Virtual Mic Hardware Churn Diagnosis Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Prove why `NoNoise Mic` can go silent after Bluetooth/CoreAudio hardware churn while NoNoise's internal meter still moves, then apply the smallest recovery fix for the confirmed layer.

**Architecture:** Treat this as a diagnostic-first bugfix. Add temporary tagged instrumentation at the app-to-HAL boundary and temporary lock-free counters at realtime boundaries, reproduce the hardware-churn failure, classify whether the stale state is app playback routing, HAL pinning, driver ring IO, or recorder stream state, then keep only the permanent fix and remove all temporary diagnostics.

**Tech Stack:** Swift, AVAudioEngine/AVAudioUnit output routing, CoreAudio HAL, C AudioServerPlugIn driver, XCTest, `swift test`, `Driver/tests/run-tests.sh`, macOS unified logs.

---

## Current Evidence

- The NoNoise UI meter moves while the recorder sees silence, so capture, DSP, and output telemetry are likely alive.
- `/Applications/NoNoiseMac.app`, `coreaudiod`, and the `NoNoiseMic.driver` host process were running during inspection.
- `NoNoiseMic:visible:48k2ch` and `NoNoiseMic:engine:48k2ch` resolved by UID translate, so the driver was installed and the hidden engine existed.
- Killing both NoNoise Mac and `coreaudiod` made output work again, which points to stale runtime state after hardware churn, not a missing install.
- Existing code refreshes devices on `kAudioHardwarePropertyDevices`, but playback repin currently depends on `selectedOutputDeviceID.didSet`; if the preferred hidden engine resolves to the same `AudioObjectID`, `setupPlaybackEngine()` does not rerun.

## Non-Negotiables

- Do not change DeepFilterNet/CoreML or render-thread DSP code.
- Do not add locks, allocations, or logging to the realtime render callback.
- Do not route cleaned mic audio to a physical output as a fallback.
- Temporary diagnostic logs must be uniquely tagged and removed before completion.
- Realtime callbacks may update pre-existing or temporary lock-free/plain scalar counters only; they must not log, allocate, call syscalls, or format strings.
- The final fix must preserve BlackHole fallback behavior.
- The final fix must not restart the incoming guest-cleanup tap engine on ordinary hardware changes.

## Root-Cause Hypotheses To Prove

1. **App playback route stale:** Hardware refresh re-resolves `NoNoise Mic Engine` to the same `AudioObjectID`, so `selectedOutputDeviceID.didSet` does not fire and `setupPlaybackEngine()` is not called. Prediction: logs show route UID/ID unchanged after hardware churn, no playback repin before recorder silence, and the app playback source-node pull counters stop advancing or go silent.
2. **HAL pin failure:** `setupPlaybackEngine()` runs, but `AudioUnitSetProperty(kAudioOutputUnitProperty_CurrentDevice)` fails or pins a device that becomes invalid. Prediction: logs show a non-`noErr` status or output-unit restart failure.
3. **Driver ring/IO stuck:** App repins successfully and continues writing, but the visible mic side reads silence. Prediction: app route logs are healthy while driver counters show writes stop or reads serve silence despite active writes.
4. **Recorder stream stale:** App and driver remain healthy, but the recording app's existing stream is stale. Prediction: switching/reopening only the recorder fixes it while NoNoise/driver logs remain healthy.

## Task 1: Add Temporary App-Side Routing And Playback-Pull Instrumentation

**Files:**
- Modify: `Sources/Core/AudioModel.swift`

**Step 1: Add a temporary unified logger and non-RT route logs**

Add a temporary `Logger` import/use for unified logs. Do not use `print` because manually launched app stdout is not reliably captured by `/usr/bin/log stream`.

```swift
// Sources/Core/AudioModel.swift
import os

private let debugRouteLogger = Logger(subsystem: "com.ivalsaraj.NoNoiseMac", category: "RouteDebug")
```

Add temporary logs tagged `[DEBUG-nn-route]` only in main-thread/control-plane code:

```swift
// Sources/Core/AudioModel.swift
debugRouteLogger.info("[DEBUG-nn-route] hardware refresh: selectedOutputDeviceID=\(self.selectedOutputDeviceID)")
```

In `fetchOutputDevices()`, log:

```swift
// Sources/Core/AudioModel.swift
debugRouteLogger.info("[DEBUG-nn-route] output refresh: engineRouteID=\(engineRouteID) routeUID=\(routeUID ?? "nil") selectedBefore=\(self.selectedOutputDeviceID)")
```

Inside the `DispatchQueue.main.async` block, before and after assigning `selectedOutputDeviceID`, log:

```swift
// Sources/Core/AudioModel.swift
let resolvedRouteID = uidToID[uid] ?? self.deviceID(forUID: uid)
debugRouteLogger.info("[DEBUG-nn-route] route assign: uid=\(uid) resolvedRouteID=\(resolvedRouteID) selectedBefore=\(self.selectedOutputDeviceID)")
self.selectedOutputDeviceID = resolvedRouteID
debugRouteLogger.info("[DEBUG-nn-route] route assigned: selectedAfter=\(self.selectedOutputDeviceID)")
```

In `setupPlaybackEngine()`, log start, selected ID, `AudioUnitSetProperty` status, and `engine.start()` failure:

```swift
// Sources/Core/AudioModel.swift
debugRouteLogger.info("[DEBUG-nn-route] setupPlaybackEngine start: selectedOutputDeviceID=\(self.selectedOutputDeviceID)")
let status = AudioUnitSetProperty(...)
debugRouteLogger.info("[DEBUG-nn-route] AudioUnitSetProperty CurrentDevice status=\(status) deviceID=\(deviceID)")
```

**Step 2: Add temporary playback-pull counters without render-thread logging**

Add temporary 32-bit scalar counters on `AudioModel`, following the existing telemetry pattern of render-thread writes and main-thread reads:

```swift
// Sources/Core/AudioModel.swift
private var debugPlaybackPullCount: UInt32 = 0
private var debugPlaybackNonSilentPullCount: UInt32 = 0
private var debugPlaybackLastPeak: Float = 0
private var debugLastLoggedPullCount: UInt32 = 0
```

Inside the `AVAudioSourceNode` render block, increment `debugPlaybackPullCount` on every invocation, including silence, underflow, and test-tone paths. After the output buffer has been filled, update the peak/non-silent scalars. Do not log or allocate:

```swift
// Sources/Core/AudioModel.swift
self?.debugPlaybackPullCount &+= 1
var peak: Float = 0
for i in 0..<count {
    peak = max(peak, abs(data[i]))
}
self?.debugPlaybackLastPeak = peak
if peak > 0.00001 {
    self?.debugPlaybackNonSilentPullCount &+= 1
}
```

In the existing main-thread control pump, log a once-per-second snapshot only when the pull count changed or when hardware refresh is being diagnosed:

```swift
// Sources/Core/AudioModel.swift
debugRouteLogger.info("[DEBUG-nn-route] playback pulls=\(self.debugPlaybackPullCount) nonSilent=\(self.debugPlaybackNonSilentPullCount) peak=\(self.debugPlaybackLastPeak)")
```

**Step 3: Build app to verify instrumentation compiles**

Run:

```bash
swift build
```

Expected: Build succeeds.

**Step 4: Reproduce hardware churn**

Manual HITL loop:

```bash
/Applications/NoNoiseMac.app/Contents/MacOS/NoNoiseMac
/usr/bin/log stream --style compact --predicate 'process == "NoNoiseMac"' | rg "\\[DEBUG-nn-route\\]"
```

Then:

- Open a recorder app and select `NoNoise Mic`.
- Confirm recorder levels move before churn.
- Connect and disconnect the Bluetooth headset a few times.
- When recorder levels stop, leave NoNoise running and capture the last 100 debug lines.

**Step 5: Run recovery matrix before killing both processes**

When recorder levels stop, perform recovery attempts in this order and record which one restores levels:

1. Reselect `NoNoise Mic` in the recorder.
2. Quit/reopen only the recorder.
3. Quit/reopen only NoNoise Mac.
4. Restart only `coreaudiod`:

```bash
sudo killall coreaudiod
```

5. Kill both NoNoise Mac and `coreaudiod` only if the prior steps fail.

This matrix is required evidence for the final explanation. It distinguishes recorder stream staleness from app route staleness and HAL/plugin wedging.

**Step 6: Classify result**

- If `routeUID == NoNoiseMic:engine:48k2ch`, `resolvedRouteID == selectedBefore`, no `setupPlaybackEngine start` follows the hardware refresh, and playback pull/non-silent counters stop advancing or drop to silence, hypothesis 1 is confirmed.
- If `setupPlaybackEngine start` appears and `AudioUnitSetProperty` status is nonzero, hypothesis 2 is confirmed.
- If app logs are healthy and recorder is still silent, continue to Task 2.

Do not implement a permanent fix until this classification is written into the task notes.

## Task 2: Add Temporary Driver Ring/IO Instrumentation Only If Needed

**Files:**
- Modify: `Driver/NoNoiseMic/NoNoiseMic.c`

**Step 1: Locate writer and reader boundaries**

Use:

```bash
rg -n "nn_ring|StartIO|StopIO|Read|Write|GetZeroTimeStamp|kDeviceName" Driver/NoNoiseMic
```

Expected: Identify the hidden engine output writer path and visible mic input reader path.

**Step 2: Add realtime-safe counters only**

Do not log from `NoNoiseMic_DoIOOperation` or any realtime callback. Add temporary C11 atomic counters updated from the writer/reader paths:

```c
// Driver/NoNoiseMic/NoNoiseMic.c
static _Atomic uint64_t gDebugEngineWriteCalls;
static _Atomic uint64_t gDebugMicReadCalls;
static _Atomic uint64_t gDebugMicSilenceReads;
static _Atomic uint64_t gDebugLastWriteSampleTime;
static _Atomic uint64_t gDebugLastReadSampleTime;
```

In `NoNoiseMic_DoIOOperation`, only update atomics with relaxed ordering. No logging, allocation, or formatting:

```c
// Driver/NoNoiseMic/NoNoiseMic.c
atomic_fetch_add_explicit(&gDebugEngineWriteCalls, 1, memory_order_relaxed);
atomic_store_explicit(&gDebugLastWriteSampleTime, (uint64_t)sd, memory_order_relaxed);
```

For visible mic reads, increment read counters and silence counters based on the same fresh/silence condition already used by `nn_ring_read_at` or the driver read path. If the freshness decision is only inside `nn_ring_read_at`, add a temporary test-only/debug-only return path or sibling helper rather than logging in the IO callback.

**Step 3: Emit driver snapshots from non-RT observation points**

Emit `[DEBUG-nn-driver]` snapshots only from non-RT paths:

- `NoNoiseMic_StartIO`
- `NoNoiseMic_StopIO`
- a temporary custom debug property queried by a Swift probe, if Start/Stop logs are insufficient

The snapshot must include:

- visible mic StartIO/StopIO
- hidden engine StartIO/StopIO
- write/read call counts
- last writer/read sample times
- silence-read count

If a custom debug property is added, it must be temporary, documented in this task, and removed before the final fix unless it becomes an explicitly approved support diagnostic.

**Step 4: Build and run driver tests**

Run:

```bash
Driver/tests/run-tests.sh
./build-driver.sh
```

Expected: Driver tests pass and driver builds.

**Step 5: Install debug driver and reproduce**

Run:

```bash
sudo ./install-driver.sh
/usr/bin/log stream --style compact --predicate 'process CONTAINS "NoNoise"' | rg "\\[DEBUG-nn-(route|driver)\\]"
```

Expected: Logs distinguish whether the app is still writing and whether the visible mic reader serves fresh frames.

**Step 6: Classify result**

- If app writes continue but driver reader serves silence, the fix belongs in driver IO/ring lifecycle.
- If app writes stop or route setup is absent/failed, skip driver changes and fix app routing.
- If both are healthy, treat the recorder app as stale and avoid app/driver code changes beyond better recovery guidance.

## Task 3A: Fix Confirmed App Playback Route Staleness

Use this task only if Task 1 confirms hypothesis 1.

**Files:**
- Modify: `Sources/Core/AudioProcessing/VirtualMicRouting.swift`
- Modify: `Sources/Core/AudioModel.swift`
- Test: `Tests/NoNoiseMacTests/VirtualMicRoutingTests.swift`
- Update: `docs/knowledge/timeline1.md`

**Step 1: Write failing pure routing test**

Add:

```swift
// Tests/NoNoiseMacTests/VirtualMicRoutingTests.swift
func testHardwareRefreshRepinsEngineEvenWhenSelectedIDIsUnchanged() {
    XCTAssertTrue(VirtualMicRouting.shouldRepinPlaybackAfterHardwareRefresh(
        preferredRouteUID: VirtualMicRouting.engineDeviceUID,
        previousOutputDeviceID: 75,
        resolvedOutputDeviceID: 75
    ))
}

func testHardwareRefreshDoesNotForceRepinForBlackHoleWhenSelectedIDIsUnchanged() {
    XCTAssertFalse(VirtualMicRouting.shouldRepinPlaybackAfterHardwareRefresh(
        preferredRouteUID: "BlackHoleUID",
        previousOutputDeviceID: 12,
        resolvedOutputDeviceID: 12
    ))
}
```

**Step 2: Verify test fails**

Run:

```bash
swift test --filter VirtualMicRoutingTests
```

Expected: Fails because `shouldRepinPlaybackAfterHardwareRefresh` does not exist.

**Step 3: Add minimal pure predicate**

Add:

```swift
// Sources/Core/AudioProcessing/VirtualMicRouting.swift
public static func shouldRepinPlaybackAfterHardwareRefresh(
    preferredRouteUID: String?,
    previousOutputDeviceID: UInt32,
    resolvedOutputDeviceID: UInt32
) -> Bool {
    preferredRouteUID == engineDeviceUID &&
    resolvedOutputDeviceID != 0 &&
    resolvedOutputDeviceID == previousOutputDeviceID
}
```

Use `AudioObjectID` only in `AudioModel`; keep `VirtualMicRouting` free of CoreAudio imports.

**Step 4: Verify pure tests pass**

Run:

```bash
swift test --filter VirtualMicRoutingTests
```

Expected: Pass.

**Step 5: Wire the predicate into the hardware refresh path**

In `fetchOutputDevices()`, capture `previousOutputDeviceID` before assignment and compute `resolvedRouteID`. If the route ID is unchanged but `VirtualMicRouting.shouldRepinPlaybackAfterHardwareRefresh(...)` returns `true`, call `setupPlaybackEngine()` explicitly after setting `activeOutputDeviceName`.

Shape:

```swift
// Sources/Core/AudioModel.swift
let previousOutputDeviceID = self.selectedOutputDeviceID
let resolvedRouteID = uidToID[uid] ?? self.deviceID(forUID: uid)
self.selectedOutputDeviceID = resolvedRouteID
if VirtualMicRouting.shouldRepinPlaybackAfterHardwareRefresh(
    preferredRouteUID: uid,
    previousOutputDeviceID: previousOutputDeviceID,
    resolvedOutputDeviceID: resolvedRouteID
) {
    self.setupPlaybackEngine()
}
```

Keep this in the main queue block, where existing `@Published` state changes already happen.

**Step 6: Improve permanent CoreAudio error visibility**

In `setupPlaybackEngine()`, store the `AudioUnitSetProperty` status. If it is nonzero, set `errorMessage` with a short user-recoverable route error and return before starting a graph pinned to an unknown route.

Shape:

```swift
// Sources/Core/AudioModel.swift
let status = AudioUnitSetProperty(...)
guard status == noErr else {
    DispatchQueue.main.async {
        self.errorMessage = "Could not route audio to NoNoise Mic. Restart NoNoise or reconnect the audio device."
    }
    return
}
```

Do not add per-buffer logging.

**Step 7: Remove temporary `[DEBUG-nn-route]` logs**

Run:

```bash
rg -n "\\[DEBUG-nn-route\\]" Sources/Core
```

Expected: No matches.

**Step 8: Verify**

Run:

```bash
swift test --filter VirtualMicRoutingTests
swift test
```

Expected: All tests pass.

Manual verification:

- Launch NoNoise Mac.
- Open recorder and select `NoNoise Mic`.
- Confirm levels move.
- Connect/disconnect Bluetooth headset several times.
- Confirm recorder levels continue without killing NoNoise or `coreaudiod`.

**Step 9: Documentation**

Update `docs/knowledge/timeline1.md` with:

- The confirmed root cause.
- The recovery decision.
- The exact tests and manual verification performed.

**Step 10: Commit**

Run:

```bash
git add Sources/Core/AudioProcessing/VirtualMicRouting.swift Sources/Core/AudioModel.swift Tests/NoNoiseMacTests/VirtualMicRoutingTests.swift docs/knowledge/timeline1.md
git commit -m "fix(audio): repin virtual mic route after hardware churn

- confirm stale NoNoise Mic Engine route after Bluetooth hardware changes
- force playback repin when the hidden engine remains selected but HAL graph refreshed
- surface route pin failures instead of silently running an unpinned playback graph
- cover the repin predicate with routing unit tests"
```

## Task 3B: Fix Confirmed HAL Pin Failure

Use this task only if Task 1 confirms hypothesis 2.

**Files:**
- Modify: `Sources/Core/AudioModel.swift`
- Test: Add a pure test seam if a route result type is extracted; otherwise document why HAL pinning is not headless-testable.
- Update: `docs/knowledge/timeline1.md`

**Step 1: Extract a small route-pin result mapper if needed**

If the failure handling needs logic beyond direct `OSStatus == noErr`, extract only the pure mapping from `OSStatus` to user-facing recovery state. Do not wrap CoreAudio in a broad abstraction.

**Step 2: Handle `AudioUnitSetProperty` failure**

In `setupPlaybackEngine()`, fail closed when pinning the selected route fails:

- stop/reset engine
- set `errorMessage`
- keep `activeOutputDeviceName` accurate
- do not fall back to a physical output

**Step 3: Add one retry on delayed hardware refresh only if logs show transient failure**

If logs show `AudioUnitSetProperty` fails immediately after hardware churn but succeeds shortly after, schedule one delayed `fetchOutputDevices()` / `setupPlaybackEngine()` retry on main after 0.5 seconds. Do not poll.

**Step 4: Remove temporary logs and verify**

Run:

```bash
rg -n "\\[DEBUG-nn-route\\]" Sources/Core
swift test
```

Manual Bluetooth churn verification is required.

**Step 5: Document and commit**

Update `docs/knowledge/timeline1.md` with the confirmed HAL pin failure and recovery behavior. Commit only the final fix and docs.

## Task 3C: Fix Confirmed Driver Ring/IO Staleness

Use this task only if Task 2 confirms hypothesis 3.

**Files:**
- Modify: `Driver/NoNoiseMic/NoNoiseMic.c`
- Modify only if needed: `Driver/NoNoiseMic/nn_ring.c`
- Test: Driver tests under `Driver/tests/`
- Update: `docs/knowledge/timeline1.md`
- Update if new invariant emerges: `docs/knowledge/critical-patterns.md`

**Step 1: Add or update failing driver test**

Create a test that reproduces the stale state at the ring/clock seam if possible:

- writer stops/starts after hardware churn
- reader must serve fresh frames after writer resumes
- reader must serve silence, not stale frames, when writer is stopped

**Step 2: Verify failing test**

Run:

```bash
Driver/tests/run-tests.sh
```

Expected: New test fails for the confirmed stale behavior.

**Step 3: Implement minimal driver lifecycle fix**

Fix only the confirmed driver state:

- reset ring/clock on the correct StartIO/StopIO boundary, or
- repair running-state tracking for the hidden engine and visible mic pair, or
- repair fresh-frame window checks if they fail after restart.

Do not change sample format, device names, UIDs, hidden flags, or install layout.

**Step 4: Verify**

Run:

```bash
Driver/tests/run-tests.sh
./build-driver.sh
swift test
```

Manual install and Bluetooth churn verification are required:

```bash
sudo ./install-driver.sh
```

**Step 5: Remove temporary logs**

Run:

```bash
rg -n "\\[DEBUG-nn-driver\\]" Driver
```

Expected: No matches.

**Step 6: Document and commit**

Update timeline and, if the bug is a new driver invariant, `docs/knowledge/critical-patterns.md`. Commit only final driver fix, tests, and docs.

## Task 4: Final Root-Cause Report

**Files:**
- No source changes unless Task 3 requires them.

**Step 1: Capture final evidence**

Record:

- confirmed hypothesis
- key log lines or test failure that proved it
- files changed
- test commands and outcomes
- manual Bluetooth churn result

**Step 2: Verify no temporary debug artifacts**

Run:

```bash
rg -n "\\[DEBUG-nn-(route|driver)\\]" Sources Driver
git status --short
```

Expected: No debug matches; only intended files changed before commit, or clean after commit.

**Step 3: User summary**

Summarize:

- actual root cause
- why killing NoNoise + `coreaudiod` fixed it
- permanent behavior after the fix
- any residual risk or manual verification that could not be automated
