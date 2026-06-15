import Foundation
import AVFoundation
import AVFAudio
import Combine
import AudioToolbox
import CoreAudio
import Accelerate

public class AudioModel: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    // Published State for UI.
    // Defaults ON so NoNoise Mac is actively cancelling noise on first launch.
    @Published public var isAIEnabled: Bool = true {
        didSet {
        }
    }
    @Published public var inputDevices: [AVCaptureDevice] = [] // Changed to AVCaptureDevice
    @Published public var selectedInputDeviceID: String = "" { // IDs are Strings in AVCapture
        didSet {
             guard selectedInputDeviceID != oldValue else { return }
             setupCaptureSession()
        }
    }
    @Published public var errorMessage: String?
    @Published public var inputLevel: Float = 0.0
    @Published public var activeOutputDeviceName: String = "Unknown"
    @Published public var permissionStatus: String = "Unknown"
    
    // Output Selection
    @Published public var outputDevices: [DeviceStruct] = []
    @Published public var selectedOutputDeviceID: AudioObjectID = 0 {
        didSet {
             guard selectedOutputDeviceID != oldValue else { return }
             setupPlaybackEngine()
        }
    }
    /// True when the visible "NoNoise Mic" virtual device is installed (resolved by UID, so it
    /// works even though that device is INPUT-only and absent from the output-scoped scan).
    @Published public var driverInstalled: Bool = false

    /// True while some app is actually capturing from "NoNoise Mic". In on-demand mode the real
    /// mic (and the macOS orange mic indicator) is only held while this is true — matching Krisp,
    /// which doesn't pin the mic just because the app is open.
    @Published public var virtualMicInUse: Bool = false

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

    // On-demand capture: when the virtual mic is installed we capture the real mic ONLY while a
    // consumer app is using "NoNoise Mic" (observed via kAudioDevicePropertyDeviceIsRunningSomewhere).
    // Without the driver (BlackHole fallback) there's no per-use signal, so we capture continuously.
    private var micDeviceID: AudioObjectID = 0
    private var isRunningSomewhereListener: AudioObjectPropertyListenerBlock?
    private var isRunningSomewhereAddr = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var hardwareDevicesListener: AudioObjectPropertyListenerBlock?
    private var hardwareDevicesAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var deviceRefreshWorkItem: DispatchWorkItem?
    private var onDemandMode: Bool { micDeviceID != 0 }
    private var shouldCapture: Bool { !onDemandMode || virtualMicInUse }
    
    @Published public var isPlayingTestTone: Bool = false {
        didSet {
            // No action needed, source node checks this flag
        }
    }
    
    @Published public var outputGainValue: Float = 1.0 {
        didSet {
             dspEngine.outputGain = outputGainValue
             onKnobChanged()
        }
    }

    // Preset + suppression intensity (persisted to UserDefaults under mv.*).
    @Published public var selectedPreset: VoicePreset = .meeting {
        didSet {
            guard !isApplyingPreset else { return }
            applyPreset(selectedPreset)   // no-op for .custom (keeps current knobs)
            applyVoiceChain()             // reconfigure voice chain for the new preset
            persistSettings()             // persist the selection itself, incl. a direct .custom pick
        }
    }

    @Published public var suppressionStrength: Float = 1.0 {
        didSet {
            dspEngine.suppressionStrength = suppressionStrength
            onKnobChanged()
        }
    }

    @Published public var attenuationLimitDb: Float = VoicePreset.maxAttenuationDb {
        didSet {
            dspEngine.attenuationLimitDb = attenuationLimitDb
            onKnobChanged()
        }
    }

    /// Master on/off for the post-DSP voice-polish chain. Effective enabled state
    /// is `voicePolishEnabled && selectedPreset.voiceChain.enabled` (see
    /// `applyVoiceChain`). Guarded like the knobs so `loadSettings` can restore it
    /// without re-persisting or reconfiguring mid-load.
    @Published public var voicePolishEnabled: Bool = true {
        didSet {
            guard !isApplyingPreset else { return }
            applyVoiceChain()
            persistSettings()
        }
    }

    /// "Broadcast Voice" clarity level. Layered on top of the active preset
    /// (independent of the noise preset and of Voice Polish). Guarded like the
    /// other knobs so `loadSettings` can restore it without re-persisting mid-load.
    @Published public var clarityLevel: ClarityLevel = .off {
        didSet {
            guard !isApplyingPreset else { return }
            applyVoiceChain()
            persistSettings()
        }
    }

    /// App-level pre-DSP input trim (25%…100%). Does not write macOS hardware volume.
    private var realtimeInputVolume: Float = 1.0

    @Published public var inputVolumeValue: Float = 1.0 {
        didSet {
            realtimeInputVolume = SmartLevelController.runtimeInputVolume(for: inputVolumeValue)
            guard !isApplyingPreset else { return }
            persistSettings()
        }
    }

    @Published public var smartLevelEnabled: Bool = false {
        didSet {
            guard !isApplyingPreset else { return }
            if !smartLevelEnabled { smartLevelMessage = nil }
            persistSettings()
        }
    }

    @Published public var rawInputPeak: Float = 0.0
    @Published public var trimmedInputPeak: Float = 0.0
    @Published public var outputPeak: Float = 0.0
    @Published public var isInputNearCeiling: Bool = false
    @Published public var isOutputClipping: Bool = false
    @Published public var isSourceMicClipping: Bool = false
    @Published public var smartLevelMessage: String?

    private var isApplyingPreset = false

    // Telemetry scalars written by capture/render; published by the meter timer (~25 Hz).
    private var tInputLevel: Float = 0
    private var tRawInputPeak: Float = 0
    private var tTrimmedInputPeak: Float = 0
    private var tOutputPeak: Float = 0
    private var tOutputClipCount: Int32 = 0
    private var tRawInputClipCount: Int32 = 0
    private var tTrimmedInputHotCount: Int32 = 0
    private var meterTimer: Timer?
    private var consecutiveTrimmedHotTicks = 0
    private var consecutiveOutputClipTicks = 0
    private var lastSmartLevelAdjustTime: Date?

    private enum PrefKey {
        static let preset = "mv.preset"
        static let strength = "mv.suppressionStrength"
        static let atten = "mv.attenuationLimitDb"
        static let gain = "mv.outputGain"
        static let voicePolish = "mv.voicePolish"
        static let clarity = "mv.clarity"
        static let inputVolume = "mv.inputVolume"
        static let smartLevel = "mv.smartLevel"
        static let incomingEnabled = "mv.incomingEnabled"
        static let incomingSourceUID = "mv.incomingSourceUID"
        static let incomingOutputUID = "mv.incomingOutputUID"
    }

    public struct DeviceStruct: Identifiable {
        public let id: AudioObjectID
        public let name: String
    }
    
    // Capture (Input)
    private let captureSession = AVCaptureSession()
    private let captureOutput = AVCaptureAudioDataOutput()
    private let processingQueue = DispatchQueue(label: "audio.processing.queue", qos: .userInteractive)
    
    // Playback (Output)
    private let engine = AVAudioEngine()
    private var playbackSourceNode: AVAudioSourceNode! 
    private var outputNode: AVAudioOutputNode { engine.outputNode }
    private var mainMixer: AVAudioMixerNode { engine.mainMixerNode }
    
    // Buffering
    private let ringBuffer = RingBuffer(capacity: 48000 * 5)
    
    // Processing Modules
    // Processing Modules
    private let dspEngine = DeepFilterNetDSP()
    private let voiceChain = VoiceChain()

    // OPTIONAL — created only while the feature is enabled (DeepFilterNetDSP.init allocates
    // MLMultiArrays + async-loads the model; a stored non-optional instance would pay that at
    // launch and break zero-cost-when-off). Released to nil on disable.
    private var incomingEngine: IncomingCleanupEngine?

    // UID lookups: capture is by UID (input scan); monitor persistence is by UID (output scan).
    // Kept SEPARATE so persistence resolves the monitor output from the correct device set
    // (AudioObjectIDs are not stable across reboots, so we store + restore by UID).
    private var incomingSourceUIDByID: [AudioObjectID: String] = [:]
    private var monitorOutputUIDByID: [AudioObjectID: String] = [:]

    public override init() {
        super.init()
        
        let bufferRef = ringBuffer
        let dsp = dspEngine
        let chain = voiceChain
        
        playbackSourceNode = AVAudioSourceNode { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard let data = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            let count = Int(frameCount)
            
            // 1. Test Tone
            if let self = self, self.isPlayingTestTone {
                 for i in 0..<count {
                     data[i] = Float.random(in: -0.1...0.1) 
                 }
                 return noErr
            }
            
            // 2. Latency
            let latencyTarget = 2400
            let available = bufferRef.count
            if available > (latencyTarget + count) {
                bufferRef.drop(available - latencyTarget)
            }
            
            // 3. Read
            // DSP Engine needs contiguous flow. If we underflow, we feed silence.
            if !bufferRef.read(into: data, count: count) {
                AudioUtils.shared.fillSilence(data, count: count)
                return noErr
            }
            
            // 4. Processing
            
            // Gain (Boost Mic)
            var gain: Float = 1.0
            vDSP_vsmul(data, 1, &gain, data, 1, vDSP_Length(frameCount))
            
            if let self = self, self.isAIEnabled {
                // DSP STFT Pipeline, then voice-polish chain (no-op when disabled).
                dsp.process(input: data, count: count, output: data)
                chain.process(data, count: count)
            }

            self?.recordOutputTelemetry(data, count: count)
            return noErr
        }
        
        checkPermissions()
        fetchInputDevices()
        fetchOutputDevices()
        fetchIncomingDevices()   // HAL input-scope scan surfaces loopback sources (BlackHole/Loopback)
        // Resolve the virtual mic up front so the first capture config is correctly gated: in
        // on-demand mode we must NOT start the real-mic capture until an app uses "NoNoise Mic".
        micDeviceID = deviceID(forUID: VirtualMicRouting.visibleDeviceUID)
        setupCaptureSession()
        setupPlaybackEngine()
        resolveVirtualMicLifecycle()   // arm the in-use listener + sync initial state
        installHardwareDeviceListener()
        loadSettings()
        startMeterTimer()
    }

    deinit {
        meterTimer?.invalidate()
        deviceRefreshWorkItem?.cancel()
        if let block = hardwareDevicesListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &hardwareDevicesAddr,
                                                   DispatchQueue.main,
                                                   block)
        }
        if let block = isRunningSomewhereListener, micDeviceID != 0 {
            AudioObjectRemovePropertyListenerBlock(micDeviceID,
                                                   &isRunningSomewhereAddr,
                                                   DispatchQueue.main,
                                                   block)
        }
    }

    // MARK: - Presets & suppression knobs

    /// Apply a preset's parameters to the live knobs. No-op for `.custom`.
    /// `isApplyingPreset` suppresses the knob `didSet`s from flipping the preset
    /// back to `.custom` while we apply it.
    private func applyPreset(_ preset: VoicePreset) {
        guard let p = preset.parameters else { return }  // .custom keeps current knobs
        let previously = isApplyingPreset
        isApplyingPreset = true
        suppressionStrength = p.suppressionStrength
        attenuationLimitDb = p.attenuationLimitDb
        outputGainValue = p.outputGain
        isApplyingPreset = previously
        // Persistence is the caller's responsibility (selectedPreset.didSet), so a
        // direct .custom selection — which no-ops here — is still persisted.
    }

    /// Configure the voice chain from the active preset, gated by the master
    /// toggle. Runs on the main thread (recomputes filter coefficients); the
    /// render thread only reads coefficients and runs scalar math.
    private func applyVoiceChain() {
        var s = selectedPreset.voiceChain
        s.enabled = s.enabled && voicePolishEnabled
        s.clarity = clarityLevel
        voiceChain.configure(s)
    }

    /// Called from any knob `didSet`. A manual change outside `applyPreset`
    /// switches the active preset to `.custom` and persists.
    private func onKnobChanged() {
        guard !isApplyingPreset else { return }
        if selectedPreset != .custom {
            isApplyingPreset = true
            selectedPreset = .custom
            isApplyingPreset = false
            applyVoiceChain()   // Custom has its own balanced chain; configure once on transition
        }
        persistSettings()
    }

    private func persistSettings() {
        let d = UserDefaults.standard
        d.set(selectedPreset.rawValue, forKey: PrefKey.preset)
        d.set(suppressionStrength, forKey: PrefKey.strength)
        d.set(attenuationLimitDb, forKey: PrefKey.atten)
        d.set(outputGainValue, forKey: PrefKey.gain)
        d.set(voicePolishEnabled, forKey: PrefKey.voicePolish)
        d.set(clarityLevel.rawValue, forKey: PrefKey.clarity)
        d.set(inputVolumeValue, forKey: PrefKey.inputVolume)
        d.set(smartLevelEnabled, forKey: PrefKey.smartLevel)
    }

    private func loadSettings() {
        let d = UserDefaults.standard
        guard let raw = d.string(forKey: PrefKey.preset),
              let preset = VoicePreset(rawValue: raw) else {
            // First launch: keep defaults (Meeting) and push them to the DSP.
            applyPreset(.meeting)
            applyVoiceChain()
            return
        }
        // Load stored knob values (used as-is for .custom; overwritten below for
        // non-custom presets where the preset is the source of truth).
        isApplyingPreset = true
        suppressionStrength = d.object(forKey: PrefKey.strength) != nil ? d.float(forKey: PrefKey.strength) : 1.0
        attenuationLimitDb = d.object(forKey: PrefKey.atten) != nil ? d.float(forKey: PrefKey.atten) : VoicePreset.maxAttenuationDb
        outputGainValue = d.object(forKey: PrefKey.gain) != nil ? d.float(forKey: PrefKey.gain) : 1.0
        // Restore the master toggle inside the guard so its didSet doesn't
        // re-persist or reconfigure mid-load (default ON when absent).
        voicePolishEnabled = d.object(forKey: PrefKey.voicePolish) as? Bool ?? true
        clarityLevel = ClarityLevel(rawValue: d.string(forKey: PrefKey.clarity) ?? "") ?? .off
        inputVolumeValue = d.object(forKey: PrefKey.inputVolume) != nil
            ? SmartLevelController.clampInputVolume(d.float(forKey: PrefKey.inputVolume)) : 1.0
        smartLevelEnabled = d.object(forKey: PrefKey.smartLevel) as? Bool ?? false
        // Incoming / guest cleanup (off by default; resolve persisted UIDs to live IDs). Restored
        // inside the isApplyingPreset guard so the didSets don't re-persist/reconfigure mid-load.
        incomingCleanupEnabled = d.bool(forKey: PrefKey.incomingEnabled)
        incomingSourceUID = d.string(forKey: PrefKey.incomingSourceUID) ?? ""
        if let outUID = d.string(forKey: PrefKey.incomingOutputUID), !outUID.isEmpty {
            incomingOutputDeviceID = deviceID(forUID: outUID)   // translate monitor UID → live ID
        }
        selectedPreset = preset
        isApplyingPreset = false
        if let p = preset.parameters {  // non-custom: preset defines the values
            isApplyingPreset = true
            suppressionStrength = p.suppressionStrength
            attenuationLimitDb = p.attenuationLimitDb
            outputGainValue = p.outputGain
            isApplyingPreset = false
        }
        // Single explicit configure from the final restored state.
        applyVoiceChain()
        // Create the incoming engine once, only if the feature was persisted enabled (off → no-op).
        applyIncomingCleanup()
    }

    // MARK: - Incoming / guest cleanup lifecycle

    /// Create-or-tear-down the incoming engine to match the current selections. Off by default —
    /// the engine object (and thus the second DeepFilterNetDSP's allocations + model load) is
    /// constructed ONLY when enabled with a valid source, and released to nil otherwise, so a
    /// disabled feature holds zero ANE/CPU/memory.
    private func applyIncomingCleanup() {
        // Tear down unless the feature is FULLY and VALIDLY configured. We require BOTH a real
        // loopback source AND a chosen real monitor output, each re-validated against the canonical
        // predicates (a persisted device may have changed identity/role since it was saved).
        // Requiring a chosen REAL monitor is load-bearing: with no monitor, playback would fall to
        // the system DEFAULT output — and if that default is the very loopback being captured (the
        // setup points the call app's speaker at it), that is a FEEDBACK loop. "No valid monitor"
        // therefore means "do not run", never "fall back to default".
        guard incomingCleanupEnabled,
              !incomingSourceUID.isEmpty,
              incomingOutputDeviceID != 0,
              let sourceInfo = deviceInfo(for: deviceID(forUID: incomingSourceUID)),
              VirtualMicRouting.isSelectableIncomingSource(sourceInfo),
              let monitorInfo = deviceInfo(for: incomingOutputDeviceID),
              VirtualMicRouting.isSelectableMonitorOutput(monitorInfo) else {
            incomingEngine?.stop()
            incomingEngine = nil          // release allocations + CoreML model
            return
        }
        // Lazily construct on first enable (DeepFilterNetDSP.init allocates + async-loads here).
        // Retain the engine ONLY if it actually starts: a failed capture attach must not leave the
        // second CoreML pipeline (model + buffers) resident — that would break zero-cost-when-off.
        let engine = incomingEngine ?? IncomingCleanupEngine()
        if engine.start(sourceDeviceUID: incomingSourceUID, monitorDeviceID: incomingOutputDeviceID) {
            incomingEngine = engine
        } else {
            engine.stop()
            incomingEngine = nil
        }
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

    /// Resolve a device UID to its AudioObjectID via the HAL. Works for INPUT-only devices too
    /// (unlike the output-scoped scan), so it's how we detect the visible "NoNoise Mic".
    private func deviceID(forUID uid: String) -> AudioObjectID {
        var translated = AudioObjectID(0)
        var cfUID = uid as CFString
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        withUnsafeMutablePointer(to: &cfUID) { uidPtr in
            _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                           UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &translated)
        }
        return translated
    }

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

        // Input / output capability — SUM the AudioBufferList channel counts; do NOT trust the
        // property data size alone. kAudioDevicePropertyStreamConfiguration returns a non-empty
        // AudioBufferList header even when a scope has ZERO streams (mNumberBuffers == 0), so a
        // `size > 0` check reports phantom channels and would misclassify devices (e.g. an
        // input-only mic offered as a monitor output, or an output-only device as an incoming
        // source). Only a positive mNumberChannels sum proves the scope actually has channels.
        func channelCount(scope: AudioObjectPropertyScope) -> Int {
            var cfgAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                     mScope: scope, mElement: 0)
            var cfgSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &cfgAddr, 0, nil, &cfgSize) == noErr, cfgSize > 0
            else { return 0 }
            let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(cfgSize),
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { raw.deallocate() }
            guard AudioObjectGetPropertyData(id, &cfgAddr, 0, nil, &cfgSize, raw) == noErr else { return 0 }
            let listPtr = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
            var channels = 0
            for buf in listPtr { channels += Int(buf.mNumberChannels) }
            return channels
        }
        let hasInput = channelCount(scope: kAudioObjectPropertyScopeInput) > 0
        let hasOutput = channelCount(scope: kAudioObjectPropertyScopeOutput) > 0

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

    /// UID for a picked incoming-source `DeviceStruct.id` (capture is by UID, not AudioObjectID).
    /// Lets the Settings picker tag rows with the UID that `incomingSourceUID` binds to.
    public func uid(forIncomingSourceID id: AudioObjectID) -> String {
        incomingSourceUIDByID[id] ?? ""
    }

    func fetchOutputDevices() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        let deviceCount = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)
        
        var newDevs: [DeviceStruct] = []
        // allDevs/uidToID cover only OUTPUT-capable devices, which is exactly the route-target set:
        // the engine is output-capable. The input-only visible "NoNoise Mic" is intentionally absent
        // here — it's detected by UID translate below.
        var allDevs: [VirtualMicRouting.DeviceInfo] = []
        var uidToID: [String: AudioObjectID] = [:]
        // Monitor outputs for the incoming/guest picker — REAL outputs only (loopback sinks,
        // aggregates, virtual, hidden, and our engine excluded by isSelectableMonitorOutput). Built
        // from the SAME output-capable set but kept SEPARATE from outputDevices (the outgoing picker
        // is filtered with isSelectableOutput and would wrongly include BlackHole as a monitor target).
        var monitors: [DeviceStruct] = []
        var monitorUID: [AudioObjectID: String] = [:]

        for id in deviceIDs {
            // Shared HAL read (name/uid/hidden/input+output capability/transport). `hasOutput` now
            // comes from the reader, so the old inline `if size > 0` output guard becomes `info.hasOutput`.
            guard let info = deviceInfo(for: id) else { continue }
            if info.hasOutput {
                allDevs.append(info)
                uidToID[info.uid] = id
                if VirtualMicRouting.isSelectableOutput(info) {   // exclude hidden + our engine from the user's picker
                    newDevs.append(DeviceStruct(id: id, name: info.name))
                }
                if VirtualMicRouting.isSelectableMonitorOutput(info) {
                    monitors.append(DeviceStruct(id: id, name: info.name))
                    monitorUID[id] = info.uid
                }
            }
        }
        
        // The hidden engine (kAudioDevicePropertyIsHidden=1) is EXCLUDED from the
        // kAudioHardwarePropertyDevices enumeration above, so the loop never sees it. Resolve it by
        // UID translate (which DOES resolve hidden/non-enumerated devices) and inject it as the
        // preferred route target. Without this, routing falls back to BlackHole and "NoNoise Mic"
        // receives no audio. The engine still never enters `newDevs` (the user-facing picker).
        let engineRouteID = deviceID(forUID: VirtualMicRouting.engineDeviceUID)
        if engineRouteID != 0 {
            allDevs.append(VirtualMicRouting.DeviceInfo(uid: VirtualMicRouting.engineDeviceUID,
                                                        name: VirtualMicRouting.engineDeviceName,
                                                        isHidden: true, hasOutput: true))
            uidToID[VirtualMicRouting.engineDeviceUID] = engineRouteID
        }

        let routeUID = VirtualMicRouting.preferredOutputUID(from: allDevs)   // engine (by UID), else BlackHole, else nil
        DispatchQueue.main.async {
            self.outputDevices = newDevs
            self.monitorOutputDevices = monitors
            self.monitorOutputUIDByID = monitorUID
            // The visible "NoNoise Mic" is INPUT-only, so it is NOT in the output-scoped allDevs.
            // Detect install by translating the visible UID directly (translate resolves input-only devices too).
            self.driverInstalled = self.deviceID(forUID: VirtualMicRouting.visibleDeviceUID) != 0
            if let uid = routeUID {
                self.selectedOutputDeviceID = uidToID[uid] ?? self.deviceID(forUID: uid)
                if uid == VirtualMicRouting.engineDeviceUID { self.activeOutputDeviceName = VirtualMicRouting.engineDeviceName }
            }
            // else: no virtual sink → leave unset; do NOT auto-route to a physical output (that would
            // play cleaned audio aloud instead of feeding a mic). Task 8's UI surfaces "install the driver".
        }
    }
    
    // ... input methods ...
    
    func setupPlaybackEngine() {
        engine.stop()
        engine.reset()
        
        // Output Device
        if selectedOutputDeviceID != 0 {
             var deviceID = selectedOutputDeviceID
             let size = UInt32(MemoryLayout<AudioObjectID>.size)
             AudioUnitSetProperty(outputNode.audioUnit!,
                                  kAudioOutputUnitProperty_CurrentDevice,
                                  kAudioUnitScope_Global,
                                  0,
                                  &deviceID,
                                  size)
             
             // Update Name
             if let dev = outputDevices.first(where: { $0.id == selectedOutputDeviceID }) {
                 DispatchQueue.main.async { self.activeOutputDeviceName = dev.name }
             }
        }

        // Attach Source
        engine.attach(playbackSourceNode)
        
        // Connect
        engine.connect(playbackSourceNode, to: mainMixer, format: AudioUtils.shared.processingFormat)
        engine.connect(mainMixer, to: outputNode, format: nil)
        
        do {
            try engine.start()
        } catch {
            print("Engine Error: \(error)")
        }
    }
    
    func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: permissionStatus = "Authorized"
        case .denied: permissionStatus = "Denied"
        case .restricted: permissionStatus = "Restricted"
        case .notDetermined:
            permissionStatus = "Not Determined"
            AVCaptureDevice.requestAccess(for: .audio) { g in
                DispatchQueue.main.async { self.permissionStatus = g ? "Authorized" : "Denied" }
            }
        @unknown default: permissionStatus = "Unknown"
        }
    }
    
    func fetchInputDevices() {
        // AVCaptureDeviceDiscovery
        let types: [AVCaptureDevice.DeviceType] = [.builtInMicrophone, .externalUnknown] // .externalUnknown covers USB mics usually
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .audio, position: .unspecified)
        // Note: AVCaptureDevice doesn't easily show "Loopback" devices like BlackHole.
        // But for "Microphone" input, that is what we want.
        
        var devs = session.devices
        // Drop our own virtual mic from the capture list — selecting it as the source would feed
        // the cleaned output back into the input (a loopback echo).
        devs = devs.filter { VirtualMicRouting.filterInputs([$0.localizedName]).isEmpty == false }
        // Sort: Built-in first?
        devs.sort { $0.localizedName < $1.localizedName }
        
        DispatchQueue.main.async {
            self.inputDevices = devs
            if devs.contains(where: { $0.uniqueID == self.selectedInputDeviceID }) {
                return
            }
            if let defaultDev = AVCaptureDevice.default(for: .audio),
               devs.contains(where: { $0.uniqueID == defaultDev.uniqueID }) {
                self.selectedInputDeviceID = defaultDev.uniqueID
            } else if let first = devs.first {
                self.selectedInputDeviceID = first.uniqueID
            } else {
                self.selectedInputDeviceID = ""
            }
        }
    }
    
    func setupCaptureSession() {
        captureSession.stopRunning()
        captureSession.beginConfiguration()
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }
        
        do {
            guard let device = AVCaptureDevice(uniqueID: selectedInputDeviceID) else {
                print("Device not found: \(selectedInputDeviceID)")
                captureSession.commitConfiguration()
                return
            }
            
            let input = try AVCaptureDeviceInput(device: device)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
            
            if captureSession.canAddOutput(captureOutput) {
                captureSession.addOutput(captureOutput)
                captureOutput.setSampleBufferDelegate(self, queue: processingQueue)
            }
            
        } catch {
            print("Capture Setup Error: \(error)")
        }
        
        captureSession.commitConfiguration()

        // Only hold the real mic when we actually need it (see on-demand mode). In always-on mode
        // (no driver) this is always true, preserving the previous behavior.
        if shouldCapture {
            DispatchQueue.global(qos: .userInitiated).async {
                self.captureSession.startRunning()
            }
        }
    }

    // MARK: - On-demand capture (mic indicator only while NoNoise Mic is in use)

    /// Resolve the visible "NoNoise Mic" device and, if present, watch when an app starts/stops
    /// using it so we can hold the real mic only then. Safe to call again (re-resolves + re-arms).
    private func resolveVirtualMicLifecycle() {
        let wasOnDemandMode = onDemandMode
        if let blk = isRunningSomewhereListener, micDeviceID != 0 {
            AudioObjectRemovePropertyListenerBlock(micDeviceID, &isRunningSomewhereAddr, DispatchQueue.main, blk)
            isRunningSomewhereListener = nil
        }
        micDeviceID = deviceID(forUID: VirtualMicRouting.visibleDeviceUID)
        guard onDemandMode else {
            virtualMicInUse = false
            if wasOnDemandMode { startCapture() }
            return
        }   // no driver → stay always-on, no listener
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshVirtualMicUsage()
        }
        isRunningSomewhereListener = block
        AudioObjectAddPropertyListenerBlock(micDeviceID, &isRunningSomewhereAddr, DispatchQueue.main, block)
        refreshVirtualMicUsage()   // sync initial state (e.g. an app already capturing at launch)
    }

    /// Read whether "NoNoise Mic" is being used right now and start/stop the real-mic capture to match.
    private func refreshVirtualMicUsage() {
        guard onDemandMode else { return }
        var val: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = isRunningSomewhereAddr
        AudioObjectGetPropertyData(micDeviceID, &addr, 0, nil, &size, &val)
        let inUse = val != 0
        virtualMicInUse = inUse
        if inUse { startCapture() } else { stopCapture() }
    }

    private func installHardwareDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleDeviceRefresh()
        }
        hardwareDevicesListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                            &hardwareDevicesAddr,
                                            DispatchQueue.main,
                                            block)
    }

    private func scheduleDeviceRefresh() {
        deviceRefreshWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.refreshDevicesAfterHardwareChange()
        }
        deviceRefreshWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func refreshDevicesAfterHardwareChange() {
        fetchInputDevices()
        fetchOutputDevices()
        fetchIncomingDevices()   // refresh loopback sources when BlackHole/Loopback is added/removed
        resolveVirtualMicLifecycle()
        // Re-validate the incoming engine against the new device set: tear it down if the selected
        // source/monitor vanished or changed role, (re)start it if a valid selection reappeared.
        // Reads the HAL directly (deviceInfo/deviceID), so it's correct even before the fetch*
        // results publish on the next runloop.
        applyIncomingCleanup()
    }

    private func startCapture() {
        guard !captureSession.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { self.captureSession.startRunning() }
    }

    private func stopCapture() {
        guard captureSession.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { self.captureSession.stopRunning() }
    }

    // MARK: - Input Volume, telemetry & Smart Level

    private func setInputVolume(_ volume: Float) {
        inputVolumeValue = SmartLevelController.clampInputVolume(volume)
    }

    /// Programmatic output-gain change for Smart Level — must not flip the active preset to `.custom`.
    private func setOutputGainForSmartLevel(_ gain: Float) {
        isApplyingPreset = true
        outputGainValue = gain
        isApplyingPreset = false
        persistSettings()
    }

    private func startMeterTimer() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.publishMeterTelemetry()
        }
    }

    private func publishMeterTelemetry() {
        let rawPeak = tRawInputPeak
        let trimmedPeak = tTrimmedInputPeak
        let outPeak = tOutputPeak
        let outputClipCount = tOutputClipCount
        let inputDecision = SmartLevelController.evaluateInputGuard(
            telemetry: SmartLevelController.InputTelemetry(
                rawPeak: rawPeak,
                trimmedPeak: trimmedPeak,
                trimmedRMS: tInputLevel,
                rawClipSamples: Int(tRawInputClipCount),
                trimmedHotSamples: Int(tTrimmedInputHotCount)),
            currentHotTicks: consecutiveTrimmedHotTicks,
            currentInputVolume: inputVolumeValue,
            smartLevelEnabled: smartLevelEnabled)

        inputLevel = inputDecision.inputLevel
        rawInputPeak = rawPeak
        trimmedInputPeak = trimmedPeak
        outputPeak = outPeak
        isInputNearCeiling = inputDecision.isInputNearCeiling
        isOutputClipping = SmartLevelController.isClipping(outPeak) || outputClipCount > 0
        isSourceMicClipping = inputDecision.isSourceMicClipping

        consecutiveTrimmedHotTicks = inputDecision.consecutiveTrimmedHotTicks
        let outputWasClipping = SmartLevelController.isClipping(outPeak) || outputClipCount > 0
        consecutiveOutputClipTicks = SmartLevelController.advanceHotTicks(
            current: consecutiveOutputClipTicks, wasHot: outputWasClipping)

        tInputLevel = 0
        tRawInputPeak = 0
        tTrimmedInputPeak = 0
        tOutputPeak = 0
        tOutputClipCount = 0
        tRawInputClipCount = 0
        tTrimmedInputHotCount = 0

        updateSmartLevel()
    }

    private func updateSmartLevel() {
        guard smartLevelEnabled else { return }
        let now = Date()
        if let last = lastSmartLevelAdjustTime, now.timeIntervalSince(last) < 0.4 { return }

        if isSourceMicClipping {
            smartLevelMessage = "Source mic is clipping before NoNoise. Lower macOS/device input volume if available."
        }

        if let next = SmartLevelController.nextInputVolume(
            current: inputVolumeValue, hotTicks: consecutiveTrimmedHotTicks, enabled: smartLevelEnabled) {
            setInputVolume(next)
            consecutiveTrimmedHotTicks = 0
            lastSmartLevelAdjustTime = now
            smartLevelMessage = "Smart Level reduced Input Volume to \(Int(next * 100))%."
            return
        }

        if let next = SmartLevelController.nextOutputGain(
            current: outputGainValue, outputClipTicks: consecutiveOutputClipTicks,
            inputHotTicks: consecutiveTrimmedHotTicks, enabled: smartLevelEnabled) {
            setOutputGainForSmartLevel(next)
            consecutiveOutputClipTicks = 0
            lastSmartLevelAdjustTime = now
            smartLevelMessage = "Smart Level reduced Output Gain to \(Int(next * 100))%."
        } else if !isInputNearCeiling && !isOutputClipping && !isSourceMicClipping {
            smartLevelMessage = nil
        }
    }

    private func recordInputTelemetry(rawPeak: Float, trimmedPeak: Float, rms: Float,
                                    rawClipSamples: Int, trimmedHotSamples: Int) {
        tInputLevel = max(tInputLevel, rms)
        tRawInputPeak = SmartLevelController.latchPeak(existing: tRawInputPeak, bufferPeak: rawPeak)
        tTrimmedInputPeak = SmartLevelController.latchPeak(existing: tTrimmedInputPeak, bufferPeak: trimmedPeak)
        if rawClipSamples > 0 { tRawInputClipCount &+= Int32(rawClipSamples) }
        if trimmedHotSamples > 0 { tTrimmedInputHotCount &+= Int32(trimmedHotSamples) }
    }

    private func recordOutputTelemetry(_ data: UnsafePointer<Float>, count: Int) {
        var peak = tOutputPeak
        var clipCount = tOutputClipCount
        for i in 0..<count {
            let mag = abs(data[i])
            peak = max(peak, mag)
            if mag >= SmartLevelController.clipThreshold { clipCount &+= 1 }
        }
        tOutputPeak = peak
        tOutputClipCount = clipCount
    }

    
    private var PermissionCheckOnce = false
    
    // Converter State
    private var inputConverter: AVAudioConverter?
    private var inputPCMBuffer: AVAudioPCMBuffer?
    private var inputBuffer48k: AVAudioPCMBuffer?
    
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Converter state persists for continuous stream. No reset needed.
        
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        // Use AudioStreamBasicDescription to create AVAudioFormat
        guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else { return }
        
        // 1. Determine Input Format
        guard let inputFormat = AVAudioFormat(streamDescription: asbd) else { return }
        
        // 2. Define Target Format (48kHz, Float32, Mono)
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000.0, channels: 1, interleaved: false) else { return }
        
        // 3. Setup Converter if needed
        if inputConverter == nil || inputConverter?.inputFormat != inputFormat {
             print("AudioModel: Initializing Converter \(inputFormat.sampleRate) -> 48000")
             inputConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
            
             // Create Buffers
             let maxInputFrames = AVAudioFrameCount(4096)
             inputPCMBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: maxInputFrames)
            
             let ratio = targetFormat.sampleRate / inputFormat.sampleRate
             let maxOutputFrames = AVAudioFrameCount(Double(maxInputFrames) * ratio + 5)
             inputBuffer48k = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: maxOutputFrames)
        }
        
        guard let converter = inputConverter,
              let inputBuffer = inputPCMBuffer,
              let outputBuffer = inputBuffer48k else { return }
              
        // 4. Copy Data Directly to InputPCMBuffer
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        inputBuffer.frameLength = AVAudioFrameCount(numSamples)
        
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(numSamples),
            into: inputBuffer.mutableAudioBufferList
        )
        
        guard status == noErr else { 
            print("AudioModel Error: CMSampleBufferCopyPCMDataIntoAudioBufferList failed with \(status)")
            return 
        }
        
        // 6. Convert
        var error: NSError? = nil
        
        // Input Block
        var haveFed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
           if !haveFed {
               outStatus.pointee = .haveData
               haveFed = true
               return inputBuffer
           } else {
               outStatus.pointee = .noDataNow
               return nil
           }
        }
        
        outputBuffer.frameLength = outputBuffer.frameCapacity
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        // 7. Write to Ring Buffer
        let convertedFrames = Int(outputBuffer.frameLength)
        
        if convertedFrames > 0, let floatData = outputBuffer.floatChannelData?[0] {
             let telemetry = SmartLevelController.applyInputVolumeAndMeasure(
                floatData, count: convertedFrames, volume: realtimeInputVolume)
             recordInputTelemetry(rawPeak: telemetry.rawPeak,
                                  trimmedPeak: telemetry.trimmedPeak,
                                  rms: telemetry.trimmedRMS,
                                  rawClipSamples: telemetry.rawClipSamples,
                                  trimmedHotSamples: telemetry.trimmedHotSamples)

             _ = self.ringBuffer.write(floatData, count: convertedFrames)
        }
    }
}
