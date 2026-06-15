# Audio File Denoise Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an offline audio-file denoise mode to `NoNoiseMacCLI` that reads an audio file, runs the existing on-device DeepFilterNet pipeline, and writes a cleaned audio file.

**Architecture:** Keep the live device-to-device CLI path unchanged. Add a pure-ish CLI argument parser, a small offline processing API in Core, and a CLI file mode that decodes audio with AVFoundation, converts it to mono 48 kHz Float32 for `DeepFilterNetDSP`, then writes cleaned PCM to the requested output. The first release handles audio containers only; MP4/video remuxing stays out of scope.

**Tech Stack:** Swift 5.9, SwiftPM, Core target, AVFoundation (`AVAudioFile`, `AVAudioConverter`), CoreML, Accelerate, XCTest.

---

## Scope

Build:
- `NoNoiseMacCLI --denoise <input-audio-file> --output <output-audio-file>`
- Optional flags: `--preset meeting|podcast|tutorial|custom`, `--gain <float>`, `--strength <0...1>`, `--attenuation-db <float>`, `--overwrite`
- Audio input formats readable by `AVAudioFile` (`wav`, `m4a`, `caf`, `aiff`, etc.)
- Output as an audio file only. Prefer `.wav` for v1 examples and smoke tests.
- Progress text every few seconds for long files.

Do not build:
- MP4/video input or remuxing
- Batch folders
- Multi-track preservation
- GUI file processing
- New model/DSP behavior
- Cloud processing

## Important Existing Context

- `Sources/CLI/main.swift` currently has two modes: live device pipeline and `--action`.
- `Sources/Core/AudioProcessing/DeepFilterNetDSP.swift` owns the streaming DFN pipeline.
- `DeepFilterNetDSP.process(input:count:output:)` expects contiguous mono Float32 samples at 48 kHz.
- `DeepFilterNetDSP` loads the model asynchronously in `init()`, then flips private `isModelLoaded`.
- If `process` runs before the model loads, it returns passthrough-ish STFT output instead of enhanced output, so offline mode needs an explicit readiness wait.
- `VoiceChain` can be reused after DFN to match app presets, but the first task should make DFN-only file processing work before adding polish.
- `VoicePreset.parameters` is the source of truth for preset DSP settings. File mode must resolve effective `gain`, `suppressionStrength`, and `attenuationLimitDb` from the selected preset, then apply any explicit CLI knob overrides.
- Public Core types must not use `DeepFilterNetDSP.maxAttenuationLimitDb` in signatures or default arguments because `DeepFilterNetDSP` is internal. Use public `VoicePreset.maxAttenuationDb` for public defaults; the existing sentinel equality test guards parity.
- Critical CoreML rule: model output arrays must be read via `NSNumber`; do not change that boundary.

## Task 1: Extract CLI Argument Parsing Into Testable Core Code

**Files:**
- Create: `Sources/Core/CLIArguments.swift`
- Modify: `Sources/CLI/main.swift`
- Test: `Tests/NoNoiseMacTests/CLIArgumentsTests.swift`

**Step 1: Write failing parser tests**

Create `Tests/NoNoiseMacTests/CLIArgumentsTests.swift`:

