# Incoming / Guest Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clean the **other side's** audio, not your mic. Capture the incoming call/guest audio from a loopback/aggregate **input** device the user selects, run it through the **same DeepFilterNet engine**, and play the de-noised/de-reverbed result to the user's speakers/headphones so the user **hears the guest clean** (Phase 1). Then optionally route that cleaned incoming audio into a **second virtual sink** so a recording/streaming app (OBS, Riverside) records the guest cleaned too (Phase 2).

**Architecture:** A new **`IncomingCleanupEngine`** — a second, fully independent capture→DSP→playback pipeline whose SHAPE mirrors the CLI (`Sources/CLI/main.swift`: input device → `DeepFilterNetDSP` → output device for any device). It owns its **own** `AVCaptureSession`, ring buffer, `DeepFilterNetDSP` instance (DFN only — no `VoiceChain`), and `AVAudioEngine`, completely decoupled from the existing `AudioModel` (the mic-cleaning pipeline). **It is held by `AudioModel` as an OPTIONAL and created only while the feature is enabled** (a stored `let` would allocate ML buffers + load the model at launch — see the performance section). `AudioModel` stays the single source of truth for the **outgoing** mic; the new engine is the **incoming** path. The pure, headless-testable logic (device classification) lives in value-type predicates extended on `VirtualMicRouting`; the live engine is verified by `swift build` + a manual smoke test (same convention as `AudioModel`). One capture detail is NOT assumed proven and is gated behind an early spike (Task S): that `AVCaptureDevice(uniqueID:)` can capture a loopback device `DiscoverySession` never lists.

**Tech Stack:** Swift 5.9, SwiftUI, Swift Package Manager, XCTest, AVFoundation/CoreAudio (capture + playback), CoreML/Accelerate (the existing `DeepFilterNetDSP`, unchanged).

**GitHub Issue:** #6 — https://github.com/ivalsaraj/NoNoise-Mac/issues/6

**Execution location:** Run all commands from the package root — the directory that contains `Package.swift`. All paths in this plan are relative to that root.

---

## Context

### Why this feature
NoNoise Mac cleans **your** microphone for the people you're talking to. The mirror-image problem is just as common: a guest joins your podcast on a noisy laptop mic in a reverberant room, or the person you're on a call with has a fan running — and **you** are stuck listening to (and recording) their noise. Today the engine only processes the outgoing mic. The same DeepFilterNet3 model that cleans your voice can clean theirs; the CLI already demonstrates an input→clean→output pipeline for arbitrary devices. This feature exposes that as a first-class, on-device "clean the guest" path.

Two distinct payoffs, planned as two phases:
- **Phase 1 — hear-them-clean:** you *hear* the guest de-noised in your own headphones, live.
- **Phase 2 — record-them-clean:** the cleaned guest audio is also routed to a second virtual sink so OBS/Riverside records the guest cleaned, not just what you hear.

### The hard macOS reality you must design around
**macOS has NO built-in per-app audio loopback.** There is no supported API to tap "the audio Zoom is playing" the way you tap a microphone. So the incoming audio cannot be captured directly from the call app. The user MUST route the call app's **output** into a loopback/aggregate **input** device first, and then NoNoise Mac captures *that* device as if it were a microphone. Concretely the user does one of:

