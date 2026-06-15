import SwiftUI
import CoreAudio
import Core

struct ContentView: View {
    @ObservedObject var audioModel: AudioModel

    var body: some View {
        VStack(spacing: 14) {
            header
            statusCard
            modeCard
            devicesCard
            driverStatusRow
            footer
        }
        .padding(16)
        .frame(width: 320)
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
                WindowManager.openSettings(model: audioModel)
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
                Toggle("", isOn: $audioModel.isAIEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(.green)
            }

            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                MeterView(level: audioModel.inputLevel)
                    .frame(height: 6)
            }
        }
        .nnCard(highlighted: on)
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

    // MARK: - Devices

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                cardLabel("Input", systemImage: "mic.fill")
                Picker("", selection: $audioModel.selectedInputDeviceID) {
                    ForEach(audioModel.inputDevices, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                cardLabel("Output", systemImage: "speaker.wave.2.fill")
                if audioModel.driverInstalled {
                    // Output is auto-routed to the hidden "NoNoise Mic Engine", which is intentionally
                    // absent from outputDevices — so a picker here would render empty. Show the routing
                    // instead. The picker remains for the BlackHole fallback (driver not installed).
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars").font(.caption2).foregroundColor(.secondary)
                        Text("Automatic → NoNoise Mic").font(.caption).foregroundColor(.secondary)
                    }
                } else {
                    Picker("", selection: $audioModel.selectedOutputDeviceID) {
                        ForEach(audioModel.outputDevices) { device in
                            Text(device.name).tag(device.id)
                        }
                    }
                    .labelsHidden()
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
                WindowManager.openSettings(model: audioModel)
            } label: {
                Label("Settings", systemImage: "slider.horizontal.3")
            }
            .controlSize(.small)

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

    static func openSettings(model: AudioModel) {
        if settingsWindow == nil {
            let view = SettingsView(audioModel: model)
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

            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: panel, queue: nil) { _ in
                settingsWindow = nil
            }
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
