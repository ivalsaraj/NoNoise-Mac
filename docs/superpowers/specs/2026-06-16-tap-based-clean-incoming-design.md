# Tap-based Clean Incoming — Design Spec

**Date:** 2026-06-16
**Status:** Approved (design) — pending implementation plan
**Area:** `Sources/Core/AudioProcessing/IncomingCleanupEngine.swift`, `Sources/Core/AudioModel.swift`, `Sources/Core/AudioProcessing/VirtualMicRouting.swift`, `Sources/App/SettingsView.swift`, `Sources/App/ContentView.swift`, `Resources/Info.plist`

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

On macOS 14.4+, inside `IncomingCleanupEngine`:

1. Resolve NoNoise's own audio process object: `kAudioHardwarePropertyTranslatePIDToProcessObject`
   with the app's PID.
2. Build a global-exclude tap description:
   `CATapDescription(stereoGlobalTapButExcludeProcesses: [ourProcessObjectID])`, mute behavior =
   **muted** (so the user hears only NoNoise's cleaned re-render, not the noisy originals).
3. `AudioHardwareCreateProcessTap(description, &tapID)`.
4. Create a **private, non-default aggregate device** that includes the tap via
   `kAudioAggregateDeviceTapListKey` (tap UUID).
5. Read the tapped audio with `AudioDeviceCreateIOProcIDWithBlock` on the aggregate; read the stream
   format from `kAudioTapPropertyFormat`. Convert to 48 kHz mono and write into the existing
   `RingBuffer` — the same capture→ring contract as today's `captureOutput`.

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

- `AudioModel.isIncomingCleanupAvailable` = `#available(macOS 14.4, *)`.
- When unavailable: the Clean Incoming toggle is **disabled** with caption
  *"Requires macOS 14.4 or later"* in both the popover (`ContentView`) and Settings (`SettingsView`).
  Toggling is a no-op when unavailable.
- When available: the card is a **single toggle + status line** (e.g. "Cleaning all incoming audio").
  The "Incoming from" and "Hear on" pickers are removed.

### 5. Persistence + lifecycle

- Keep `mv.incomingEnabled`. Stop using `mv.incomingSourceUID` / `mv.incomingOutputUID` (no longer
  chosen). `SettingsResetPolicy` continues to reset the enabled flag.
- `applyIncomingCleanup()`: if `incomingCleanupEnabled && isIncomingCleanupAvailable` → create the
  engine (build tap + aggregate + IOProc, start playback to the default output); else tear down to
  `nil`. Preserve the **zero-cost-when-off** mandate and the truthful `start() -> Bool` contract
  (retain only a genuinely capturing+cleaning+playing engine).
- `refreshDevicesAfterHardwareChange()` and the default-output listener re-pin playback rather than
  full teardown, unless the tap/aggregate itself died.

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
  3. The exact `@available` floor (confirm 14.4 vs an earlier 14.2 symbol availability) so the gate
     string and `#available` match reality.

## Removal surface (single tap-only path)

Deleted (with orphan cleanup, after confirming no remaining callers):

- `fetchIncomingDevices` and the `incomingSourceDevices` published list.
- The "Incoming from" + "Hear on" pickers in `SettingsView` and `ContentView`.
- `incomingSourceUID` / `incomingOutputDeviceID` state + `mv.incomingSource*` / `mv.incomingOutput*`
  persistence (and their `SettingsResetPolicy` / `loadSettings` wiring).
- `VirtualMicRouting.isSelectableIncomingSource`, `selectableIncomingSources`,
  `isSelectableMonitorOutput`, and their unit tests — **iff** no other caller remains. The
  monitor-output enumeration is shared with `fetchOutputDevices`; verify before removing that branch.
- The `AVCaptureSession` capture half of `IncomingCleanupEngine` (`configureCapture`, the capture
  delegate), replaced by the tap path.

Kept: `mv.incomingEnabled`, the DFN + ring + `AVAudioSourceNode` playback core, the truthful
`start() -> Bool` lifecycle and lazy-owned-optional ownership in `AudioModel`.

## Testing

- The tap / aggregate / IOProc path is **integration-only** (needs a 14.4+ host + granted TCC) →
  manual smoke test, like today's `AVCaptureSession` path.
- New **pure** logic goes in testable helpers with unit tests: own-process-object resolution shaping,
  and the "re-pin playback on default-output change" decision.
- `IncomingCleanupEngine.start() -> Bool` keeps its truthfulness test intent (returns `true` only
  when capturing + playing; `false` + full teardown otherwise).

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
