@preconcurrency import AVFoundation
import CoreMedia
import NaturalLanguage
@preconcurrency import Noora
import Speech
@preconcurrency import WhisperKit

// MARK: - Whisper engine for Listen

extension Listen {
    /// Live system-audio transcription with WhisperKit.
    ///
    /// Audio is collected into a pending utterance, which Whisper transcribes once speech pauses (or,
    /// without a pause, once it grows long). Apple's transcriber runs alongside: on a terminal it shows
    /// words as they're heard, and in every output format it supplies the text for lines Whisper loses.
    /// Without Apple's transcriber, live text output falls back to re-transcribing the pending audio
    /// to show Whisper's own tentative text.
    @MainActor func runWhisper(vocabulary: [String]) async throws {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(WhisperKit.sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw ListenError.noCompatibleAudioFormat
        }
        let sampleRate = Double(WhisperKit.sampleRate)
        let format = outputFormat
        let live = format == .txt && isatty(STDOUT_FILENO) != 0

        // Start capturing first, so speech during the (possibly long) model load is buffered, not lost
        let audio = PendingAudio()
        let previewInput = PreviewInput()
        let streamDelegate = AudioStreamDelegate(targetFormat: targetFormat) { buffer in
            audio.append(buffer)
            previewInput.feed(buffer)
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

        let output = CaptionOutput(format: format, live: live, maxLength: maxLength)
        if let translate {
            do {
                output.translator = try await CaptionTranslator.make(from: locale, to: translate)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription) Continuing without translation.\n".utf8))
            }
        }

        // Apple's transcriber is small and quick to start, so it comes before the Whisper model
        var preview: ApplePreview?
        if self.preview {
            do {
                let started = try await ApplePreview.start(
                    locale: locale,
                    vocabulary: vocabulary,
                    sourceFormat: targetFormat
                ) {
                    Task { @MainActor in output.render() }
                }
                // Catch it up on the audio captured so far, then feed it live, keeping both timelines aligned
                streamDelegate.queue.sync {
                    previewInput.attach(started, replaying: audio.snapshot().samples, format: targetFormat)
                }
                preview = started
            } catch {
                FileHandle.standardError.write(Data("Apple transcriber unavailable (\(error.localizedDescription)); using Whisper output only.\n".utf8))
            }
        }
        output.preview = preview

        let activity: SpeechActivity
        if vad == .silero {
            do {
                activity = try await SileroModelStore.load()
            } catch {
                FileHandle.standardError.write(Data("Silero voice detection unavailable (\(error.localizedDescription)); using loudness instead.\n".utf8))
                activity = EnergyActivity()
            }
        } else {
            activity = EnergyActivity()
        }

        nonisolated(unsafe) let whisper = try await WhisperModelStore.load(model: whisperModel, repo: whisperRepo)
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
        // Whisper conditions on the prompt as preceding text: the vocabulary biases spelling toward its
        // terms, and the previous line gives short utterances the context they lack on their own
        // (未来永劫 alone can come out as "Mira, Diego").
        let tokenizer = whisper.tokenizer
        func tokens(_ text: String, limit: Int) -> [Int] {
            guard let tokenizer, !text.isEmpty else { return [] }
            return Array(
                tokenizer.encode(text: " " + text)
                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                    .suffix(limit)
            )
        }
        let vocabularyTokens = tokens(vocabulary.joined(separator: "、"), limit: 160)
        var previousLine = ""

        if let header = format.header(locale: locale) {
            print(header)
        }

        func transcribe(_ samples: [Float]) async throws -> [TranscriptionSegment] {
            // Only the end of the previous line matters as context, and each prompt token costs decode time
            let prompt = vocabularyTokens + tokens(previousLine, limit: 16)
            options.promptTokens = prompt.isEmpty ? nil : prompt
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
            previousLine = text
            let base = Double(offset) / sampleRate
            output.add(text, start: base + Double(segment.start), end: base + Double(segment.end))
        }

        // Transcribe each utterance once, unless Whisper's own tentative text is the only live feedback
        let oncePerUtterance = preview != nil || !live
        var analyzedUpTo = 0
        /// End of the last speech that was finalized, to tell when the speaker has gone quiet.
        var lastSpeechEnd = 0
        var lastDecodedEnd = 0
        let padding = Int(sampleRate * 0.2)

        while true {
            let (samples, offset, finished) = audio.snapshot()
            let end = offset + samples.count
            if end > analyzedUpTo {
                activity.add(samples[max(0, analyzedUpTo - offset)...])
                analyzedUpTo = end
            }

            // Wait for some new audio between decodes
            if !finished, end - lastDecodedEnd < Int(sampleRate * 0.3) {
                try await Task.sleep(for: .milliseconds(100))
                continue
            }
            lastDecodedEnd = end

            guard let speechStart = activity.firstSpeech(in: offset..<end).map({ $0 - offset }) else {
                // Nothing worth transcribing; keep a short tail in case speech is starting
                audio.drop(upTo: end - Int(sampleRate * 0.3))
                // The current line ends once the speaker has been quiet for a while
                await output.commit(upTo: Double(end) / sampleRate - 0.3, endsLine: end - lastSpeechEnd >= Int(sampleRate * 0.8))
                if finished { break }
                continue
            }
            if speechStart > padding {
                // Trim leading silence so timestamps and decoding start near the speech
                audio.drop(upTo: offset + speechStart - padding)
                lastDecodedEnd = 0
                continue
            }

            // A pause ends the utterance before it, even if it fell between two decodes. A short utterance
            // needs a longer pause, so a sentence isn't cut into fragments too short to transcribe well;
            // a pause still growing at the end of the audio is checked again on the next pass.
            var searchFrom = offset
            var acceptedPause: Range<Int>?
            while let pause = activity.firstPause(in: searchFrom..<end, minimumLength: Int(sampleRate * 0.4)) {
                let utteranceLength = Double(pause.lowerBound - offset) / sampleRate
                let pauseLength = Double(pause.count) / sampleRate
                if finished || utteranceLength >= 3 || pauseLength >= 0.8 {
                    acceptedPause = pause
                    break
                }
                searchFrom = pause.upperBound
            }
            if let pause = acceptedPause.map({ ($0.lowerBound - offset)..<($0.upperBound - offset) }) {
                let utterance = Array(samples[..<min(samples.count, pause.lowerBound + padding)])
                for segment in try await transcribe(utterance) {
                    emitFinal(segment, offset: offset)
                }
                audio.drop(upTo: offset + pause.upperBound - padding)
                lastSpeechEnd = offset + pause.lowerBound
                await output.commit(
                    upTo: Double(offset + pause.upperBound - padding) / sampleRate,
                    endsLine: pause.count >= Int(sampleRate * 0.8)
                )
                lastDecodedEnd = 0
                continue
            }

            let duration = Double(samples.count) / sampleRate
            if oncePerUtterance, !finished {
                // Without a pause (e.g. over loud music), split long speech at its quietest moment,
                // well inside Whisper's 30 s window
                lastDecodedEnd = end - Int(sampleRate * 0.2)
                guard duration >= 10 else { continue }
                let split = activity.quietestPoint(
                    in: (offset + Int(sampleRate * 4))..<min(end - Int(sampleRate * 1), offset + Int(sampleRate * 25))
                ) - offset
                for segment in try await transcribe(Array(samples[..<split])) {
                    emitFinal(segment, offset: offset)
                }
                audio.drop(upTo: offset + split)
                lastSpeechEnd = offset + split
                await output.commit(upTo: Double(offset + split) / sampleRate, endsLine: false)
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
                output.whisperTentative = ""
                lastSpeechEnd = end
                await output.commit(upTo: Double(end) / sampleRate, endsLine: finished)
            } else {
                output.whisperTentative = segments.dropFirst(finalCount)
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .joined()
                if finalCount > 0 {
                    let committedEnd = min(offset + Int(Double(segments[finalCount - 1].end) * sampleRate), end)
                    audio.drop(upTo: committedEnd)
                    lastSpeechEnd = committedEnd
                    await output.commit(upTo: Double(committedEnd) / sampleRate, endsLine: false)
                } else {
                    output.render()
                }
            }

            if finished { break }
        }

        preview?.stop()
        await output.finish()
    }
}

