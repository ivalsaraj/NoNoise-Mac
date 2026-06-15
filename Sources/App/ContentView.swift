import SwiftUI
import CoreAudio
import Core

struct ContentView: View {
    @ObservedObject var audioModel: AudioModel
    @ObservedObject var dispatcher: ActionDispatcher
    @ObservedObject var hotkeyManager: HotkeyManager
    @ObservedObject var updaterController: UpdaterController

    var body: some View {
        VStack(spacing: 14) {
            header
            statusCard
            bypassBanner
            modeCard
            LiveHUDCard(meter: audioModel.meterModel, addedLatencyMs: audioModel.addedLatencyMs)
            clarityCard
            incomingCard
            mouthNoiseCard
            devicesCard
            driverStatusRow
            footer
        }
        .animation(.easeInOut(duration: 0.18), value: dispatcher.isBypassed)
        .padding(16)
        .frame(width: 320)
        // Drive the gated UI-meter publish loop only while the popover is on screen. The control
        // pump (Smart Level + loudness) keeps running always — see AudioModel.beginMeterObservation.
        .onAppear { audioModel.beginMeterObservation(.popover) }
        .onDisappear { audioModel.endMeterObservation(.popover) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            logo
            VStack(alignment: .leading, spacing: 1) {
                Text("NoNoise Mac")
                    .font(.system(.headline, design: .rounded))
                    .fontWeight(.bold)
                Text("Noise Cancellation")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                WindowManager.openSettings(model: audioModel, hotkeyManager: hotkeyManager)
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
    }

    private var logo: some View {
        NoNoiseLogoAsset()
        .frame(width: 38, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Status / master toggle (hero)

    private var statusCard: some View {
        let on = audioModel.isAIEnabled
        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(on ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12))
                        .frame(width: 42, height: 42)
                    Image(systemName: on ? "waveform.badge.magnifyingglass" : "waveform.slash")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(on ? .accentColor : .secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Noise Cancellation")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text(on ? "Active · DeepFilterNet AI" : "Off · Passthrough")
                        .font(.caption)
                        .foregroundColor(on ? .green : .secondary)
                }
                Spacer()
                // Route through the dispatcher so a UI flip uses the SAME desired-vs-effective
                // path as the toggle-AI hotkey, and disable it during bypass so the user can't
                // re-enable AI processing against an active A/B bypass (finding #2).
                Toggle("", isOn: dispatcher.aiToggleBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
                    .disabled(dispatcher.isBypassed)
                    .help(dispatcher.isBypassed
                          ? "Disabled while A/B bypass is active — release bypass to change AI."
                          : "Toggle Noise Cancellation")
            }

            // Live meters + warnings observe `meterModel` (NOT audioModel), so their 25 Hz
            // refresh re-renders only this subview — the master toggle / title above stay snappy.
            StatusMeters(meter: audioModel.meterModel)
        }
        .nnCard(highlighted: on)
    }

    // MARK: - A/B bypass banner

    @ViewBuilder
    private var bypassBanner: some View {
        if dispatcher.isBypassed {
            HStack(spacing: 8) {
                Image(systemName: "waveform.slash")
                    .foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("A/B Bypass Active").font(.caption).fontWeight(.medium).foregroundColor(.orange)
                    Text("Hearing raw mic — AI off while bypass is on.")
                        .font(.caption2).foregroundColor(.secondary)
                }
                Spacer()
            }
            .nnCard()
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    // MARK: - Mode (presets)

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardLabel("Mode", systemImage: "wand.and.stars")
            Picker("", selection: $audioModel.selectedPreset) {
                ForEach(VoicePreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .nnCard()
    }

    // MARK: - Broadcast Voice (clarity)

    private var clarityCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardLabel("Broadcast Voice", systemImage: "waveform.path.ecg")
            Picker("", selection: $audioModel.clarityLevel) {
                ForEach(ClarityLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .nnCard()
    }

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
                Text(audioModel.incomingSourceUID.isEmpty || audioModel.incomingOutputDeviceID == 0
                     ? "Pick a loopback source and output in Settings."
                    : "Cleaning the guest you hear.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .nnCard()
    }

    // MARK: - Mouth Noise finishers

    private var mouthNoiseCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardLabel("Mouth Noise", systemImage: "mouth.fill")
            Picker("", selection: $audioModel.mouthNoiseLevel) {
                ForEach(MouthNoiseLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
        .nnCard()
    }

    // MARK: - Devices

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                cardLabel("Input", systemImage: "mic.fill")
                    .frame(width: 74, alignment: .leading)
                Picker("", selection: $audioModel.selectedInputDeviceID) {
                    ForEach(audioModel.inputDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            HStack(spacing: 10) {
                cardLabel("Output", systemImage: "speaker.wave.2.fill")
                    .frame(width: 74, alignment: .leading)
                if audioModel.driverInstalled {
                    // Output is auto-routed to the hidden "NoNoise Mic Engine", which is intentionally
                    // absent from outputDevices — so a picker here would render empty. Show the routing
                    // instead. The picker remains for the BlackHole fallback (driver not installed).
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars").font(.caption2).foregroundColor(.secondary)
                        Text("Automatic → NoNoise Mic").font(.caption).foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("", selection: $audioModel.selectedOutputDeviceID) {
                        ForEach(audioModel.outputDevices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .nnCard()
    }

    // MARK: - Driver status
    // The "ready" state is the "✅ Slack will hear you" north-star signal; both states are kept to
    // one compact row (the full health dashboard + system-default-trap warnings are Spec B).
    private var driverStatusRow: some View {
        HStack(spacing: 8) {
            if audioModel.driverInstalled {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text("NoNoise Mic ready").font(.caption).fontWeight(.medium)
                    Text("Pick “NoNoise Mic” as the mic in Slack/Zoom/Meet/OBS.")
                        .font(.caption2).foregroundColor(.secondary)
                }
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("NoNoise Mic not installed").font(.caption).fontWeight(.medium)
                    Text("Run ./install-driver.sh to add the virtual mic.")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .nnCard()
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                WindowManager.openSettings(model: audioModel, hotkeyManager: hotkeyManager)
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .controlSize(.small)

            Link(destination: SupportLinks.reportIssueOrFeature) {
                Label("Report", systemImage: "exclamationmark.bubble")
            }
            .controlSize(.small)

            Button {
                updaterController.checkForUpdates()
            } label: {
                Label("Check for Updates…", systemImage: "arrow.down.circle")
            }
            .controlSize(.small)
            .disabled(!updaterController.canCheckForUpdates)

            Spacer()

            if let error = audioModel.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
                    .help(error)
            }

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
            .controlSize(.small)
            .keyboardShortcut("q")
        }
        .font(.caption)
    }

    private func cardLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundColor(.secondary)
    }
}

// MARK: - Live meter subviews (observe MeterModel, not AudioModel)
// These are the ONLY views that subscribe to the ~25 Hz meter stream. Isolating them here keeps
// the high-frequency invalidation off ContentView's body, so the master toggle, pickers, and
// cards do not rebuild on every meter tick (menu-bar perf fix).

private struct StatusMeters: View {
    @ObservedObject var meter: MeterModel

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                MeterView(level: meter.inputLevel)
                    .frame(height: 6)
            }

            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                MeterView(level: meter.outputLevel)
                    .frame(height: 6)
                if meter.isOutputClipping {
                    Text("CLIP").font(.caption2).fontWeight(.bold).foregroundColor(.red)
                }
            }

            if meter.isInputNearCeiling || meter.isSourceMicClipping || meter.isOutputClipping {
                VStack(alignment: .leading, spacing: 4) {
                    if meter.isSourceMicClipping {
                        Label("Source mic clipping — lower device input volume if available.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    if meter.isInputNearCeiling {
                        Label("Input too loud", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    if meter.isOutputClipping {
                        Label("Output clipping", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                    if let msg = meter.smartLevelMessage {
                        Text(msg).font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        }
    }
}

private struct LiveHUDCard: View {
    @ObservedObject var meter: MeterModel
    let addedLatencyMs: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Live", systemImage: "waveform.path.ecg")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Text("AI").font(.caption2).foregroundColor(.secondary)
                // MeterView scales level ×5 internally; aiActivity is already 0…1, so
                // divide by 5 to use the full bar without a 5× over-scale.
                MeterView(level: meter.aiActivity / 5).frame(height: 6)
            }
            HStack {
                Text(meter.momentaryLUFS <= LoudnessMeter.silenceLUFS + 1
                     ? "— LUFS" : String(format: "%.1f LUFS", meter.momentaryLUFS))
                    .font(.caption).monospacedDigit().foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.0f ms latency", addedLatencyMs))
                    .font(.caption).monospacedDigit().foregroundColor(.secondary)
            }
        }
        .nnCard()
    }
}

// MARK: - Live input meter

struct MeterView: View {
    var level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, min(CGFloat(level) * 5 * geometry.size.width, geometry.size.width)))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
    }
}

// MARK: - Shared card styling (used by ContentView + SettingsView)

extension View {
    /// Consistent rounded "card" container used across NoNoise Mac surfaces.
    func nnCard(highlighted: Bool = false) -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(highlighted ? Color.accentColor.opacity(0.55)
                                              : Color(nsColor: .separatorColor).opacity(0.7),
                                  lineWidth: highlighted ? 1.2 : 0.5)
            )
    }
}

// MARK: - Settings window

class WindowManager {
    static var settingsWindow: NSWindow?

    static func openSettings(model: AudioModel, hotkeyManager: HotkeyManager) {
        if settingsWindow == nil {
            let view = SettingsView(audioModel: model, hotkeyManager: hotkeyManager)
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                backing: .buffered, defer: false)
            panel.center()
            panel.title = "NoNoise Mac Settings"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.contentView = NSHostingView(rootView: view)
            panel.isFloatingPanel = false
            panel.isReleasedWhenClosed = false
            panel.minSize = NSSize(width: 480, height: 420)

            settingsWindow = panel

            // Drive the gated UI-meter publish loop while the Settings window is open so its live
            // diagnostics (clip warnings, Smart Level message, integrated LUFS) stay current even
            // when the popover is closed. Reference-counted in AudioModel, so this composes with
            // the popover's own begin/end. Tied to the window lifecycle (begin on create, end on
            // willClose) rather than SwiftUI onDisappear, which is unreliable for a reused NSPanel.
            model.beginMeterObservation(.settings)

            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: nil) { [weak model] _ in
                settingsWindow = nil
                model?.endMeterObservation(.settings)
            }
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
