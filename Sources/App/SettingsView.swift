import SwiftUI
import Core

struct SettingsView: View {
    @ObservedObject var audioModel: AudioModel

    var body: some View {
        TabView {
            GeneralSettingsView(audioModel: audioModel)
                .tabItem {
                    Label("General", systemImage: "slider.horizontal.3")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                brandedHeader
                suppressionCard
                gainCard
                footer
            }
            .padding(.trailing, 2)
        }
    }

    private var brandedHeader: some View {
        HStack(spacing: 12) {
            logo
            VStack(alignment: .leading, spacing: 2) {
                Text("NoNoise Mac")
                    .font(.system(.title3, design: .rounded))
                    .fontWeight(.bold)
                Text("Real-time, on-device noise cancellation")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }

    private var logo: some View {
        NoNoiseLogoMark()
            .padding(5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        .frame(width: 40, height: 40)
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
        }
        .nnCard()
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

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").foregroundColor(.secondary)
            Text("NoNoise Mac v1.0.0 • Built with DeepFilterNet")
                .font(.caption2)
                .foregroundColor(.secondary)
            Spacer()
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