// MARK: - CaptionOutput

/// Output for the Whisper engine. Final lines come from Whisper, or from Apple's transcriber when
/// Whisper lost most of a stretch of audio. On a terminal, the words after the last final line are
/// shown as dimmed tentative text (from Apple's transcriber when available, else from Whisper).
@MainActor
final class CaptionOutput {
    var preview: ApplePreview?
    var translator: CaptionTranslator?
    var whisperTentative = ""

    private let format: OutputFormat
    private let live: Bool
    private let maxLength: Int
    private var line = LiveLine()
    private var segmentIndex = 0
    /// Audio before this time (in seconds) already has final text.
    private var committedTime = 0.0
    /// Whisper's final lines for the audio since the last commit.
    private var pending: [(text: String, start: Double, end: Double)] = []

    init(format: OutputFormat, live: Bool, maxLength: Int) {
        self.format = format
        self.live = live
        self.maxLength = maxLength
    }

    func add(_ text: String, start: Double, end: Double) {
        pending.append((text, start, end))
    }

    /// Marks audio up to `time` as final and writes its lines, hiding the preview words they replaced.
    /// If Whisper dropped most of what Apple's transcriber heard (e.g. it hallucinated and was filtered),
    /// Apple's text is written instead.
    ///
    /// In text output, the final text stays on the current line, with the preview's words continuing
    /// after it, until a sentence ends: at sentence-ending punctuation, when `endsLine` (the speaker
    /// paused for a while), or when the line grows long.
    ///
    /// With a translator, each line is translated once it's complete: in text output when the line
    /// ends, so whole sentences are translated rather than halves.
    func commit(upTo time: Double, endsLine: Bool) async {
        let commitEnd = max(committedTime, time)
        var lines = pending
        if let fallback = preview?.settle(pending.map(\.text).joined(), from: committedTime, to: commitEnd) {
            lines = [(fallback, committedTime, commitEnd)]
        }
        pending = []
        committedTime = commitEnd
        for (index, line) in lines.enumerated() {
            await write(line.text, start: line.start, end: line.end, endsLine: endsLine && index == lines.count - 1)
        }
        if endsLine, lines.isEmpty, let ended = line.endLine() {
            await printTranslation(of: ended)
        }
        render()
    }

