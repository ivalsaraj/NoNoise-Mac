# Incoming / Guest Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clean the **other side's** audio, not your mic. Capture the incoming call/guest audio from a loopback/aggregate **input** device the user selects, run it through the **same DeepFilterNet engine**, and play the de-noised/de-reverbed result to the user's speakers/headphones so the user **hears the guest clean** (Phase 1). Then optionally route that cleaned incoming audio into a **second virtual sink** so a recording/streaming app (OBS, Riverside) records the guest cleaned too (Phase 2).

**Architecture:** A new **`IncomingCleanupEngine`** — a second, fully independent capture→DSP→playback pipeline that mirrors what the CLI already proves (`Sources/CLI/main.swift`: input device → `DeepFilterNetDSP` → output device for any device). It owns its **own** `AVCaptureSession`, ring buffer, `DeepFilterNetDSP` instance, and `AVAudioEngine`, completely decoupled from the existing `AudioModel` (the mic-cleaning pipeline). `AudioModel` stays the single source of truth for the **outgoing** mic; the new engine is the **incoming** path. The pure, headless-testable logic (device-classification + routing) lives in value types extended on `VirtualMicRouting` and a new `IncomingRoute` value type; the live engine is verified by `swift build` + a manual smoke test (same convention as `AudioModel`).

**Tech Stack:** Swift 5.9, SwiftUI, Swift Package Manager, XCTest, AVFoundation/CoreAudio (capture + playback), CoreML/Accelerate (the existing `DeepFilterNetDSP`, unchanged).

**GitHub Issue:** _(create via `github-issue-lifecycle` Phase 1 before execution; embed `#N — URL` here)_

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

`AVCaptureDevice.DiscoverySession` (the API `AudioModel.fetchInputDevices` uses) does **not** reliably surface loopback devices like BlackHole — there's a code comment to this effect at `Sources/Core/AudioModel.swift:460`. The incoming-source picker therefore must enumerate **input-capable devices via the CoreAudio HAL** (`kAudioHardwarePropertyDevices`, input-scoped `kAudioDevicePropertyStreamConfiguration`), the same HAL path `fetchOutputDevices` already uses for outputs — NOT `AVCaptureDevice.DiscoverySession`. This is the single biggest correctness fact in the plan.

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
- **Real-time rules still apply** to the new engine's render callback: allocation-free, scalar/vDSP only, lock-free `var` scalars from main→render (same pattern as `AudioModel`'s `isAIEnabled` / `outputGain`). The new engine reuses `DeepFilterNetDSP` and `VoiceChain` exactly as `AudioModel` does — no new hot-path code beyond wiring.

### Privacy (a core promise — unchanged)
100% on-device. The incoming pipeline is the same local CoreML model; nothing leaves the machine, no telemetry. Phase 2's second virtual sink is a local CoreAudio device. No new entitlements: capturing a loopback *input* device uses the existing `com.apple.security.device.audio-input` entitlement (it's an audio input from the OS's perspective).

### Current code facts (verified against the repo)
- `Sources/CLI/main.swift` is the canonical proof: it builds an `AudioModel`, picks input + output devices by name, sets `isAIEnabled = true`, and runs the pipeline — input device → clean → output device, for *any* device. The new engine generalizes this without `AudioModel`'s mic/virtual-mic coupling.
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
- **Reuse `DeepFilterNetDSP` + `VoiceChain` as-is.** No DSP math changes. The incoming engine applies the same suppression; a follow-up could give it its own preset, but v1 uses full suppression (the guest just needs to be cleaned).
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

## Task 1: `IncomingSourceClassifier` — pick valid incoming sources & monitor outputs — TDD

The incoming source must be a **loopback/aggregate input** carrying the call app's output — never the real mic (capturing the mic as "incoming" makes no sense) and never our own NoNoise Mic virtual device (would loop our cleaned voice back in). The monitor output must be a **real, non-virtual** output (the whole point is to hear the guest on real speakers; routing the monitor into BlackHole again would create a loop). This is pure logic — exactly the kind `VirtualMicRouting` already hosts.

