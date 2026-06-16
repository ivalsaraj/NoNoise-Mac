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

    // Incoming / guest cleanup (clean the OTHER side) — a SINGLE toggle. Captures all system audio
    // except NoNoise via a Core Audio process tap (macOS 14.4+), cleans it (DFN only), and plays to
    // the current default output (auto-following device changes). No BlackHole, no manual routing.
    // Off by default — the second CoreML stream has real ANE cost, so the engine is created only
    // while enabled (see plan perf note).
    @Published public var incomingCleanupEnabled: Bool = false {
        didSet {
            guard !isApplyingPreset else { return }
            applyIncomingCleanup()
            persistIncomingSettings()
        }
    }
    /// Effective, never-lying state for the UI: `start()` can fail (TCC denied, own-process
    /// unresolved, tap/aggregate creation failed) and the owner then retains NO engine. The toggle
    /// binds to THIS (not the raw persisted flag) so it reflects what's actually happening.
    @Published public private(set) var incomingCleanupStatus: IncomingCleanupStatus = .off

    /// Whether the process-tap path is usable on this OS (macOS 14.4+ is the product floor). The UI
    /// disables the toggle and shows a "requires macOS 14.4" caption when false.
    public var isIncomingCleanupAvailable: Bool {
        if #available(macOS 14.4, *) { return true } else { return false }
    }

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

    /// Mouth-noise finisher level (de-plosive + de-click). Layered on top of the
    /// active preset, independent of the noise preset, Voice Polish, and Broadcast
    /// Voice. Guarded by `isApplyingPreset` like all other knobs.
    @Published public var mouthNoiseLevel: MouthNoiseLevel = .off {
        didSet {
            guard !isApplyingPreset else { return }
            applyVoiceChain()
            persistSettings()
        }
    }

    /// App-level pre-DSP input trim (25%…100%). Does not write macOS hardware volume.
    private var realtimeInputVolume: Float = SmartLevelController.defaultInputVolume

    @Published public var inputVolumeValue: Float = SmartLevelController.defaultInputVolume {
        didSet {
            realtimeInputVolume = SmartLevelController.runtimeInputVolume(for: inputVolumeValue)
            guard !isApplyingPreset else { return }
            persistSettings()
        }
    }

    @Published public var smartLevelEnabled: Bool = false {
        didSet {
            guard !isApplyingPreset else { return }
            // Clear the Smart Level message via the snapshot (the gated UI loop reflects it on the
            // next publish / on reopen). The control pump is the single owner of this field.
            if !smartLevelEnabled { meterSnapshot.smartLevelMessage = nil }
            persistSettings()
        }
    }

    /// Loudness normalization (gentle auto-gain toward target). OFF by default —
    /// default behavior is byte-for-byte unchanged. Guarded like the other knobs.
    @Published public var loudnessNormEnabled: Bool = false {
        didSet {
            guard !isApplyingPreset else { return }
            if !loudnessNormEnabled {            // reset to unity when off (no residual gain)
                currentLoudnessGain = 1
                voiceChain.setLoudnessGain(1.0)
            }
            applyVoiceChain()                    // (re)activate the chain if needed
            persistSettings()
        }
    }
    /// Target integrated loudness in LUFS (e.g. −14 YouTube/Spotify, −16 Apple Podcasts).
    @Published public var loudnessTargetLUFS: Float = -14 {
        didSet { guard !isApplyingPreset else { return }; persistSettings() }
    }

    /// The user's saved Voice Profiles. Persisted as a JSON array under `mv.profiles`.
    /// Mutations go through `saveCurrentAsProfile`, `deleteProfile`, and `renameProfile`
    /// (not direct array mutation) to keep persistence consistent.
    @Published public var profiles: [VoiceProfile] = []

    /// Fixed added latency in ms (ring-buffer target + one STFT frame), computed once.
    /// Low-frequency state — stays on AudioModel (NOT part of the 25 Hz meter stream).
    @Published public var addedLatencyMs: Float = 0.0

    // MARK: Live meter / HUD telemetry — ISOLATED off AudioModel (menu-bar perf fix).
    // The high-frequency (~25 Hz) live-meter fields (input/output level + peaks, AI activity,
    // LUFS, clip/ceiling warnings, Smart Level message) live on `meterModel`, NOT here, so
    // `AudioModel.objectWillChange` no longer fires on every telemetry tick — which decouples the
    // MenuBarExtra Scene/label (it observes AudioModel) from the meter storm. The always-on
    // control pump writes plain `meterSnapshot` fields; the gated UI-publish loop copies them
    // into `meterModel` ONLY while a meter view is on screen (popover or Settings).
    public let meterModel = MeterModel()
    private var meterSnapshot = MeterSnapshot()

    private var isApplyingPreset = false

    // Telemetry scalars written by capture/render; published by the meter timer (~25 Hz).
    private var tInputLevel: Float = 0
    private var tRawInputPeak: Float = 0
    private var tTrimmedInputPeak: Float = 0
    private var tOutputPeak: Float = 0
    private var tOutputClipCount: Int32 = 0
    private var tRawInputClipCount: Int32 = 0
    private var tTrimmedInputHotCount: Int32 = 0
    // Two timers replace the single legacy meter timer (menu-bar perf fix):
    //  • controlPumpTimer — ALWAYS-ON ~25 Hz; owns the t* read-and-reset and runs BOTH audio
    //    control loops (Smart Level + loudness normalization). Non-publishing → zero SwiftUI churn.
    //  • uiPublishTimer — ~25 Hz but GATED to meter-view visibility; copies the snapshot into
    //    `meterModel`. Driven by an active-source set so it never double-starts or leaks.
    private var controlPumpTimer: Timer?
    private var uiPublishTimer: Timer?
    /// A live-meter surface that wants the gated UI-publish loop running. One case per surface so
    /// observation is tracked per-source (idempotent) rather than by a drift-prone counter.
    public enum MeterObserver { case popover, settings }
    /// Meter surfaces currently on screen. The gated UI-publish timer runs iff this set is
    /// non-empty. A Set keyed by source (NOT a blind counter) makes the lifecycle idempotent:
    /// a duplicate begin for the same source is a no-op, and the state self-heals on the next
    /// clean begin/end cycle even if a SwiftUI `onDisappear` / window `willClose` was missed —
    /// so the timer can never be permanently leaked the way a drifting counter could.
    private var activeMeterObservers: Set<MeterObserver> = []
    private var consecutiveTrimmedHotTicks = 0
    private var consecutiveOutputClipTicks = 0
    private var lastSmartLevelAdjustTime: Date?

    // Live HUD / loudness telemetry. The meter is a value-type struct mutated ONLY on
    // the render thread (recordOutputTelemetry); it is NEVER read from main — the render
    // thread copies its getters into the t* scalars below, which the timer reads (no
    // cross-thread struct access). Output peak/clip reuse tOutputPeak / tOutputClipCount.
    private var loudnessMeter = LoudnessMeter()
    private var tOutputLevel: Float = 0
    private var tMomentaryLUFS: Float = LoudnessMeter.silenceLUFS
    private var tIntegratedLUFS: Float = LoudnessMeter.silenceLUFS
    private var currentLoudnessGain: Float = 1

    private enum PrefKey {
        static let preset = SettingsResetPolicy.presetKey
        static let strength = SettingsResetPolicy.strengthKey
        static let atten = SettingsResetPolicy.attenuationKey
        static let gain = SettingsResetPolicy.gainKey
        static let voicePolish = SettingsResetPolicy.voicePolishKey
        static let clarity = SettingsResetPolicy.clarityKey
        static let mouthNoise = SettingsResetPolicy.mouthNoiseKey
        static let inputVolume = SettingsResetPolicy.inputVolumeKey
        static let smartLevel = SettingsResetPolicy.smartLevelKey
        static let incomingEnabled = SettingsResetPolicy.incomingEnabledKey
        static let profiles = SettingsResetPolicy.profilesKey   // Voice Profiles (JSON array)
        static let loudnessNorm = SettingsResetPolicy.loudnessNormKey
        static let loudnessTarget = SettingsResetPolicy.loudnessTargetKey
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
    // OPTIONAL — created only while the feature is enabled (the tap engine allocates MLMultiArrays +
    // async-loads the model; a resident instance would break zero-cost-when-off). Stored as
    // `AnyObject?` so AudioModel itself needn't be `@available(macOS 14.4,*)`: `IncomingCleanupEngine`
    // is gated and only ever constructed/cast inside `#available` blocks (see `applyIncomingCleanup`).
    private var incomingEngine: AnyObject?

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
        // Resolve the virtual mic up front so the first capture config is correctly gated: in
        // on-demand mode we must NOT start the real-mic capture until an app uses "NoNoise Mic".
        micDeviceID = deviceID(forUID: VirtualMicRouting.visibleDeviceUID)
        setupCaptureSession()
        setupPlaybackEngine()
        resolveVirtualMicLifecycle()   // arm the in-use listener + sync initial state
        installHardwareDeviceListener()
        loadSettings()
        // Fixed pipeline latency: ring-buffer target (2400 samples) + one STFT frame
        // (960 samples) @ 48 kHz. Reported as the "added latency" readout, not measured.
        addedLatencyMs = Float(2400 + 960) / 48000.0 * 1000.0   // = 70 ms
        startControlPump()   // always-on audio-control loop (Smart Level + loudness); never gated
    }

    deinit {
        controlPumpTimer?.invalidate()
        uiPublishTimer?.invalidate()
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
        s.mouthNoiseLevel = mouthNoiseLevel
        s.loudnessActive = loudnessNormEnabled   // activate the chain for normalization
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

    // MARK: - Voice Profiles

    /// Capture the current live settings as a named profile and persist.
    /// If `existingID` is provided, the existing profile is updated in place (rename + re-snapshot);
    /// otherwise a new profile with a fresh UUID is created.
    public func saveCurrentAsProfile(name: String, existingID: UUID? = nil) {
        let profile = VoiceProfile(
            id: existingID ?? UUID(),
            name: name,
            preset: selectedPreset,
            suppressionStrength: suppressionStrength,
            attenuationLimitDb: attenuationLimitDb,
            outputGainValue: outputGainValue,
            voicePolishEnabled: voicePolishEnabled,
            clarityLevel: clarityLevel,
            mouthNoiseLevel: mouthNoiseLevel,
            inputVolumeValue: inputVolumeValue,
            smartLevelEnabled: smartLevelEnabled,
            loudnessNormEnabled: loudnessNormEnabled,
            loudnessTargetLUFS: loudnessTargetLUFS
        )
        var store = VoiceProfileStore.from(profiles)
        store.upsert(profile)
        profiles = store.profiles
        persistProfiles()
    }

    /// Apply a saved profile to the live engine. Uses the `isApplyingPreset` guard so:
    /// — setting each @Published property does NOT trigger `onKnobChanged` mid-apply
    /// — `persistSettings` and `applyVoiceChain` are called exactly once, after all values are set
    /// — `selectedPreset` does not spuriously flip to `.custom` during the apply
    ///
    /// Verified by the REQUIRED manual smoke test (step 4 of the smoke test checklist).
    /// `AudioModel.init()` starts CoreAudio/AVCapture, making headless XCTest impossible here.
    public func applyProfile(_ profile: VoiceProfile) {
        isApplyingPreset = true
        // Apply DSP suppression knobs from the profile's stored values (not re-derived from preset,
        // in case the user had manually overridden them before saving).
        suppressionStrength = profile.suppressionStrength
        attenuationLimitDb = profile.attenuationLimitDb
        outputGainValue = profile.outputGainValue
        dspEngine.suppressionStrength = suppressionStrength
        dspEngine.attenuationLimitDb = attenuationLimitDb
        dspEngine.outputGain = outputGainValue
        // Apply voice chain settings.
        voicePolishEnabled = profile.voicePolishEnabled
        clarityLevel = profile.clarityLevel
        if let mouthNoise = profile.mouthNoiseLevel {
            mouthNoiseLevel = mouthNoise
        }
        if let inputVolume = profile.inputVolumeValue {
            inputVolumeValue = SmartLevelController.clampInputVolume(inputVolume)
        }
        if let smartLevel = profile.smartLevelEnabled {
            smartLevelEnabled = smartLevel
        }
        if let loudnessNorm = profile.loudnessNormEnabled {
            loudnessNormEnabled = loudnessNorm
        }
        if let loudnessTarget = profile.loudnessTargetLufs {
            loudnessTargetLUFS = loudnessTarget
        }
        // Apply the preset last so selectedPreset.didSet fires with isApplyingPreset=true,
        // suppressing the re-entry into applyPreset and applyVoiceChain.
        selectedPreset = profile.preset
        isApplyingPreset = false
        // Single reconfigure with the final restored state — matches loadSettings() pattern.
        applyVoiceChain()
        persistSettings()
    }

    /// Delete a saved profile by ID and persist.
    public func deleteProfile(id: UUID) {
        var store = VoiceProfileStore.from(profiles)
        store.remove(id: id)
        profiles = store.profiles
        persistProfiles()
    }

    /// Rename a saved profile and persist.
    public func renameProfile(id: UUID, to newName: String) {
        var store = VoiceProfileStore.from(profiles)
        store.rename(id: id, to: newName)
        profiles = store.profiles
        persistProfiles()
    }

    /// Serialize the current profiles array to UserDefaults under `mv.profiles`.
    private func persistProfiles() {
        guard let data = try? VoiceProfileStore.from(profiles).encodeToJSON() else { return }
        UserDefaults.standard.set(data, forKey: PrefKey.profiles)
    }

    private func persistSettings() {
        let d = UserDefaults.standard
        d.set(selectedPreset.rawValue, forKey: PrefKey.preset)
        d.set(suppressionStrength, forKey: PrefKey.strength)
        d.set(attenuationLimitDb, forKey: PrefKey.atten)
        d.set(outputGainValue, forKey: PrefKey.gain)
        d.set(voicePolishEnabled, forKey: PrefKey.voicePolish)
        d.set(clarityLevel.rawValue, forKey: PrefKey.clarity)
        d.set(mouthNoiseLevel.rawValue, forKey: PrefKey.mouthNoise)
        d.set(inputVolumeValue, forKey: PrefKey.inputVolume)
        d.set(smartLevelEnabled, forKey: PrefKey.smartLevel)
        d.set(loudnessNormEnabled, forKey: PrefKey.loudnessNorm)
        d.set(loudnessTargetLUFS, forKey: PrefKey.loudnessTarget)
    }

    public func resetSettingsToDefaults() {
        SettingsResetPolicy.reset()

        isApplyingPreset = true
        isAIEnabled = true
        selectedPreset = .meeting
        suppressionStrength = 1.0
        attenuationLimitDb = VoicePreset.maxAttenuationDb
        outputGainValue = 1.0
        voicePolishEnabled = true
        clarityLevel = .off
        mouthNoiseLevel = .off
        inputVolumeValue = SmartLevelController.defaultInputVolume
        smartLevelEnabled = false
        incomingCleanupEnabled = false
        loudnessNormEnabled = false
        loudnessTargetLUFS = -14
        isApplyingPreset = false

        meterSnapshot.smartLevelMessage = nil
        currentLoudnessGain = 1
        voiceChain.setLoudnessGain(1.0)
        dspEngine.suppressionStrength = suppressionStrength
        dspEngine.attenuationLimitDb = attenuationLimitDb
        dspEngine.outputGain = outputGainValue

        applyVoiceChain()
        applyIncomingCleanup()
        persistSettings()
        persistIncomingSettings()
    }

    private func loadSettings() {
        let d = UserDefaults.standard
        // Load saved profiles BEFORE any early return. Profiles persist independently of
        // the Tier 1 settings: saveCurrentAsProfile writes only `mv.profiles` (never `mv.preset`),
        // so a user who saved a profile from the default state (no `mv.preset` yet) must still
        // see it on relaunch. Tolerant: corrupt/absent → empty array.
        if let data = d.data(forKey: PrefKey.profiles) {
            profiles = VoiceProfileStore.decodeSafe(from: data).profiles
        }
        guard let raw = d.string(forKey: PrefKey.preset),
              let preset = VoicePreset(rawValue: raw) else {
            // First launch: keep defaults (Meeting) and push them to the DSP.
            inputVolumeValue = SmartLevelController.defaultInputVolume
            applyPreset(.meeting)
            applyVoiceChain()
            applyIncomingCleanup()   // feature off on first launch; sets status (.off or .unavailable)
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
        mouthNoiseLevel = MouthNoiseLevel(rawValue: d.string(forKey: PrefKey.mouthNoise) ?? "") ?? .off
        inputVolumeValue = d.object(forKey: PrefKey.inputVolume) != nil
            ? SmartLevelController.clampInputVolume(d.float(forKey: PrefKey.inputVolume))
            : SmartLevelController.defaultInputVolume
        smartLevelEnabled = d.object(forKey: PrefKey.smartLevel) as? Bool ?? false
        loudnessNormEnabled = d.object(forKey: PrefKey.loudnessNorm) as? Bool ?? false
        loudnessTargetLUFS  = d.object(forKey: PrefKey.loudnessTarget) != nil
            ? d.float(forKey: PrefKey.loudnessTarget) : -14
        // Incoming / guest cleanup (off by default). Restored inside the isApplyingPreset guard so
        // the didSet doesn't re-persist/reconfigure mid-load; the explicit applyIncomingCleanup()
        // below starts it if it was persisted enabled (and resolves the effective status).
        incomingCleanupEnabled = d.bool(forKey: PrefKey.incomingEnabled)
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

    /// Create-or-tear-down the tap-based incoming engine to match `incomingCleanupEnabled`, and
    /// publish the effective `incomingCleanupStatus` for the UI. Off by default — the engine object
    /// (and thus the second DeepFilterNetDSP's allocations + model load) is constructed ONLY when
    /// enabled on a supported OS, and released to nil otherwise, so a disabled feature holds zero
    /// ANE/CPU/memory. Retains the engine ONLY if `start()` returns true (truthful contract): a
    /// failed start (TCC denied, own-process unresolved, tap/aggregate creation failed) leaves no
    /// resident pipeline and surfaces `.failed` so granting permission + re-toggling retries.
    private func applyIncomingCleanup() {
        guard isIncomingCleanupAvailable else {
            // OS < 14.4: never construct the tap engine; the toggle is disabled and shows "unavailable".
            incomingCleanupStatus = .unavailable
            return
        }
        if #available(macOS 14.4, *) {
            if incomingCleanupEnabled {
                // Already genuinely running — don't rebuild the tap on a redundant apply.
                if incomingCleanupStatus == .cleaning, incomingEngine != nil { return }
                let engine = IncomingCleanupEngine()
                // Runtime self-teardown (e.g. default output vanished, re-pin/rebuild failed): release
                // the engine and drop to .failed so the toggle never shows a lying ".cleaning" over a
                // dead pipeline. Delivered on main; weak captures + identity check ignore a late
                // callback from an engine we've already replaced or disabled.
                engine.onRuntimeFailure = { [weak self, weak engine] in
                    guard let self = self, let engine = engine,
                          self.incomingEngine === engine else { return }
                    self.incomingEngine = nil
                    self.incomingCleanupStatus = .failed
                }
                if engine.start() {
                    incomingEngine = engine
                    incomingCleanupStatus = .cleaning
                } else {
                    engine.stop()
                    incomingEngine = nil
                    incomingCleanupStatus = .failed   // toggle stays on; retry on re-toggle after TCC grant
                }
            } else {
                (incomingEngine as? IncomingCleanupEngine)?.stop()
                incomingEngine = nil
                incomingCleanupStatus = .off
            }
        }
    }

    private func persistIncomingSettings() {
        UserDefaults.standard.set(incomingCleanupEnabled, forKey: PrefKey.incomingEnabled)
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

    /// Shared HAL reader: name + REAL uid + hidden flag + output capability. Used by
    /// `fetchOutputDevices` (route-target enumeration) and the engine-route translate.
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

        // Output capability — SUM the AudioBufferList channel counts; do NOT trust the property data
        // size alone. kAudioDevicePropertyStreamConfiguration returns a non-empty AudioBufferList
        // header even when a scope has ZERO streams (mNumberBuffers == 0), so a `size > 0` check
        // reports phantom channels and would misclassify devices (e.g. an input-only mic offered as
        // an output). Only a positive mNumberChannels sum proves the scope actually has channels.
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
        let hasOutput = channelCount(scope: kAudioObjectPropertyScopeOutput) > 0

        return VirtualMicRouting.DeviceInfo(uid: realUID, name: name, isHidden: hidden != 0,
                                            hasOutput: hasOutput)
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

        for id in deviceIDs {
            // Shared HAL read (name/uid/hidden/output capability). `hasOutput` comes from the reader,
            // so the old inline `if size > 0` output guard becomes `info.hasOutput`.
            guard let info = deviceInfo(for: id) else { continue }
            if info.hasOutput {
                allDevs.append(info)
                uidToID[info.uid] = id
                if VirtualMicRouting.isSelectableOutput(info) {   // exclude hidden + our engine from the user's picker
                    newDevs.append(DeviceStruct(id: id, name: info.name))
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
        resolveVirtualMicLifecycle()
        // The incoming tap engine is NOT re-applied here: it captures all-system-minus-NoNoise (so
        // device add/remove doesn't change its source) and follows the default output via its own
        // HAL listener + AVAudioEngineConfigurationChange observer. Re-applying would needlessly
        // rebuild the tap on every hardware change.
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

    // MARK: Control pump (always-on) vs UI publish (gated) — see "Metering & loudness" in AGENTS.md.

    /// Start the ALWAYS-ON audio-control pump. Created once at init and lives for the app's
    /// lifetime — it is the single owner of the `t*` read-and-reset and runs BOTH control loops
    /// (Smart Level + loudness normalization) regardless of popover/Settings visibility. It writes
    /// ONLY plain `meterSnapshot` fields, so it triggers ZERO SwiftUI invalidation. The 25 Hz
    /// cadence is preserved so the loudness slew (`slewDb:1`/tick ≈ 25 dB/s) and the Smart Level
    /// tick thresholds keep their tuned timing unchanged.
    private func startControlPump() {
        controlPumpTimer?.invalidate()
        controlPumpTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            self?.runControlPump()
        }
    }

    private func runControlPump() {
        let rawPeak = tRawInputPeak
        let trimmedPeak = tTrimmedInputPeak
        let outPeak = tOutputPeak
        let outputClipCount = tOutputClipCount
        // Input-side meter + Smart Level contract goes through the pure helper so the raw
        // (source) vs trimmed (processed) split matches what SmartLevelControllerTests prove.
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

        consecutiveTrimmedHotTicks = inputDecision.consecutiveTrimmedHotTicks

        let outputClipping = SmartLevelController.isClipping(outPeak) || outputClipCount > 0

        // Write derived telemetry into the plain snapshot ONLY (read by the gated UI publish loop).
        // NO @Published is touched here → zero SwiftUI invalidation while the pump runs at 25 Hz.
        meterSnapshot.inputLevel = inputDecision.inputLevel
        meterSnapshot.rawInputPeak = rawPeak
        meterSnapshot.trimmedInputPeak = trimmedPeak
        meterSnapshot.outputPeak = outPeak
        meterSnapshot.isInputNearCeiling = inputDecision.isInputNearCeiling
        meterSnapshot.isOutputClipping = outputClipping
        meterSnapshot.isSourceMicClipping = inputDecision.isSourceMicClipping
        // Live HUD: output level/peak/clip + LUFS update whenever audio flows (recordOutputTelemetry
        // runs regardless of AI, like Smart Level). AI activity is AI-specific, so it reads 0 when
        // AI is off (the DSP scalar would otherwise freeze at its last value — no processHop runs).
        meterSnapshot.outputLevel = tOutputLevel
        meterSnapshot.aiActivity = isAIEnabled ? dspEngine.aiActivity : 0
        meterSnapshot.momentaryLUFS = tMomentaryLUFS
        meterSnapshot.integratedLUFS = tIntegratedLUFS

        // Loudness normalization control loop — ALWAYS-ON (gated only by the feature flag, never by
        // popover visibility). Slew-limited make-up gain computed on main from the integrated-LUFS
        // snapshot and pushed to the chain (lock-free scalar). When the meter has no measurement
        // (silence below the gate), the gain is held — no pumping.
        if loudnessNormEnabled {
            let g = LoudnessMeter.normalizationGain(
                measuredLUFS: tIntegratedLUFS, targetLUFS: loudnessTargetLUFS,
                currentGain: currentLoudnessGain, maxDb: 12, slewDb: 1)  // ~1 dB/tick → smooth
            currentLoudnessGain = g
            voiceChain.setLoudnessGain(g)
        }
        consecutiveOutputClipTicks = SmartLevelController.advanceHotTicks(
            current: consecutiveOutputClipTicks, wasHot: outputClipping)

        // Single owner of the render/capture-written t* read-and-reset (the UI publish loop is
        // snapshot-read-only and never resets these — prevents the double-consume / starvation hazard).
        tInputLevel = 0
        tRawInputPeak = 0
        tTrimmedInputPeak = 0
        tOutputPeak = 0
        tOutputLevel = 0
        tOutputClipCount = 0
        tRawInputClipCount = 0
        tTrimmedInputHotCount = 0

        updateSmartLevel()
    }

    /// Begin observing the live meters for `source` (e.g. the popover's `onAppear`). The popover
    /// and the Settings window observe through ONE shared UI-publish timer, started on the
    /// empty → non-empty transition. Idempotent: a duplicate begin for the same source is a no-op
    /// (Set insert), so a stray/repeated `onAppear` can never spawn a second timer or inflate the
    /// state. Seeds `meterModel` from the latest snapshot BEFORE the first timed publish so the
    /// first visible frame after a closed interval is correct, not stale.
    public func beginMeterObservation(_ source: MeterObserver) {
        let wasEmpty = activeMeterObservers.isEmpty
        activeMeterObservers.insert(source)
        guard wasEmpty, uiPublishTimer == nil else { return }
        meterModel.apply(meterSnapshot)
        uiPublishTimer = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.meterModel.apply(self.meterSnapshot)
        }
    }

    /// End observing the live meters for `source` (e.g. the popover's `onDisappear`). Stops the
    /// UI-publish timer only when the LAST surface goes away; the always-on control pump keeps
    /// running so Smart Level + loudness normalization stay live with every meter view closed.
    /// Idempotent: ending an inactive source is a no-op, and because each source is tracked
    /// independently the state self-heals on the next clean cycle even if an end was missed.
    public func endMeterObservation(_ source: MeterObserver) {
        guard activeMeterObservers.remove(source) != nil else { return }
        guard activeMeterObservers.isEmpty else { return }
        uiPublishTimer?.invalidate()
        uiPublishTimer = nil
    }

    private func updateSmartLevel() {
        guard smartLevelEnabled else { return }
        let now = Date()
        if let last = lastSmartLevelAdjustTime, now.timeIntervalSince(last) < 0.4 { return }

        if meterSnapshot.isSourceMicClipping {
            meterSnapshot.smartLevelMessage = "Source mic is clipping before NoNoise. Lower macOS/device input volume if available."
        }

        if let next = SmartLevelController.nextInputVolume(
            current: inputVolumeValue, hotTicks: consecutiveTrimmedHotTicks, enabled: smartLevelEnabled) {
            setInputVolume(next)
            consecutiveTrimmedHotTicks = 0
            lastSmartLevelAdjustTime = now
            meterSnapshot.smartLevelMessage = "Smart Level reduced Input Volume to \(Int(next * 100))%."
            return
        }

        if let next = SmartLevelController.nextOutputGain(
            current: outputGainValue, outputClipTicks: consecutiveOutputClipTicks,
            inputHotTicks: consecutiveTrimmedHotTicks, enabled: smartLevelEnabled) {
            setOutputGainForSmartLevel(next)
            consecutiveOutputClipTicks = 0
            lastSmartLevelAdjustTime = now
            meterSnapshot.smartLevelMessage = "Smart Level reduced Output Gain to \(Int(next * 100))%."
        } else if !meterSnapshot.isInputNearCeiling && !meterSnapshot.isOutputClipping && !meterSnapshot.isSourceMicClipping {
            meterSnapshot.smartLevelMessage = nil
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
        var sumSq: Float = 0
        for i in 0..<count {
            let s = data[i]
            let mag = abs(s)
            peak = max(peak, mag)
            if mag >= SmartLevelController.clipThreshold { clipCount &+= 1 }
            sumSq += s * s
            loudnessMeter.process(s)   // K-weighted BS.1770 loudness + sample-peak (render thread only)
        }
        tOutputPeak = peak
        tOutputClipCount = clipCount
        tOutputLevel = sqrtf(sumSq / Float(max(count, 1)))
        // Snapshot the meter getters into plain scalars (render thread only) so the UI
        // timer never touches the meter struct cross-thread.
        tMomentaryLUFS = loudnessMeter.momentaryLUFS
        tIntegratedLUFS = loudnessMeter.integratedLUFS
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
             // Trim in place and measure raw (source) + trimmed (NoNoise input) levels in one
             // allocation-free helper (raw scan → in-place trim → trimmed scan). The meter must
             // reflect the trimmed signal that enters ringBuffer.write, while raw peak/clip still
             // report physical/source clipping that trim cannot repair.
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