```swift
import XCTest
@testable import Core

final class CLIArgumentsTests: XCTestCase {
    func testParsesLiveDeviceMode() throws {
        let mode = try CLIArguments.parse(["NoNoiseMacCLI", "--in", "Built-in", "--out", "BlackHole", "--gain", "1.5"])
        XCTAssertEqual(mode, .live(input: "Built-in", output: "BlackHole", gain: 1.5))
    }

    func testParsesActionMode() throws {
        let mode = try CLIArguments.parse(["NoNoiseMacCLI", "--action", "toggle"])
        XCTAssertEqual(mode, .action("toggle"))
    }

    func testParsesAudioDenoiseMode() throws {
        let mode = try CLIArguments.parse([
            "NoNoiseMacCLI",
            "--denoise", "/tmp/noisy.wav",
            "--output", "/tmp/clean.wav",
            "--preset", "podcast",
            "--gain", "1.25",
            "--strength", "0.8",
            "--attenuation-db", "24",
            "--overwrite"
        ])
        XCTAssertEqual(mode, .denoise(AudioDenoiseOptions(
            inputPath: "/tmp/noisy.wav",
            outputPath: "/tmp/clean.wav",
            preset: .podcast,
            gain: 1.25,
            strength: 0.8,
            attenuationDb: 24,
            shouldOverwrite: true
        )))
    }

    func testPresetAppliesDSPDefaultsWhenKnobsAreNotExplicit() throws {
        let mode = try CLIArguments.parse([
            "NoNoiseMacCLI",
            "--denoise", "/tmp/noisy.wav",
            "--output", "/tmp/clean.wav",
            "--preset", "podcast"
        ])
        XCTAssertEqual(mode, .denoise(AudioDenoiseOptions(
            inputPath: "/tmp/noisy.wav",
            outputPath: "/tmp/clean.wav",
            preset: .podcast,
            gain: 1.0,
            strength: 1.0,
            attenuationDb: 24.0,
            shouldOverwrite: false
        )))
    }

    func testExplicitKnobsOverridePresetDefaults() throws {
        let mode = try CLIArguments.parse([
            "NoNoiseMacCLI",
            "--denoise", "/tmp/noisy.wav",
            "--output", "/tmp/clean.wav",
            "--preset", "podcast",
            "--attenuation-db", "18"
        ])
        if case .denoise(let options) = mode {
            XCTAssertEqual(options.attenuationDb, 18)
        } else {
            XCTFail("expected denoise mode")
        }
    }

    func testMixedActionAndDenoiseModeFails() {
        XCTAssertThrowsError(try CLIArguments.parse([
            "NoNoiseMacCLI", "--action", "toggle", "--denoise", "/tmp/noisy.wav", "--output", "/tmp/clean.wav"
        ]))
    }

    func testDenoiseRequiresOutput() {
        XCTAssertThrowsError(try CLIArguments.parse(["NoNoiseMacCLI", "--denoise", "/tmp/noisy.wav"])) { error in
            XCTAssertEqual(error as? CLIArguments.ParseError, .missingValue("--output"))
        }
    }

    func testUnknownPresetFails() {
        XCTAssertThrowsError(try CLIArguments.parse([
            "NoNoiseMacCLI", "--denoise", "/tmp/noisy.wav", "--output", "/tmp/clean.wav", "--preset", "radio"
        ]))
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter CLIArgumentsTests
```

Expected: FAIL because `CLIArguments`, `AudioDenoiseOptions`, and denoise mode do not exist.

**Step 3: Add minimal parser models**

Create `Sources/Core/CLIArguments.swift`:

