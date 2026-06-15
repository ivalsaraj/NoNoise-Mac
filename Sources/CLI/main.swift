import Foundation
import AppKit   // NSWorkspace (used by --action verb mode to open nonoisemac:// URLs)
import Core

print("NoNoise Mac CLI 🎙️")

var inputName: String?
var outputName: String?
var gain: Float = 1.0
var actionVerb: String?

var args = CommandLine.arguments
var i = 1
while i < args.count {
    switch args[i] {
    case "--in":
        if i + 1 < args.count { inputName = args[i + 1]; i += 1 }
    case "--out":
        if i + 1 < args.count { outputName = args[i + 1]; i += 1 }
    case "--gain":
        if i + 1 < args.count, let g = Float(args[i + 1]) { gain = g; i += 1 }
    case "--action":
        if i + 1 < args.count { actionVerb = args[i + 1]; i += 1 }
    case "--help":
        print("""
        Usage:
          NoNoiseMacCLI --in <device> --out <device> [--gain <float>]
          NoNoiseMacCLI --action <verb>

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
    default:
        break
    }
    i += 1
}

// One-shot action mode: send the verb as a URL open and exit.
// The running .app handles it via the nonoisemac:// URL scheme handler.
if let verb = actionVerb {
    let urlStrings: [String: String] = [
        "toggle":       "nonoisemac://toggle",
        "bypass":       "nonoisemac://bypass",
        "preset-next":  "nonoisemac://preset/next",
        "preset-prev":  "nonoisemac://preset/prev",
        "clarity-next": "nonoisemac://clarity/next",
        "gain-up":      "nonoisemac://gain/up",
        "gain-down":    "nonoisemac://gain/down",
    ]
    guard let urlStr = urlStrings[verb], let url = URL(string: urlStr) else {
        print("Error: Unknown action verb '\(verb)'. Run --help for the list.")
        exit(1)
    }
    // NSWorkspace.open delivers the URL to the registered app (NoNoiseMac.app).
    // This requires the .app to be running; the CLI exits immediately after.
    NSWorkspace.shared.open(url)
    print("Sent action '\(verb)' to NoNoise Mac.")
    exit(0)
}

// Pipeline mode (unchanged)
guard let input = inputName, let output = outputName else {
    print("Error: Missing --in or --out.")
    print("Run --help for usage.")
    exit(1)
}

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