    private func printTranslation(of text: String) async {
        guard let translator, let translation = await translator.translate(text), !translation.isEmpty else { return }
        line.printNote(translation)
    }

    func render() {
        guard live else { return }
        let text = preview?.text(after: committedTime) ?? whisperTentative
        if text.isEmpty { line.clear() } else { line.show(text, isFinal: false) }
    }

    func finish() async {
        if format == .txt {
            line.clear()
            if let ended = line.endLine() {
                await printTranslation(of: ended)
            }
            print()
        } else {
            if segmentIndex > 0 { print() }
            if let footer = format.footer {
                print(footer)
            }
        }
    }

    private func write(_ text: String, start: Double, end: Double, endsLine: Bool) async {
        if format == .txt {
            let endsSentence = text.last.map { "。！？!?…".contains($0) } ?? false
            let endsLine = endsLine || endsSentence || line.openLength + text.count > 80
            if let ended = line.appendFinal(text, endsLine: endsLine) {
                await printTranslation(of: ended)
            }
            return
        }
        let cues = splitCaption(text, start: start, end: end, maxLength: maxLength)
        // Translate the whole line, then share the translation out over its cues
        var translations: [String?] = Array(repeating: nil, count: cues.count)
        if let translator, let translation = await translator.translate(text) {
            translations = splitEvenly(translation, into: cues.count)
        }
        for (cue, translation) in zip(cues, translations) {
            let timeRange = CMTimeRange(
                start: CMTime(seconds: cue.start, preferredTimescale: 1000),
                end: CMTime(seconds: cue.end, preferredTimescale: 1000)
            )
            if segmentIndex > 0, let sep = format.segmentSeparator {
                print(sep, terminator: "")
            }
            segmentIndex += 1
            print(
                format.formatSegment(index: segmentIndex, timeRange: timeRange, text: cue.text, translation: translation),
                terminator: ""
            )
        }
        fflush(stdout)
    }
}