1. **BlackHole / Loopback as the call app's speaker.** Set the call app's *speaker/output* to a loopback device (e.g. "BlackHole 2ch"). The call app's audio now flows into BlackHole, which presents as an **input** device. NoNoise Mac captures BlackHole as the incoming source. **Trap:** if BlackHole is the *only* output, the user no longer hears anything from their real speakers — Phase 1's whole job is to re-play the cleaned audio to the real speakers, which solves this; but until Phase 1 is running, the user is deaf to the call. We surface this in the setup UX (route via a **Multi-Output Device** that includes both BlackHole *and* the real speakers if they want raw monitoring, OR just rely on Phase 1's cleaned playback).
2. **An aggregate/multi-output device** that carries the call app's output into a capturable input.

This is **identical in spirit** to the existing virtual-mic story (the user must point their chat app at "NoNoise Mic"), so the UX language reuses the same "pick X in the other app" pattern. The setup friction is real and MUST be documented in the in-app Setup Guide, not hidden.

`AVCaptureDevice.DiscoverySession` (the API `AudioModel.fetchInputDevices` uses) does **not** reliably surface loopback devices like BlackHole — there's a code comment to this effect at `Sources/Core/AudioModel.swift:475`. The incoming-source picker therefore must enumerate **input-capable devices via the CoreAudio HAL** (`kAudioHardwarePropertyDevices`, input-scoped `kAudioDevicePropertyStreamConfiguration`), the same HAL path `fetchOutputDevices` already uses for outputs — NOT `AVCaptureDevice.DiscoverySession`. This is the single biggest correctness fact in the plan.

### The engine question: second `AudioModel` vs. reusable engine
The existing pipeline is **one `AudioModel`** — a CoreAudio-coupled `NSObject` with shared/singleton-ish state:
- `AudioUtils.shared` (a singleton; its `processingFormat` and helpers are stateless/read-only, so sharing is safe).
- A `kAudioHardwarePropertyDevices` HAL listener (`installHardwareDeviceListener`).
- A per-mic `kAudioDevicePropertyDeviceIsRunningSomewhere` listener keyed by `micDeviceID` (on-demand capture).
- **Auto-routing in `fetchOutputDevices()`** that *force-routes* its `AVAudioEngine` output to the hidden "NoNoise Mic Engine" sink — i.e. `AudioModel` always wants to send its output to the virtual mic.

**Decision: do NOT instantiate a second `AudioModel`.** Reasons (all verified against the source):
- `AudioModel.fetchOutputDevices()` would hijack the second instance's output and point it at the NoNoise Mic engine — the exact opposite of "play to the user's speakers."
- Two `AudioModel`s = two `kAudioHardwarePropertyDevices` listeners + duplicated on-demand-mic logic fighting over the same real mic and the same `mv.*` UserDefaults keys.
- `AudioModel`'s capture is hardwired to a *microphone* (`AVCaptureDevice`), with the virtual mic filtered OUT of its input list (`fetchInputDevices` → `VirtualMicRouting.filterInputs`). The incoming path needs the *opposite*: capture a loopback device, which is exactly what's filtered out.

Instead, extract the proven CLI pattern into a **new, focused `IncomingCleanupEngine`** that owns an independent capture session, ring buffer, a **fresh `DeepFilterNetDSP()` instance**, and an `AVAudioEngine` playing to a chosen physical output. `DeepFilterNetDSP` is safe to instantiate a second time: it allocates its own scratch + input `MLMultiArray`s + recurrent hidden state in `init()` and is single-threaded per instance (its hidden state must NOT be shared — two streams sharing one `DeepFilterNetDSP` would corrupt each other's recurrent state). The CoreML model object is loaded per-instance; that's the standard usage.

### The performance question (Apple-Silicon mandate — addressed honestly)
Running a **second** DeepFilterNet stream concurrently with the mic stream is **not free**. Both run `computeUnits = .all` (ANE/GPU). The ANE is a shared, finite resource; two real-time DFN streams roughly double the model's compute and memory-bandwidth load and can contend on the ANE, raising latency/CPU for *both* streams. The plan addresses this, not hand-waves it:
- **Off by default.** The incoming pipeline does nothing — no capture, no model load, no engine — until the user explicitly enables "Clean incoming/guest." Zero cost for the default user (preserves the always-available menu-bar feel).
- **Lazy + tear-down.** The `DeepFilterNetDSP`, capture session, and `AVAudioEngine` are created when enabled and fully torn down when disabled, so a disabled feature holds no ANE/CPU/mic.
- **Measure, don't assume.** A mandatory manual step profiles CPU + latency with both streams live (Activity Monitor / `powermetrics` / Instruments) and records a before/after note. If two concurrent streams cause audible glitches on the baseline target Mac, that's a finding to surface — the plan does NOT pretend the cost is zero.
- **Real-time rules still apply** to the new engine's render callback: allocation-free, scalar/vDSP only, lock-free `var` scalars from main→render (same pattern as `AudioModel`'s `isAIEnabled` / `outputGain`). The new engine reuses `DeepFilterNetDSP` exactly as `AudioModel` does (DFN suppression only — it deliberately does NOT run a `VoiceChain`; the guest needs cleaning, not voice "polish" coloring) — no new hot-path code beyond wiring.
- **Zero-cost-when-off, enforced at the OWNER:** `DeepFilterNetDSP.init()` allocates 6 `MLMultiArray`s + ~12 `[Float]` scratch buffers and async-loads the CoreML model. A `private let incomingEngine = IncomingCleanupEngine()` stored on `AudioModel` would therefore pay that cost **at app launch**, defeating the mandate. So `AudioModel` holds `IncomingCleanupEngine?` (optional) and constructs the instance ONLY in the enable path, releasing it to `nil` on disable. No engine object exists while the feature is off → no buffers, no model, no ANE. A fresh instance per enable also guarantees fresh DFN recurrent hidden state each session.

### Privacy (a core promise — unchanged)
100% on-device. The incoming pipeline is the same local CoreML model; nothing leaves the machine, no telemetry. Phase 2's second virtual sink is a local CoreAudio device. No new entitlements: capturing a loopback *input* device uses the existing `com.apple.security.device.audio-input` entitlement (it's an audio input from the OS's perspective).

### Current code facts (verified against the repo)
- `Sources/CLI/main.swift` is the SHAPE template: it builds an `AudioModel`, picks input + output devices by name, sets `isAIEnabled = true`, and runs the pipeline — input device → clean → output device. The new engine generalizes this without `AudioModel`'s mic/virtual-mic coupling. **Caveat:** the CLI selects its input by name from `model.inputDevices` (the `AVCaptureDevice.DiscoverySession` list), so it has NEVER captured a loopback device that discovery misses — it does NOT prove the incoming capture path. Task S exists precisely to close that gap.
- `AudioModel.fetchOutputDevices()` (`Sources/Core/AudioModel.swift:319`) enumerates **output-capable** devices via `kAudioHardwarePropertyDevices` + output-scoped `kAudioDevicePropertyStreamConfiguration`, reads each device's real UID (`kAudioDevicePropertyDeviceUID`) and hidden flag, and resolves UIDs to `AudioObjectID` via `kAudioHardwarePropertyTranslateUIDToDevice` (`deviceID(forUID:)`, line 305). The incoming-**input** picker mirrors this with `kAudioObjectPropertyScopeInput`.
- `AudioModel.setupPlaybackEngine()` (line 407) shows how to bind an `AVAudioEngine`'s `outputNode` to a chosen `AudioObjectID` via `AudioUnitSetProperty(..., kAudioOutputUnitProperty_CurrentDevice, ...)`, attach a source node, connect through the mixer, and `engine.start()`. The new engine reuses this exact shape for playback to the user's speakers.
- `AudioModel.captureOutput(...)` (line 604) shows the capture→convert-to-48k-mono→`ringBuffer.write` path; the render callback (line 153) shows ring-read → `dsp.process` → `chain.process`. The new engine reuses both shapes.
- `DeepFilterNetDSP` (`Sources/Core/AudioProcessing/DeepFilterNetDSP.swift`) is a `class` with mutable recurrent hidden state and pre-allocated input `MLMultiArray`s; a fresh instance is independent. Reading model **outputs** must go through `NSNumber` (see `docs/knowledge/critical-patterns.md` — shipped-and-broke silent-output bug). The new engine does NOT touch the model call; it only constructs a second instance and calls `process(input:count:output:)`.
- `VirtualMicRouting` (`Sources/Core/AudioProcessing/VirtualMicRouting.swift`) is the pure, headless-tested routing/filtering type. Its constants are the app↔driver shared contract. Phase 2 adds a **second** virtual sink contract here (kept parallel to the existing engine-sink constants).
- `AudioModel` persists under the legacy `mv.*` UserDefaults namespace via `PrefKey`. New keys follow the same namespace (`mv.incoming*`). Never introduce "MetalVoice"/"Ghostkwebb" into `Sources/`.
- UI: `ContentView.swift` (menu-bar popover, card-based via `nnCard()`) and `SettingsView.swift` → `GeneralSettingsView` (cards). The new "Clean incoming/guest" controls follow the existing card + picker + toggle patterns.
- Tests live in `Tests/NoNoiseMacTests/` (`@testable import Core`), run headless with `swift test`. `VirtualMicRoutingTests.swift` is the style reference for pure routing-logic tests.

### Design decisions
- **Incoming cleanup is fully independent of the outgoing mic.** It is its own engine, its own enable toggle, its own device selections, its own persisted keys. Rationale: the two streams have opposite routing intents and must be independently startable/stoppable for the performance mandate.
- **No second `AudioModel`.** Extract the CLI pipeline into `IncomingCleanupEngine` (see "The engine question" above).
- **Off by default; lazy create / full teardown on toggle.** The second ANE stream only exists while enabled.
- **Input devices enumerated via the HAL, input-scoped** — NOT `AVCaptureDevice.DiscoverySession`, which misses loopback devices.
- **Phase 1 ships independently of Phase 2.** Phase 1 (hear-them-clean) is a complete, shippable feature. Phase 2 (record-them-clean, second virtual sink) is gated behind Phase 1 and is the more involved driver work.
- **Reuse `DeepFilterNetDSP` as-is; NO `VoiceChain`.** No DSP math changes. The incoming engine applies the same suppression (DFN only — the guest needs cleaning, not the outgoing voice-polish coloring; an unconfigured `VoiceChain` would be inert dead code). A follow-up could give it its own preset, but v1 uses full suppression.
- **Pure logic stays testable.** Device classification (which devices are valid incoming sources / valid monitor outputs) and Phase 2 routing are pure value-type functions with XCTests; the live engine is build- + smoke-verified.
- **Persisted keys (legacy namespace):** `mv.incomingEnabled`, `mv.incomingSourceUID`, `mv.incomingOutputUID` (Phase 1); `mv.incomingRecordEnabled` (Phase 2).

### Phase / device map (the feature in one table)

| Path | Captures from | Cleans with | Plays / routes to | Phase |
|---|---|---|---|---|
| Outgoing mic (existing) | real microphone | `AudioModel`'s `DeepFilterNetDSP` | NoNoise Mic engine sink (→ chat app) | shipped |
| **Incoming (hear)** | loopback/aggregate **input** (BlackHole/Loopback) carrying the call app's output | a **second** `DeepFilterNetDSP` | user's **speakers/headphones** | **1** |
| **Incoming (record)** | same loopback input | same second `DeepFilterNetDSP` | also a **second virtual sink** (→ OBS/Riverside) | **2** |

---

## Task 0: Branch

- [ ] **Step 1: Create a feature branch** (do NOT stage unrelated working-tree changes)

```bash
# Run from the package root (the directory that contains Package.swift)
git checkout -b feat/incoming-guest-cleanup
```

Expected: `Switched to a new branch 'feat/incoming-guest-cleanup'`. Throughout this plan, `git add` **only the specific files named in each task** — never `git add -A`/`.`.

---

## Task S (SPIKE — DO THIS FIRST): Prove `AVCaptureDevice(uniqueID:)` resolves a BlackHole HAL UID for capture

> **Gate for the whole capture design.** Task 2's `IncomingCleanupEngine` captures via
> `AVCaptureDevice(uniqueID: sourceDeviceUID)`, where `sourceDeviceUID` is the **HAL** UID from
> the Task-3 input scan. But `AVCaptureDevice.DiscoverySession` is documented (and commented at
> `Sources/Core/AudioModel.swift:475`) to **miss** loopback devices like BlackHole. There is a
> real, unproven question: **does `AVCaptureDevice(uniqueID:)` return a usable capture device for a
> BlackHole UID that DiscoverySession never lists?** AVFoundation's `uniqueID` is *usually* the HAL
> device UID, but a device absent from discovery may also fail to instantiate or fail to deliver
> sample buffers. The existing CLI does NOT prove this — it selects inputs by name from
> `model.inputDevices` (the DiscoverySession list), so it has never captured a non-discovered
> loopback. **Prove it before building the engine on top of it.**

**Files:**
- Create (temporary spike): `Sources/CLI/main.swift` is NOT touched; instead add a throwaway spike behind a CLI flag, OR run the inline verification snippet below and record the result. The spike must NOT ship — delete it (and any temporary file) before Task 2's commit and note the deletion in the timeline.

- [ ] **Step 1: Run the verification.** With BlackHole installed (and some audio routed into it so the stream is live), enumerate the BlackHole HAL UID (the Task-3 scan, or a one-off print) and attempt capture:

```swift
// Throwaway spike — verifies AVCaptureDevice(uniqueID:) resolves a HAL loopback UID.
import AVFoundation
import CoreAudio

// 1) Get BlackHole's HAL UID via the input-scoped HAL scan (same path Task 3 uses).
//    Print every input-capable device's (name, uid, transportType) and copy BlackHole's UID.
// 2) Attempt to resolve + capture it:
let halUID = "<BlackHole HAL UID from step 1>"
if let dev = AVCaptureDevice(uniqueID: halUID) {
    print("RESOLVED: \(dev.localizedName) uid=\(dev.uniqueID)")
    let session = AVCaptureSession()
    let input = try AVCaptureDeviceInput(device: dev)
    print("canAddInput=\(session.canAddInput(input))")
    session.beginConfiguration(); session.addInput(input)
    let out = AVCaptureAudioDataOutput()
    print("canAddOutput=\(session.canAddOutput(out))"); session.addOutput(out)
    session.commitConfiguration()
    // Attach a delegate that counts sample buffers for ~2s; print the count.
    session.startRunning()
} else {
    print("NOT RESOLVED: AVCaptureDevice(uniqueID:) returned nil for \(halUID)")
}
```

- [ ] **Step 2: Record the result — be explicit and honest.** One of two outcomes, both must be written into `docs/knowledge/timeline1.md` (and, if it changes the design, into a `[GOTCHA]`/`[DECISION]` knowledge entry):
  - **PASS** — `AVCaptureDevice(uniqueID:)` resolves the BlackHole UID, the session adds it, AND sample buffers arrive (non-zero count). → Proceed with Task 2 as written (AVCapture path). Note the proof in the timeline.
  - **FAIL** — resolution returns `nil`, or no sample buffers arrive. → **Do NOT build the engine on AVCapture.** Switch Task 2's capture to a **CoreAudio/HAL input path** that consumes the selected `AudioObjectID` directly: open the device with an input `AudioUnit` (`kAudioUnitSubType_HALOutput` with input enabled, `kAudioOutputUnitProperty_CurrentDevice = <AudioObjectID>`, `kAudioOutputUnitProperty_EnableIO`), install an input render callback, and write the pulled frames into the same ring buffer. In this case Task 3 hands the engine the **`AudioObjectID`** (already enumerated), not a UID, and the engine's `configureCapture(sourceDeviceUID:)` signature becomes `configureCapture(sourceDeviceID: AudioObjectID)`.

- [ ] **Step 3: Remove the spike.** Delete the throwaway snippet/file. Confirm `git status` shows no spike artifact. The spike is verification-only — it never ships.

> **Documented fallback (honesty mandate):** If the spike FAILS, the entire capture half of Task 2
> uses the HAL input-`AudioUnit` path above instead of `AVCaptureSession`. This plan keeps the
> AVCapture path as the primary (it reuses the proven `AudioModel.captureOutput` converter shape and
> is less code) but treats it as **provisional until the spike passes**. Do not present Phase 1 as
> validated until this gate is green.

---

## Task 1: Device classification — accept loopback sources, REJECT physical mics — TDD

The incoming source must be a **loopback/aggregate input** carrying the call app's output. It must NEVER be:
- a **real microphone** (e.g. "MacBook Pro Microphone", a USB mic) — capturing the mic as "incoming" makes no sense, and the canonical contract is "loopback/aggregate sources only";
- our own **NoNoise Mic** virtual device (would loop our cleaned voice back in);
- a **hidden** device.

The monitor output must be a **real physical output** (the whole point is to hear the guest on real speakers/headphones). It must actually HAVE output channels (`hasOutput`), and it must reject every re-feed path: virtual transports, known loopback sinks (BlackHole/Loopback), **and aggregate/multi-output devices** — a Multi-Output/Aggregate containing BlackHole + speakers would silently re-feed the captured loopback and create a feedback path, so it is never a valid monitor output even though it has output channels. This is pure logic — exactly the kind `VirtualMicRouting` already hosts.

**Why `DeviceInfo` must grow:** the existing `DeviceInfo` (`uid`, `name`, `isHidden`, `hasOutput`) carries **no input-capability and no transport-type metadata**, so the *only* way today's draft predicate could reject a physical mic is by name — which fails for any mic not literally named "Microphone". The canonical predicate needs structured metadata: whether the device has **input** channels, and its **transport type** (a built-in/USB/Bluetooth/etc. mic is physical; an aggregate or virtual loopback reports `kAudioDeviceTransportTypeAggregate`/`...Virtual`, and BlackHole/Loopback are matched by their known names as a belt-and-suspenders fallback). We add `hasInput` and `transportType` to `DeviceInfo` (both default-initialized so existing call sites — `fetchOutputDevices` and the existing routing tests — keep compiling unchanged).

> **`AudioDeviceTransportType` values used (verified against `CoreAudio/AudioHardwareBase.h`):**
> `kAudioDeviceTransportTypeBuiltIn` (`'bltn'`), `...USB` (`'usb '`), `...Bluetooth` (`'blue'`), `...BluetoothLE` (`'blea'`), `...HDMI` (`'hdmi'`), `...DisplayPort` (`'dprt'`), `...AirPlay` (`'airp'`), `...Aggregate` (`'grup'`), `...Virtual` (`'virt'`), `...Unknown` (`0`). The predicate treats these as a raw `UInt32`; the `Core` module already imports `CoreAudio` transitively for `AudioObjectID`, but `VirtualMicRouting` itself is CoreAudio-free, so we store the transport type as a plain `UInt32` and define the handful of constants we compare against locally (keeping the type headless-testable).

**Files:**
- Modify: `Sources/Core/AudioProcessing/VirtualMicRouting.swift` (extend `DeviceInfo`; add input-source + monitor-output predicates)
- Create: `Tests/NoNoiseMacTests/IncomingCleanupTests.swift`

- [ ] **Step 1: Write the failing tests** — create `Tests/NoNoiseMacTests/IncomingCleanupTests.swift`

```swift
import XCTest
@testable import Core

final class IncomingCleanupTests: XCTestCase {

    // MARK: - Helpers

    /// A loopback/aggregate INPUT (e.g. BlackHole, Loopback, an aggregate device).
    private func loopbackInput(_ uid: String, _ name: String,
                               transport: UInt32 = VirtualMicRouting.transportTypeVirtual,
                               hidden: Bool = false) -> VirtualMicRouting.DeviceInfo {
        VirtualMicRouting.DeviceInfo(uid: uid, name: name, isHidden: hidden,
                                     hasOutput: false, hasInput: true, transportType: transport)
    }

    /// A real, physical microphone (built-in / USB / Bluetooth).
    private func physicalMic(_ uid: String, _ name: String,
                             transport: UInt32) -> VirtualMicRouting.DeviceInfo {
        VirtualMicRouting.DeviceInfo(uid: uid, name: name, isHidden: false,
                                     hasOutput: false, hasInput: true, transportType: transport)
    }

    private func output(_ uid: String, _ name: String,
                        transport: UInt32 = VirtualMicRouting.transportTypeBuiltIn,
                        hidden: Bool = false) -> VirtualMicRouting.DeviceInfo {
        VirtualMicRouting.DeviceInfo(uid: uid, name: name, isHidden: hidden,
                                     hasOutput: true, hasInput: false, transportType: transport)
    }

    // MARK: - Incoming source classification

    /// A loopback/aggregate input (BlackHole) IS a valid incoming source.
    func testBlackHoleIsValidIncomingSource() {
        XCTAssertTrue(VirtualMicRouting.isSelectableIncomingSource(loopbackInput("BH:2ch", "BlackHole 2ch")))
    }

    /// An aggregate device (transport = aggregate) IS a valid incoming source.
    func testAggregateIsValidIncomingSource() {
        XCTAssertTrue(VirtualMicRouting.isSelectableIncomingSource(
            loopbackInput("agg:1", "Podcast Aggregate", transport: VirtualMicRouting.transportTypeAggregate)))
    }

    /// THE CONTRACT FIX: a real physical microphone is NOT an incoming source.
    /// (Currently passes the draft predicate — this is the failing-first test that proves the bug.)
    func testPhysicalMicIsNotAnIncomingSource() {
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(
            physicalMic("blt:in", "MacBook Pro Microphone", transport: VirtualMicRouting.transportTypeBuiltIn)))
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(
            physicalMic("usb:mic", "Yeti Stereo Microphone", transport: VirtualMicRouting.transportTypeUSB)))
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(
            physicalMic("bt:ap", "AirPods Pro", transport: VirtualMicRouting.transportTypeBluetooth)))
    }

    /// Our own NoNoise Mic devices are NOT valid incoming sources (would loop the cleaned mic back in).
    func testNoNoiseMicIsNotAnIncomingSource() {
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(
            loopbackInput(VirtualMicRouting.visibleDeviceUID, VirtualMicRouting.visibleDeviceName)))
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(
            loopbackInput(VirtualMicRouting.engineDeviceUID, VirtualMicRouting.engineDeviceName)))
    }

    /// SELF-LOOP FIX: the visible NoNoise Mic is rejected by UID even when its NAME differs
    /// (localised / renamed). The shared contract's strongest id is the UID, so a UID match
    /// with a differing name must STILL be rejected — proves `isNoNoiseVisible` matches by UID.
    func testNoNoiseVisibleRejectedByUIDWhenNameDiffers() {
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(
            loopbackInput(VirtualMicRouting.visibleDeviceUID, "Renamed Virtual Input")))
    }

    /// A device with no input channels is never an incoming source (you can't capture it).
    func testOutputOnlyDeviceIsNotAnIncomingSource() {
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(output("spk:0", "MacBook Pro Speakers")))
    }

    /// A hidden device is never offered as an incoming source.
    func testHiddenDeviceIsNotAnIncomingSource() {
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(
            loopbackInput("hidden:x", "Some Hidden Device", hidden: true)))
    }

    /// The selectable-incoming-source filter drops physical mics + our devices + hidden, keeps loopbacks.
    func testIncomingSourceFilterKeepsLoopbackDropsMicsAndOurs() {
        let devices = [
            loopbackInput("BH:2ch", "BlackHole 2ch"),
            loopbackInput("LB:1", "Loopback Audio"),
            physicalMic("blt:in", "MacBook Pro Microphone", transport: VirtualMicRouting.transportTypeBuiltIn),
            loopbackInput(VirtualMicRouting.visibleDeviceUID, VirtualMicRouting.visibleDeviceName),
            loopbackInput("hidden:x", "Hidden", hidden: true),
        ]
        let kept = VirtualMicRouting.selectableIncomingSources(from: devices).map(\.name)
        XCTAssertEqual(kept, ["BlackHole 2ch", "Loopback Audio"])
    }

    // MARK: - Monitor (hear-them) output classification

    /// A real physical output (built-in speakers / headphones) IS a valid monitor output.
    func testSpeakersAreValidMonitorOutput() {
        XCTAssertTrue(VirtualMicRouting.isSelectableMonitorOutput(output("spk:0", "MacBook Pro Speakers")))
    }

    /// A physical USB / Bluetooth OUTPUT remains a valid monitor output (real output, not a re-feed).
    func testPhysicalUSBAndBluetoothOutputsAreValidMonitorOutputs() {
        XCTAssertTrue(VirtualMicRouting.isSelectableMonitorOutput(
            output("usb:out", "USB Audio Device", transport: VirtualMicRouting.transportTypeUSB)))
        XCTAssertTrue(VirtualMicRouting.isSelectableMonitorOutput(
            output("bt:ap", "AirPods Pro", transport: VirtualMicRouting.transportTypeBluetooth)))
    }

    /// Routing the monitor into a loopback sink (BlackHole) or our engine would re-loop — reject it.
    func testLoopbackAndEngineAreNotMonitorOutputs() {
        XCTAssertFalse(VirtualMicRouting.isSelectableMonitorOutput(
            output("BH:2ch", "BlackHole 2ch", transport: VirtualMicRouting.transportTypeVirtual)))
        XCTAssertFalse(VirtualMicRouting.isSelectableMonitorOutput(
            output(VirtualMicRouting.engineDeviceUID, VirtualMicRouting.engineDeviceName)))
    }

    /// REAL-OUTPUT-ONLY FIX (a): an input-only device (no output channels) is NOT a monitor output,
    /// even if its transport is aggregate. The monitor must actually be able to play audio.
    func testInputOnlyAggregateIsNotAMonitorOutput() {
        XCTAssertFalse(VirtualMicRouting.isSelectableMonitorOutput(
            loopbackInput("agg:in", "Input-Only Aggregate",
                          transport: VirtualMicRouting.transportTypeAggregate)))
    }

    /// REAL-OUTPUT-ONLY FIX (b): a Multi-Output / Aggregate device (BlackHole + speakers) is NOT a
    /// valid monitor output — even though it has output channels — because it would re-feed the
    /// captured loopback and create a feedback path. Aggregate transport is rejected outright.
    func testAggregateMultiOutputIsNotAMonitorOutput() {
        XCTAssertFalse(VirtualMicRouting.isSelectableMonitorOutput(
            output("multi:1", "Multi-Output Device",
                   transport: VirtualMicRouting.transportTypeAggregate)))
    }

    /// REAL-OUTPUT-ONLY FIX (c): a physical built-in OUTPUT (speakers) with output channels remains
    /// valid — guards against the new `hasOutput`/aggregate gates over-rejecting real outputs.
    func testBuiltInOutputRemainsValidMonitorOutput() {
        XCTAssertTrue(VirtualMicRouting.isSelectableMonitorOutput(
            output("spk:builtin", "MacBook Pro Speakers",
                   transport: VirtualMicRouting.transportTypeBuiltIn)))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter IncomingCleanupTests`
Expected: compile error — `incorrect argument label` (`DeviceInfo` has no `hasInput:`/`transportType:`) and `type 'VirtualMicRouting' has no member 'isSelectableIncomingSource'`. After Step 3a compiles, `testPhysicalMicIsNotAnIncomingSource` is the load-bearing failing-first test that proves the wrong-contract bug before Step 3b fixes it.

- [ ] **Step 3a: Extend `DeviceInfo` with input-capability + transport metadata**

In `Sources/Core/AudioProcessing/VirtualMicRouting.swift`, replace the existing `DeviceInfo` struct with this widened version (new fields are default-initialized so `fetchOutputDevices` and the existing routing tests keep compiling unchanged):

```swift
    public struct DeviceInfo: Equatable {
        public let uid: String
        public let name: String
        public let isHidden: Bool
        public let hasOutput: Bool
        /// True if the device exposes INPUT (capture) channels. Required to reject output-only
        /// devices from the incoming-source picker.
        public let hasInput: Bool
        /// CoreAudio `kAudioDevicePropertyTransportType` as a raw `UInt32` (kept CoreAudio-free here).
        /// Lets us reject physical mics (built-in/USB/Bluetooth/HDMI/…) and accept aggregate/virtual.
        public let transportType: UInt32
        public init(uid: String, name: String, isHidden: Bool, hasOutput: Bool,
                    hasInput: Bool = false, transportType: UInt32 = 0) {
            self.uid = uid; self.name = name; self.isHidden = isHidden; self.hasOutput = hasOutput
            self.hasInput = hasInput; self.transportType = transportType
        }
    }
```

- [ ] **Step 3b: Add the transport-type constants + predicates**

Add after `filterInputs(_:)` (the existing last function), still inside the `enum`:

```swift
    // ---- Incoming / guest cleanup (the OTHER side) ----

    // CoreAudio `AudioDeviceTransportType` values (FourCharCodes from <CoreAudio/AudioHardwareBase.h>).
    // Mirrored here as plain UInt32 so VirtualMicRouting stays headless-testable (no CoreAudio import).
    public static let transportTypeUnknown: UInt32   = 0
    public static let transportTypeBuiltIn: UInt32   = 0x626C746E // 'bltn'
    public static let transportTypeAggregate: UInt32 = 0x67727570 // 'grup'
    public static let transportTypeVirtual: UInt32   = 0x76697274 // 'virt'
    public static let transportTypeUSB: UInt32       = 0x75736220 // 'usb '
    public static let transportTypeBluetooth: UInt32 = 0x626C7565 // 'blue'

    /// Transport types that identify a PHYSICAL mic — never a valid incoming (loopback) source.
    private static let physicalInputTransports: Set<UInt32> = [
        transportTypeBuiltIn,
        transportTypeUSB,
        transportTypeBluetooth,
        0x626C6561, // 'blea' BluetoothLE
        0x68646D69, // 'hdmi' HDMI
        0x64707274, // 'dprt' DisplayPort
        0x61697270, // 'airp' AirPlay
        0x7468756E, // 'thun' Thunderbolt
        0x70636920, // 'pci ' PCI
        0x66697265, // 'fire' FireWire
    ]

    /// True for the VISIBLE NoNoise Mic device. Matches by UID OR name — the shared contract's
    /// strongest id is the UID, so a UID match with a differing/localised name must STILL be
    /// rejected (a self-loop: capturing our own cleaned voice back as the "incoming" guest).
    /// Mirrors `isNoNoiseEngine`'s UID-or-name strategy for the hidden engine device.
    public static func isNoNoiseVisible(_ d: DeviceInfo) -> Bool {
        d.uid == visibleDeviceUID || d.name == visibleDeviceName
    }

    /// True for a device the user may pick as the INCOMING (guest) source — a loopback/aggregate
    /// INPUT carrying the call app's output. The canonical contract is "loopback/aggregate only":
    /// it must have input channels, must NOT be hidden, must NOT be our own NoNoise Mic devices
    /// (matched by UID OR name via `isNoNoiseEngine`/`isNoNoiseVisible` so a UID match with a
    /// differing name is still rejected), and must NOT be a physical mic (built-in/USB/Bluetooth/…).
    /// Known loopbacks (BlackHole/Loopback) are accepted by name even if their transport is reported
    /// as Unknown.
    public static func isSelectableIncomingSource(_ d: DeviceInfo) -> Bool {
        guard d.hasInput, !d.isHidden, !isNoNoiseEngine(d), !isNoNoiseVisible(d) else { return false }
        if physicalInputTransports.contains(d.transportType) { return false }
        // Accept: aggregate/virtual transports, or known loopback names (belt-and-suspenders for
        // drivers that report Unknown transport).
        if d.transportType == transportTypeAggregate || d.transportType == transportTypeVirtual { return true }
        if knownLoopbackNames.contains(where: { d.name.contains($0) }) { return true }
        // Unknown transport + not a known loopback → reject (we only accept proven loopback paths).
        return false
    }

    /// Devices to offer as the incoming source — physical mics, our devices, hidden, and
    /// output-only devices excluded.
    public static func selectableIncomingSources(from devices: [DeviceInfo]) -> [DeviceInfo] {
        devices.filter(isSelectableIncomingSource)
    }

    /// True for a device the user may pick to MONITOR (hear) the cleaned guest — a REAL output.
    /// The canonical contract is "real physical output only". It must HAVE output channels
    /// (`hasOutput`), must NOT be hidden, must NOT be our engine, and must NOT be a re-feed path:
    /// we REJECT virtual transports, aggregate transports, and known loopback sinks (BlackHole/
    /// Loopback). Rejecting aggregate is load-bearing: a Multi-Output / Aggregate device containing
    /// BlackHole + speakers would silently re-feed the incoming source (the captured loopback),
    /// creating a feedback path — so an aggregate is never a valid monitor output even though it
    /// has output channels.
    public static func isSelectableMonitorOutput(_ d: DeviceInfo) -> Bool {
        d.hasOutput
            && !d.isHidden
            && !isNoNoiseEngine(d)
            && d.transportType != transportTypeVirtual
            && d.transportType != transportTypeAggregate
            && !knownLoopbackNames.contains(where: { d.name.contains($0) })
    }

    /// Known software-loopback device names (matched as `contains`). Superset of `fallbackVirtualSinks`
    /// because Loopback (Rogue Amoeba) is also a valid INCOMING source but an invalid MONITOR output.
    private static let knownLoopbackNames = ["BlackHole", "Loopback"]
```

The predicates reuse the existing `isNoNoiseEngine` / `visibleDeviceName` constants. `fallbackVirtualSinks` is left unchanged (it governs auto-route only); `knownLoopbackNames` is the incoming/monitor superset.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter IncomingCleanupTests`
Expected: all 15 tests PASS (including `testPhysicalMicIsNotAnIncomingSource`, the self-loop
`testNoNoiseVisibleRejectedByUIDWhenNameDiffers`, and the real-output-only monitor tests
`testInputOnlyAggregateIsNotAMonitorOutput` / `testAggregateMultiOutputIsNotAMonitorOutput` /
`testBuiltInOutputRemainsValidMonitorOutput`).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/VirtualMicRouting.swift Tests/NoNoiseMacTests/IncomingCleanupTests.swift
git commit -m "feat(routing): classify incoming sources (reject physical mics) + monitor outputs"
```

---

## Task 2: `IncomingCleanupEngine` — independent capture→clean→play pipeline (Phase 1 core)

The second pipeline. It owns its own capture session, ring buffer, a **fresh `DeepFilterNetDSP`**, and an `AVAudioEngine` playing to a chosen monitor output. Built by generalizing the proven CLI path (`Sources/CLI/main.swift`) and reusing `AudioModel`'s capture/playback shapes — but with NO mic/virtual-mic coupling and NO auto-routing to the NoNoise Mic sink. **No XCTest:** it depends on CoreAudio/AVCapture and is not unit-testable in the headless suite (same reason `AudioModel` is not). Verification is `swift build` + the green Core suite + the manual smoke test.

> **Lazy lifecycle (CRITICAL — zero cost when off):** `DeepFilterNetDSP.init()` allocates 6
> `MLMultiArray`s + ~12 `[Float]` scratch buffers AND fires an async `Task` to load the CoreML
> model (`Sources/Core/AudioProcessing/DeepFilterNetDSP.swift:222`). So the engine must NOT exist
> while the feature is off. This plan makes the engine **lazy at the owner level**: `AudioModel`
> holds `IncomingCleanupEngine?` and creates the instance only in the enable path, releasing it to
> `nil` on disable (Task 3). Because the engine is created fresh on each enable, a fresh
> `DeepFilterNetDSP` is constructed each session → **fresh recurrent hidden state every session**
> (no stale state carried across enable/disable — verify in the smoke test). The engine therefore
> does NOT need its own lazy-DSP machinery; owning a non-optional `DeepFilterNetDSP` is correct
> *because the engine itself is only alive while enabled.*
>
> **Incoming = DFN only (no VoiceChain):** the guest path needs noise/reverb suppression, not the
> outgoing "voice polish" coloring. A bare `VoiceChain()` is inert anyway (`VoiceChain.active`
> defaults to `false`; `process` is a no-op until `configure(_:)` runs on main), so a `VoiceChain`
> member that is never configured would be dead code. We therefore OMIT `VoiceChain` from the
> incoming engine. (If a future "polish the guest" option is wanted, add a `VoiceChain` and call
> `configure(_:)` on main with the canonical order hp → shelves → presence → deEsser → comp →
> limiter — but that is out of scope for Phase 1.)

**Files:**
- Create: `Sources/Core/AudioProcessing/IncomingCleanupEngine.swift`

- [ ] **Step 1: Create the engine** — `Sources/Core/AudioProcessing/IncomingCleanupEngine.swift`

> If the Task-S spike FAILED, replace the `AVCaptureSession` capture half below with the HAL input-`AudioUnit` path the spike task specifies, and change `start`/`configureCapture` to take a `sourceDeviceID: AudioObjectID`. The playback half, ring buffer, DSP, and render callback are unchanged. The code below is the AVCapture variant (primary path, provisional until the spike passes).

```swift
import Foundation
import AVFoundation
import AVFAudio
import AudioToolbox
import CoreAudio
import Accelerate

/// Independent "clean the OTHER side" pipeline: captures a loopback/aggregate INPUT device
/// (carrying the call app's output), runs it through its OWN DeepFilterNet engine, and plays
/// the cleaned result to the user's chosen monitor output — so the user HEARS the guest clean.
///
/// Deliberately NOT an `AudioModel`: it must NOT auto-route to the NoNoise Mic sink, must NOT
/// touch the real mic, and must be fully tear-down-able. The second CoreML stream has real ANE
/// cost AND a real allocation/model-load cost at `DeepFilterNetDSP.init()`, so the OWNER
/// (`AudioModel`) only constructs this engine while the feature is enabled and releases it to nil
/// on disable — see the plan's performance section. A fresh instance => fresh DFN recurrent state.
/// Single-threaded per instance; its render callback is allocation-free. Incoming = DFN only
/// (no VoiceChain — see the plan note above).
public final class IncomingCleanupEngine: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    /// Set from MAIN, read on the render thread. Plain scalar — atomic on arm64, no lock
    /// (same pattern as `AudioModel.isAIEnabled` / `DeepFilterNetDSP.outputGain`).
    public var isCleaningEnabled: Bool = true

    private let captureSession = AVCaptureSession()
    private let captureOutput = AVCaptureAudioDataOutput()
    private let processingQueue = DispatchQueue(label: "incoming.processing.queue", qos: .userInteractive)

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    private var sourceNodeAttached = false        // attach once; engine.reset() does NOT detach nodes
    private var outputNode: AVAudioOutputNode { engine.outputNode }
    private var mainMixer: AVAudioMixerNode { engine.mainMixerNode }

    private let ringBuffer = RingBuffer(capacity: 48000 * 5)
    private let dsp = DeepFilterNetDSP()          // fresh, independent recurrent state (per instance)

    // Converter state (capture → 48k mono Float32), mirrors AudioModel.captureOutput.
    private var inputConverter: AVAudioConverter?
    private var inputPCMBuffer: AVAudioPCMBuffer?
    private var inputBuffer48k: AVAudioPCMBuffer?

    private var running = false

    public override init() {
        super.init()
        let bufferRef = ringBuffer
        let dspRef = dsp
        sourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let count = Int(frameCount)

            // Latency trim (same shape as AudioModel's render callback).
            let latencyTarget = 2400
            let available = bufferRef.count
            if available > (latencyTarget + count) { bufferRef.drop(available - latencyTarget) }

            if !bufferRef.read(into: data, count: count) {
                AudioUtils.shared.fillSilence(data, count: count)
                return noErr
            }
            if let self = self, self.isCleaningEnabled {
                dspRef.process(input: data, count: count, output: data)
            }
            return noErr
        }
    }

    /// Begin cleaning: capture `sourceDeviceUID`, play to `monitorDeviceID`. Idempotent.
    public func start(sourceDeviceUID: String, monitorDeviceID: AudioObjectID) {
        stop()                                   // clean slate (rebuild capture + engine)
        configureCapture(sourceDeviceUID: sourceDeviceUID)
        configurePlayback(monitorDeviceID: monitorDeviceID)
        running = true
    }

    /// Stop and fully tear down. The OWNER releases the whole engine to nil after this, so the
    /// second CoreML stream's allocations/model are freed too (the performance mandate requires
    /// zero cost when off). `engine.reset()` does NOT detach the source node — keep `sourceNode`
    /// attached across stop/start within one instance; the instance is short-lived anyway.
    public func stop() {
        guard running || captureSession.isRunning || engine.isRunning else { return }
        captureSession.stopRunning()
        captureSession.beginConfiguration()
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }
        captureSession.commitConfiguration()
        engine.stop()
        engine.reset()
        running = false
    }

    // MARK: - Capture (loopback INPUT device, resolved by UID via the HAL)

    private func configureCapture(sourceDeviceUID: String) {
        // PROVISIONAL until Task-S spike passes: AVCaptureDevice.DiscoverySession misses loopback
        // devices (comment at AudioModel.swift:475). The spike must prove AVCaptureDevice(uniqueID:)
        // resolves AND delivers sample buffers for a BlackHole HAL UID; if it fails, this whole
        // method is replaced by the HAL input-AudioUnit path. The picker (Task 3) enumerates via
        // the HAL and hands us that UID.
        guard let device = AVCaptureDevice(uniqueID: sourceDeviceUID) else {
            print("IncomingCleanupEngine: source device not found: \(sourceDeviceUID)")
            return
        }
        captureSession.beginConfiguration()
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) { captureSession.addInput(input) }
            if captureSession.canAddOutput(captureOutput) {
                captureSession.addOutput(captureOutput)
                captureOutput.setSampleBufferDelegate(self, queue: processingQueue)
            }
        } catch {
            print("IncomingCleanupEngine capture error: \(error)")
        }
        captureSession.commitConfiguration()
        DispatchQueue.global(qos: .userInitiated).async { self.captureSession.startRunning() }
    }

    // MARK: - Playback (to the user's monitor output)

    private func configurePlayback(monitorDeviceID: AudioObjectID) {
        engine.stop(); engine.reset()
        if monitorDeviceID != 0 {
            var dev = monitorDeviceID
            let size = UInt32(MemoryLayout<AudioObjectID>.size)
            AudioUnitSetProperty(outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice,
                                 kAudioUnitScope_Global, 0, &dev, size)
        }
        // Attach the source node ONCE per instance. `engine.reset()` (in `stop`) tears down the
        // render state but does NOT detach attached nodes, so re-attaching would throw / duplicate.
        if !sourceNodeAttached {
            engine.attach(sourceNode)
            sourceNodeAttached = true
        }
        engine.connect(sourceNode, to: mainMixer, format: AudioUtils.shared.processingFormat)
        engine.connect(mainMixer, to: outputNode, format: nil)
        do { try engine.start() } catch { print("IncomingCleanupEngine engine error: \(error)") }
    }

    // MARK: - Capture delegate (→ 48k mono → ring), mirrors AudioModel.captureOutput

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc),
              let inputFormat = AVAudioFormat(streamDescription: asbd),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000.0,
                                               channels: 1, interleaved: false) else { return }

        if inputConverter == nil || inputConverter?.inputFormat != inputFormat {
            inputConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
            let maxIn = AVAudioFrameCount(4096)
            inputPCMBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: maxIn)
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            inputBuffer48k = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                              frameCapacity: AVAudioFrameCount(Double(maxIn) * ratio + 5))
        }
        guard let converter = inputConverter, let inBuf = inputPCMBuffer, let outBuf = inputBuffer48k
        else { return }

        let n = CMSampleBufferGetNumSamples(sampleBuffer)
        inBuf.frameLength = AVAudioFrameCount(n)
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0,
                        frameCount: Int32(n), into: inBuf.mutableAudioBufferList)
        guard status == noErr else { return }

        var err: NSError?
        var fed = false
        outBuf.frameLength = outBuf.frameCapacity
        converter.convert(to: outBuf, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true; outStatus.pointee = .haveData; return inBuf
        }
        let frames = Int(outBuf.frameLength)
        if frames > 0, let ch = outBuf.floatChannelData?[0] {
            _ = self.ringBuffer.write(ch, count: frames)
        }
    }
}
```

> **Note on `DeepFilterNetDSP` access:** `DeepFilterNetDSP` is currently declared without an explicit access modifier (internal to `Core`). `IncomingCleanupEngine` is in the **same `Core` module**, so internal access is fine — no visibility change to `DeepFilterNetDSP` is required. Confirm at build time; if a future split moves it out of `Core`, that's a separate change.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds (the engine compiles against the existing `Core` types).

- [ ] **Step 3: Commit**

```bash
git add Sources/Core/AudioProcessing/IncomingCleanupEngine.swift
git commit -m "feat(audio): add IncomingCleanupEngine (independent capture→clean→play pipeline)"
```

---

## Task 3: Incoming device enumeration + wiring on `AudioModel` (HAL input-scope) — Phase 1

`AudioModel` is the app's single owner of device state and persistence, so it owns the incoming **selections** and the engine **lifecycle** too (mirroring how it owns the outgoing pipeline). Enumerate input-capable devices via the HAL (input scope) — NOT `AVCaptureDevice.DiscoverySession`, which misses BlackHole. Enumerate monitor outputs by reusing the existing output scan + the new `isSelectableMonitorOutput` filter. **No XCTest** (CoreAudio): build + smoke verified.

**Files:**
- Modify: `Sources/Core/AudioModel.swift`

- [ ] **Step 1: Add the `PrefKey`s** — in the `PrefKey` enum (lines ~114–120) add:

```swift
        static let incomingEnabled = "mv.incomingEnabled"
        static let incomingSourceUID = "mv.incomingSourceUID"
        static let incomingOutputUID = "mv.incomingOutputUID"
```

- [ ] **Step 2: Add published state + the engine** — after `virtualMicInUse` (line ~43) add the published selections, and near the other private modules (after `voiceChain`, line ~144) add the engine:

```swift
    // Incoming / guest cleanup (clean the OTHER side). Off by default — the second CoreML
    // stream has real ANE cost, so the engine is created only while enabled (see plan perf note).
    @Published public var incomingCleanupEnabled: Bool = false {
        didSet {
            guard !isApplyingPreset else { return }
            applyIncomingCleanup()
            persistIncomingSettings()
        }
    }
    /// HAL UID of the loopback/aggregate INPUT carrying the call app's output.
    @Published public var incomingSourceUID: String = "" {
        didSet {
            guard !isApplyingPreset, incomingSourceUID != oldValue else { return }
            applyIncomingCleanup()
            persistIncomingSettings()
        }
    }
    /// AudioObjectID of the monitor output (real speakers/headphones) the user hears the guest on.
    @Published public var incomingOutputDeviceID: AudioObjectID = 0 {
        didSet {
            guard !isApplyingPreset, incomingOutputDeviceID != oldValue else { return }
            applyIncomingCleanup()
            persistIncomingSettings()
        }
    }
    /// Input devices offered as the incoming source (loopback/aggregate; our devices + hidden excluded).
    @Published public var incomingSourceDevices: [DeviceStruct] = []
    /// Real outputs offered to monitor the cleaned guest (loopback sinks + our engine excluded).
    @Published public var monitorOutputDevices: [DeviceStruct] = []
```

And after `private let voiceChain = VoiceChain()`:

```swift
    // OPTIONAL — created only while the feature is enabled (DeepFilterNetDSP.init allocates
    // MLMultiArrays + async-loads the model; a stored non-optional instance would pay that at
    // launch and break zero-cost-when-off). Released to nil on disable.
    private var incomingEngine: IncomingCleanupEngine?
```

> `DeviceStruct` already exists on `AudioModel` (`id: AudioObjectID`, `name: String`) — reuse it. The incoming **source** picker stores a `DeviceStruct` whose `id` we won't use directly for capture (capture needs the UID); add a parallel UID lookup below.

- [ ] **Step 3: Enumerate incoming sources (HAL, input scope) + monitor outputs**

Add a shared HAL property reader, then the input scan. The reader must populate the NEW `DeviceInfo` fields (`hasInput`, `transportType`) — without them the canonical predicate from Task 1 can't reject physical mics. Add an `incomingSourceUIDByID` map so a picked source `DeviceStruct.id` resolves to its UID for capture, and a **separate** `monitorOutputUIDByID` map so the monitor output persists from the OUTPUT scan (never the input map — see Step 4):

```swift
    /// UID lookup for the incoming-source picker (capture is by UID, not AudioObjectID).
    private var incomingSourceUIDByID: [AudioObjectID: String] = [:]
    /// SEPARATE UID lookup for the monitor-output picker (built from the OUTPUT scan in
    /// fetchOutputDevices). Kept distinct from the input map so persistence resolves the
    /// monitor output from the correct device set (AudioObjectIDs are not stable across reboots).
    private var monitorOutputUIDByID: [AudioObjectID: String] = [:]

    /// Shared HAL reader: name + REAL uid + hidden flag + input/output capability + transport type.
    /// Extracted so fetchOutputDevices and fetchIncomingDevices read identical metadata (DRY) and
    /// so the new DeviceInfo fields are populated everywhere the predicate runs.
    private func deviceInfo(for id: AudioObjectID) -> VirtualMicRouting.DeviceInfo? {
        // Name.
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        var namePtr: Unmanaged<CFString>?
        var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, &namePtr)
        guard let cf = namePtr?.takeRetainedValue() else { return nil }
        let name = cf as String

        // REAL UID (only a UID translates to an AudioObjectID at runtime).
        var uidPtr: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<CFString?>.size)
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, &uidPtr)
        let realUID = (uidPtr?.takeRetainedValue() as String?) ?? name

        // Hidden flag (absent on most devices; treat absent as not-hidden).
        var hidden: UInt32 = 0
        var hiddenSize = UInt32(MemoryLayout<UInt32>.size)
        var hiddenAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyIsHidden,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &hiddenAddr) {
            AudioObjectGetPropertyData(id, &hiddenAddr, 0, nil, &hiddenSize, &hidden)
        }

        // Input / output capability (stream-config size > 0 means the scope has channels).
        func hasChannels(scope: AudioObjectPropertyScope) -> Bool {
            var cfgAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                     mScope: scope, mElement: 0)
            var cfgSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &cfgAddr, 0, nil, &cfgSize)
            return cfgSize > 0
        }
        let hasInput = hasChannels(scope: kAudioObjectPropertyScopeInput)
        let hasOutput = hasChannels(scope: kAudioObjectPropertyScopeOutput)

        // Transport type (FourCharCode → UInt32). Absent → 0 (Unknown).
        var transport: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        var tAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &tAddr) {
            AudioObjectGetPropertyData(id, &tAddr, 0, nil, &tSize, &transport)
        }

        return VirtualMicRouting.DeviceInfo(uid: realUID, name: name, isHidden: hidden != 0,
                                            hasOutput: hasOutput, hasInput: hasInput,
                                            transportType: transport)
    }

    /// Enumerate INPUT-capable devices via the HAL (input scope). Unlike
    /// AVCaptureDevice.DiscoverySession (used for the mic), this surfaces loopback/aggregate
    /// devices like BlackHole — exactly the incoming-source candidates.
    func fetchIncomingDevices() {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize)
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &dataSize, &ids)

        var sources: [DeviceStruct] = []
        var uidByID: [AudioObjectID: String] = [:]
        for id in ids {
            guard let info = deviceInfo(for: id) else { continue }
            guard VirtualMicRouting.isSelectableIncomingSource(info) else { continue }
            sources.append(DeviceStruct(id: id, name: info.name))
            uidByID[id] = info.uid
        }
        DispatchQueue.main.async {
            self.incomingSourceDevices = sources
            self.incomingSourceUIDByID = uidByID
        }
    }
```

> **Refactor note (8-Fold):** `fetchOutputDevices()` currently reads name/UID/hidden inline. Refactor it to call the shared `deviceInfo(for:)` above (which now also reads `hasInput`/`hasOutput`/`transportType`) instead of duplicating the property reads — keeps one source of truth for HAL metadata. Inside `fetchOutputDevices`, while iterating `allDevs`, ALSO build the monitor-output list + map from the SAME output-capable set: for each `info` where `VirtualMicRouting.isSelectableMonitorOutput(info)` is true, append a `DeviceStruct(id:name:)` to a local `monitors` array and record `monitorUID[id] = info.uid`; then on the main queue set `self.monitorOutputDevices = monitors` and `self.monitorOutputUIDByID = monitorUID`. Do NOT reuse `self.outputDevices` (that list is filtered with `isSelectableOutput` for the OUTGOING picker and would wrongly include BlackHole as a monitor target). Because `deviceInfo(for:)` now populates `hasOutput` from the input-scoped scan too, the `if size > 0` output guard in `fetchOutputDevices` is replaced by `if info.hasOutput`.

- [ ] **Step 4: Apply / persist / restore the incoming lifecycle (LAZY create, full release)**

```swift
    /// Create-or-tear-down the incoming engine to match the current selections. Off by default —
    /// the engine object (and thus the second DeepFilterNetDSP's allocations + model load) is
    /// constructed ONLY when enabled with a valid source, and released to nil otherwise, so a
    /// disabled feature holds zero ANE/CPU/memory.
    private func applyIncomingCleanup() {
        guard incomingCleanupEnabled, !incomingSourceUID.isEmpty else {
            incomingEngine?.stop()
            incomingEngine = nil          // release allocations + CoreML model
            return
        }
        // Lazily construct on first enable (DeepFilterNetDSP.init allocates + async-loads here).
        let engine = incomingEngine ?? IncomingCleanupEngine()
        incomingEngine = engine
        engine.start(sourceDeviceUID: incomingSourceUID, monitorDeviceID: incomingOutputDeviceID)
    }

    private func persistIncomingSettings() {
        let d = UserDefaults.standard
        d.set(incomingCleanupEnabled, forKey: PrefKey.incomingEnabled)
        d.set(incomingSourceUID, forKey: PrefKey.incomingSourceUID)
        // Persist the MONITOR output by UID, resolved from the MONITOR-output map (the OUTPUT scan)
        // — NOT the input-source map. AudioObjectIDs are not stable across reboots, so we store the
        // UID; fall back to a live HAL translate if the map is momentarily stale.
        let monitorUID = monitorOutputUIDByID[incomingOutputDeviceID]
            ?? uidForDevice(incomingOutputDeviceID)
        d.set(monitorUID, forKey: PrefKey.incomingOutputUID)
    }

    /// Reverse of deviceID(forUID:): read a live device's REAL UID by AudioObjectID. Used as a
    /// fallback when the cached monitorOutputUIDByID map hasn't been rebuilt yet.
    private func uidForDevice(_ id: AudioObjectID) -> String {
        guard id != 0, let info = deviceInfo(for: id) else { return "" }
        return info.uid
    }
```

Restore inside `loadSettings()`'s guarded region (so the `didSet`s don't re-persist mid-load), then call `applyIncomingCleanup()` once at the end:

