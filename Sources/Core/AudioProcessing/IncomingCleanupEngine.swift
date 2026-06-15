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
        // devices. The spike proved AVCaptureDevice(uniqueID:) RESOLVES a BlackHole HAL UID to a
        // real AVCaptureHALDevice; live sample-buffer delivery is gated only by mic TCC permission
        // (the app holds com.apple.security.device.audio-input). The picker (Task 3) enumerates via
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