/// Splits `text` into `count` pieces of similar length at word boundaries.
func splitEvenly(_ text: String, into count: Int) -> [String?] {
    guard count > 1 else { return [text] }
    let pieceLength = (text.count + count - 1) / count
    var pieces: [String?] = splitCaption(text, start: 0, end: 1, maxLength: max(1, pieceLength)).map(\.text)
    while pieces.count > count {
        let last = pieces.removeLast() ?? ""
        let previous = pieces.removeLast() ?? ""
        let separator = previous.last?.isASCII == true && last.first?.isASCII == true ? " " : ""
        pieces.append(previous + separator + last)
    }
    while pieces.count < count {
        pieces.append(nil)
    }
    return pieces
}

/// Splits a caption longer than `maxLength` characters into evenly sized pieces at word boundaries
/// (which `NLTokenizer` finds for Japanese too), and divides its time range in proportion to each
/// piece's length. Boundaries after punctuation are preferred, then Japanese boundaries between a
/// particle and the next content word (kana followed by kanji or katakana), as in subtitles.
func splitCaption(
    _ text: String,
    start: Double,
    end: Double,
    maxLength: Int
) -> [(text: String, start: Double, end: Double)] {
    guard maxLength > 0, text.count > maxLength else { return [(text, start, end)] }

    // Possible cut points, as character offsets: after each word and any punctuation or spaces following it
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    func isHiragana(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) }
    }
    func isContentStart(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) || (0x30A0...0x30FF).contains($0.value) }
    }
    var cuts: [(offset: Int, bonus: Int)] = []
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
        var index = range.upperBound
        var afterPunctuation = false
        while index < text.endIndex, text[index].isPunctuation || text[index].isWhitespace {
            afterPunctuation = afterPunctuation || text[index].isPunctuation
            index = text.index(after: index)
        }
        guard index < text.endIndex, index > text.startIndex else { return true }
        let betweenWords = isHiragana(text[text.index(before: index)]) && isContentStart(text[index])
        cuts.append((text.distance(from: text.startIndex, to: index), afterPunctuation ? 4 : betweenWords ? 2 : 0))
        return true
    }

    // Cut nearest each evenly spaced target; a boundary after punctuation wins within a few characters
    func cutOffsets(pieceCount: Int) -> [Int] {
        var offsets: [Int] = [0]
        for piece in 1..<pieceCount {
            let target = text.count * piece / pieceCount
            let best = cuts
                .filter { $0.offset > offsets.last! }
                .min { cost($0, target) < cost($1, target) }
            if let best { offsets.append(best.offset) }
        }
        offsets.append(text.count)
        return offsets
    }
    func fits(_ offsets: [Int]) -> Bool {
        zip(offsets, offsets.dropFirst()).allSatisfy { $1 - $0 <= maxLength }
    }

    // Use more pieces until every piece fits; cut within a word only if no word boundary allows it
    var pieceCount = (text.count + maxLength - 1) / maxLength
    let mostPieces = pieceCount * 2
    var offsets = cutOffsets(pieceCount: pieceCount)
    while !fits(offsets), pieceCount < mostPieces {
        pieceCount += 1
        offsets = cutOffsets(pieceCount: pieceCount)
    }
    if !fits(offsets) {
        var fitted = [0]
        for offset in offsets.dropFirst() {
            while offset - fitted.last! > maxLength {
                fitted.append(fitted.last! + maxLength)
            }
            fitted.append(offset)
        }
        offsets = fitted
    }

    let characters = Array(text)
    return zip(offsets, offsets.dropFirst()).compactMap { from, to in
        let piece = String(characters[from..<to]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { return nil }
        return (
            piece,
            start + (end - start) * Double(from) / Double(text.count),
            start + (end - start) * Double(to) / Double(text.count)
        )
    }

    func cost(_ cut: (offset: Int, bonus: Int), _ target: Int) -> Int {
        abs(cut.offset - target) - cut.bonus
    }
}

