import AVFoundation
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

    func testPodcastPresetEnablesVoiceChainForFileMode() {
        XCTAssertTrue(AudioFileDenoiser.voiceChainSettings(for: .podcast).enabled)
    }

    func testMeetingPresetLeavesVoiceChainDisabledForFileMode() {
        XCTAssertFalse(AudioFileDenoiser.voiceChainSettings(for: .meeting).enabled)
    }

    func testTemporaryOutputURLPreservesAudioExtension() {
        let output = URL(fileURLWithPath: "/tmp/clean.wav")
        let temp = AudioFileDenoiser.temporaryOutputURL(for: output)
        XCTAssertEqual(temp.lastPathComponent, ".clean.tmp.wav")
    }

    func testRejectsMp4VideoContainer() async throws {
        let temp = FileManager.default.temporaryDirectory
        let input = temp.appendingPathComponent("nonoise-video.mp4")
        FileManager.default.createFile(atPath: input.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: input) }

        let denoiser = AudioFileDenoiser()
        let options = AudioDenoiseOptions(inputPath: input.path, outputPath: temp.appendingPathComponent("out.wav").path)
        do {
            try await denoiser.denoise(options)
            XCTFail("expected unsupported video container")
        } catch let error as AudioFileDenoiser.DenoiseError {
            XCTAssertEqual(error, .unsupportedVideoContainer("mp4"))
        }
    }

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
        let inputFile = try AVAudioFile(forReading: input)
        let outputFile = try AVAudioFile(forReading: output)
        XCTAssertGreaterThan(outputFile.length, 0)
        let delta = abs(Int64(outputFile.length) - Int64(inputFile.length))
        XCTAssertLessThanOrEqual(delta, Int64(48_000 * 0.1))
    }
}

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