```swift
        // Incoming / guest cleanup (off by default; resolve persisted UIDs to live IDs).
        incomingCleanupEnabled = d.bool(forKey: PrefKey.incomingEnabled)
        incomingSourceUID = d.string(forKey: PrefKey.incomingSourceUID) ?? ""
        if let outUID = d.string(forKey: PrefKey.incomingOutputUID), !outUID.isEmpty {
            incomingOutputDeviceID = deviceID(forUID: outUID)   // translate monitor UID → live ID
        }
```

> Add `applyIncomingCleanup()` next to the existing `applyVoiceChain()` call at the end of `loadSettings()` (it is the only place the engine is created during restore — and only if the feature was persisted enabled). Add `fetchIncomingDevices()` to `init()` (after `fetchOutputDevices()`) and to `refreshDevicesAfterHardwareChange()` so the source list updates when BlackHole/Loopback is added/removed; `fetchOutputDevices()` already rebuilds `monitorOutputDevices` + `monitorOutputUIDByID` (Step 3 refactor), so it's covered by the existing call in both `init()` and `refreshDevicesAfterHardwareChange()`. The two UID-by-ID maps are intentionally separate: `incomingSourceUIDByID` (input scan, for capture-by-UID) and `monitorOutputUIDByID` (output scan, for monitor persistence).