```swift
import Foundation

public struct AudioDenoiseOptions: Equatable {
    public let inputPath: String
    public let outputPath: String
    public let preset: VoicePreset
    public let gain: Float
    public let strength: Float
    public let attenuationDb: Float
    public let shouldOverwrite: Bool

    public init(inputPath: String,
                outputPath: String,
                preset: VoicePreset = .meeting,
                gain: Float = 1.0,
                strength: Float = 1.0,
                attenuationDb: Float = VoicePreset.maxAttenuationDb,
                shouldOverwrite: Bool = false) {
        self.inputPath = inputPath
        self.outputPath = outputPath
        self.preset = preset
        self.gain = gain
        self.strength = strength
        self.attenuationDb = attenuationDb
        self.shouldOverwrite = shouldOverwrite
    }
}

public enum CLIMode: Equatable {
    case help
    case live(input: String, output: String, gain: Float)
    case action(String)
    case denoise(AudioDenoiseOptions)
}

public enum CLIArguments {
    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingValue(String)
        case unknownOption(String)
        case invalidFloat(String, String)
        case invalidPreset(String)
        case mixedModes
        case missingLiveDevice

        public var description: String {
            switch self {
            case .missingValue(let flag): return "Missing value for \(flag)."
            case .unknownOption(let option): return "Unknown option \(option)."
            case .invalidFloat(let flag, let value): return "Invalid numeric value for \(flag): \(value)."
            case .invalidPreset(let value): return "Unknown preset \(value)."
            case .mixedModes: return "Choose exactly one mode: live device pipeline, --action, or --denoise."
            case .missingLiveDevice: return "Missing --in or --out."
            }
        }
    }

    public static func parse(_ arguments: [String]) throws -> CLIMode {
        var inputName: String?
        var outputName: String?
        var liveGain: Float = 1.0
        var denoiseGainOverride: Float?
        var actionVerb: String?
        var denoiseInput: String?
        var denoiseOutput: String?
        var preset: VoicePreset = .meeting
        var strengthOverride: Float?
        var attenuationDbOverride: Float?
        var shouldOverwrite = false

        var index = 1
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--help", "-h":
                return .help
            case "--in":
                inputName = try value(after: arg, in: arguments, index: &index)
            case "--out":
                outputName = try value(after: arg, in: arguments, index: &index)
            case "--gain":
                let parsedGain = try floatValue(after: arg, in: arguments, index: &index)
                liveGain = parsedGain
                denoiseGainOverride = parsedGain
            case "--action":
                actionVerb = try value(after: arg, in: arguments, index: &index)
            case "--denoise":
                denoiseInput = try value(after: arg, in: arguments, index: &index)
            case "--output":
                denoiseOutput = try value(after: arg, in: arguments, index: &index)
            case "--preset":
                let rawPreset = try value(after: arg, in: arguments, index: &index)
                guard let parsed = VoicePreset.allCases.first(where: { $0.rawValue == rawPreset.lowercased() }) else {
                    throw ParseError.invalidPreset(rawPreset)
                }
                preset = parsed
            case "--strength":
                strengthOverride = try floatValue(after: arg, in: arguments, index: &index)
            case "--attenuation-db":
                attenuationDbOverride = try floatValue(after: arg, in: arguments, index: &index)
            case "--overwrite":
                shouldOverwrite = true
            default:
                throw ParseError.unknownOption(arg)
            }
            index += 1
        }

        let hasLiveMode = inputName != nil || outputName != nil
        let hasActionMode = actionVerb != nil
        let hasDenoiseMode = denoiseInput != nil || denoiseOutput != nil
        if [hasLiveMode, hasActionMode, hasDenoiseMode].filter({ $0 }).count > 1 {
            throw ParseError.mixedModes
        }

        if let actionVerb { return .action(actionVerb) }
        if let denoiseInput {
            guard let denoiseOutput else { throw ParseError.missingValue("--output") }
            let presetDefaults = preset.parameters ?? (suppressionStrength: Float(1.0),
                                                       attenuationLimitDb: VoicePreset.maxAttenuationDb,
                                                       outputGain: Float(1.0))
            return .denoise(AudioDenoiseOptions(
                inputPath: denoiseInput,
                outputPath: denoiseOutput,
                preset: preset,
                gain: denoiseGainOverride ?? presetDefaults.outputGain,
                strength: strengthOverride ?? presetDefaults.suppressionStrength,
                attenuationDb: attenuationDbOverride ?? presetDefaults.attenuationLimitDb,
                shouldOverwrite: shouldOverwrite
            ))
        }
        guard let inputName, let outputName else { throw ParseError.missingLiveDevice }
        return .live(input: inputName, output: outputName, gain: liveGain)
    }

    private static func value(after flag: String, in arguments: [String], index: inout Int) throws -> String {
        guard index + 1 < arguments.count else { throw ParseError.missingValue(flag) }
        index += 1
        return arguments[index]
    }

    private static func floatValue(after flag: String, in arguments: [String], index: inout Int) throws -> Float {
        let rawValue = try value(after: flag, in: arguments, index: &index)
        guard let value = Float(rawValue) else { throw ParseError.invalidFloat(flag, rawValue) }
        return value
    }
}
```

If `VoicePreset.rawValue` is not lowercase-friendly, add a tiny computed parse helper in `VoicePreset` instead of duplicating strings in the parser. Keep `VoicePreset.parameters` as the canonical source for non-custom preset DSP values; explicit CLI knob flags override those values after preset resolution.