**Files:**
- Modify: `Sources/Core/AudioProcessing/VirtualMicRouting.swift` (add input-source + monitor-output predicates)
- Create: `Tests/NoNoiseMacTests/IncomingCleanupTests.swift`

- [ ] **Step 1: Write the failing tests** — create `Tests/NoNoiseMacTests/IncomingCleanupTests.swift`

```swift
import XCTest
@testable import Core

final class IncomingCleanupTests: XCTestCase {

    // MARK: - Incoming source classification

    private func input(_ uid: String, _ name: String, hidden: Bool = false) -> VirtualMicRouting.DeviceInfo {
        VirtualMicRouting.DeviceInfo(uid: uid, name: name, isHidden: hidden, hasOutput: false)
    }

    /// A loopback/aggregate input (BlackHole) IS a valid incoming source.
    func testBlackHoleIsValidIncomingSource() {
        XCTAssertTrue(VirtualMicRouting.isSelectableIncomingSource(input("BH:2ch", "BlackHole 2ch")))
    }

    /// Our own NoNoise Mic devices are NOT valid incoming sources (would loop the cleaned mic back in).
    func testNoNoiseMicIsNotAnIncomingSource() {
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(
            input(VirtualMicRouting.visibleDeviceUID, VirtualMicRouting.visibleDeviceName)))
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(
            input(VirtualMicRouting.engineDeviceUID, VirtualMicRouting.engineDeviceName)))
    }

    /// A hidden device is never offered as an incoming source.
    func testHiddenDeviceIsNotAnIncomingSource() {
        XCTAssertFalse(VirtualMicRouting.isSelectableIncomingSource(
            input("hidden:x", "Some Hidden Device", hidden: true)))
    }

    /// The selectable-incoming-source filter drops our devices + hidden, keeps the rest.
    func testIncomingSourceFilterKeepsLoopbackDropsOurs() {
        let devices = [
            input("BH:2ch", "BlackHole 2ch"),
            input("LB:1", "Loopback Audio"),
            input(VirtualMicRouting.visibleDeviceUID, VirtualMicRouting.visibleDeviceName),
            input("hidden:x", "Hidden", hidden: true),
        ]
        let kept = VirtualMicRouting.selectableIncomingSources(from: devices).map(\.name)
        XCTAssertEqual(kept, ["BlackHole 2ch", "Loopback Audio"])
    }

    // MARK: - Monitor (hear-them) output classification

    private func output(_ uid: String, _ name: String, hidden: Bool = false) -> VirtualMicRouting.DeviceInfo {
        VirtualMicRouting.DeviceInfo(uid: uid, name: name, isHidden: hidden, hasOutput: true)
    }

    /// A real physical output (built-in speakers / headphones) IS a valid monitor output.
    func testSpeakersAreValidMonitorOutput() {
        XCTAssertTrue(VirtualMicRouting.isSelectableMonitorOutput(output("spk:0", "MacBook Pro Speakers")))
    }

    /// Routing the monitor into a loopback sink (BlackHole) or our engine would re-loop — reject it.
    func testLoopbackAndEngineAreNotMonitorOutputs() {
        XCTAssertFalse(VirtualMicRouting.isSelectableMonitorOutput(output("BH:2ch", "BlackHole 2ch")))
        XCTAssertFalse(VirtualMicRouting.isSelectableMonitorOutput(
            output(VirtualMicRouting.engineDeviceUID, VirtualMicRouting.engineDeviceName)))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter IncomingCleanupTests`
Expected: compile error — `type 'VirtualMicRouting' has no member 'isSelectableIncomingSource'`.

- [ ] **Step 3: Add the predicates to `VirtualMicRouting`**

In `Sources/Core/AudioProcessing/VirtualMicRouting.swift`, add after `filterInputs(_:)` (the existing last function), still inside the `enum`:

```swift
    // ---- Incoming / guest cleanup (the OTHER side) ----

    /// True for a device the user may pick as the INCOMING (guest) source — a loopback/aggregate
    /// input carrying the call app's output. Excludes hidden devices and our OWN NoNoise Mic
    /// devices (capturing those would loop the cleaned mic back into the incoming path).
    public static func isSelectableIncomingSource(_ d: DeviceInfo) -> Bool {
        !d.isHidden && !isNoNoiseEngine(d) && d.name != visibleDeviceName
    }

    /// Devices to offer as the incoming source — our devices + hidden excluded.
    public static func selectableIncomingSources(from devices: [DeviceInfo]) -> [DeviceInfo] {
        devices.filter(isSelectableIncomingSource)
    }

    /// True for a device the user may pick to MONITOR (hear) the cleaned guest — a real output.
    /// Excludes our engine and known loopback sinks (BlackHole): routing the cleaned monitor back
    /// into a loopback would re-feed the incoming source, creating a loop/echo.
    public static func isSelectableMonitorOutput(_ d: DeviceInfo) -> Bool {
        !d.isHidden
            && !isNoNoiseEngine(d)
            && !fallbackVirtualSinks.contains(where: { d.name.contains($0) })
    }
```

The predicates reference the existing `isNoNoiseEngine`, `visibleDeviceName`, and `fallbackVirtualSinks` constants — no new constants needed.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter IncomingCleanupTests`
Expected: 6 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/VirtualMicRouting.swift Tests/NoNoiseMacTests/IncomingCleanupTests.swift
git commit -m "feat(routing): classify incoming-source + monitor-output devices for guest cleanup"
```

---

## Task 2: `IncomingCleanupEngine` — independent capture→clean→play pipeline (Phase 1 core)

The second pipeline. It owns its own capture session, ring buffer, a **fresh `DeepFilterNetDSP`**, and an `AVAudioEngine` playing to a chosen monitor output. Built by generalizing the proven CLI path (`Sources/CLI/main.swift`) and reusing `AudioModel`'s capture/playback shapes — but with NO mic/virtual-mic coupling and NO auto-routing to the NoNoise Mic sink. **No XCTest:** it depends on CoreAudio/AVCapture and is not unit-testable in the headless suite (same reason `AudioModel` is not). Verification is `swift build` + the green Core suite + the manual smoke test.

**Files:**
- Create: `Sources/Core/AudioProcessing/IncomingCleanupEngine.swift`

- [ ] **Step 1: Create the engine** — `Sources/Core/AudioProcessing/IncomingCleanupEngine.swift`

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
/// touch the real mic, and must be fully tear-down-able (the second CoreML stream has real ANE
/// cost — see the plan's performance section). Off by default; created on `start`, destroyed on
/// `stop`. Single-threaded per instance; its render callback is allocation-free.
public final class IncomingCleanupEngine: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {

    /// Set from MAIN, read on the render thread. Plain scalar — atomic on arm64, no lock
    /// (same pattern as `AudioModel.isAIEnabled` / `DeepFilterNetDSP.outputGain`).
    public var isCleaningEnabled: Bool = true

    private let captureSession = AVCaptureSession()
    private let captureOutput = AVCaptureAudioDataOutput()
    private let processingQueue = DispatchQueue(label: "incoming.processing.queue", qos: .userInteractive)

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode!
    private var outputNode: AVAudioOutputNode { engine.outputNode }
    private var mainMixer: AVAudioMixerNode { engine.mainMixerNode }

    private let ringBuffer = RingBuffer(capacity: 48000 * 5)
    private let dsp = DeepFilterNetDSP()          // fresh, independent recurrent state
    private let chain = VoiceChain()

