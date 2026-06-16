import SwiftUI
import CoreAudio
import Core

struct SettingsView: View {
    @ObservedObject var audioModel: AudioModel
    @ObservedObject var hotkeyManager: HotkeyManager
    @ObservedObject var updaterController: UpdaterController

    var body: some View {
        TabView {
            GeneralSettingsView(audioModel: audioModel, meterModel: audioModel.meterModel, updaterController: updaterController)
                .tabItem {
                    Label("General", systemImage: "slider.horizontal.3")
                }

            HotkeySettingsView(manager: hotkeyManager)
                .tabItem {
                    Label("Hotkeys", systemImage: "keyboard")
                }

            GuideView()
                .tabItem {
                    Label("Setup Guide", systemImage: "book.pages")
                }
        }
        .padding(20)
        .frame(minWidth: 500, minHeight: 440)
    }
}

// MARK: - General Tab

struct GeneralSettingsView: View {
    @ObservedObject var audioModel: AudioModel
    // Live diagnostics (clip/ceiling warnings, Smart Level message, integrated LUFS) now live on
    // MeterModel — observe it so the Settings readouts stay live while the popover is closed.
    @ObservedObject var meterModel: MeterModel
    @ObservedObject var updaterController: UpdaterController

    @State private var isShowingSaveSheet = false
    @State private var newProfileName: String = ""
    @State private var renameTargetID: UUID? = nil
    @State private var renameText: String = ""
    @State private var isShowingResetConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                brandedHeader
                suppressionCard
                inputVolumeCard
                profilesCard
                gainCard
                incomingCard
                loudnessCard
                resetCard
                footer
            }
            .padding(.trailing, 2)
        }
        .alert("Reset settings?", isPresented: $isShowingResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                withAnimation { audioModel.resetSettingsToDefaults() }
            }
        } message: {
            Text("This restores NoNoise Mac audio and device settings to defaults. Saved Voice Profiles and custom Hotkeys are kept.")
        }
    }

    private var brandedHeader: some View {
        HStack(spacing: 12) {
            logo
            VStack(alignment: .leading, spacing: 2) {
                Text("NoNoise Mac")
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.bold)
                Text("Real-time, on-device AI noise cancellation for macOS")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private var logo: some View {
        NoNoiseLogoAsset()
        .frame(width: 40, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: Suppression

    private var suppressionCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Noise Suppression", systemImage: "waveform.badge.magnifyingglass")

            Picker("", selection: $audioModel.selectedPreset) {
                ForEach(VoicePreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            sliderRow(
                title: "Suppression Strength",
                value: "\(Int(audioModel.suppressionStrength * 100))%",
                help: "How much noise to remove. Lower keeps more of your original sound."
            ) {
                Slider(value: $audioModel.suppressionStrength, in: 0...1).tint(.accentColor)
            }

            sliderRow(
                title: "Reduction Limit",
                value: audioModel.attenuationLimitDb >= VoicePreset.maxAttenuationDb
                    ? "Max" : "\(Int(audioModel.attenuationLimitDb)) dB",
                help: "Caps how much background is removed so your voice keeps a natural tone. Higher = more aggressive."
            ) {
                Slider(value: $audioModel.attenuationLimitDb,
                       in: VoicePreset.minAttenuationDb...VoicePreset.maxAttenuationDb).tint(.accentColor)
            }

            Divider()

            Toggle(isOn: $audioModel.voicePolishEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice Polish").font(.subheadline)
                    Text("Tone + leveling for podcasts & tutorials. Off in Meeting mode.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Broadcast Voice").font(.subheadline)
                Picker("", selection: $audioModel.clarityLevel) {
                    ForEach(ClarityLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text("Adds studio presence and clarity while keeping your natural voice — sibilance is tamed automatically, so “crisp” never turns harsh.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Mouth Noise").font(.subheadline)
                Picker("", selection: $audioModel.mouthNoiseLevel) {
                    ForEach(MouthNoiseLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                Text("Tames P-pops and lip-smacks. De-plosive ducks low-band thumps; de-click masks short mouth clicks. Off = no processing added.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .nnCard()
    }

    // MARK: Input volume & Smart Level

    private var inputVolumeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader("Input Volume", systemImage: "mic.fill")
                Spacer()
                Text("\(Int(audioModel.inputVolumeValue * 100))%")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Image(systemName: "mic.fill").foregroundColor(.secondary).font(.caption)
                Slider(value: $audioModel.inputVolumeValue, in: 0.25...1.0).tint(.accentColor)
                Image(systemName: "mic.fill").foregroundColor(.secondary).font(.caption)
            }

            Text("Lowers your mic before NoNoise processing. Use this if your voice sounds clipped, crushed, or too loud even when speaking normally.")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Spacer()
                Button("Reset to 80%") {
                    withAnimation { audioModel.inputVolumeValue = SmartLevelController.defaultInputVolume }
                }
                .controlSize(.small)
            }

            if meterModel.isSourceMicClipping {
                Label("Source mic is clipping before NoNoise. Lower macOS/device input volume if available.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            if meterModel.isInputNearCeiling {
                Label("Input too loud", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Divider()

            Toggle(isOn: $audioModel.smartLevelEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart Level").font(.subheadline)
                    Text("Automatically lowers Input Volume or Output Gain when your voice repeatedly hits the ceiling.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)

            if let msg = meterModel.smartLevelMessage {
                Text(msg).font(.caption).foregroundColor(.secondary)
            }
        }
        .nnCard()
    }

    // MARK: - Voice Profiles

    private var profilesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader("Voice Profiles", systemImage: "person.crop.rectangle.stack")
                Spacer()
                Button {
                    newProfileName = ""
                    isShowingSaveSheet = true
                } label: {
                    Label("Save Current", systemImage: "plus")
                        .font(.caption)
                }
                .controlSize(.small)
            }

            if audioModel.profiles.isEmpty {
                Text("No profiles saved yet. Dial in your settings and tap \"Save Current\".")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(audioModel.profiles) { profile in
                    profileRow(profile)
                    if profile.id != audioModel.profiles.last?.id {
                        Divider()
                    }
                }
            }
        }
        .nnCard()
        // "Save Current" sheet — presented as a SwiftUI sheet over the settings window.
        .sheet(isPresented: $isShowingSaveSheet) {
            saveProfileSheet
        }
    }

    private func profileRow(_ profile: VoiceProfile) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(profile.preset.label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button("Recall") {
                audioModel.applyProfile(profile)
            }
            .controlSize(.small)
            .buttonStyle(.bordered)

            Button {
                renameTargetID = profile.id
                renameText = profile.name
            } label: {
                Image(systemName: "pencil")
            }
            .controlSize(.small)
            .help("Rename this profile")
            .popover(isPresented: Binding(
                get: { renameTargetID == profile.id },
                set: { if !$0 { renameTargetID = nil } }
            )) {
                renamePopover(for: profile)
            }

            Button(role: .destructive) {
                audioModel.deleteProfile(id: profile.id)
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("Delete this profile")
        }
    }

    private var saveProfileSheet: some View {
        VStack(spacing: 16) {
            Text("Save Profile")
                .font(.headline)
            Text("Name this snapshot of your current settings.")
                .font(.caption)
                .foregroundColor(.secondary)
            TextField("Profile name", text: $newProfileName)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 260)
                .onSubmit { commitSave() }
            HStack {
                Button("Cancel") { isShowingSaveSheet = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { commitSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 300)
    }

    private func renamePopover(for profile: VoiceProfile) -> some View {
        HStack(spacing: 8) {
            TextField("New name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160)
                .onSubmit { commitRename(id: profile.id) }
            Button("OK") { commitRename(id: profile.id) }
                .controlSize(.small)
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(10)
    }

    private func commitSave() {
        let trimmed = newProfileName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        audioModel.saveCurrentAsProfile(name: trimmed)
        isShowingSaveSheet = false
    }

    private func commitRename(id: UUID) {
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        audioModel.renameProfile(id: id, to: trimmed)
        renameTargetID = nil
    }

    // MARK: Output gain

    private var gainCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader("Output Gain", systemImage: "speaker.wave.2.fill")
                Spacer()
                Text("\(Int(audioModel.outputGainValue * 100))%")
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 10) {
                Image(systemName: "speaker.fill").foregroundColor(.secondary).font(.caption)
                Slider(value: $audioModel.outputGainValue, in: 0.5...4.0).tint(.accentColor)
                Image(systemName: "speaker.wave.3.fill").foregroundColor(.secondary).font(.caption)
            }

            Text("Boost the volume if the noise suppression makes your voice too quiet.")
                .font(.caption)
                .foregroundColor(.secondary)

            if meterModel.isOutputClipping {
                Label("Output clipping", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            HStack {
                Spacer()
                Button("Reset to 100%") {
                    withAnimation { audioModel.outputGainValue = 1.0 }
                }
                .controlSize(.small)
            }
        }
        .nnCard()
    }

    // MARK: Clean Incoming / Guest

    private var incomingCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader("Clean Incoming / Guest", systemImage: "person.wave.2.fill")

            Toggle(isOn: $audioModel.incomingCleanupEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean the other side").font(.subheadline)
                    Text("De-noise everyone you hear (guests/callers). Captures all system audio except NoNoise, cleans it, and plays to your current output — no loopback or extra setup.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(!audioModel.isIncomingCleanupAvailable)

            if let caption = incomingStatusCaption {
                Label(caption, systemImage: incomingStatusIcon)
                    .font(.caption).foregroundColor(incomingStatusColor)
            }
        }
        .nnCard()
    }

    /// Status line driven by the never-lying `incomingCleanupStatus` (not the raw persisted flag).
    private var incomingStatusCaption: String? {
        switch audioModel.incomingCleanupStatus {
        case .unavailable: return "Requires macOS 14.4 or later"
        case .off:         return nil
        case .cleaning:    return "Cleaning all incoming audio"
        case .failed:      return "Couldn’t start — allow audio capture in System Settings ▸ Privacy & Security"
        }
    }

    private var incomingStatusIcon: String {
        switch audioModel.incomingCleanupStatus {
        case .cleaning:    return "checkmark.circle.fill"
        case .failed:      return "exclamationmark.triangle.fill"
        default:           return "info.circle"
        }
    }

    private var incomingStatusColor: Color {
        switch audioModel.incomingCleanupStatus {
        case .failed: return .orange
        default:      return .secondary
        }
    }

    // MARK: Loudness (LUFS) + normalization

    private var loudnessCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionHeader("Loudness", systemImage: "speaker.wave.2.circle.fill")
                Spacer()
                Text(meterModel.integratedLUFS <= LoudnessMeter.silenceLUFS + 1
                     ? "— LUFS" : String(format: "%.1f LUFS", meterModel.integratedLUFS))
                    .font(.callout).monospacedDigit().foregroundColor(.secondary)
            }
            Toggle(isOn: $audioModel.loudnessNormEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Normalize Loudness").font(.subheadline)
                    Text("Gently rides gain toward a target level so you’re consistent across calls and recordings.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            Picker("Target", selection: $audioModel.loudnessTargetLUFS) {
                Text("−14 LUFS (YouTube / Spotify)").tag(Float(-14))
                Text("−16 LUFS (Apple Podcasts)").tag(Float(-16))
            }
            .pickerStyle(.menu)
            .disabled(!audioModel.loudnessNormEnabled)
            Text("Peak-safe: a limiter caps the output just below clipping (≈ −1 dBFS). Loudness is K-weighted (ITU-R BS.1770); peak is sample-peak, not certified true-peak.")
                .font(.caption2).foregroundColor(.secondary)
        }
        .nnCard()
    }

    private var resetCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                sectionHeader("Reset Settings", systemImage: "arrow.counterclockwise")
                Text("Restore audio and device settings to defaults. Voice Profiles and Hotkeys are kept.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                isShowingResetConfirmation = true
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .controlSize(.small)
        }
        .nnCard()
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundColor(.secondary)
            Text("NoNoise Mac v1.0.0 • Built with DeepFilterNet")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
            Link(destination: SupportLinks.reportIssueOrFeature) {
                Label("Report Issue", systemImage: "exclamationmark.bubble")
            }
            .controlSize(.small)
            Button {
                updaterController.checkForUpdates()
            } label: {
                Label("Check for Updates", systemImage: "arrow.down.circle")
            }
            .controlSize(.small)
            .disabled(!updaterController.canCheckForUpdates)
        }
        .padding(.top, 2)
    }

    // MARK: Helpers

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline)
            .fontWeight(.semibold)
    }

    private func sliderRow<Control: View>(
        title: String, value: String, help: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(value)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
            control()
            Text(help).font(.caption).foregroundColor(.secondary)
        }
    }
}

// MARK: - Hotkey Settings

struct HotkeySettingsView: View {
    @ObservedObject var manager: HotkeyManager
    @State private var rebindingAction: HotkeyActionID?

    private let actionLabels: [(HotkeyActionID, String)] = [
        (.toggleAI,        "Toggle Noise Cancellation"),
        (.bypassMomentary, "A/B Bypass (hold for raw)"),
        (.bypassToggle,    "A/B Bypass (toggle)"),
        (.presetNext,      "Preset → Next"),
        (.presetPrev,      "Preset → Previous"),
        (.clarityNext,     "Broadcast Voice → Next Level"),
        (.gainUp,          "Output Gain +"),
        (.gainDown,        "Output Gain −"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Global Hotkeys")
                .font(.title3).fontWeight(.semibold)
                .padding(.bottom, 12)

            ForEach(actionLabels, id: \.0) { (id, label) in
                hotkeyRow(id: id, label: label)
                Divider()
            }

            if !manager.conflictedActions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("Some hotkeys conflict with another app. Rebind them or change the conflicting app's shortcuts.")
                        .font(.caption).foregroundColor(.secondary)
                }
                .padding(.top, 10)
            }
        }
        .padding()
        .sheet(item: $rebindingAction) { id in
            RebindSheet(actionID: id, manager: manager)
        }
    }

    private func hotkeyRow(id: HotkeyActionID, label: String) -> some View {
        HStack {
            Text(label).frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            if manager.conflictedActions.contains(id) {
                Image(systemName: "exclamationmark.circle.fill").foregroundColor(.orange)
                    .help("This combo is in use by another app")
            }
            if let b = manager.bindings[id] {
                Text(hotkeyDisplayString(b))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            } else {
                Text("—").foregroundColor(.secondary)
            }
            Button("Edit") { rebindingAction = id }
                .controlSize(.small)
        }
        .padding(.vertical, 6)
    }

    private func hotkeyDisplayString(_ b: HotkeyBinding) -> String {
        var s = ""
        // b.modifiers is a plain UInt32 (Core HotkeyModifier bits) — test bits directly.
        let m = b.modifiers
        if m & HotkeyModifier.control.rawValue != 0 { s += "⌃" }
        if m & HotkeyModifier.option.rawValue  != 0 { s += "⌥" }
        if m & HotkeyModifier.shift.rawValue   != 0 { s += "⇧" }
        if m & HotkeyModifier.command.rawValue != 0 { s += "⌘" }
        // Map common kVK codes to printable glyphs (non-exhaustive — covers the default set).
        let keyGlyphs: [UInt32: String] = [
            0x2D: "N", 0x0B: "B", 0x1E: "]", 0x21: "[", 0x08: "C",
            0x18: "=", 0x1B: "-",
        ]
        s += keyGlyphs[b.keyCode] ?? "?\(b.keyCode)"
        return s
    }
}

// HotkeyActionID is declared in Core; add Identifiable conformance here (App-only, for SwiftUI).
extension HotkeyActionID: Identifiable {
    public var id: String { rawValue }
}

// MARK: - Rebind sheet

/// Key-capture sheet: wait for the user to press a key combo, then commit it.
/// Uses an invisible NSView subclass that overrides keyDown to capture the event.
struct RebindSheet: View {
    let actionID: HotkeyActionID
    @ObservedObject var manager: HotkeyManager
    @Environment(\.dismiss) var dismiss
    @State private var capturedBinding: HotkeyBinding?
    @State private var conflict: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Press a new key combo for:")
            Text(actionID.id.replacingOccurrences(of: "mv.hotkey.", with: ""))
                .font(.headline)
            KeyCaptureView { binding in
                capturedBinding = binding
                conflict = false
            }
            .frame(width: 200, height: 44)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1.5))
            if let b = capturedBinding {
                Text("New: \(b.encoded)").font(.caption).foregroundColor(.secondary)
            }
            if conflict {
                Text("That combo is in use by another app.").foregroundColor(.orange).font(.caption)
            }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    if let b = capturedBinding {
                        let ok = manager.rebind(action: actionID, to: b)
                        if ok { dismiss() } else { conflict = true }
                    }
                }
                .disabled(capturedBinding == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

/// NSViewRepresentable that captures the next key-down event and reports it
/// as a `HotkeyBinding` via the callback. The view becomes first responder
/// on appear to receive key events without Accessibility permission.
struct KeyCaptureView: NSViewRepresentable {
    var onCapture: (HotkeyBinding) -> Void

    func makeNSView(context: Context) -> _KeyCaptureNSView {
        let v = _KeyCaptureNSView()
        v.onCapture = onCapture
        return v
    }

    func updateNSView(_ nsView: _KeyCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
    }
}

final class _KeyCaptureNSView: NSView {
    var onCapture: ((HotkeyBinding) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // Ignore bare modifiers; wait for a real key code.
        guard event.keyCode != 0xFF else { return }
        // Adapt NSEvent.ModifierFlags → plain UInt32 mask at the App boundary. The relevant bits
        // (command/option/shift/control) share the same raw values as Core's HotkeyModifier, so
        // the masked rawValue maps 1:1.
        let masked = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let binding = HotkeyBinding(keyCode: UInt32(event.keyCode),
                                    modifiers: UInt32(masked.rawValue))
        onCapture?(binding)
    }
}

// MARK: - Guide Tab

struct GuideView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Quick Setup")
                    .font(.headline)
                    .padding(.bottom, 2)

                StepRow(number: 1, title: "Install NoNoise Mic",
                        description: "Run ./build-driver.sh then sudo ./install-driver.sh once. This adds a 'NoNoise Mic' microphone that any app can select directly — no BlackHole needed.")
                Divider()
                StepRow(number: 2, title: "Input: Your Microphone",
                        description: "Select your real physical microphone (e.g. Built-in, USB Mic) as the Input Device. Output is automatic — cleaned audio is routed to the hidden 'NoNoise Mic Engine'; there is no Output Device to choose.")
                Divider()
                StepRow(number: 3, title: "Chat App: Pick 'NoNoise Mic'",
                        description: "In Slack, Zoom, Meet, Discord, or OBS, set the Microphone to 'NoNoise Mic'.")
                Divider()
                StepRow(number: 4, title: "You're Live",
                        description: "Noise cancellation is ON by default. Toggle it any time from the menu bar. Your voice is now crystal clear!")
                Divider()
                StepRow(number: 5, title: "Clean the Guest (optional)",
                        description: "To de-noise the people you HEAR, turn on Clean Incoming / Guest in Settings. NoNoise captures all system audio except itself, cleans it, and re-plays it to your current output automatically — no loopback or routing needed (requires macOS 14.4+).")

                HStack {
                    Spacer()
                    Label("No driver? Fallback: set the Output Device to 'BlackHole 2ch' and point your chat app's microphone at 'BlackHole 2ch' instead.",
                          systemImage: "lightbulb.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.accentColor.opacity(0.08))
                )
            }
            .padding(.trailing)
        }
    }
}

struct StepRow: View {
    let number: Int
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 26, height: 26)
                Text("\(number)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.accentColor)
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}
