# Tap-based Clean Incoming — Design Spec

**Date:** 2026-06-16
**Status:** Approved (design) — revised per Codex plan review (2026-06-16)
**Area:** `Sources/Core/AudioProcessing/IncomingCleanupEngine.swift`, `Sources/Core/AudioModel.swift`, `Sources/Core/AudioProcessing/VirtualMicRouting.swift`, `Sources/Core/SettingsResetPolicy.swift`, a new lock-free SPSC ring (`Sources/Core/AudioProcessing/`), `Sources/App/SettingsView.swift`, `Sources/App/ContentView.swift`, `Resources/Info.plist`, `Package.swift` (availability only)

## Goal

Make "Clean Incoming / Guest (hear them clean)" a **single-toggle** feature with **no third-party
dependency** (no BlackHole / Loopback) and **no manual audio routing**. The user turns on Clean
Incoming and NoNoise cleans the audio they hear from other apps in real time, on-device.

## Decision summary (locked with the user)

| Decision | Choice |
| --- | --- |
| Capture mechanism | Core Audio **process taps** (`AudioHardwareCreateProcessTap`), **no virtual device** |
| Capture scope | **All system audio except NoNoise's own process**, originals **muted** |
| macOS floor | **14.4+** (tap path only). Below 14.4 the feature is **disabled with a message** |
| `< 14.4` fallback | **None.** The existing BlackHole-loopback incoming path is **removed** (single code path) |
| Playback target | **Auto-follow the current default output**; re-route on device change / Bluetooth-TWS auto-switch |
| "Incoming from" / "Hear on" pickers | **Removed** — the card becomes one toggle + a status line |

The "NoNoise Speaker" virtual-device idea (earlier Option A) is **dropped**: process taps need no
device, so there is nothing to publish or name.

## Background — current state

Today (`IncomingCleanupEngine`) the feature captures a loopback/aggregate **input** device
(BlackHole/Loopback) via `AVCaptureSession`, runs its own `DeepFilterNetDSP` (DFN-only, no
`VoiceChain`), and plays the cleaned result to a user-chosen monitor output. It requires the user to
(a) install BlackHole and (b) point the call app's speaker at it and (c) pick source + monitor in
Settings. `applyIncomingCleanup()` lazily creates/tears down the engine; `start() -> Bool` is
truthful (retains only a genuinely-running pipeline); the feedback guard refuses to run without a
valid real monitor.

macOS has no built-in per-app/system output capture **without** a loopback device on ≤14.3, which is
why BlackHole was needed. macOS **14.4** added a reliable global process-tap API that captures other
apps' output directly — removing both the third-party dependency and the manual routing.

## Architecture

### 1. Capture — process tap (replaces the loopback `AVCaptureSession`)

All tap calls are isolated behind `#available(macOS 14.4, *)` (see Availability in §4). Inside
`IncomingCleanupEngine`:

1. Resolve NoNoise's own audio process object: `kAudioHardwarePropertyTranslatePIDToProcessObject`
   with the app's PID. **Hard-fail on invalid resolution** — if
   `status != noErr || processObjectID == kAudioObjectUnknown || processObjectID == 0`, `start()`
   returns `false` and **no tap is created**. A global-exclude tap built around an unknown own-process
   id would exclude *nothing* and re-capture/mute NoNoise's own cleaned playback (a feedback / self-
   mute bug). The resolution check is a pure, unit-tested predicate.
