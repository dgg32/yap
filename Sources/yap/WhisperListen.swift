@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import Noora
@preconcurrency import WhisperKit

// MARK: - Whisper engine for Listen

extension Listen {
    /// Live system-audio transcription with WhisperKit.
    ///
    /// Audio is accumulated into a pending utterance and re-transcribed about twice a second.
    /// Segments become final once speech pauses, Whisper starts a new segment, or the
    /// utterance grows too long; everything after the last final segment is shown as tentative text.
    @MainActor func runWhisper(vocabulary: [String]) async throws {
        nonisolated(unsafe) let whisper = try await WhisperModelStore.load(variant: whisperModel)

        var options = DecodingOptions(
            task: .transcribe,
            language: locale.language.languageCode?.identifier,
            temperature: 0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: locale.language.languageCode == nil,
            skipSpecialTokens: true,
            withoutTimestamps: false
        )
        if !vocabulary.isEmpty, let tokenizer = whisper.tokenizer {
            // Whisper conditions on the prompt as preceding text, which biases spelling toward these terms.
            let prompt = " " + vocabulary.joined(separator: "、")
            options.promptTokens = Array(
                tokenizer.encode(text: prompt)
                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                    .suffix(200)
            )
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperKit.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw ListenError.noCompatibleAudioFormat
        }

        let audio = PendingAudio()
        let streamDelegate = AudioStreamDelegate(targetFormat: targetFormat) { audio.append($0) }
        let stream = try await makeSystemAudioStream(format: targetFormat, delegate: streamDelegate)
        do {
            try await stream.startCapture()
        } catch {
            throw ListenError.screenRecordingPermissionDenied
        }
        streamDelegate.startSilencePadding()

        nonisolated(unsafe) let streamToStop = stream
        onInterrupt {
            try? await streamToStop.stopCapture()
            audio.finish()
        }

        let format = outputFormat
        if let header = format.header(locale: locale) {
            print(header)
        }
        var line = LiveLine()
        var segmentIndex = 0
        let sampleRate = Double(WhisperKit.sampleRate)
        var lastDecodedEnd = 0

        func transcribe(_ samples: [Float]) async throws -> [TranscriptionSegment] {
            let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
            return results
                .flatMap(\.segments)
                .filter { !WhisperFilter.isLikelyHallucination($0) }
        }

        func emitFinal(_ segment: TranscriptionSegment, offset: Int) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if format == .txt {
                line.show(text, isFinal: true)
                return
            }
            let start = Double(offset) / sampleRate + Double(segment.start)
            let end = Double(offset) / sampleRate + Double(segment.end)
            let timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 1000),
                end: CMTime(seconds: end, preferredTimescale: 1000)
            )
            if segmentIndex > 0, let sep = format.segmentSeparator {
                print(sep, terminator: "")
            }
            segmentIndex += 1
            print(format.formatSegment(index: segmentIndex, timeRange: timeRange, text: text), terminator: "")
            fflush(stdout)
        }

        while true {
            let (samples, offset, finished) = audio.snapshot()
            let end = offset + samples.count

            // Wait for at least half a second of new audio between decodes
            if !finished, end - lastDecodedEnd < Int(sampleRate * 0.5) {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            lastDecodedEnd = end

            guard let speechStart = AudioLevel.firstSpeech(in: samples) else {
                // Nothing worth transcribing; keep a short tail in case speech is starting
                if format == .txt { line.clear() }
                audio.drop(upTo: end - Int(sampleRate * 0.3))
                if finished { break }
                continue
            }
            let padding = Int(sampleRate * 0.2)
            if speechStart > padding {
                // Trim leading silence so timestamps and decoding start near the speech
                audio.drop(upTo: offset + speechStart - padding)
                lastDecodedEnd = 0
                continue
            }

            // A pause ends the utterance before it, even if it fell between two decodes
            if let pause = AudioLevel.firstPause(in: samples, minimumLength: Int(sampleRate * 0.6)) {
                let utterance = Array(samples[..<min(samples.count, pause.lowerBound + padding)])
                for segment in try await transcribe(utterance) {
                    emitFinal(segment, offset: offset)
                }
                if format == .txt { line.clear() }
                audio.drop(upTo: offset + pause.upperBound - padding)
                lastDecodedEnd = 0
                continue
            }

            let segments = try await transcribe(samples)
            let duration = Double(samples.count) / sampleRate
            // Without a pause, settle everything only at the end or before Whisper's 30 s window fills up;
            // otherwise earlier segments are settled once Whisper starts a new one.
            let settled = finished || duration >= 25
            let finalCount = settled ? segments.count : max(0, segments.count - 1)

            for segment in segments.prefix(finalCount) {
                emitFinal(segment, offset: offset)
            }

            if settled {
                audio.drop(upTo: end)
                if format == .txt { line.clear() }
            } else {
                if finalCount > 0 {
                    let committedEnd = offset + Int(Double(segments[finalCount - 1].end) * sampleRate)
                    audio.drop(upTo: min(committedEnd, end))
                }
                if format == .txt {
                    let tentative = segments.dropFirst(finalCount)
                        .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .joined()
                    if tentative.isEmpty { line.clear() } else { line.show(tentative, isFinal: false) }
                }
            }

            if finished { break }
        }

        if format == .txt {
            print()
        } else {
            if segmentIndex > 0 { print() }
            if let footer = format.footer {
                print(footer)
            }
        }
    }
}