    // Converter state (capture → 48k mono Float32), mirrors AudioModel.captureOutput.
    private var inputConverter: AVAudioConverter?
    private var inputPCMBuffer: AVAudioPCMBuffer?
    private var inputBuffer48k: AVAudioPCMBuffer?

    private var running = false

    public override init() {
        super.init()
        let bufferRef = ringBuffer
        let dspRef = dsp
        let chainRef = chain
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
                chainRef.process(data, count: count)
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

    /// Stop and fully tear down (releases the mic-equivalent input, the engine, and lets the
    /// second CoreML stream go idle — the performance mandate requires zero cost when off).
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
        // BlackHole/Loopback are not reliably surfaced by AVCaptureDevice.DiscoverySession, but
        // AVCaptureDevice(uniqueID:) resolves a device whose uniqueID equals the HAL UID. The
        // picker (Task 4) enumerates via the HAL and hands us that UID.
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
        engine.attach(sourceNode)
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
    private let incomingEngine = IncomingCleanupEngine()
```

> `DeviceStruct` already exists on `AudioModel` (`id: AudioObjectID`, `name: String`) — reuse it. The incoming **source** picker stores a `DeviceStruct` whose `id` we won't use directly for capture (capture needs the UID); add a parallel UID lookup below.

- [ ] **Step 3: Enumerate incoming sources (HAL, input scope) + monitor outputs**

Add a method that scans input-capable devices via the HAL. Model it on `fetchOutputDevices()` but with `kAudioObjectPropertyScopeInput`. Add a `incomingSourceUIDByID` map so a picked `DeviceStruct.id` resolves to its UID for capture:

```swift
    /// UID lookup for the incoming-source picker (capture is by UID, not AudioObjectID).
    private var incomingSourceUIDByID: [AudioObjectID: String] = [:]

    /// Enumerate INPUT-capable devices via the HAL (input scope). Unlike
    /// AVCaptureDevice.DiscoverySession (used for the mic), this surfaces loopback/aggregate
    /// devices like BlackHole — exactly the incoming-source candidates. Also rebuilds the
    /// monitor-output list from the existing output scan.
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
            // INPUT-scoped stream config: > 0 means the device has input channels.
            var cfgAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                     mScope: kAudioObjectPropertyScopeInput, mElement: 0)
            var cfgSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(id, &cfgAddr, 0, nil, &cfgSize)
            guard cfgSize > 0 else { continue }

            let info = deviceInfo(for: id, hasOutput: false)   // shared name/uid/hidden reader (Step 4)
            guard VirtualMicRouting.isSelectableIncomingSource(info) else { continue }
            sources.append(DeviceStruct(id: id, name: info.name))
            uidByID[id] = info.uid
        }
        DispatchQueue.main.async {
            self.incomingSourceDevices = sources
            self.incomingSourceUIDByID = uidByID
            self.monitorOutputDevices = self.outputDevices   // refined below via the monitor filter
        }
    }
```

> **Refactor note (8-Fold):** `fetchOutputDevices()` already reads each device's name/UID/hidden flag inline. Extract that into a small private `deviceInfo(for:hasOutput:) -> VirtualMicRouting.DeviceInfo` helper so both `fetchOutputDevices` and `fetchIncomingDevices` share it (DRY; keeps the HAL property-reading in one place). Build the `monitorOutputDevices` list by filtering the same `allDevs` set with `VirtualMicRouting.isSelectableMonitorOutput` inside `fetchOutputDevices` (where `allDevs` is already assembled), rather than reusing `outputDevices` (which is filtered for the *outgoing* picker). Wire `monitorOutputDevices` from there.

- [ ] **Step 4: Apply / persist / restore the incoming lifecycle**

```swift
    /// Start or stop the incoming engine to match the current selections. Off by default —
    /// the second CoreML stream is created only when enabled with a valid source.
    private func applyIncomingCleanup() {
        guard incomingCleanupEnabled, !incomingSourceUID.isEmpty else {
            incomingEngine.stop()
            return
        }
        incomingEngine.start(sourceDeviceUID: incomingSourceUID, monitorDeviceID: incomingOutputDeviceID)
    }

    private func persistIncomingSettings() {
        let d = UserDefaults.standard
        d.set(incomingCleanupEnabled, forKey: PrefKey.incomingEnabled)
        d.set(incomingSourceUID, forKey: PrefKey.incomingSourceUID)
        // Persist the monitor output by UID (AudioObjectIDs are not stable across reboots).
        d.set(incomingSourceUIDByID[incomingOutputDeviceID] ?? monitorOutputUID(for: incomingOutputDeviceID),
              forKey: PrefKey.incomingOutputUID)
    }
