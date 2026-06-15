import Foundation
import AppKit   // NSWorkspace (used by --action verb mode to open nonoisemac:// URLs)
import Core

print("NoNoise Mac CLI 🎙️")

let mode: CLIMode
do {
    mode = try CLIArguments.parse(CommandLine.arguments)
} catch {
    print("Error: \(error)")
    exit(1)
}

switch mode {
case .help:
    print("""
    Usage:
      NoNoiseMacCLI --in <device> --out <device> [--gain <float>]
      NoNoiseMacCLI --action <verb>
      NoNoiseMacCLI --denoise <input-audio-file> --output <output-audio-file> [--preset meeting|podcast|tutorial|custom] [--gain <float>] [--strength <0...1>] [--attenuation-db <float>] [--overwrite]

    Action verbs (send a one-shot control to the running app via URL scheme):
      toggle         Toggle Noise Cancellation
      bypass         Toggle A/B bypass (passthrough)
      preset-next    Cycle preset forward
      preset-prev    Cycle preset backward
      clarity-next   Cycle Broadcast Voice clarity forward
      gain-up        Nudge output gain up
      gain-down      Nudge output gain down

    URL scheme (Stream Deck / scripting):
      open nonoisemac://toggle
      open nonoisemac://bypass
      open nonoisemac://preset/next
      open nonoisemac://preset/prev
      open nonoisemac://clarity/next
      open nonoisemac://gain/up
      open nonoisemac://gain/down
    """)
    exit(0)

case .action(let verb):
    guard let action = ControlAction.from(cliVerb: verb),
          let urlStr = action.urlString,
          let url = URL(string: urlStr) else {
        print("Error: Unknown action verb '\(verb)'. Run --help for the list.")
        exit(1)
    }
    NSWorkspace.shared.open(url)
    print("Sent action '\(verb)' to NoNoise Mac.")
    exit(0)

case .denoise(let options):
    Task {
        await runDenoise(options)
    }
    RunLoop.main.run()

case .live(let input, let output, let gain):
    let model = AudioModel()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 1.0))

    if let inDev = model.inputDevices.first(where: { $0.localizedName.localizedCaseInsensitiveContains(input) }) {
        print("Selecting Input: \(inDev.localizedName)")
        model.selectedInputDeviceID = inDev.uniqueID
    } else {
        print("Error: Input device '\(input)' not found.")
        exit(1)
    }

    if let outDev = model.outputDevices.first(where: { $0.name.localizedCaseInsensitiveContains(output) }) {
        print("Selecting Output: \(outDev.name)")
        model.selectedOutputDeviceID = outDev.id
    } else {
        print("Error: Output device '\(output)' not found.")
        exit(1)
    }

    model.outputGainValue = gain
    model.isAIEnabled = true

    print("AI Pipeline Active. Press Ctrl+C to stop.")
    RunLoop.main.run()
}

@MainActor
func runDenoise(_ options: AudioDenoiseOptions) async {
    print("Denoising: \(options.inputPath)")
    print("Preset: \(options.preset.rawValue)")
    print("Output: \(options.outputPath)")
    do {
        var lastPercent = -1
        try await AudioFileDenoiser().denoise(options) { progress in
            let percent = Int(progress * 100)
            if percent != lastPercent, percent % 5 == 0 {
                lastPercent = percent
                print("Progress: \(percent)%")
            }
        }
        print("Wrote cleaned audio: \(options.outputPath)")
        exit(0)
    } catch {
        print("Error: \(error)")
        exit(1)
    }
}