// MARK: - PreviewInput

/// Forwards captured audio to Apple's transcriber once it has started. Used on the audio queue.
final class PreviewInput: @unchecked Sendable {
    private var preview: ApplePreview?

    func feed(_ buffer: AVAudioPCMBuffer) {
        preview?.feed(buffer)
    }

    /// Feeds `samples` (everything captured so far) to `preview`, then forwards live audio to it.
    func attach(_ preview: ApplePreview, replaying samples: [Float], format: AVAudioFormat) {
        let chunk = 1600
        for start in stride(from: 0, to: samples.count, by: chunk) {
            let count = min(chunk, samples.count - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.floatChannelData?[0] else { continue }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress! + start, count: count)
            }
            preview.feed(buffer)
        }
        self.preview = preview
    }
}

// MARK: - ApplePreview

/// Runs Apple's SpeechTranscriber on the same audio, to show words as soon as they're heard and to
/// supply text for lines Whisper loses. Both transcribers receive identical audio from the start of
/// capture, so their timelines line up.
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
        vocabulary: [String],
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
        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = vocabulary
            try await analyzer.setContext(context)
        }
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

            // Even two characters (はい, そう) are a complete reply, but filler alone (ん, っ) is not
            let previewLetters = letters(previewText)
            let previewContent = previewText.filter { !Self.isPunctuation($0) }
            // A short Whisper line in the wrong script ("Mira, Diego" for 未来永劫) while Apple heard Japanese
            // is a mishearing. Longer non-Japanese lines are kept: in a meeting someone may really speak English.
            // Apple must have heard more than a short reply, or an English "OK" would become Apple's 「はい」.
            let wrongScript = Self.hasJapanese(previewText) && !Self.hasJapanese(whisperText)
                && letters(whisperText) <= 12 && previewLetters >= 4
            if previewLetters >= 2, !previewContent.allSatisfy(WhisperFilter.fillerCharacters.contains),
               letters(whisperText) * 2 < previewLetters || wrongScript {
                volatileConsumed = estimatedCut
                return previewText.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if estimatedCut == characters.count || estimatedCut == volatileConsumed {
                volatileConsumed = estimatedCut
            } else {
                // Count Whisper's characters into the volatile text, past what Apple's finals covered.
                // Kanji and kana spellings of the same words differ in length, so move the cut to
                // punctuation close by, where Apple marks the pause that ended Whisper's sentence.
                var remaining = letters(whisperText) - letters(finalsText)
                var index = volatileConsumed
                while index < characters.count, remaining > 0 {
                    if !Self.isPunctuation(characters[index]) { remaining -= 1 }
                    index += 1
                }
                // Better still: where Whisper's last few characters also appear in Apple's text nearby
                let tail = Array(whisperText.filter { !Self.isPunctuation($0) }.suffix(3))
                let lowest = max(volatileConsumed + tail.count, index - 4)
                let highest = min(characters.count, index + 4)
                let candidates = lowest <= highest ? Array(lowest...highest) : []
                if tail.count == 3,
                   let match = candidates
                    .filter({ Array(characters[($0 - tail.count)..<$0]) == tail })
                    .min(by: { abs($0 - index) < abs($1 - index) }) {
                    index = match
                }
                let nearby = max(volatileConsumed, index - 3)..<min(characters.count, index + 3)
                if let punctuation = nearby
                    .filter({ Self.isPunctuation(characters[$0]) && !characters[$0].isWhitespace })
                    .min(by: { abs($0 + 1 - index) < abs($1 + 1 - index) }) {
                    index = punctuation + 1
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

    /// True when `text` contains Japanese: CJK punctuation, kana (including half-width) or kanji.
    static func hasJapanese(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            switch $0.value {
            case 0x3000...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF66...0xFF9F, 0x20000...0x3FFFD:
                true
            default:
                false
            }
        }
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
    /// RMS level below which a 30 ms frame counts as silence, until a noise floor has been measured.
    static let silenceThreshold: Float = 0.01

    static func rms(_ samples: [Float], from start: Int, length: Int = 480) -> Float {
        let end = min(start + length, samples.count)
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
    /// Phrases Whisper tends to invent on music or silence (learned from video subtitles). Matched as
    /// regular expressions to also catch misspellings like ご視力ありがとうございました, and only when
    /// the phrase is essentially the whole line, so real speech that contains these words is kept.
    static let knownHallucinations = [
        "ご視.{0,2}ありがとうございま(した|す)",
        "ご清聴ありがとうございま(した|す)",
        "最後までご視.{0,2}(いただき)?ありがとうございま(した|す)",
        "チャンネル登録(を)?(よろしく)?お願いします",
        "字幕.{0,12}(作成|提供|制作)",
        "thank(s| you) (so much )?for watching",
    ]

    /// Fillers Whisper emits for breaths, grunts and sound effects.
    static let fillerCharacters = Set("んンーっッ〜")

    static func letters(_ text: String) -> String {
        text.filter { !$0.isPunctuation && !$0.isWhitespace && !$0.isSymbol }
    }

    static func isLikelyHallucination(_ segment: TranscriptionSegment) -> Bool {
        isLikelyHallucination(segment.text)
    }

    static func isLikelyHallucination(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = letters(text)
        if content.isEmpty { return true }
        if content.allSatisfy(fillerCharacters.contains) { return true }
        return knownHallucinations.contains { pattern in
            guard let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
                return false
            }
            return letters(String(text[range])).count * 5 >= content.count * 4
        }
    }

    /// Whisper thinks there's no speech, is very unsure of what it heard, is stuck in a loop, or is
    /// reciting the vocabulary prompt. Only applied to final text: tentative guesses on partial speech
    /// are often low-confidence, and hiding them would delay the captions.
    static func isUnreliable(_ segment: TranscriptionSegment, vocabulary: [String] = []) -> Bool {
        let content = letters(segment.text)
        if segment.noSpeechProb > 0.6, content.count <= 4 || segment.avgLogprob < -1 { return true }
        if segment.avgLogprob < -1.2 || segment.compressionRatio > 2.4 { return true }
        return hasRepeatedPhrase(content) || recitesVocabulary(content, vocabulary: vocabulary)
    }

    /// True when a phrase of 2–20 characters repeats back to back for at least 20 characters, making up
    /// at least half the line. Whisper loops like this on music and noise; ordinary reduplication
    /// (なるほどなるほどなるほど, はいはいはいはい) is much shorter.
    static func hasRepeatedPhrase(_ text: String) -> Bool {
        let characters = Array(text)
        guard characters.count >= 20 else { return false }
        for length in 2...20 {
            var start = 0
            while start + length * 2 <= characters.count {
                var repeats = 1
                while start + (repeats + 1) * length <= characters.count,
                      characters[(start + repeats * length)..<(start + (repeats + 1) * length)]
                      == characters[start..<(start + length)] {
                    repeats += 1
                }
                let span = repeats * length
                if repeats >= 3, span >= 20, span * 2 >= characters.count {
                    return true
                }
                start += 1
            }
        }
        return false
    }

    /// True when the line is the vocabulary list read back: at least four different terms, in the
    /// order of the list, with almost nothing else. Whisper does this when it echoes its prompt;
    /// real dialogue that mentions several terms has particles and other words between them.
    static func recitesVocabulary(_ text: String, vocabulary: [String]) -> Bool {
        let terms = vocabulary.enumerated()
            .map { (index: $0.offset, term: letters($0.element)) }
            .filter { !$0.term.isEmpty }
            .sorted { $0.term.count > $1.term.count }
        guard !terms.isEmpty else { return false }

        // Match the longest term at each position, so 黄金聖闘士 isn't also counted as 聖闘士
        var matches: [Int] = []
        var unmatched = 0
        var rest = Substring(text)
        while !rest.isEmpty {
            if let match = terms.first(where: { rest.hasPrefix($0.term) }) {
                matches.append(match.index)
                rest = rest.dropFirst(match.term.count)
            } else {
                unmatched += 1
                rest = rest.dropFirst()
            }
        }
        guard Set(matches).count >= 4, unmatched * 10 <= text.count else { return false }
        let inOrder = zip(matches, matches.dropFirst()).filter { $0 < $1 }.count
        return inOrder * 5 >= (matches.count - 1) * 4
    }

    /// True when two lines are the same speech transcribed twice: nearly the same length and nearly
    /// all of their character pairs in common. Lines that merely share a phrase (十二宮の聖闘士たち,
    /// 十二宮の黄金聖闘士たち) are different lines.
    static func isNearDuplicate(_ a: String, _ b: String) -> Bool {
        let x = Array(letters(a))
        let y = Array(letters(b))
        let (shorter, longer) = (min(x.count, y.count), max(x.count, y.count))
        guard shorter > 6 else { return x == y }
        guard shorter * 5 >= longer * 4 else { return false }

        func bigrams(_ characters: [Character]) -> Set<String> {
            Set((0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) })
        }
        let (bx, by) = (bigrams(x), bigrams(y))
        return Double(bx.intersection(by).count) / Double(bx.union(by).count) >= 0.8
    }
}

// MARK: - WhisperModelStore

enum WhisperModelStore {
    static let defaultRepo = "argmaxinc/whisperkit-coreml"

    /// Short names for models outside the default repository, as (repository, variant).
    static let shortcuts: [String: (repo: String, variant: String)] = [
        // Whisper large-v3 distilled and retrained on Japanese TV speech (ReazonSpeech) by Kotoba
        // Technologies; community Core ML conversion
        "kotoba-whisper-v2.2": ("yslinear/kotoba-whisper-v2.2-coreml", "kotoba-tech_kotoba-whisper-v2.2"),
    ]

    /// Models are kept in ~/Library/Application Support/yap/whisper.
    static var downloadBase: URL {
        URL.applicationSupportDirectory.appending(path: "yap/whisper", directoryHint: .isDirectory)
    }

    static func localFolder(variant: String, repo: String) -> URL {
        downloadBase.appending(path: "models/\(repo)/\(variant)", directoryHint: .isDirectory)
    }

    /// Downloads the model on first use (with a progress bar) and loads it. `model` is a variant
    /// name in `repo` (default: `defaultRepo`) or one of the `shortcuts`.
    static func load(model: String, repo: String?) async throws -> WhisperKit {
        let shortcut = shortcuts[model]
        let variant = shortcut?.variant ?? model
        let repo = repo ?? shortcut?.repo ?? defaultRepo
        var folder = localFolder(variant: variant, repo: repo)
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