2. Build a global-exclude tap description:
   `CATapDescription(stereoGlobalTapButExcludeProcesses: [ourProcessObjectID])`, mute behavior =
   **muted** (so the user hears only NoNoise's cleaned re-render, not the noisy originals).
3. `AudioHardwareCreateProcessTap(description, &tapID)` — the **C** API (available macOS **14.2**),
   NOT the macOS 15 `AudioHardwareTap` / `makeProcessTap` Swift overlay.
4. Create a **private, non-default aggregate device** that includes the tap via
   `kAudioAggregateDeviceTapListKey` (tap UUID). **Pin the aggregate's nominal sample rate to
   48 kHz** so the IOProc receives 48 kHz frames (CoreAudio resamples the tapped process audio into
   the aggregate's clock domain) — this keeps the realtime IOProc free of `AVAudioConverter`.
5. Read the tapped audio with `AudioDeviceCreateIOProcIDWithBlock` on the aggregate; read the stream
   layout **once at setup** (non-realtime) from `kAudioTapPropertyFormat` / the aggregate's stream
   format.

**Realtime-safety contract (CRITICAL — the IOProc is a realtime audio callback):**
- The IOProc treats the HAL-provided `inInputData` (`AudioBufferList`) as **read-only** — it must
  NEVER modify the tap's input buffers. It READS those frames and WRITES the downmixed **mono**
  result (stereo→mono via Accelerate `vDSP`, e.g. averaging L+R) into the SPSC ring's pre-allocated
  storage (the ring's write region / ring-owned scratch — never back into `inInputData`). It must NOT
  allocate `AVAudioPCMBuffer`, create/run `AVAudioConverter`, use a Swift `Array`, `dispatch_async`,
  or take any lock, and must handle BOTH interleaved and non-interleaved tap stream layouts (layout
  read once at setup). (Today's `captureOutput` does conversion on a NON-realtime GCD queue — that
  pattern must NOT be copied verbatim into the IOProc.)
- The incoming path uses a **new lock-free SPSC float ring** for the producer (tap IOProc) → consumer
  (`AVAudioSourceNode`) handoff. Model it on the driver's tested `Driver/NoNoiseMic/nn_ring.{c,h}`
  SPSC precedent: pre-allocated power-of-two Float storage, a single producer advancing a write index
  and a single consumer advancing a read index (no CAS), wraparound by mask. The cross-thread
  published write index / watermark uses **acquire/release** semantics — a **release-store AFTER** the
  sample writes and an **acquire-load BEFORE** the consumer reads — exactly like `nn_ring.h`'s
  `_Atomic uint64_t writeEnd` (publishes with release, consumes with acquire). This is **NOT** the
  plain aligned-scalar pattern used for the independent suppression knobs / meter `t*` telemetry: a
  ring index publishes the *visibility/ownership* of the sample bytes, so plain non-atomic words
  could expose the consumer to stale or partially-published audio. Implement the index via an
  explicit atomic primitive (a small C11-atomics helper mirroring `nn_ring`, or `swift-atomics`) —
  **never** a plain Swift `Int` / `UInt64`. Both ends are realtime threads, so the existing
  `RingBuffer` (which locks every op on `os_unfair_lock`) must NOT bridge them (a realtime↔realtime
  lock risks priority inversion / dropouts). The **mic-path `RingBuffer` is unchanged**.
- If the aggregate cannot be pinned to 48 kHz, sample-rate conversion runs on a NON-realtime worker
  between a lock-free staging ring (written by the IOProc at the tap rate) and the playback ring —
  never inside the IOProc.

A global-exclude tap **auto-includes** apps that start playing later, so the tap is not recreated as
apps come and go.

### 2. Clean — unchanged

Reuse the per-instance `DeepFilterNetDSP` (fresh recurrent state per engine), **DFN only** (no
`VoiceChain`/Broadcast Voice — that polish is for the outgoing mic), allocation-free render, and the
existing ring → `AVAudioSourceNode` playback graph.

### 3. Playback — auto-follow the default output

Do **not** pin a user-chosen monitor. Render the cleaned audio to the **current default output
device** and follow changes automatically:

- Register a HAL property listener on `kAudioHardwarePropertyDefaultOutputDevice`.
- Also observe `AVAudioEngineConfigurationChange`.
- On either, re-point the playback output unit's `kAudioOutputUnitProperty_CurrentDevice` to the new
  default (restart the graph only if required).

This covers manual output switches **and** Bluetooth/TWS connections that auto-change the system
default. **No feedback risk:** the tap excludes NoNoise's own process, so the cleaned playback to the
same output device is never re-captured.

### 4. UX + gating

- **Availability:** `AudioModel.isIncomingCleanupAvailable` = `#available(macOS 14.4, *)`. **14.4 is
  the explicit product/reliability floor** even though the underlying symbols are older (tap C API
  14.2, `CATapDescription` init 14.0). Every tap call is isolated behind `#available(macOS 14.4, *)`
  / `@available` helpers so the package still compiles against its `.macOS(.v13)` deployment target,
  and we never reference the macOS 15 `AudioHardwareTap` Swift wrappers.
- **Canonical effective status — never a lying toggle.** Because `start() -> Bool` can fail (TCC
  denied, own-process unresolved, tap/aggregate creation failed) and the owner then retains NO
  engine, the UI binds to a published `AudioModel.incomingCleanupStatus`, not the raw persisted flag:
  - `.unavailable` (OS < 14.4) → toggle **disabled**, caption *"Requires macOS 14.4 or later"*.
  - `.off` → toggle off.
  - `.cleaning` → engine genuinely running; caption *"Cleaning all incoming audio"*.
  - `.failed` → user toggled on but `start()` returned `false`; caption *"Couldn’t start — allow
    audio capture in System Settings ▸ Privacy & Security"* (covers first-run TCC denial; the toggle
    stays on so granting permission + re-toggling retries).
- Both the popover (`ContentView`) and Settings (`SettingsView`) bind the status line **and** the
  toggle's enabled state to `incomingCleanupStatus`. Toggling is a no-op when `.unavailable`.
- The card is a **single toggle + status line**. The "Incoming from" and "Hear on" pickers are
  removed.

### 5. Persistence + lifecycle

- Keep `mv.incomingEnabled`. Stop using `mv.incomingSourceUID` / `mv.incomingOutputUID` (no longer
  chosen): **remove** the `incomingSourceUIDKey` / `incomingOutputUIDKey` constants and their
  `SettingsResetPolicy.resettableKeys` entries (nothing reads or writes them anymore). Any value an
  older build stored becomes a harmless dead default — **no migration is performed**.
  `SettingsResetPolicy` continues to reset `mv.incomingEnabled`; update `SettingsResetPolicyTests` to
  drop the two removed keys.
- `applyIncomingCleanup()`: if `incomingCleanupEnabled && isIncomingCleanupAvailable` → create the
  engine (build tap + aggregate + IOProc, start playback to the default output); else tear down to
  `nil`. Preserve the **zero-cost-when-off** mandate and the truthful `start() -> Bool` contract
  (retain only a genuinely capturing+cleaning+playing engine). On `start() -> false`, set
  `incomingCleanupStatus = .failed` and release the engine to `nil`; on success, `.cleaning`.
- **Start order (minimize the muted-but-silent window):** create tap + aggregate + IOProc, **start &
  pin the playback engine to the default output FIRST**, then `AudioDeviceStart` the aggregate IO
  last — so the global mute is only active once our cleaned re-render is already playing.
- **Single idempotent teardown path** (`stop()`), invoked on disable, on `deinit`, AND on every
  failure branch in `start()` after any HAL object was created — in this exact order:
  1. `AudioDeviceStop(aggregateID, ioProcID)`
  2. `AudioDeviceDestroyIOProcID(aggregateID, ioProcID)`
  3. `AudioHardwareDestroyAggregateDevice(aggregateID)`
  4. `AudioHardwareDestroyProcessTap(tapID)`
  5. remove the `kAudioHardwarePropertyDefaultOutputDevice` HAL listener
  6. remove the `AVAudioEngineConfigurationChange` observer
  7. stop + reset the playback engine
  Each handle is guarded (skip if `0` / `nil`) and zeroed after release, so a second call is a no-op.
  A leaked **muted** tap keeps OTHER apps muted system-wide, so teardown MUST run on all paths.
- `refreshDevicesAfterHardwareChange()` and the default-output listener **re-pin** playback rather
  than full teardown, UNLESS the tap/aggregate itself died (then full `stop()` + re-`start()`). The
  re-pin-vs-rebuild decision is a pure, unit-tested helper.

## Permissions & entitlements (highest risk — spike first)

- Process taps require **TCC audio-capture consent**. Reference implementations add
  **`NSAudioCaptureUsageDescription`** to `Info.plist` (a usage-description string, **not** a new
  entitlement — the two-entitlement policy in `AGENTS.md`/`CLAUDE.md` still holds; this is documented
  here as the one added Info.plist key).
- There is **no public API** to pre-check or request the permission; the system prompt fires on first
  tap use. **We will not ship private TCC probing** (AudioCap does this behind a build flag — out of
  scope for us).
- The spike must confirm, on a real 14.4+ machine:
  1. The tap loads and the TCC prompt appears under the app's current ad-hoc / minimal-entitlement
     signing.
  2. Whether the hardened-runtime nested-Sparkle signing flow (`bundle.sh`, inside-out, no `--deep`)
     needs any adjustment for the tap to function.
  3. **RESOLVED via SDK headers (Codex review):** `AudioHardwareCreateProcessTap` is annotated macOS
     **14.2**, the `CATapDescription(stereoGlobalTapButExcludeProcesses:)` Swift init is **14.0**, and
     the `AudioHardwareTap` / `makeProcessTap` Swift wrappers are **15.0**. Decision: keep **14.4** as
     the explicit product floor, call the **C** `AudioHardwareCreateProcessTap` (not the 15.0 Swift
     overlay), and isolate every tap call behind `#available(macOS 14.4, *)` so the `.macOS(.v13)`
     package still builds. Items 1–2 remain manual smoke items on a 14.4+ host.

## Removal surface (single tap-only path)

Deleted (with orphan cleanup, after confirming no remaining callers):

- `fetchIncomingDevices` and the `incomingSourceDevices` published list.
- The "Incoming from" + "Hear on" pickers in `SettingsView` and `ContentView`.
- `incomingSourceUID` / `incomingOutputDeviceID` state + `mv.incomingSource*` / `mv.incomingOutput*`
  persistence (and their `SettingsResetPolicy` / `loadSettings` wiring). Also the now-orphaned
  helpers/maps: `monitorOutputDevices`, `monitorOutputUIDByID`, `incomingSourceUIDByID`,
  `uid(forIncomingSourceID:)`, and the **monitor-list branch inside `fetchOutputDevices`** — but KEEP
  the OUTGOING `outputDevices` / `isSelectableOutput` branch (unrelated to incoming).
- `VirtualMicRouting.isSelectableIncomingSource`, `selectableIncomingSources`,
  `isSelectableMonitorOutput` — and the **entire `Tests/NoNoiseMacTests/IncomingCleanupTests.swift`**
  (every test there targets only these three helpers). Confirmed safe: `isSelectableMonitorOutput`'s
  only caller is the `fetchOutputDevices` monitor branch (removed above); `VirtualMicRoutingTests`
  covers the OUTGOING helpers (`preferredOutputUID`, `visibleOutputs`, `filterInputs`) and **stays**.
- The `AVCaptureSession` capture half of `IncomingCleanupEngine` (`configureCapture`, the capture
  delegate, the `AVCaptureSession` / `AVCaptureAudioDataOutput` members, and the `AVAudioConverter`
  capture buffers), replaced by the tap + lock-free SPSC ring path.

Kept: `mv.incomingEnabled`, the DFN + ring + `AVAudioSourceNode` playback core, the truthful
`start() -> Bool` lifecycle and lazy-owned-optional ownership in `AudioModel`.

## Testing

- The tap / aggregate / IOProc path is **integration-only** (needs a 14.4+ host + granted TCC) →
  manual smoke test, like today's `AVCaptureSession` path. Smoke matrix: TCC allow, TCC deny,
  no-default-output, Bluetooth/TWS auto-switch mid-session, app quit (mute released, no leaked tap),
  and an Instruments allocation pass confirming the IOProc + source-node render stay allocation-free.
- New **pure, headless** logic goes in testable helpers WITH unit tests:
  - own-process-object resolution predicate (`noErr && id != kAudioObjectUnknown && id != 0`),
  - the "re-pin playback vs full-rebuild on default-output change" decision,
  - the **lock-free SPSC ring** wraparound / fill / drain / underflow behavior (pure value type,
    mirroring the driver's `nn_ring` host tests).
- `IncomingCleanupEngine.start() -> Bool` keeps its truthfulness test intent (returns `true` only
  when capturing + playing; `false` + full teardown otherwise).
- `swift build` and `swift build -c release --arch arm64` MUST still succeed against `.macOS(.v13)`
  — i.e. every tap symbol is behind an availability guard (compile-tested even on older hosts).

## Implementation-approach note

Keep the existing `IOProc → ring → AVAudioSourceNode` playback shape (matches the current engine and
the reference impls' read pattern) rather than an `AVAudioEngine`-with-aggregate-input. Less churn and
it preserves the allocation-free render path.

## Out of scope (v1)

- Per-app capture selection (chosen scope is all-system-minus-NoNoise).
- Keeping a BlackHole fallback for < 14.4 (feature is disabled there).
- Applying `VoiceChain`/Broadcast Voice to incoming audio.
- Any change to the outgoing mic path or the NoNoise Mic virtual driver.

## References

- [insidegui/AudioCap](https://github.com/insidegui/AudioCap) — canonical macOS process-tap sample.
- [AudioTee — capturing system audio on macOS](https://stronglytyped.uk/articles/audiotee-capture-system-audio-output-macos).
- [Apple — AudioHardwareCreateProcessTap](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)).