```

Restore inside `loadSettings()`'s guarded region (so the `didSet`s don't re-persist mid-load), then call `applyIncomingCleanup()` once at the end:

```swift
        // Incoming / guest cleanup (off by default; resolve persisted UIDs to live IDs).
        incomingCleanupEnabled = d.bool(forKey: PrefKey.incomingEnabled)
        incomingSourceUID = d.string(forKey: PrefKey.incomingSourceUID) ?? ""
        if let outUID = d.string(forKey: PrefKey.incomingOutputUID), !outUID.isEmpty {
            incomingOutputDeviceID = deviceID(forUID: outUID)
        }
```

> Add `applyIncomingCleanup()` next to the existing `applyVoiceChain()` call at the end of `loadSettings()`. Add `fetchIncomingDevices()` to `init()` (after `fetchOutputDevices()`) and to `refreshDevicesAfterHardwareChange()` so the source list updates when BlackHole/Loopback is added or removed. Add a `monitorOutputUID(for:)` reverse lookup (or store a `monitorOutputUIDByID` map alongside the source map) — keep the UID-by-ID maps symmetric with the existing output route resolution.

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
  - `AudioProcessing/IncomingCleanupEngine` — a SECOND, independent capture→clean→play pipeline ("clean the other side"). Captures a loopback/aggregate INPUT device, runs its OWN `DeepFilterNetDSP` instance, plays to the user's monitor output. Off by default (the second CoreML stream has real ANE cost); created on enable, fully torn down on disable. NOT an `AudioModel` (no mic coupling, no auto-route to the NoNoise Mic sink).
```

And add a short subsection capturing the invariants: off-by-default, lazy create / full teardown, HAL input-scope enumeration (NOT `AVCaptureDevice.DiscoverySession`), second `DeepFilterNetDSP` must have its OWN recurrent state, persisted keys `mv.incoming*`.

- [ ] **Step 4: `docs/knowledge/timeline1.md`** — append a dated changelog entry (match existing format):

```markdown
## 2026-06-15 — Incoming / Guest cleanup (Phase 1: hear-them-clean)

Added a second, independent pipeline (`IncomingCleanupEngine`) that captures a
loopback/aggregate INPUT device (the call app's output), cleans it with its own
`DeepFilterNetDSP`, and plays it to the user's chosen monitor output. Off by default;
created on enable and fully torn down on disable (second CoreML stream has real ANE cost).
Incoming sources are enumerated via the CoreAudio HAL (input scope) — `AVCaptureDevice`
discovery misses BlackHole. Pure device classification added to `VirtualMicRouting`
(`isSelectableIncomingSource`, `isSelectableMonitorOutput`). UI: Settings card + popover
toggle + Setup Guide steps. Persisted under `mv.incoming*`.
```

- [ ] **Step 5: `docs/knowledge/knowledge1.md`** — append two entries (detect username via `git config user.name`):