**Step 4: Wire `main.swift` to the parser without behavior changes**

Modify `Sources/CLI/main.swift`:
- Replace the hand-rolled `while` parser with `CLIArguments.parse(CommandLine.arguments)`.
- Keep `--action` behavior exactly as-is after parser output.
- Keep live `--in` / `--out` behavior exactly as-is after parser output.
- Add a placeholder denoise case that prints a clear not-yet-implemented error for this task.

**Step 5: Run tests**

Run:

```bash
swift test --filter CLIArgumentsTests
swift test
```

Expected: parser tests pass; full suite passes.

**Step 6: Commit**

```bash
git add Sources/Core/CLIArguments.swift Sources/CLI/main.swift Tests/NoNoiseMacTests/CLIArgumentsTests.swift
git commit -m "test(cli): cover denoise argument parsing"
```

## Task 2: Add Explicit DSP Readiness For Offline Jobs

**Files:**
- Modify: `Sources/Core/AudioProcessing/DeepFilterNetDSP.swift`
- Test: `Tests/NoNoiseMacTests/DeepFilterNetDSPTests.swift`

**Step 1: Write failing readiness test**

Create or extend `Tests/NoNoiseMacTests/DeepFilterNetDSPTests.swift`:

```swift
import XCTest
@testable import Core

final class DeepFilterNetDSPTests: XCTestCase {
    func testReadinessIsInitiallyFalseForFreshDSP() {
        let dsp = DeepFilterNetDSP()
        XCTAssertFalse(dsp.isReady)
    }
}
```

This is intentionally small; do not make unit tests wait for CoreML model loading.

**Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter DeepFilterNetDSPTests
```

Expected: FAIL because `isReady` is not exposed.

**Step 3: Add readiness API**

Modify `Sources/Core/AudioProcessing/DeepFilterNetDSP.swift`:

```swift
public var isReady: Bool { isModelLoaded }
```

Add an async wait helper:

```swift
public func waitUntilReady(timeoutSeconds: TimeInterval = 15) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while !isReady {
        if Date() >= deadline { return false }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return true
}
```

Keep `isModelLoaded` private. This exposes a narrow readiness surface without exposing the model object or changing render behavior.

**Step 4: Run tests**

Run:

```bash
swift test --filter DeepFilterNetDSPTests
swift test
```

Expected: PASS.

**Step 5: Commit**

```bash
git add Sources/Core/AudioProcessing/DeepFilterNetDSP.swift Tests/NoNoiseMacTests/DeepFilterNetDSPTests.swift
git commit -m "feat(core): expose DSP readiness for offline processing"
```

## Task 3: Create Offline Audio Processor Skeleton

**Files:**
- Create: `Sources/Core/AudioFileDenoiser.swift`
- Test: `Tests/NoNoiseMacTests/AudioFileDenoiserTests.swift`

**Step 1: Write failing validation tests**

Create `Tests/NoNoiseMacTests/AudioFileDenoiserTests.swift`:

```swift
import XCTest
@testable import Core

final class AudioFileDenoiserTests: XCTestCase {
    func testRejectsMissingInputFile() async {
        let denoiser = AudioFileDenoiser()
        let options = AudioDenoiseOptions(inputPath: "/tmp/does-not-exist.wav", outputPath: "/tmp/out.wav")
        await XCTAssertThrowsErrorAsync(try await denoiser.denoise(options))
    }

    func testRejectsExistingOutputWithoutOverwrite() async throws {
        let temp = FileManager.default.temporaryDirectory
        let input = temp.appendingPathComponent("nonoise-empty-input.wav")
        let output = temp.appendingPathComponent("nonoise-existing-output.wav")
        FileManager.default.createFile(atPath: input.path, contents: Data())
        FileManager.default.createFile(atPath: output.path, contents: Data())
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }

        let denoiser = AudioFileDenoiser()
        let options = AudioDenoiseOptions(inputPath: input.path, outputPath: output.path)
        await XCTAssertThrowsErrorAsync(try await denoiser.denoise(options))
    }
}
```

If the test suite does not already have async throw helpers, add this local helper at the bottom of the test file:

```swift
private func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {
        // Expected.
    }
}
```

**Step 2: Run test to verify it fails**

Run:

```bash
swift test --filter AudioFileDenoiserTests
```

Expected: FAIL because `AudioFileDenoiser` does not exist.

**Step 3: Add validation-only implementation**

Create `Sources/Core/AudioFileDenoiser.swift`:

```swift
import AVFoundation
import Foundation

public final class AudioFileDenoiser {
    public enum DenoiseError: Error, Equatable, CustomStringConvertible {
        case inputFileMissing(String)
        case outputExists(String)
        case modelNotReady

        public var description: String {
            switch self {
            case .inputFileMissing(let path): return "Input file does not exist: \(path)"
            case .outputExists(let path): return "Output file already exists: \(path). Pass --overwrite to replace it."
            case .modelNotReady: return "Noise cancellation model did not finish loading."
            }
        }
    }

    public init() {}

    public func denoise(_ options: AudioDenoiseOptions,
                        progress: ((Double) -> Void)? = nil) async throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: options.inputPath) else {
            throw DenoiseError.inputFileMissing(options.inputPath)
        }
        if fileManager.fileExists(atPath: options.outputPath), !options.shouldOverwrite {
            throw DenoiseError.outputExists(options.outputPath)
        }
        _ = progress
        throw DenoiseError.modelNotReady
    }
}
```

**Step 4: Run tests**

Run:

```bash
swift test --filter AudioFileDenoiserTests
```

Expected: PASS for validation tests.

**Step 5: Commit**

```bash
git add Sources/Core/AudioFileDenoiser.swift Tests/NoNoiseMacTests/AudioFileDenoiserTests.swift
git commit -m "test(core): add offline denoise validation shell"
```

## Task 4: Implement Audio Decode, Resample, Denoise, And Write

**Files:**
- Modify: `Sources/Core/AudioFileDenoiser.swift`
- Test: `Tests/NoNoiseMacTests/AudioFileDenoiserTests.swift`

**Step 1: Write an integration-style test with a generated WAV**

Append to `AudioFileDenoiserTests`:

```swift
func testDenoisesGeneratedWavToOutputFile() async throws {
    let temp = FileManager.default.temporaryDirectory
    let input = temp.appendingPathComponent("nonoise-test-input.wav")
    let output = temp.appendingPathComponent("nonoise-test-output.wav")
    defer {
        try? FileManager.default.removeItem(at: input)
        try? FileManager.default.removeItem(at: output)
    }

    try makeSineWaveFile(url: input, seconds: 0.25)

    let denoiser = AudioFileDenoiser()
    let options = AudioDenoiseOptions(inputPath: input.path, outputPath: output.path, shouldOverwrite: true)
    try await denoiser.denoise(options)

    XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
    let outputFile = try AVAudioFile(forReading: output)
    XCTAssertGreaterThan(outputFile.length, 0)
}
```

Add helper:

```swift
private func makeSineWaveFile(url: URL, seconds: Double) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let frameCount = AVAudioFrameCount(seconds * 48_000)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
    buffer.frameLength = frameCount
    let samples = buffer.floatChannelData![0]
    for i in 0..<Int(frameCount) {
        samples[i] = 0.05 * sinf(2 * Float.pi * 440 * Float(i) / 48_000)
    }
    try file.write(from: buffer)
}
```

This test may take longer than pure tests because it loads CoreML. If it is too slow/flaky for normal CI, mark it as a manual smoke test instead and keep unit tests focused on parser/validation. Prefer running it locally before shipping.

**Step 2: Run the new test and observe expected failure**

Run:

```bash
swift test --filter AudioFileDenoiserTests/testDenoisesGeneratedWavToOutputFile
```

Expected: FAIL with `modelNotReady` or not-yet-implemented behavior.

**Step 3: Implement the offline processing loop**

Modify `AudioFileDenoiser.denoise`:
- Open input with `AVAudioFile(forReading:)`.
- Convert to target mono 48 kHz Float32 using `AVAudioConverter` when needed.
- Instantiate `DeepFilterNetDSP`.
- Set:
  - `dsp.outputGain = options.gain`
  - `dsp.suppressionStrength = clamp(options.strength, 0, 1)`
  - `dsp.attenuationLimitDb = options.attenuationDb`
- Await `dsp.waitUntilReady()`, throw `.modelNotReady` on timeout.
- Stream input in bounded chunks, e.g. 4096 or 8192 frames.
- Downmix multi-channel audio to mono before DSP. V1 output is mono.
- Call `dsp.process(input:count:output:)` for each converted chunk.
- Write output chunks to `AVAudioFile(forWriting:)` with a 48 kHz mono Float32 format.
- When `shouldOverwrite` is true, write to a temporary sibling file first, then replace/move to `outputPath` only after successful completion. This prevents a failed denoise run from leaving a partial destination at the requested output path.
- Emit progress as `framesRead / totalFrames`.

Implementation sketch:

```swift
let inputURL = URL(fileURLWithPath: options.inputPath)
let outputURL = URL(fileURLWithPath: options.outputPath)
let inputFile = try AVAudioFile(forReading: inputURL)
let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                 sampleRate: 48_000,
                                 channels: 1,
                                 interleaved: false)!