// MARK: - PendingAudio

/// Thread-safe buffer of 16 kHz mono samples that have not been finalized yet.
final class PendingAudio: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    /// Number of samples already dropped from the front, so absolute positions stay stable.
    private var offset = 0
    private var finished = false

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let chunk = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
    }

    func snapshot() -> (samples: [Float], offset: Int, finished: Bool) {
        lock.withLock { (samples, offset, finished) }
    }

    /// Drops samples before absolute position `position`.
    func drop(upTo position: Int) {
        lock.withLock {
            let count = min(max(0, position - offset), samples.count)
            samples.removeFirst(count)
            offset += count
        }
    }

    func finish() {
        lock.withLock { finished = true }
    }
}

// MARK: - AudioLevel

enum AudioLevel {
    /// RMS level below which a 30 ms frame counts as silence.
    static let silenceThreshold: Float = 0.01
    static let frameLength = 480

    /// Index of the first frame containing speech, or nil if `samples` is silent.
    static func firstSpeech(in samples: [Float]) -> Int? {
        stride(from: 0, to: samples.count, by: frameLength).first { rms(samples, from: $0) >= silenceThreshold }
    }

    /// The first run of silence at least `minimumLength` samples long that follows speech.
    static func firstPause(in samples: [Float], minimumLength: Int) -> Range<Int>? {
        var heardSpeech = false
        var silenceStart: Int?
        for start in stride(from: 0, to: samples.count, by: frameLength) {
            if rms(samples, from: start) >= silenceThreshold {
                if heardSpeech, let silenceStart, start - silenceStart >= minimumLength {
                    return silenceStart..<start
                }
                heardSpeech = true
                silenceStart = nil
            } else if heardSpeech, silenceStart == nil {
                silenceStart = start
            }
        }
        if let silenceStart, samples.count - silenceStart >= minimumLength {
            return silenceStart..<samples.count
        }
        return nil
    }

    private static func rms(_ samples: [Float], from start: Int) -> Float {
        let end = min(start + frameLength, samples.count)
        guard end > start else { return 0 }
        var sum: Float = 0
        for i in start..<end {
            sum += samples[i] * samples[i]
        }
        return (sum / Float(end - start)).squareRoot()
    }
}

// MARK: - WhisperFilter

enum WhisperFilter {
    /// Phrases Whisper tends to invent on music or silence (learned from video subtitles).
    static let knownHallucinations = [
        "ご視聴ありがとうございました",
        "チャンネル登録",
        "最後までご視聴",
        "Thank you for watching",
    ]

    static func isLikelyHallucination(_ segment: TranscriptionSegment) -> Bool {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return true }
        if segment.noSpeechProb > 0.6, segment.avgLogprob < -1 { return true }
        return knownHallucinations.contains { text.contains($0) }
    }
}

// MARK: - WhisperModelStore

enum WhisperModelStore {
    static let repo = "argmaxinc/whisperkit-coreml"

    /// Models are kept in ~/Library/Application Support/yap/whisper.
    static var downloadBase: URL {
        URL.applicationSupportDirectory.appending(path: "yap/whisper", directoryHint: .isDirectory)
    }

    static func localFolder(variant: String) -> URL {
        downloadBase.appending(path: "models/\(repo)/\(variant)", directoryHint: .isDirectory)
    }

    /// Downloads the model on first use (with a progress bar) and loads it.
    static func load(variant: String) async throws -> WhisperKit {
        var folder = localFolder(variant: variant)
        let isDownloaded = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
        let interactive = isatty(STDERR_FILENO) != 0

        if !isDownloaded {
            struct StderrPipeline: StandardPipelining {
                func write(content: String) { FileHandle.standardError.write(Data(content.utf8)) }
            }
            struct DevNull: StandardPipelining { func write(content _: String) {} }
            let noora = Noora(standardPipelines: .init(output: interactive ? StderrPipeline() : DevNull()))
            nonisolated(unsafe) var downloaded: URL?
            try await noora.progressBarStep(
                message: "Downloading Whisper model \(variant)…"
            ) { @Sendable progressCallback in
                struct ReportProgress: @unchecked Sendable {
                    let callAsFunction: (Double) -> Void
                }
                let reportProgress = ReportProgress(callAsFunction: progressCallback)
                downloaded = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: downloadBase,
                    from: repo
                ) { progress in
                    reportProgress.callAsFunction(progress.fractionCompleted)
                }
            }
            if let downloaded { folder = downloaded }
        }

        if interactive {
            FileHandle.standardError.write(Data("Loading Whisper model (the first run can take a few minutes)…\n".utf8))
        }
        let config = WhisperKitConfig(
            model: variant,
            downloadBase: downloadBase,
            modelRepo: repo,
            modelFolder: folder.path,
            tokenizerFolder: downloadBase,
            // The GPU runs the audio encoder faster than the Neural Engine on M-series Macs (~0.4 s vs ~1 s per decode)
            computeOptions: ModelComputeOptions(audioEncoderCompute: .cpuAndGPU),
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }
}