```markdown
## 2026-06-15 — [DECISION] Incoming cleanup is a separate engine, not a second AudioModel (@<username>)

**Problem**: Cleaning the guest needs an input→clean→output pipeline, which `AudioModel` already is — tempting to instantiate a second `AudioModel`.
**Decision**: Build a dedicated `IncomingCleanupEngine`. `AudioModel.fetchOutputDevices()` force-routes its output to the NoNoise Mic sink and its capture is hardwired to a microphone (virtual mic filtered OUT), with a HAL `kAudioHardwarePropertyDevices` listener and on-demand-mic logic — all of which fight a second instance. The CLI already proves the bare input→clean→output path; extract that, not `AudioModel`.
**Rule**: When a feature needs a generic input→clean→output pipeline, reuse `DeepFilterNetDSP` + `VoiceChain` in a focused engine — do NOT clone `AudioModel`, which carries mic/virtual-mic/auto-route coupling.
**Files**: `Sources/Core/AudioProcessing/IncomingCleanupEngine.swift`, `Sources/Core/AudioModel.swift`

## 2026-06-15 — [GOTCHA] Loopback inputs (BlackHole) are invisible to AVCaptureDevice discovery (@<username>)

**Problem**: The incoming source picker came up empty even with BlackHole installed.
**Root Cause**: `AVCaptureDevice.DiscoverySession` (used for the mic) does not surface loopback/aggregate devices (noted at `Sources/Core/AudioModel.swift:460`).
**Fix**: Enumerate incoming sources via the CoreAudio HAL with `kAudioObjectPropertyScopeInput` stream config (mirroring the output scan), then resolve the picked UID with `AVCaptureDevice(uniqueID:)` for capture.
**Rule**: Enumerate non-mic input devices (loopback/aggregate) through the HAL, never `AVCaptureDevice.DiscoverySession`.
**Files**: `Sources/Core/AudioModel.swift`, `Sources/Core/AudioProcessing/IncomingCleanupEngine.swift`
```

- [ ] **Step 6: Commit**

```bash
git add README.md CONCEPTS.md AGENTS.md docs/knowledge/timeline1.md docs/knowledge/knowledge1.md
git commit -m "docs: document incoming/guest cleanup (Phase 1), engine decision, loopback gotcha"
```

---

## Phase 1 manual smoke test (after Tasks 0–7)

The headless suite cannot exercise the live audio path. After Phase 1, verify in the running app:

