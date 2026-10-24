@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import Noora
import Speech
@preconcurrency import WhisperKit

// MARK: - Whisper engine for Listen

extension Listen {
    /// Live system-audio transcription with WhisperKit.
    ///
    /// Audio is accumulated into a pending utterance and re-transcribed continuously.
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

        let format = outputFormat
        let captions = Captions()

        // Apple's transcriber streams words immediately; Whisper replaces them with the final sentence
        var preview: ApplePreview?
        if self.preview, format == .txt, isatty(STDOUT_FILENO) != 0 {
            do {
                preview = try await ApplePreview.start(locale: locale, sourceFormat: targetFormat) {
                    Task { @MainActor in captions.render() }
                }
            } catch {
                FileHandle.standardError.write(Data("Live preview unavailable (\(error.localizedDescription)); showing Whisper output only.\n".utf8))
            }
        }
        captions.preview = preview

        let audio = PendingAudio()
        let streamDelegate = AudioStreamDelegate(targetFormat: targetFormat) { [preview] buffer in
            audio.append(buffer)
            preview?.feed(buffer)
        }
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

        if let header = format.header(locale: locale) {
            print(header)
        }
        var segmentIndex = 0
        let sampleRate = Double(WhisperKit.sampleRate)
        var lastDecodedEnd = 0

        func transcribe(_ samples: [Float]) async throws -> [TranscriptionSegment] {
            let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
            return results
                .flatMap(\.segments)
                .map { segment in
                    // A character split across tokens can decode as U+FFFD
                    var segment = segment
                    segment.text = segment.text.replacingOccurrences(of: "\u{FFFD}", with: "")
                    return segment
                }
                .filter { !WhisperFilter.isLikelyHallucination($0) }
        }

        var recentFinals: [String] = []
        func emitFinal(_ segment: TranscriptionSegment, offset: Int) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // A line nearly identical to a recent one is Whisper looping or re-reading the same audio
            guard !text.isEmpty, !WhisperFilter.isUnreliable(segment, vocabulary: vocabulary),
                  !recentFinals.contains(where: { WhisperFilter.isNearDuplicate(text, $0) }) else { return }
            recentFinals = Array((recentFinals + [text]).suffix(3))
            if format == .txt {
                captions.addFinal(text)
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

            // Wait for some new audio between decodes
            if !finished, end - lastDecodedEnd < Int(sampleRate * 0.3) {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            lastDecodedEnd = end

            guard let speechStart = AudioLevel.firstSpeech(in: samples) else {
                // Nothing worth transcribing; keep a short tail in case speech is starting
                audio.drop(upTo: end - Int(sampleRate * 0.3))
                captions.commit(upTo: Double(end) / sampleRate - 0.3)
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
            if let pause = AudioLevel.firstPause(in: samples, minimumLength: Int(sampleRate * 0.5)) {
                let utterance = Array(samples[..<min(samples.count, pause.lowerBound + padding)])
                for segment in try await transcribe(utterance) {
                    emitFinal(segment, offset: offset)
                }
                audio.drop(upTo: offset + pause.upperBound - padding)
                captions.commit(upTo: Double(offset + pause.upperBound - padding) / sampleRate)
                lastDecodedEnd = 0
                continue
            }

            let duration = Double(samples.count) / sampleRate
            if preview != nil, !finished {
                // With the live preview showing words, Whisper only runs on complete utterances, which keeps it
                // free for the next pause and never transcribes the same audio twice. Without a pause
                // (e.g. over background music), split long speech at its quietest moment.
                lastDecodedEnd = end - Int(sampleRate * 0.2)
                guard duration >= 10 else { continue }
                let split = AudioLevel.quietestPoint(
                    in: samples,
                    within: Int(sampleRate * 4)..<(samples.count - Int(sampleRate * 1))
                )
                for segment in try await transcribe(Array(samples[..<split])) {
                    emitFinal(segment, offset: offset)
                }
                audio.drop(upTo: offset + split)
                captions.commit(upTo: Double(offset + split) / sampleRate)
                lastDecodedEnd = 0
                continue
            }

            let segments = try await transcribe(samples)
            // Without a pause, settle everything only at the end or before Whisper's 30 s window fills up;
            // otherwise earlier segments are settled once Whisper starts a new one.
            let settled = finished || duration >= 25
            let finalCount = settled ? segments.count : max(0, segments.count - 1)

            for segment in segments.prefix(finalCount) {
                emitFinal(segment, offset: offset)
            }

            if settled {
                audio.drop(upTo: end)
                captions.whisperTentative = ""
                captions.commit(upTo: Double(end) / sampleRate)
            } else {
                captions.whisperTentative = segments.dropFirst(finalCount)
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .joined()
                if finalCount > 0 {
                    let committedEnd = min(offset + Int(Double(segments[finalCount - 1].end) * sampleRate), end)
                    audio.drop(upTo: committedEnd)
                    captions.commit(upTo: Double(committedEnd) / sampleRate)
                } else {
                    captions.render()
                }
            }

            if finished { break }
        }

        preview?.stop()
        if format == .txt {
            captions.clear()
            print()
        } else {
            if segmentIndex > 0 { print() }
            if let footer = format.footer {
                print(footer)
            }
        }
    }
}

// MARK: - Captions

/// Text output for the Whisper engine: final sentences from Whisper, with the words after them
/// shown as dimmed tentative text (from the Apple preview when available, else from Whisper).
@MainActor
final class Captions {
    var preview: ApplePreview?
    var whisperTentative = ""
    /// Audio before this time (in seconds) already has final text.
    private var committedTime = 0.0
    private var line = LiveLine()

