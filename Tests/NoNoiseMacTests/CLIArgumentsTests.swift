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

    func testOutputWithoutDenoiseFails() {
        XCTAssertThrowsError(try CLIArguments.parse(["NoNoiseMacCLI", "--output", "/tmp/clean.wav"])) { error in
            XCTAssertEqual(error as? CLIArguments.ParseError, .missingValue("--denoise"))
        }
    }

    func testUnknownPresetFails() {
        XCTAssertThrowsError(try CLIArguments.parse([
            "NoNoiseMacCLI", "--denoise", "/tmp/noisy.wav", "--output", "/tmp/clean.wav", "--preset", "radio"
        ]))
    }
}