1. `./install-app.sh` (or `swift run`), open the popover. Confirm **Clean Incoming is OFF** by default and the second engine is NOT running (no extra mic indicator; baseline CPU).
2. Install BlackHole (or Loopback) if not present. Set a system or app loopback so a known audio source (e.g. a YouTube tab, or a real call) plays into BlackHole. Set that app's **speaker/output** to BlackHole.
3. Open Settings → **Clean Incoming/Guest**, enable it, pick **BlackHole** as "Incoming from" and your **real speakers/headphones** as "Hear on."
4. Confirm you HEAR the source through your speakers, **de-noised** (play a noisy clip — fan/keyboard/room reverb — and confirm it's cleaned).
5. Toggle Clean Incoming **off** → confirm the cleaned playback stops immediately and the engine is torn down (no lingering audio, CPU returns to baseline).
6. Quit + relaunch → confirm the enabled state, source, and monitor output are restored (persistence). If BlackHole's `AudioObjectID` changed across reboot, confirm the UID resolved correctly.
7. **Performance (mandatory):** with BOTH streams live (your mic cleaning ON + incoming cleaning ON), record CPU% (Activity Monitor / `powermetrics`) and listen for glitches/dropouts on EITHER stream. Note the before/after CPU and any audible latency. If two concurrent streams glitch on the baseline target Mac, record it as a finding (see plan's performance section) — do not silently ship a degraded experience.

---

## Phase 2: Record-them-clean (second virtual sink) — gated behind Phase 1

> **Ship Phase 1 first.** Phase 2 is the more involved driver work and is only worth doing once Phase 1 is validated. It routes the cleaned incoming audio into a SECOND virtual sink so a recording/streaming app (OBS/Riverside) records the guest cleaned too. These tasks are intentionally lighter on code (the driver work mirrors the existing NoNoise Mic driver) and heavier on contract/design — flesh out exact C constants during execution against `Driver/NoNoiseMic/`.

### Task 8: Second virtual-sink contract in `VirtualMicRouting` — TDD

Add the shared-contract constants + classification for a SECOND device pair ("NoNoise Guest" — a visible input the recorder picks + a hidden engine sink the incoming pipeline writes to), kept strictly parallel to the existing NoNoise Mic constants. **These MUST match the driver's C constants exactly — a mismatch fails SILENTLY** (per `CLAUDE.md` → NoNoise Mic virtual driver).

**Files:**
- Modify: `Sources/Core/AudioProcessing/VirtualMicRouting.swift`
- Modify: `Tests/NoNoiseMacTests/IncomingCleanupTests.swift`

- [ ] **Step 1: Write failing tests** asserting the new constants exist, are distinct from the mic constants, and that the new "NoNoise Guest" devices are excluded from incoming-source + monitor-output pickers (same self-loop reasoning as the NoNoise Mic devices).
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Add the parallel constants** (e.g. `guestVisibleDeviceUID = "NoNoiseGuest:visible:48k2ch"`, `guestEngineDeviceUID = "NoNoiseGuest:engine:48k2ch"`, names, bundle id) and extend `isNoNoiseEngine`/`isSelectableIncomingSource`/`isSelectableMonitorOutput` to also reject the guest devices. **Do not hardcode the FourCharCode or repack the ASBD** — reuse the canonical layout rules from the existing driver.
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit** `feat(routing): add NoNoise Guest second-sink contract (Phase 2)`.

### Task 9: NoNoise Guest driver instance + engine fan-out

> **Driver work (`Driver/`).** Follow `CLAUDE.md` → "NoNoise Mic virtual driver" EXACTLY: canonical Float32 interleaved stereo layout, ad-hoc sign AFTER full assembly (any post-sign edit silently breaks load), pure testable ring/clock math host-tested via `Driver/tests/run-tests.sh`, ring serves SILENCE not stale audio. This is an original implementation against the public API — NOT BlackHole-derived.

- [ ] **Step 1:** Stand up a second driver device pair ("NoNoise Guest" visible input + hidden engine sink), mirroring the existing NoNoise Mic device with the Task-8 constants. Decide: a second `AudioServerPlugIn` device inside the SAME plug-in (preferred — one bundle, two device pairs) vs. a separate bundle. The shared `nn_ring`/`nn_clock` math is reusable; instantiate a SECOND ring/clock for the guest pair (do NOT share the mic's ring).
- [ ] **Step 2:** Teach `IncomingCleanupEngine` to ALSO write its cleaned output to the guest engine sink when recording is enabled — i.e. fan-out the render result to (a) the monitor output (Phase 1) and (b) the guest sink. Resolve the guest engine sink by UID translate (it's hidden, so it won't appear in enumeration — same path as the NoNoise Mic engine).
- [ ] **Step 3:** Build the driver (`./build-driver.sh`), run the host ring/clock tests (`Driver/tests/run-tests.sh`), install + verify the device appears (`install-driver.sh` verifies). Smoke test recording the guest-clean in OBS.
- [ ] **Step 4:** Commit driver + engine changes as atomic units.

### Task 10: Phase 2 UI + persistence

- [ ] **Step 1:** Add a "Also record the cleaned guest" toggle to the Settings incoming card (only meaningful when the NoNoise Guest device is installed; show install hint otherwise — mirror the existing driver-status row). Persist `mv.incomingRecordEnabled`.
- [ ] **Step 2:** Drive the fan-out from `AudioModel.applyIncomingCleanup()` based on the toggle. Build + smoke.
- [ ] **Step 3:** Commit `feat(ui): add record-the-cleaned-guest toggle (Phase 2)`.

### Task 11: Phase 2 documentation

- [ ] Update `README.md`, `CONCEPTS.md`, `AGENTS.md` (driver section — now TWO device pairs), `docs/knowledge/timeline1.md`, and a `[DECISION]` entry in `knowledge1.md` (one plug-in / two device pairs, second ring/clock, guest sink resolved by UID translate). Commit.

### Phase 2 manual smoke test

1. Install the updated driver (`sudo ./install-driver.sh`); confirm "NoNoise Guest" appears as an input and the device check passes.
2. With Clean Incoming ON + recording ON, set OBS/Riverside's mic for the guest track to **NoNoise Guest**; confirm it records the guest CLEANED.
3. Confirm the guest sink serves SILENCE (not stale audio) when the incoming engine stops while the recorder keeps running (privacy-critical, per the driver's `nn_ring` watermark rule).
4. Re-run the Phase 1 performance step with the fan-out active (write to two destinations) — confirm no new glitches.

---

## Self-Review (completed during authoring)

- **Spec coverage:** "Clean the OTHER side" → `IncomingCleanupEngine` (Task 2). Phase 1 hear-them-clean (loopback input → same DFN engine → speakers) → Tasks 1–7. Phase 2 record-them-clean (second virtual sink) → Tasks 8–11, gated behind Phase 1. Device-selection UX + setup → Tasks 4/6 + the loopback Setup Guide. CLI-proves-the-engine → cited as the template for Task 2.
- **Design realities addressed honestly:**
  - *No built-in app loopback* — stated up front; setup requires routing the call app's speaker into BlackHole/Loopback; documented in Setup Guide (Task 6) and the empty-source UI hint (Task 4).
  - *Second `AudioModel` vs. reusable engine* — explicit DECISION to extract a focused `IncomingCleanupEngine` (NOT a second `AudioModel`), with the shared-state risks enumerated (`fetchOutputDevices` auto-route hijack, duplicate HAL listeners, mic/virtual-mic coupling, `mv.*` key contention) and verified against the source.
  - *Two concurrent CoreML streams cost* — addressed via off-by-default, lazy create / full teardown, and a MANDATORY profiling smoke step; the plan explicitly refuses to claim the second ANE stream is free.
  - *Routing via `VirtualMicRouting`* — Phase 1 adds pure device-classification predicates; Phase 2 adds a parallel second-sink contract there.
- **Invariants honored:** render thread allocation-free (engine reuses `DeepFilterNetDSP`/`VoiceChain` unchanged; lock-free `var Bool` scalar from main→render); 100% on-device / no telemetry; HAL input-scope enumeration (not `AVCaptureDevice` discovery); pure logic in headless XCTest-able `VirtualMicRouting`, the live engine build+smoke-verified; legacy `mv.*` persistence namespace; no "MetalVoice"/"Ghostkwebb" in `Sources/`; no absolute local paths (repo-relative + "package root" only).
- **Placeholder scan:** Phase 1 (Tasks 1–7) shows complete code + exact commands. Phase 2 (Tasks 8–11) is intentionally design-level (driver work to be fleshed out against `Driver/` during execution, per `CLAUDE.md`'s driver rules) and is explicitly gated behind Phase 1 shipping.
- **Type consistency:** `VirtualMicRouting.isSelectableIncomingSource`/`selectableIncomingSources`/`isSelectableMonitorOutput`, `IncomingCleanupEngine(start:stop:isCleaningEnabled)`, `AudioModel.incomingCleanupEnabled`/`incomingSourceUID`/`incomingOutputDeviceID`/`incomingSourceDevices`/`monitorOutputDevices`, and `PrefKey.incoming*` are used consistently across tasks.
- **Open design questions flagged:** (1) the real cost of two concurrent ANE streams on the baseline Mac (measured in the smoke step, not assumed); (2) loopback setup friction (mitigated by UX + Setup Guide, but inherent to macOS); (3) Phase 2's one-plug-in-two-device-pairs vs. separate bundle (decided in Task 9 against the live driver). Whether the incoming path should get its own preset (v1 uses full suppression) is deferred.
```