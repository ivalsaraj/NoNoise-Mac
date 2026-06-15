import AVFoundation
import Foundation

public final class AudioFileDenoiser {
    public enum DenoiseError: Error, Equatable, CustomStringConvertible {
        case inputFileMissing(String)
        case outputExists(String)
        case modelNotReady
        case decodeFailed(String)
        case encodeFailed(String)

        public var description: String {
            switch self {
            case .inputFileMissing(let path): return "Input file does not exist: \(path)"
            case .outputExists(let path): return "Output file already exists: \(path). Pass --overwrite to replace it."
            case .modelNotReady: return "Noise cancellation model did not finish loading."
            case .decodeFailed(let detail): return "Could not decode input audio: \(detail)"
            case .encodeFailed(let detail): return "Could not write output audio: \(detail)"
            }
        }
    }

    private static let targetSampleRate: Double = 48_000
    private static let chunkFrames: AVAudioFrameCount = 8192
    private static let tailSilenceFrames = 960 * 2

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

        let inputURL = URL(fileURLWithPath: options.inputPath)
        let outputURL = URL(fileURLWithPath: options.outputPath)
        let tempOutputURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(".\(outputURL.lastPathComponent).tmp")

        if fileManager.fileExists(atPath: tempOutputURL.path) {
            try fileManager.removeItem(at: tempOutputURL)
        }

        let inputFile: AVAudioFile
        do {
            inputFile = try AVAudioFile(forReading: inputURL)
        } catch {
            throw DenoiseError.decodeFailed(error.localizedDescription)
        }

        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: Self.targetSampleRate,
                                               channels: 1,
                                               interleaved: false) else {
            throw DenoiseError.encodeFailed("Could not create target PCM format.")
        }

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(forWriting: tempOutputURL, settings: targetFormat.settings)
        } catch {
            throw DenoiseError.encodeFailed(error.localizedDescription)
        }

        let dsp = DeepFilterNetDSP()
        dsp.outputGain = options.gain
        dsp.suppressionStrength = min(max(options.strength, 0), 1)
        dsp.attenuationLimitDb = options.attenuationDb

        guard await dsp.waitUntilReady() else {
            try? fileManager.removeItem(at: tempOutputURL)
            throw DenoiseError.modelNotReady
        }

        let totalInputFrames = inputFile.length
        var sourceFramesRead: AVAudioFrameCount = 0
        var monoSamplesProcessed = 0
        var converter: AVAudioConverter?

        do {
            while sourceFramesRead < totalInputFrames {
                let framesToRead = min(Self.chunkFrames, AVAudioFrameCount(totalInputFrames - Int64(sourceFramesRead)))
                guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: inputFile.processingFormat,
                                                          frameCapacity: framesToRead) else {
                    throw DenoiseError.decodeFailed("Could not allocate decode buffer.")
                }
                try inputFile.read(into: sourceBuffer, frameCount: framesToRead)
                sourceFramesRead += sourceBuffer.frameLength

                let monoBuffer = try convert(sourceBuffer, to: targetFormat, converter: &converter)
                let count = Int(monoBuffer.frameLength)
                guard count > 0, let inputPtr = monoBuffer.floatChannelData?[0] else { continue }

                var outputSamples = [Float](repeating: 0, count: count)
                outputSamples.withUnsafeMutableBufferPointer { outputPtr in
                    guard let base = outputPtr.baseAddress else { return }
                    dsp.process(input: inputPtr, count: count, output: base)
                }

                try write(samples: outputSamples, count: count, to: outputFile, format: targetFormat)
                monoSamplesProcessed += count

                if totalInputFrames > 0 {
                    progress?(Double(sourceFramesRead) / Double(totalInputFrames))
                }
            }

            let silence = [Float](repeating: 0, count: Self.tailSilenceFrames)
            var tailOutput = [Float](repeating: 0, count: Self.tailSilenceFrames)
            silence.withUnsafeBufferPointer { inputPtr in
                tailOutput.withUnsafeMutableBufferPointer { outputPtr in
                    guard let inBase = inputPtr.baseAddress, let outBase = outputPtr.baseAddress else { return }
                    dsp.process(input: inBase, count: silence.count, output: outBase)
                }
            }

            let writtenFrames = Int(outputFile.length)
            let excess = writtenFrames + tailOutput.count - monoSamplesProcessed
            let tailToWrite = max(0, min(tailOutput.count, tailOutput.count - max(0, excess)))
            if tailToWrite > 0 {
                try write(samples: tailOutput, count: tailToWrite, to: outputFile, format: targetFormat)
            }

            progress?(1.0)

            if fileManager.fileExists(atPath: outputURL.path) {
                try fileManager.removeItem(at: outputURL)
            }
            try fileManager.moveItem(at: tempOutputURL, to: outputURL)
        } catch let error as DenoiseError {
            try? fileManager.removeItem(at: tempOutputURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: tempOutputURL)
            if error is DenoiseError {
                throw error
            }
            throw DenoiseError.encodeFailed(error.localizedDescription)
        }
    }

    private func write(samples: [Float], count: Int, to file: AVAudioFile, format: AVAudioFormat) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else {
            throw DenoiseError.encodeFailed("Could not allocate output buffer.")
        }
        buffer.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            channel.update(from: base, count: count)
        }
        try file.write(from: buffer)
    }

    private func convert(_ sourceBuffer: AVAudioPCMBuffer,
                         to targetFormat: AVAudioFormat,
                         converter: inout AVAudioConverter?) throws -> AVAudioPCMBuffer {
        let sourceFormat = sourceBuffer.format
        if sourceFormat.sampleRate == targetFormat.sampleRate,
           sourceFormat.channelCount == targetFormat.channelCount,
           sourceFormat.commonFormat == targetFormat.commonFormat,
           !sourceFormat.isInterleaved == !targetFormat.isInterleaved {
            return sourceBuffer
        }

        if converter == nil {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let converter else {
            throw DenoiseError.decodeFailed("Could not create audio converter.")
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outCapacity = AVAudioFrameCount(ceil(Double(sourceBuffer.frameLength) * ratio) + 8)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else {
            throw DenoiseError.decodeFailed("Could not allocate conversion buffer.")
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }
        if status == .error {
            throw DenoiseError.decodeFailed(conversionError?.localizedDescription ?? "Conversion failed.")
        }
        return outBuffer
    }
}