let outputFile = try AVAudioFile(forWriting: outputURL, settings: targetFormat.settings)
let dsp = DeepFilterNetDSP()
dsp.outputGain = options.gain
dsp.suppressionStrength = min(max(options.strength, 0), 1)
dsp.attenuationLimitDb = options.attenuationDb
guard await dsp.waitUntilReady() else { throw DenoiseError.modelNotReady }
```

Use a helper for format conversion:

```swift
private func convert(_ sourceBuffer: AVAudioPCMBuffer,
                     to targetFormat: AVAudioFormat,
                     converter: inout AVAudioConverter?) throws -> AVAudioPCMBuffer
```

If `sourceBuffer.format` already matches target format, return the source or copy into a target buffer. Otherwise use `AVAudioConverter` with an input block. Keep this helper covered by generated WAV tests where possible.

**Step 4: Flush DSP tail**

After all input frames are processed, feed silence for at least one frame size plus hop padding so overlap-add tail is emitted:

```swift
var silence = [Float](repeating: 0, count: 960 * 2)
var tail = [Float](repeating: 0, count: silence.count)
silence.withUnsafeBufferPointer { inputPtr in
    tail.withUnsafeMutableBufferPointer { outputPtr in
        dsp.process(input: inputPtr.baseAddress!, count: silence.count, output: outputPtr.baseAddress!)
    }
}
```

Trim or accept the small padded tail. For v1, prefer trimming output to approximately input duration if it is straightforward; otherwise document that output may include a very short tail. Do not risk cutting speech. The generated-WAV test should verify output duration is close to input duration, not only that the file is non-empty.

**Step 5: Run tests**

Run:

```bash
swift test --filter AudioFileDenoiserTests
swift test
```

Expected: PASS locally. If CoreML loading makes the generated-WAV test unsuitable for CI, split it into a manual command and keep only non-CoreML unit tests in XCTest.

**Step 6: Commit**

```bash
git add Sources/Core/AudioFileDenoiser.swift Tests/NoNoiseMacTests/AudioFileDenoiserTests.swift
git commit -m "feat(core): process audio files through offline denoise"
```

## Task 5: Wire Denoise Mode Into `NoNoiseMacCLI`

**Files:**
- Modify: `Sources/CLI/main.swift`
- Modify: `README.md`

**Step 1: Add CLI behavior**

In `Sources/CLI/main.swift`:
- Print help for denoise mode.
- On `.denoise(options)`, call `AudioFileDenoiser().denoise(options, progress:)`.
- Print:
  - Input path
  - Output path
  - Preset
  - Progress as integer percent
  - Completion message
- On errors, print `Error: ...` and exit non-zero.

Behavior sketch:

```swift
case .denoise(let options):
    print("Denoising: \(options.inputPath)")
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
```

Because `main.swift` currently uses top-level synchronous code, wrap the denoise call in a small async entry point if needed:

```swift
Task {
    await runCLI()
    exit(0)
}
RunLoop.main.run()
```

Keep action mode exiting immediately after URL dispatch and live mode running the main run loop.

**Step 2: Update help text**

Add:

```text
NoNoiseMacCLI --denoise <input-audio-file> --output <output-audio-file> [--preset meeting|podcast|tutorial|custom] [--gain <float>] [--strength <0...1>] [--attenuation-db <float>] [--overwrite]
```

**Step 3: Update README**

In `README.md`, add an audio-file section after the existing CLI section:

```markdown
### Offline audio file cleanup