    /// Whisper's final lines for the audio since the last commit.
    private var pendingFinals: [String] = []

    func addFinal(_ text: String) {
        pendingFinals.append(text)
    }

    /// Marks audio up to `time` as final and prints its text, hiding the preview words it replaced.
    /// If Whisper dropped most of what the preview heard (e.g. it hallucinated and was filtered),
    /// the preview's text is kept as the final line instead.
    func commit(upTo time: Double) {
        let end = max(committedTime, time)
        let whisperText = pendingFinals.joined()
        if let fallback = preview?.settle(whisperText, from: committedTime, to: end) {
            line.show(fallback, isFinal: true)
        } else {
            for text in pendingFinals {
                line.show(text, isFinal: true)
            }
        }
        pendingFinals = []
        committedTime = end
        render()
    }

    func render() {
        let text = preview?.text(after: committedTime) ?? whisperTentative
        if text.isEmpty { line.clear() } else { line.show(text, isFinal: false) }
    }

    func clear() {
        line.clear()
    }
}

// MARK: - ApplePreview

/// Runs Apple's SpeechTranscriber on the same audio to show words as soon as they're heard.
/// Both transcribers receive identical buffers from the start, so their timelines line up.
final class ApplePreview: @unchecked Sendable {
    private let lock = NSLock()
    private var finals: [AttributedString] = []
    private var volatile = AttributedString()
    /// Characters at the start of `volatile` that final Whisper text already replaced.
    private var volatileConsumed = 0
    private var volatileStart = 0.0
    private let format: AVAudioFormat
    private let converter: AVAudioConverter
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let analyzer: SpeechAnalyzer
    private var resultsTask: Task<Void, Never>?

    private init(
        format: AVAudioFormat,
        converter: AVAudioConverter,
        input: AsyncStream<AnalyzerInput>.Continuation,
        analyzer: SpeechAnalyzer
    ) {
        self.format = format
        self.converter = converter
        self.input = input
        self.analyzer = analyzer
    }

    static func start(
        locale: Locale,
        sourceFormat: AVAudioFormat,
        onChange: @escaping @Sendable () -> Void
    ) async throws -> ApplePreview {
        try await reserveSpeechAssets(for: locale)
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
        let modules: [any SpeechModule] = [transcriber]
        try await installSpeechAssets(for: locale, modules: modules)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules),
              let converter = AVAudioConverter(from: sourceFormat, to: format) else {
            throw ListenError.noCompatibleAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: format)
        let (inputSequence, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: inputSequence)

        let preview = ApplePreview(format: format, converter: converter, input: input, analyzer: analyzer)
        preview.resultsTask = Task.detached {
            do {
                for try await result in transcriber.results {
                    preview.update(result.text, isFinal: result.isFinal)
                    onChange()
                }
            } catch {
                // The preview is best effort; Whisper output continues without it
            }
        }
        return preview
    }

    /// Called on the audio queue with 16 kHz mono Float32 buffers.
    func feed(_ buffer: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(
            ceil(Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate)
        )
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var error: NSError?
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let source = buffer
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        if error == nil, converted.frameLength > 0 {
            input.yield(AnalyzerInput(buffer: converted))
        }
    }

    func stop() {
        input.finish()
        resultsTask?.cancel()
    }