- [ ] **Step 5: Build + regression test**

Run: `swift build && swift test`
Expected: build succeeds; all existing tests + `IncomingCleanupTests` PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/AudioModel.swift
git commit -m "feat(audio): enumerate incoming sources via HAL + drive IncomingCleanupEngine lifecycle"
```

---

## Task 4: Settings UI — "Clean incoming / guest" section (Phase 1)

Add a card to `GeneralSettingsView` to enable incoming cleanup, pick the incoming (loopback) source, and pick the monitor output. **No XCTest** (SwiftUI) — build + manual.

**Files:**
- Modify: `Sources/App/SettingsView.swift`

- [ ] **Step 1: Add `incomingCard`** to `GeneralSettingsView` and place it in the `VStack` after `gainCard`:

```swift
    private var incomingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Clean Incoming / Guest", systemImage: "person.wave.2.fill")

            Toggle(isOn: $audioModel.incomingCleanupEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean the other side").font(.subheadline)
                    Text("De-noise the guest/caller you hear. Route the call app's speaker into a loopback device (e.g. BlackHole), then pick it below.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)

            if audioModel.incomingCleanupEnabled {
                HStack(spacing: 10) {
                    Text("Incoming from").font(.subheadline).frame(width: 110, alignment: .leading)
                    Picker("", selection: $audioModel.incomingSourceUID) {
                        Text("Select…").tag("")
                        ForEach(audioModel.incomingSourceDevices) { dev in
                            Text(dev.name).tag(audioModel.uid(forIncomingSourceID: dev.id))
                        }
                    }
                    .labelsHidden().frame(maxWidth: .infinity)
                }
                HStack(spacing: 10) {
                    Text("Hear on").font(.subheadline).frame(width: 110, alignment: .leading)
                    Picker("", selection: $audioModel.incomingOutputDeviceID) {
                        ForEach(audioModel.monitorOutputDevices) { dev in
                            Text(dev.name).tag(dev.id)
                        }
                    }
                    .labelsHidden().frame(maxWidth: .infinity)
                }
                if audioModel.incomingSourceDevices.isEmpty {
                    Label("No loopback device found. Install BlackHole or Loopback and set your call app's speaker to it.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(.orange)
                }
            }
        }
        .nnCard()
    }
```

> The `Picker` for the incoming source binds to `incomingSourceUID` (a `String`), so each row's tag is the device UID. Add a tiny public helper `func uid(forIncomingSourceID:) -> String` on `AudioModel` that reads `incomingSourceUIDByID` (or expose the map) so the view can tag rows by UID. Keep the helper in `AudioModel` (the view stays dumb).

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/App/SettingsView.swift Sources/Core/AudioModel.swift
git commit -m "feat(ui): add Clean Incoming/Guest section to Settings (source + monitor pickers)"
```

> If Step 1 requires the `uid(forIncomingSourceID:)` helper on `AudioModel`, that one-line addition rides in this commit (it exists solely to support the picker).

---

## Task 5: Popover UI — compact incoming-cleanup toggle (Phase 1)

Surface the on/off state in the menu-bar popover (the full source/monitor pickers stay in Settings to keep the popover compact). **No XCTest** — build + manual.

**Files:**
- Modify: `Sources/App/ContentView.swift`

- [ ] **Step 1: Add an `incomingCard`** computed view after `modeCard` (before `devicesCard`):

```swift
    // MARK: - Clean incoming / guest

    private var incomingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                cardLabel("Clean Incoming", systemImage: "person.wave.2.fill")
                Spacer()
                Toggle("", isOn: $audioModel.incomingCleanupEnabled)
                    .labelsHidden().toggleStyle(.switch)
            }
            if audioModel.incomingCleanupEnabled {
                Text(audioModel.incomingSourceUID.isEmpty
                     ? "Pick a loopback source in Settings."
                     : "Cleaning the guest you hear.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .nnCard()
    }
```

- [ ] **Step 2: Place it in `body`'s `VStack`**, after `modeCard`:

```swift
        VStack(spacing: 14) {
            header
            statusCard
            modeCard
            incomingCard
            devicesCard
            driverStatusRow
            footer
        }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add Sources/App/ContentView.swift
git commit -m "feat(ui): add compact Clean Incoming toggle to menu-bar popover"
```

---

## Task 6: Setup Guide — document the loopback routing (Phase 1)

The loopback setup is the highest-friction part of this feature. Add a guide section so the user knows the call app's *speaker* must point at a loopback device. **No XCTest** — build + manual.

**Files:**
- Modify: `Sources/App/SettingsView.swift` (the `GuideView`)

- [ ] **Step 1: Add steps** to `GuideView` after the existing virtual-mic steps:

```swift
                Divider()
                StepRow(number: 5, title: "Clean the Guest (optional)",
                        description: "To de-noise the person you HEAR: set the call app's SPEAKER/OUTPUT to a loopback device (BlackHole 2ch or Loopback). In NoNoise Mac Settings → Clean Incoming/Guest, pick that loopback as ‘Incoming from’ and your real speakers/headphones as ‘Hear on’.")
                Divider()
                StepRow(number: 6, title: "Still Want to Hear Raw Audio?",
                        description: "Routing the call app into a loopback means its sound no longer reaches your speakers directly. NoNoise Mac re-plays the CLEANED audio to your chosen output, so you still hear the call — just de-noised. For raw monitoring too, use a macOS Multi-Output Device that includes both the loopback and your speakers.")
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/App/SettingsView.swift
git commit -m "docs(ui): add loopback-routing setup steps for incoming/guest cleanup"
```

---

## Task 7: Documentation (8-Fold Awareness Step 2 + compounding) — Phase 1

Every code change requires a docs pass. Update user docs, domain vocab, the architecture map, and the knowledge base.

**Files:**
- Modify: `README.md`
- Modify: `CONCEPTS.md`
- Modify: `AGENTS.md`
- Modify: `docs/knowledge/timeline1.md`
- Modify: `docs/knowledge/knowledge1.md`

- [ ] **Step 1: `README.md`** — add a feature bullet under "✨ Why NoNoise Mac":

```markdown
- **🎧 Clean Incoming / Guest** — de-noise the *other* side too. Route a noisy guest or caller through a loopback device and NoNoise Mac cleans what you hear (and, optionally, what you record) with the same on-device AI — no cloud, no subscription.
```

And a short subsection explaining the loopback requirement (the call app's speaker → loopback → NoNoise Mac → your speakers).

- [ ] **Step 2: `CONCEPTS.md`** — append to the signal-pipeline / product vocabulary:

```markdown
- **Incoming / Guest cleanup** — the mirror of mic cleaning: capture the call app's
  output from a loopback/aggregate INPUT device, clean it with a SECOND DeepFilterNet
  stream (`IncomingCleanupEngine`), and play it to the user's speakers (Phase 1) and/or
  a second virtual sink for recording (Phase 2). Independent of the outgoing mic.
- **Loopback source** — a device (BlackHole/Loopback/aggregate) the user points the call
  app's speaker at, so its audio becomes a capturable INPUT. macOS has no built-in app loopback.
- **Monitor output** — the real speakers/headphones the cleaned guest is played to.
```

- [ ] **Step 3: `AGENTS.md`** — add to the `Sources/Core` architecture map:

```markdown
  - `AudioProcessing/IncomingCleanupEngine` — a SECOND, independent capture→clean→play pipeline ("clean the other side"). Captures a loopback/aggregate INPUT device, runs its OWN `DeepFilterNetDSP` instance (DFN only — NO `VoiceChain`), plays to the user's monitor output. NOT an `AudioModel` (no mic coupling, no auto-route to the NoNoise Mic sink). Held by `AudioModel` as an OPTIONAL (`IncomingCleanupEngine?`) and created ONLY while enabled — never a stored `let`, because `DeepFilterNetDSP.init()` allocates ML buffers + async-loads the model and must not run at launch.
```

And add a short subsection capturing the invariants: off-by-default + **lazy-OWNED (optional) create / release-to-nil teardown** (NEVER a stored `let` engine — that breaks zero-cost-when-off); DFN-only (no `VoiceChain` unless `configure(_:)`'d); HAL input-scope enumeration (NOT `AVCaptureDevice.DiscoverySession`); incoming-source predicate REJECTS physical mics via `DeviceInfo.transportType`/`hasInput` (not by name); capture-by-UID proven via the Task-S spike (HAL input-`AudioUnit` fallback); each fresh `DeepFilterNetDSP` has its OWN recurrent state; monitor output persisted from `monitorOutputUIDByID` (output scan), not the input-source map; persisted keys `mv.incoming*`.

- [ ] **Step 4: `docs/knowledge/timeline1.md`** — append a dated changelog entry (match existing format):

```markdown
## 2026-06-15 — Incoming / Guest cleanup (Phase 1: hear-them-clean)

Added a second, independent pipeline (`IncomingCleanupEngine`) that captures a
loopback/aggregate INPUT device (the call app's output), cleans it with its own
`DeepFilterNetDSP` (DFN only — no VoiceChain), and plays it to the user's chosen monitor
output. **Lazy-owned for zero-cost-when-off:** `AudioModel` holds it as `IncomingCleanupEngine?`,
constructed only on enable and released to `nil` on disable, so the model + ML buffers never
allocate at launch (the off-by-default mandate). Fresh instance per enable → fresh DFN recurrent
state. Incoming sources are enumerated via the CoreAudio HAL (input scope) — `AVCaptureDevice`
discovery misses BlackHole — and the AVCapture-by-UID capture path was proven first with a spike
(Task S) before building on it (falls back to a HAL input-`AudioUnit` path if the spike fails).
Device classification added to `VirtualMicRouting`: `DeviceInfo` gained `hasInput` + `transportType`
so `isSelectableIncomingSource` REJECTS physical mics (built-in/USB/Bluetooth) and accepts only
aggregate/virtual/known-loopback; `isSelectableMonitorOutput` rejects loopback sinks + our engine.
Monitor output persisted from a SEPARATE `monitorOutputUIDByID` (output scan), not the input-source
map. UI: Settings card + popover toggle + Setup Guide steps. Persisted under `mv.incoming*`.
Phase 2 (record-them-clean, second virtual sink) intentionally deferred to its own concrete plan.
```

- [ ] **Step 5: `docs/knowledge/knowledge1.md`** — append two entries (detect username via `git config user.name`):

```markdown
## 2026-06-15 — [DECISION] Incoming cleanup is a separate engine, not a second AudioModel (@<username>)

**Problem**: Cleaning the guest needs an input→clean→output pipeline, which `AudioModel` already is — tempting to instantiate a second `AudioModel`.
**Decision**: Build a dedicated `IncomingCleanupEngine`. `AudioModel.fetchOutputDevices()` force-routes its output to the NoNoise Mic sink and its capture is hardwired to a microphone (virtual mic filtered OUT), with a HAL `kAudioHardwarePropertyDevices` listener and on-demand-mic logic — all of which fight a second instance. The CLI proves the bare input→clean→output shape; extract that, not `AudioModel`. The engine runs **DFN only** (no `VoiceChain` — the guest needs suppression, not voice "polish"; an unconfigured `VoiceChain` is inert dead code anyway).
**Rule**: When a feature needs a generic input→clean→output pipeline, reuse `DeepFilterNetDSP` in a focused engine — do NOT clone `AudioModel`, which carries mic/virtual-mic/auto-route coupling. Only add `VoiceChain` if you `configure(_:)` it on main.
**Files**: `Sources/Core/AudioProcessing/IncomingCleanupEngine.swift`, `Sources/Core/AudioModel.swift`

## 2026-06-15 — [DECISION] Incoming engine is lazy-owned (optional) for zero-cost-when-off (@<username>)

**Problem**: A stored `private let incomingEngine = IncomingCleanupEngine()` (with the engine owning `let dsp = DeepFilterNetDSP()`) would allocate 6 `MLMultiArray`s + ~12 scratch buffers AND async-load the CoreML model at APP LAUNCH — even though the feature is off by default. That violates the Apple-Silicon zero-cost-when-off mandate.
**Decision**: `AudioModel` holds `IncomingCleanupEngine?` and constructs the instance ONLY in the enable path (`incomingCleanupEnabled && !incomingSourceUID.isEmpty`); on disable it calls `stop()` then sets the reference to `nil`, freeing the model + buffers. A fresh instance per enable also guarantees fresh DFN recurrent hidden state each session.
**Rule**: Any engine whose `init()` allocates ML buffers / loads a model MUST be created lazily and released on disable — never stored as a non-optional `let` that runs at launch for an off-by-default feature.
**Files**: `Sources/Core/AudioModel.swift`, `Sources/Core/AudioProcessing/IncomingCleanupEngine.swift`, `Sources/Core/AudioProcessing/DeepFilterNetDSP.swift`

## 2026-06-15 — [GOTCHA] Loopback inputs (BlackHole) are invisible to AVCaptureDevice discovery + capture is UNPROVEN (@<username>)

**Problem**: The incoming source picker came up empty with BlackHole installed; and even after HAL enumeration, capturing a non-discovered loopback via AVFoundation was unverified.
**Root Cause**: `AVCaptureDevice.DiscoverySession` (used for the mic) does not surface loopback/aggregate devices (noted at `Sources/Core/AudioModel.swift:475`). Separately, `AVCaptureDevice(uniqueID:)` resolving + delivering sample buffers for a device DiscoverySession never lists is not guaranteed.
**Fix**: Enumerate incoming sources via the CoreAudio HAL with `kAudioObjectPropertyScopeInput` stream config (mirroring the output scan). For capture, FIRST run a spike (Task S) proving `AVCaptureDevice(uniqueID:)` resolves a BlackHole HAL UID AND delivers buffers; if it fails, capture via a HAL input-`AudioUnit` consuming the selected `AudioObjectID` directly.
**Rule**: Enumerate non-mic input devices (loopback/aggregate) through the HAL, never `AVCaptureDevice.DiscoverySession`; and PROVE the capture path for a non-discovered device with a spike before building on it.
**Files**: `Sources/Core/AudioModel.swift`, `Sources/Core/AudioProcessing/IncomingCleanupEngine.swift`

## 2026-06-15 — [GOTCHA] Incoming-source predicate must reject physical mics by transport type, not name (@<username>)

**Problem**: The "loopback source only" predicate excluded only hidden + NoNoise devices, so a real mic ("MacBook Pro Microphone", USB/Bluetooth mics) passed and could be picked as the "incoming" source — wrong contract.
**Root Cause**: `VirtualMicRouting.DeviceInfo` carried no input-capability or transport-type metadata, so the predicate could only filter by name (fragile, locale/model-dependent).
**Fix**: Extend `DeviceInfo` with `hasInput` + `transportType` (raw `UInt32` of `kAudioDevicePropertyTransportType`), populate them from a shared HAL reader, and make `isSelectableIncomingSource` reject physical transports (built-in/USB/Bluetooth/HDMI/…) while accepting aggregate/virtual + known loopback names.
**Rule**: Classify audio devices by structured HAL metadata (capability + transport type), never by display name alone.
**Files**: `Sources/Core/AudioProcessing/VirtualMicRouting.swift`, `Sources/Core/AudioModel.swift`
```

- [ ] **Step 6: Commit**

```bash
git add README.md CONCEPTS.md AGENTS.md docs/knowledge/timeline1.md docs/knowledge/knowledge1.md
git commit -m "docs: document incoming/guest cleanup (Phase 1), engine decision, loopback gotcha"
```

---

## Phase 1 manual smoke test (after Tasks S, 0–7)

The headless suite cannot exercise the live audio path. After Phase 1, verify in the running app:

1. **Zero-cost-when-off (CRITICAL):** `./install-app.sh` (or `swift run`), open the popover. Confirm **Clean Incoming is OFF** by default. Verify the second engine object does NOT exist: no extra mic indicator, baseline CPU, and — to prove the model/buffers are NOT allocated at launch — confirm there is **no "DFN3 Model Loaded" print from the incoming engine** at startup (only the outgoing `AudioModel`'s DSP loads). The optional `incomingEngine` must still be `nil`.
2. Install BlackHole (or Loopback) if not present. Set a system or app loopback so a known audio source (e.g. a YouTube tab, or a real call) plays into BlackHole. Set that app's **speaker/output** to BlackHole.
3. Open Settings → **Clean Incoming/Guest**, enable it. Confirm the **incoming-source picker lists BlackHole but NOT any physical mic** (e.g. "MacBook Pro Microphone" must be absent — Task 1 contract). Also confirm the **"Hear on" picker lists your speakers/headphones but NEVER BlackHole/Loopback, an Aggregate, or a Multi-Output device** (the real-output-only monitor contract — picking a Multi-Output containing BlackHole would re-feed the captured loopback). Pick **BlackHole** as "Incoming from" and your **real speakers/headphones** as "Hear on."
4. Confirm you HEAR the source through your speakers, **de-noised** (play a noisy clip — fan/keyboard/room reverb — and confirm it's cleaned).
5. **Teardown + fresh state:** Toggle Clean Incoming **off** → confirm the cleaned playback stops immediately, the engine is released (`incomingEngine == nil`), no lingering audio, CPU returns to baseline. Toggle **on again** → confirm a NEW engine constructs (a new "DFN3 Model Loaded" print), audio resumes cleanly with NO carried-over artifact/ring from the previous session (proves fresh DFN recurrent hidden state per session).
6. Quit + relaunch → confirm the enabled state, source, and monitor output are restored (persistence). Specifically verify the **monitor output** restores to the chosen real speakers/headphones (NOT a loopback) — proves the monitor UID was persisted from `monitorOutputUIDByID`, not the input-source map. If BlackHole's / the monitor's `AudioObjectID` changed across reboot, confirm both UIDs resolved correctly.
7. **Performance (mandatory):** with BOTH streams live (your mic cleaning ON + incoming cleaning ON), record CPU% (Activity Monitor / `powermetrics`) and listen for glitches/dropouts on EITHER stream. Note the before/after CPU and any audible latency. If two concurrent streams glitch on the baseline target Mac, record it as a finding (see plan's performance section) — do not silently ship a degraded experience.

---

## Phase 2 — DESIGN SKETCH (NOT executable here; authored as its own concrete plan after Phase 1 smoke passes)

> **This section is a DESIGN SKETCH, not part of the executable plan.** Phase 1 (Tasks S, 1–7 +
> the Phase 1 smoke test) is the rigorous, commit-ready deliverable of THIS document. Phase 2 is
> the more involved CoreAudio **driver** work — a second virtual sink so a recording/streaming app
> (OBS/Riverside) records the guest cleaned too. It is intentionally NOT specified to executable
> precision here (no exact C constants, no driver ring/clock edits, no test bodies, no signing
> steps).
>
> **Do NOT execute the tasks below from this document.** When Phase 1's smoke test passes, Phase 2
> will be authored as **its own separate implementation plan** with: the exact `VirtualMicRouting`
> guest constants (matched byte-for-byte to new `Driver/NoNoiseMic/` C constants), the precise
> driver edits (second device pair, second `nn_ring`/`nn_clock` instance, canonical ASBD, ad-hoc
> signing AFTER assembly per `CLAUDE.md`), full TDD test bodies, and the install/verify/signing
> sequence. The sketch below exists only to record the intended shape so the Phase 2 plan starts
> from a known direction — treat every item as a design note to be expanded, not a step to run.

### (Sketch) Task 8: Second virtual-sink contract in `VirtualMicRouting` — TDD

Add the shared-contract constants + classification for a SECOND device pair ("NoNoise Guest" — a visible input the recorder picks + a hidden engine sink the incoming pipeline writes to), kept strictly parallel to the existing NoNoise Mic constants. **These MUST match the driver's C constants exactly — a mismatch fails SILENTLY** (per `CLAUDE.md` → NoNoise Mic virtual driver).

**Files:**
- Modify: `Sources/Core/AudioProcessing/VirtualMicRouting.swift`
- Modify: `Tests/NoNoiseMacTests/IncomingCleanupTests.swift`

- [ ] **Step 1: Write failing tests** asserting the new constants exist, are distinct from the mic constants, and that the new "NoNoise Guest" devices are excluded from incoming-source + monitor-output pickers (same self-loop reasoning as the NoNoise Mic devices).
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Add the parallel constants** (e.g. `guestVisibleDeviceUID = "NoNoiseGuest:visible:48k2ch"`, `guestEngineDeviceUID = "NoNoiseGuest:engine:48k2ch"`, names, bundle id) and extend `isNoNoiseEngine`/`isSelectableIncomingSource`/`isSelectableMonitorOutput` to also reject the guest devices. **Match the guest devices by UID OR name** (the same `isNoNoiseVisible`/`isNoNoiseEngine` strategy Phase 1 uses — the UID is the strongest id, so a UID match with a differing/localised name must still be rejected to prevent a self-loop). **Do not hardcode the FourCharCode or repack the ASBD** — reuse the canonical layout rules from the existing driver.
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit** `feat(routing): add NoNoise Guest second-sink contract (Phase 2)`.

### (Sketch) Task 9: NoNoise Guest driver instance + engine fan-out

> **Driver work (`Driver/`).** Follow `CLAUDE.md` → "NoNoise Mic virtual driver" EXACTLY: canonical Float32 interleaved stereo layout, ad-hoc sign AFTER full assembly (any post-sign edit silently breaks load), pure testable ring/clock math host-tested via `Driver/tests/run-tests.sh`, ring serves SILENCE not stale audio. This is an original implementation against the public API — NOT BlackHole-derived.

- [ ] **Step 1:** Stand up a second driver device pair ("NoNoise Guest" visible input + hidden engine sink), mirroring the existing NoNoise Mic device with the Task-8 constants. Decide: a second `AudioServerPlugIn` device inside the SAME plug-in (preferred — one bundle, two device pairs) vs. a separate bundle. The shared `nn_ring`/`nn_clock` math is reusable; instantiate a SECOND ring/clock for the guest pair (do NOT share the mic's ring).
- [ ] **Step 2:** Teach `IncomingCleanupEngine` to ALSO write its cleaned output to the guest engine sink when recording is enabled — i.e. fan-out the render result to (a) the monitor output (Phase 1) and (b) the guest sink. Resolve the guest engine sink by UID translate (it's hidden, so it won't appear in enumeration — same path as the NoNoise Mic engine).
- [ ] **Step 3:** Build the driver (`./build-driver.sh`), run the host ring/clock tests (`Driver/tests/run-tests.sh`), install + verify the device appears (`install-driver.sh` verifies). Smoke test recording the guest-clean in OBS.
- [ ] **Step 4:** Commit driver + engine changes as atomic units.

### (Sketch) Task 10: Phase 2 UI + persistence

- [ ] **Step 1:** Add a "Also record the cleaned guest" toggle to the Settings incoming card (only meaningful when the NoNoise Guest device is installed; show install hint otherwise — mirror the existing driver-status row). Persist `mv.incomingRecordEnabled`.
- [ ] **Step 2:** Drive the fan-out from `AudioModel.applyIncomingCleanup()` based on the toggle. Build + smoke.
- [ ] **Step 3:** Commit `feat(ui): add record-the-cleaned-guest toggle (Phase 2)`.

### (Sketch) Task 11: Phase 2 documentation

- [ ] Update `README.md`, `CONCEPTS.md`, `AGENTS.md` (driver section — now TWO device pairs), `docs/knowledge/timeline1.md`, and a `[DECISION]` entry in `knowledge1.md` (one plug-in / two device pairs, second ring/clock, guest sink resolved by UID translate). Commit.

### (Sketch) Phase 2 manual smoke test

1. Install the updated driver (`sudo ./install-driver.sh`); confirm "NoNoise Guest" appears as an input and the device check passes.
2. With Clean Incoming ON + recording ON, set OBS/Riverside's mic for the guest track to **NoNoise Guest**; confirm it records the guest CLEANED.
3. Confirm the guest sink serves SILENCE (not stale audio) when the incoming engine stops while the recorder keeps running (privacy-critical, per the driver's `nn_ring` watermark rule).
4. Re-run the Phase 1 performance step with the fan-out active (write to two destinations) — confirm no new glitches.

---

## Self-Review (completed during authoring)

- **Spec coverage:** "Clean the OTHER side" → `IncomingCleanupEngine` (Task 2). Phase 1 hear-them-clean (loopback input → DFN-only engine → speakers) → Tasks S + 1–7 + the Phase 1 smoke test. Phase 2 record-them-clean (second virtual sink) → DESIGN SKETCH only, to be authored as its own concrete plan after Phase 1 smoke passes. Device-selection UX + setup → Tasks 4/6 + the loopback Setup Guide. CLI is cited as the shape template — but the loopback CAPTURE path is explicitly NOT assumed proven (Task S spike).
- **Design realities addressed honestly:**
  - *No built-in app loopback* — stated up front; setup requires routing the call app's speaker into BlackHole/Loopback; documented in Setup Guide (Task 6) and the empty-source UI hint (Task 4).
  - *Second `AudioModel` vs. reusable engine* — explicit DECISION to extract a focused `IncomingCleanupEngine` (NOT a second `AudioModel`), with the shared-state risks enumerated (`fetchOutputDevices` auto-route hijack, duplicate HAL listeners, mic/virtual-mic coupling, `mv.*` key contention) and verified against the source.
  - *Zero-cost-when-off (CRITICAL fix)* — `DeepFilterNetDSP.init()` allocates ML buffers + async-loads the model, so the engine is **lazy-OWNED**: `AudioModel` holds `IncomingCleanupEngine?`, constructs it only on enable, releases to `nil` on disable. Verified against `DeepFilterNetDSP.swift:222` (async model load). Smoke test asserts no launch-time model load and fresh hidden state per session.
  - *Wrong "loopback only" contract (CRITICAL fix)* — `DeviceInfo` extended with `hasInput` + `transportType`; `isSelectableIncomingSource` rejects physical mics by transport type (built-in/USB/Bluetooth/…) with a failing-first test (`testPhysicalMicIsNotAnIncomingSource`).
  - *Self-loop via UID-only NoNoise Mic match (CRITICAL fix)* — the visible NoNoise device was excluded by NAME only, but the contract's strongest id is `visibleDeviceUID`. Added `isNoNoiseVisible(_:)` (UID OR name) and use it in `isSelectableIncomingSource`, so a UID match with a differing/localised name is still rejected (`testNoNoiseVisibleRejectedByUIDWhenNameDiffers`). The Phase-2 (sketch) guest device follows the same UID-or-name pattern.
  - *Monitor output must be a REAL output (CRITICAL fix)* — `isSelectableMonitorOutput` now REQUIRES `hasOutput` AND REJECTS aggregate transport (in addition to virtual/loopback/hidden/engine), so an input-only aggregate, a Multi-Output/Aggregate (BlackHole + speakers feedback path), and our engine are never offered as the monitor; physical built-in/USB/Bluetooth outputs remain valid. Tests: `testInputOnlyAggregateIsNotAMonitorOutput`, `testAggregateMultiOutputIsNotAMonitorOutput`, `testBuiltInOutputRemainsValidMonitorOutput`, `testPhysicalUSBAndBluetoothOutputsAreValidMonitorOutputs`.
  - *Unproven loopback capture (CRITICAL fix)* — Task S spike PROVES `AVCaptureDevice(uniqueID:)` resolves + delivers buffers for a BlackHole HAL UID before the engine is built on it, with an explicit HAL input-`AudioUnit` fallback documented if it fails.
  - *Monitor-output persistence contract drift (fix)* — a SEPARATE `monitorOutputUIDByID` (from the output scan) is used to persist/restore the monitor output; `persistIncomingSettings()` no longer reads the input-source map.
  - *Two concurrent CoreML streams cost* — addressed via off-by-default, lazy create / full teardown, and a MANDATORY profiling smoke step; the plan explicitly refuses to claim the second ANE stream is free.
  - *Routing via `VirtualMicRouting`* — Phase 1 adds pure device-classification predicates; Phase 2 (sketch) would add a parallel second-sink contract there.
- **Invariants honored:** render thread allocation-free (engine reuses `DeepFilterNetDSP` unchanged — DFN only, no `VoiceChain`; lock-free `var Bool` scalar from main→render); engine source node attached once (`engine.reset()` does not detach); 100% on-device / no telemetry; HAL input-scope enumeration (not `AVCaptureDevice` discovery); pure logic in headless XCTest-able `VirtualMicRouting`, the live engine build+smoke-verified; legacy `mv.*` persistence namespace; no "MetalVoice"/"Ghostkwebb" in `Sources/`; no absolute local paths (repo-relative + "package root" only).
- **Placeholder scan:** Phase 1 (Tasks S, 1–7) shows complete code + exact commands. Phase 2 is intentionally a DESIGN SKETCH (driver work) to be authored as its own concrete plan after Phase 1 ships — explicitly NOT executable from this document.
- **Type consistency:** `VirtualMicRouting.DeviceInfo(hasInput:transportType:)`, `isNoNoiseVisible`/`isSelectableIncomingSource`/`selectableIncomingSources`/`isSelectableMonitorOutput`, the transport-type constants, `IncomingCleanupEngine.start(sourceDeviceUID:monitorDeviceID:)`/`stop()`/`isCleaningEnabled`, `AudioModel.incomingCleanupEnabled`/`incomingSourceUID`/`incomingOutputDeviceID`/`incomingSourceDevices`/`monitorOutputDevices`/`incomingSourceUIDByID`/`monitorOutputUIDByID`/`deviceInfo(for:)`, and `PrefKey.incoming*` are used consistently across tasks.
- **Open design questions flagged:** (1) the real cost of two concurrent ANE streams on the baseline Mac (measured in the smoke step, not assumed); (2) loopback setup friction (mitigated by UX + Setup Guide, but inherent to macOS); (3) whether `AVCaptureDevice(uniqueID:)` captures a non-discovered loopback (resolved by the Task-S spike, with a HAL fallback). Whether the incoming path should get its own preset (v1 uses full suppression) is deferred; Phase 2's driver topology is deferred to its own plan.
```

---

## Post-Implementation Amendments (from Codex code review — 2026-06-15)

A 4-round Codex review (gpt-5.5) of the shipped Phase 1 surfaced gaps the plan did not specify. All were fixed (commit `5c6c62d`) and re-approved. These are **plan gaps**, not implementation drift — the plan was faithfully implemented, but it under-specified the following:

1. **HAL channel-capability detection method (gap → fixed).** The plan promoted `deviceInfo(for:)` to drive BOTH input and output classification but never specified *how* capability is read. The first implementation reused the pre-existing `AudioObjectGetPropertyDataSize(...StreamConfiguration) > 0` shortcut, which reports phantom channels (a non-empty `AudioBufferList` header exists even for a zero-stream scope) and could misclassify an input-only mic as a monitor output. **Amendment:** capability MUST sum `AudioBufferList.mBuffers[*].mNumberChannels` and treat a scope as capable only when the sum is `> 0`. (Root cause: precedent reused without re-validating it for the new, broader use.)

2. **Lifecycle truthfulness / retention semantics (gap → fixed).** The plan's "zero-cost-when-off" addressed `DeepFilterNetDSP.init()` *launch* cost (lazy create / teardown) but did not specify that a *failed or half-open start* must also leave nothing resident. The first implementation could (a) retain the engine after a failed capture attach, and (b) return success from `start()` even when monitor-pin (`AudioUnitSetProperty`) or `AVAudioEngine.start()` failed — leaving the second CoreML pipeline running with no audible output; and the hardware-refresh path never re-validated the engine. **Amendment:** `IncomingCleanupEngine.start()` returns `Bool` and is truthful (capture-attach + monitor-pin + engine-start must all succeed; capture is started only after playback is live); `AudioModel` retains the engine ONLY on a `true` start; `refreshDevicesAfterHardwareChange()` re-runs `applyIncomingCleanup()` to tear down vanished selections or restart recovered ones; `stop()` also tears down the attached-but-idle state.

3. **"No chosen monitor" handling (refinement → fixed).** The plan required the monitor to be a real output (`isSelectableMonitorOutput`) but did not pin down the *unselected* case. **Amendment:** `applyIncomingCleanup()` additionally requires `incomingOutputDeviceID != 0` and the engine NEVER falls back to the system default output (loopback-feedback risk); the "Hear on" picker exposes an explicit "Select…" (`tag(0)`) state.

**Generalizable lesson for future plans:** when promoting an existing helper to a broader role, re-validate the helper's internals against the new use; and "zero-cost-when-off" must explicitly cover failed/half-open starts, not just construction cost.