Clean an audio file locally:

```bash
./NoNoiseMacCLI --denoise noisy.wav --output clean.wav --preset podcast --overwrite
```

This v1 file mode writes a cleaned audio file. Video containers such as MP4 are planned separately so the CLI can preserve the original video track correctly.
```

**Step 4: Build**

Run:

```bash
swift build
```

Expected: build succeeds.

**Step 5: Manual smoke test**

Create or use a short noisy WAV, then run:

```bash
swift run NoNoiseMacCLI --denoise /tmp/noisy.wav --output /tmp/clean.wav --overwrite
```

Expected:
- CLI prints progress.
- `/tmp/clean.wav` exists.
- The output opens in QuickTime or `afinfo`.

Also verify overwrite guard:

```bash
swift run NoNoiseMacCLI --denoise /tmp/noisy.wav --output /tmp/clean.wav
```

Expected: exits non-zero with "Output file already exists".

**Step 6: Commit**

```bash
git add Sources/CLI/main.swift README.md
git commit -m "feat(cli): add offline audio denoise command"
```

## Task 6: Add Preset-Aware Voice Polish For File Mode

**Files:**
- Modify: `Sources/Core/AudioFileDenoiser.swift`
- Test: `Tests/NoNoiseMacTests/AudioFileDenoiserTests.swift`

**Step 1: Decide whether v1 should include polish**

Recommendation: yes, because users selecting `--preset podcast` expect the same podcast-style output, not DFN-only output.

Rules:
- Meeting: DFN only unless clarity/mouth-noise flags are added later.
- Podcast/Tutorial/Custom: configure `VoiceChain` from `options.preset.voiceChain`.
- DSP preset parameters (`suppressionStrength`, `attenuationLimitDb`, `outputGain`) are already resolved in Task 1 and applied in Task 4. Do not duplicate preset parameter logic here; Task 6 only adds the post-DFN `VoiceChain`.
- Do not add clarity or mouth-noise CLI flags in this first pass unless requested.

**Step 2: Add a small unit test for preset mapping**

Add a pure helper in `AudioFileDenoiser`:

```swift
static func voiceChainSettings(for preset: VoicePreset) -> VoiceChainSettings
```

Test:

```swift
func testPodcastPresetEnablesVoiceChainForFileMode() {
    XCTAssertTrue(AudioFileDenoiser.voiceChainSettings(for: .podcast).enabled)
}