    private func update(_ text: AttributedString, isFinal: Bool) {
        lock.withLock {
            if isFinal {
                finals.append(text)
                volatile = AttributedString()
                volatileConsumed = 0
            } else {
                // A volatile result with a new start time follows a final result and starts fresh
                let start = text.runs.compactMap(\.audioTimeRange).first?.start.seconds ?? 0
                if start != volatileStart { volatileConsumed = 0 }
                volatileStart = start
                volatile = text
            }
        }
    }

    /// Recognized text for audio after `time` seconds.
    func text(after time: Double) -> String {
        let (finals, volatile, consumed) = lock.withLock { (finals, volatile, volatileConsumed) }
        let text = finals.map { Self.words(in: $0, after: time) }.joined()
            + String(volatile.characters).dropFirst(consumed)
        return String(text.drop { Self.isPunctuation($0) })
    }

    /// Hides the preview words for audio between `start` and `end`, which Whisper turned into `whisperText`.
    /// Returns the preview's own text for that audio when Whisper's text is missing most of it.
    ///
    /// Final Apple results have per-character times, so they're cut by time. Volatile results carry a
    /// single time range for the whole text, so the cut is found by counting characters instead:
    /// both transcribers write roughly the same number of characters, ignoring punctuation. When
    /// Whisper's text can't be trusted for that, the cut is estimated from the time range.
    func settle(_ whisperText: String, from start: Double, to end: Double) -> String? {
        lock.withLock {
            func letters(_ text: String) -> Int { text.filter { !Self.isPunctuation($0) }.count }

            // Apple's final results for this audio
            let finalsText = finals.map {
                String(Self.words(in: $0, after: start).dropLast(Self.words(in: $0, after: end).count))
            }.joined()
            finals.removeAll { Self.words(in: $0, after: end).isEmpty }

            // Apple's volatile text for this audio, by time estimate
            let characters = Array(volatile.characters)
            // Apple can revise a volatile result to be shorter than what was already consumed
            volatileConsumed = min(volatileConsumed, characters.count)
            let ranges = volatile.runs.compactMap(\.audioTimeRange)
            var estimatedCut = volatileConsumed
            if let rangeStart = ranges.first?.start.seconds, let rangeEnd = ranges.last?.end.seconds,
               rangeStart < end {
                estimatedCut = rangeEnd <= end
                    ? characters.count
                    : max(volatileConsumed, Self.cutIndex(in: characters, at: (end - rangeStart) / (rangeEnd - rangeStart)))
            }
            let previewText = finalsText + String(characters[volatileConsumed..<estimatedCut])

            let previewLetters = letters(previewText)
            if previewLetters >= 4, letters(whisperText) * 2 < previewLetters {
                volatileConsumed = estimatedCut
                return previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if estimatedCut == characters.count || estimatedCut == volatileConsumed {
                volatileConsumed = estimatedCut
            } else {
                // Count Whisper's characters into the volatile text, past what Apple's finals covered
                var remaining = letters(whisperText) - letters(finalsText)
                var index = volatileConsumed
                while index < characters.count, remaining > 0 {
                    if !Self.isPunctuation(characters[index]) { remaining -= 1 }
                    index += 1
                }
                while index < characters.count, Self.isPunctuation(characters[index]) {
                    index += 1
                }
                volatileConsumed = index
            }
            return nil
        }
    }

    /// Index after which `fraction` of `characters` lies, moved to nearby punctuation where pauses usually fall.
    private static func cutIndex(in characters: [Character], at fraction: Double) -> Int {
        let estimate = Int((Double(characters.count) * fraction).rounded())
        let window = max(0, estimate - 8)..<min(characters.count, estimate + 8)
        let snapped = window
            .filter { isPunctuation(characters[$0]) && !characters[$0].isWhitespace }
            .map { $0 + 1 }
            .min { abs($0 - estimate) < abs($1 - estimate) }
        return min(snapped ?? estimate, characters.count)
    }

    private static func isPunctuation(_ character: Character) -> Bool {
        character.isPunctuation || character.isWhitespace || character.isSymbol
    }

    private static func words(in text: AttributedString, after time: Double) -> String {
        var result = ""
        for run in text.runs {
            let piece = String(text[run.range].characters)
            if let range = run.audioTimeRange {
                // Keep words that are mostly after the cut
                if (range.start.seconds + range.end.seconds) / 2 > time { result += piece }
            } else if !result.isEmpty {
                // Untimed text (like punctuation) follows the word before it
                result += piece
            }
        }
        return result
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

    /// Start of the quietest 300 ms window within `range`, the best place to split speech without a pause.
    static func quietestPoint(in samples: [Float], within range: Range<Int>) -> Int {
        let window = 10
        let frames = stride(from: range.lowerBound, to: range.upperBound, by: frameLength).map { rms(samples, from: $0) }
        guard frames.count > window else { return range.upperBound }
        var best = 0
        var bestLevel = Float.infinity
        for index in 0...(frames.count - window) {
            let level = frames[index..<(index + window)].reduce(0, +)
            if level < bestLevel {
                bestLevel = level
                best = index
            }
        }
        // Split in the middle of the quiet window
        return min(range.lowerBound + (best + window / 2) * frameLength, range.upperBound)
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
    /// Matched as regular expressions to also catch misspellings like ご視力ありがとうございました.
    static let knownHallucinations = [
        "ご視.{0,2}ありがとうございま",
        "ご清聴ありがとうございま",
        "最後までご視",
        "チャンネル登録",
        "字幕",
        "thank(s| you) for watching",
    ]

    /// Fillers Whisper emits for breaths, grunts and sound effects.
    static let fillerCharacters = Set("んンーっッ〜")

    static func isLikelyHallucination(_ segment: TranscriptionSegment) -> Bool {
        let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = text.filter { !$0.isPunctuation && !$0.isWhitespace && !$0.isSymbol }
        if content.isEmpty { return true }
        if content.allSatisfy(fillerCharacters.contains) { return true }
        return knownHallucinations.contains {
            text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Whisper thinks there's no speech, is very unsure of what it heard, is stuck in a loop, or is
    /// reciting the vocabulary prompt. Only applied to final text: tentative guesses on partial speech
    /// are often low-confidence, and hiding them would delay the captions.
    static func isUnreliable(_ segment: TranscriptionSegment, vocabulary: [String] = []) -> Bool {
        let letters = segment.text.filter { !$0.isPunctuation && !$0.isWhitespace }
        if segment.noSpeechProb > 0.6, letters.count <= 4 || segment.avgLogprob < -1 { return true }
        if segment.avgLogprob < -1.2 || segment.compressionRatio > 2.4 { return true }
        return hasRepeatedPhrase(String(letters)) || echoesVocabulary(String(letters), vocabulary: vocabulary)
    }

    /// True when a phrase repeats back to back: 2–3 characters four or more times, or 4–20 characters
    /// three or more times. Whisper loops like this on music and noise.
    static func hasRepeatedPhrase(_ text: String) -> Bool {
        let characters = Array(text)
        for length in 2...20 {
            let repeats = length <= 3 ? 4 : 3
            guard characters.count >= length * repeats else { break }
            for start in 0...(characters.count - length * repeats) {
                let phrase = characters[start..<(start + length)]
                if (1..<repeats).allSatisfy({ characters[(start + $0 * length)..<(start + ($0 + 1) * length)] == phrase }) {
                    return true
                }
            }
        }
        return false
    }

    /// True when most of the text is vocabulary terms, which happens when Whisper repeats its prompt.
    static func echoesVocabulary(_ text: String, vocabulary: [String]) -> Bool {
        guard !text.isEmpty else { return false }
        var matched = 0
        var distinct = 0
        for term in vocabulary where !term.isEmpty {
            let count = text.components(separatedBy: term).count - 1
            if count > 0 {
                distinct += 1
                matched += count * term.count
            }
        }
        return distinct >= 3 && matched * 2 >= text.count
    }

    /// True when two lines are the same speech transcribed twice: they share most of their character
    /// pairs, or most of the shorter line appears word for word in the longer one.
    static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        let x = Array(a.filter { !$0.isPunctuation && !$0.isWhitespace })
        let y = Array(b.filter { !$0.isPunctuation && !$0.isWhitespace })
        let shorter = min(x.count, y.count)
        guard shorter > 6 else { return x == y }

        func bigrams(_ characters: [Character]) -> Set<String> {
            Set((0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) })
        }
        let (bx, by) = (bigrams(x), bigrams(y))
        if Double(bx.intersection(by).count) / Double(bx.union(by).count) >= 0.6 { return true }

        // Longest common substring
        var longest = 0
        var previous = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            var current = [Int](repeating: 0, count: y.count + 1)
            for j in 1...y.count where x[i - 1] == y[j - 1] {
                current[j] = previous[j - 1] + 1
                longest = max(longest, current[j])
            }
            previous = current
        }
        return Double(longest) >= Double(shorter) * 0.7
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
