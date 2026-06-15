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
    /// Returns `true` ONLY once the playback graph is actually live AND capture has been kicked off;
    /// returns `false` (fully torn down) if the source can't be resolved/attached OR the monitor
    /// can't be pinned / the audio engine can't start. The owner then releases this engine, so a
    /// half-open start never leaves the second CoreML pipeline resident with no audible output.
    @discardableResult
    public func start(sourceDeviceUID: String, monitorDeviceID: AudioObjectID) -> Bool {
        stop()                                   // clean slate (rebuild capture + engine)
        guard configureCapture(sourceDeviceUID: sourceDeviceUID) else {
            // Source couldn't be resolved/attached — nothing was started; owner releases us.
            return false
        }
        guard configurePlayback(monitorDeviceID: monitorDeviceID) else {
            // Monitor couldn't be pinned or the engine refused to start. Tear down the attached-
            // but-idle capture graph so we never retain a running/half-open pipeline that produces
            // NO audible output (false-positive "started"). Owner releases us on the false return.
            stop()
            return false
        }
        // Playback is live; only NOW pull capture so the ring fills into a ready graph (a few ms of
        // silence at most). `[weak self]` so a teardown that races this never revives a dead capture.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.captureSession.startRunning() }
        running = true
        return true
    }

    /// Stop and fully tear down. The OWNER releases the whole engine to nil after this, so the
    /// second CoreML stream's allocations/model are freed too (the performance mandate requires
    /// zero cost when off). `engine.reset()` does NOT detach the source node — keep `sourceNode`
    /// attached across stop/start within one instance; the instance is short-lived anyway.
    public func stop() {
        // Also tear down when the graph is ATTACHED-but-idle (inputs added, capture not yet started):
        // that's the `start()` playback-failure path, where nothing is "running" yet but the capture
        // input still needs removing. Without `!inputs.isEmpty` here, stop() would no-op and leak it.
        guard running || captureSession.isRunning || engine.isRunning
                || !captureSession.inputs.isEmpty else { return }
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

    /// Resolve + ATTACH the loopback source (does NOT start the session — `start()` kicks capture
    /// off only after playback is confirmed live). Returns `false` if the device can't be resolved
    /// or the input/output can't be added, so `start()` won't open a dead graph.
    private func configureCapture(sourceDeviceUID: String) -> Bool {
        // AVCaptureDevice.DiscoverySession misses loopback devices, but AVCaptureDevice(uniqueID:)
        // RESOLVES a BlackHole HAL UID to a real AVCaptureHALDevice (proven by the Task-S spike);
        // live sample-buffer delivery is gated only by mic TCC permission (the app holds
        // com.apple.security.device.audio-input). The picker (Task 3) enumerates via the HAL and
        // hands us that UID.
        guard let device = AVCaptureDevice(uniqueID: sourceDeviceUID) else {
            print("IncomingCleanupEngine: source device not found: \(sourceDeviceUID)")
            return false
        }
        captureSession.beginConfiguration()
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }
        var added = false
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
                if captureSession.canAddOutput(captureOutput) {
                    captureSession.addOutput(captureOutput)
                    captureOutput.setSampleBufferDelegate(self, queue: processingQueue)
                    added = true
                }
            }
        } catch {
            print("IncomingCleanupEngine capture error: \(error)")
        }
        captureSession.commitConfiguration()
        return added                              // started later by start(), after playback is live
    }

    // MARK: - Playback (to the user's monitor output)

    /// Pin the chosen monitor, wire the graph, and start the engine. Returns `false` (caller tears
    /// down) if the monitor can't be pinned or the engine won't start — never reports success for a
    /// graph that isn't actually playing.
    private func configurePlayback(monitorDeviceID: AudioObjectID) -> Bool {
        engine.stop(); engine.reset()
        if monitorDeviceID != 0 {
            var dev = monitorDeviceID
            let size = UInt32(MemoryLayout<AudioObjectID>.size)
            let status = AudioUnitSetProperty(outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &dev, size)
            // If we can't PIN the chosen monitor, refuse to start: letting the output unit fall back
            // to the system DEFAULT output risks routing the cleaned audio into the very loopback we
            // capture — the exact feedback loop the owner's monitor guard exists to prevent.
            guard status == noErr else {
                print("IncomingCleanupEngine: could not set monitor device \(monitorDeviceID): \(status)")
                return false
            }
        }
        // Attach the source node ONCE per instance. `engine.reset()` (in `stop`) tears down the
        // render state but does NOT detach attached nodes, so re-attaching would throw / duplicate.
        if !sourceNodeAttached {
            engine.attach(sourceNode)
            sourceNodeAttached = true
        }
        engine.connect(sourceNode, to: mainMixer, format: AudioUtils.shared.processingFormat)
        engine.connect(mainMixer, to: outputNode, format: nil)
        do {
            try engine.start()
        } catch {
            print("IncomingCleanupEngine engine error: \(error)")
            return false
        }
        return true
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