func testMeetingPresetLeavesVoiceChainDisabledForFileMode() {
    XCTAssertFalse(AudioFileDenoiser.voiceChainSettings(for: .meeting).enabled)
}
```

**Step 3: Run tests to verify failure**

Run:

```bash
swift test --filter AudioFileDenoiserTests
```

Expected: FAIL until helper exists.

**Step 4: Implement voice chain**

In `AudioFileDenoiser.denoise`:
- Create `let voiceChain = VoiceChain()`.
- Configure it once from `options.preset.voiceChain`.
- After each `dsp.process(...)`, call `voiceChain.process(outputPtr, count: frameCount)` when settings are active.

Keep processing order identical to live app:

```text
decode -> resample/downmix -> DeepFilterNetDSP -> VoiceChain -> write
```

**Step 5: Run tests**

Run:

```bash
swift test --filter AudioFileDenoiserTests
swift test
```

Expected: PASS.

**Step 6: Commit**

```bash
git add Sources/Core/AudioFileDenoiser.swift Tests/NoNoiseMacTests/AudioFileDenoiserTests.swift
git commit -m "feat(core): apply preset polish in offline denoise"
```

## Task 7: Documentation And Knowledge Base Pass

**Files:**
- Modify: `README.md`
- Modify: `CONCEPTS.md`
- Modify: `AGENTS.md`
- Modify: `docs/knowledge/timeline1.md`
- Modify if needed: `docs/knowledge/critical-patterns.md`

**Step 1: Search references**

Run:

```bash
rg -n "NoNoiseMacCLI|Advanced: dual pipelines|offline|denoise|MP4|audio file" README.md CONCEPTS.md AGENTS.md docs Sources Tests
```

Expected: list of all stale CLI descriptions.

**Step 2: Update docs**

Update:
- `README.md`: usage examples and "audio file cleanup" section.
- `CONCEPTS.md`: add "offline denoise" definition if CLI concepts are listed there.
- `AGENTS.md`: update architecture map under `Sources/CLI` to mention file mode and add any offline-specific invariants.
- `docs/knowledge/timeline1.md`: add a top entry for offline audio denoise.
- `docs/knowledge/critical-patterns.md`: only update if implementation creates a new shipped-and-broke-level rule. Likely not needed.

**Step 3: Run doc reference search again**

Run:

```bash
rg -n "NoNoiseMacCLI|--denoise|audio file|offline denoise|MP4" README.md CONCEPTS.md AGENTS.md docs
```

Expected: CLI docs are consistent and MP4 is clearly described as future/out of scope.

**Step 4: Commit**

```bash
git add README.md CONCEPTS.md AGENTS.md docs/knowledge/timeline1.md
git commit -m "docs(cli): document offline audio denoise"
```

## Task 8: Final Verification

**Files:**
- No edits unless verification reveals a bug.

**Step 1: Run full tests**

Run:

```bash
swift test
```

Expected: PASS.

**Step 2: Run debug build**

Run:

```bash
swift build
```

Expected: PASS.

**Step 3: Run optimized Apple Silicon build**

Run:

```bash
swift build -c release --arch arm64
```

Expected: PASS on Apple Silicon.

**Step 4: Run CLI help**

Run:

```bash
swift run NoNoiseMacCLI --help
```

Expected: help includes live, action, and denoise modes.

**Step 5: Run manual audio smoke**

Run:

```bash
swift run NoNoiseMacCLI --denoise /tmp/noisy.wav --output /tmp/clean.wav --overwrite
afinfo /tmp/clean.wav
```

Expected:
- CLI completes.
- `afinfo` can inspect output.
- Output duration is close to input duration.

**Step 6: Inspect diff**

Run:

```bash
git diff --stat HEAD
git diff -- Sources/Core Sources/CLI Tests README.md CONCEPTS.md AGENTS.md docs/knowledge/timeline1.md
```

Expected: only planned files changed.

**Step 7: Final commit if any verification fixes were required**

If verification fixes changed files:

```bash
git add <specific-files>
git commit -m "fix(cli): harden offline denoise verification issues"
```

## Rollback Plan

If file denoise has runtime problems after merge:
- Leave `AudioFileDenoiser` in Core but hide the CLI mode behind help removal only if needed.
- The live pipeline remains independent, so rollback should only touch `Sources/CLI/main.swift`, `README.md`, and file-mode docs.
- Do not change `DeepFilterNetDSP` model-call internals during rollback.

## Acceptance Criteria

- `NoNoiseMacCLI --denoise noisy.wav --output clean.wav --overwrite` writes a playable cleaned audio file.
- Existing live CLI commands still work:
  - `NoNoiseMacCLI --in "Built-in Microphone" --out "BlackHole 2ch" --gain 1.0`
  - `NoNoiseMacCLI --action toggle`
- Existing app behavior is unchanged.
- `swift test`, `swift build`, and release arm64 build pass.
- Docs clearly state MP4/video processing is not included in this first audio-only implementation.
