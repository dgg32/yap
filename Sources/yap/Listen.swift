import ArgumentParser
@preconcurrency import AVFoundation
import CoreMedia
@preconcurrency import Noora
import ScreenCaptureKit
import Speech

private nonisolated(unsafe) var listenSignalWriteFD: Int32 = -1

// MARK: - Listen

struct Listen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Transcribe live system audio in real time."
    )

    @Option(
        name: .shortAndLong,
        help: "(default: current)",
        transform: Locale.init(identifier:)
    ) var locale: Locale = .init(identifier: Locale.current.identifier)

    @Flag(
        help: "Replaces certain words and phrases with a redacted form."
    ) var censor: Bool = false

    @Flag(
        help: "Output format for the transcription."
    ) var outputFormat: OutputFormat = .txt

    @Option(
        name: .shortAndLong,
        help: "Maximum sentence length in characters for timed output formats."
    ) var maxLength: Int = 40

    @Flag(
        help: "Include word-level timestamps in JSON output."
    ) var wordTimestamps: Bool = false

    @Flag(
        inversion: .prefixedNo,
        help: "Favor responsiveness over accuracy. Use --no-fast for more accurate but slower results."
    ) var fast: Bool = true

    @Option(
        help: "Path to a text file of names and terms to expect, one per line (lines starting with # are ignored)."
    ) var vocabulary: String?

    @Option(
        help: "Speech recognition engine: apple (on-device Speech framework) or whisper (WhisperKit, more accurate)."
    ) var engine: ListenEngine = .apple

    @Option(
        help: ArgumentHelp(
            "WhisperKit model variant used with --engine whisper. Downloaded on first use.",
            discussion: "Shortcuts: \(WhisperModelStore.shortcuts.keys.sorted().joined(separator: ", "))."
        )
    ) var whisperModel: String = "openai_whisper-large-v3-v20240930"

    @Option(
        help: "Hugging Face repository to download --whisper-model from. (default: argmaxinc/whisperkit-coreml, or the shortcut's repository)"
    ) var whisperRepo: String?

    @Option(
        help: "With --engine whisper, how to detect speech and pauses: silero (neural voice detection) or energy (loudness)."
    ) var vad: VoiceActivityDetector = .silero

    @Flag(
        inversion: .prefixedNo,
        help: "With --engine whisper, also run Apple's engine to stream words live and to fill in lines Whisper loses."
    ) var preview: Bool = true

    @Option(
        help: ArgumentHelp(
            "With --engine whisper, translate each final line into this language (e.g. en, zh-Hans, zh-Hant).",
            discussion: "Uses Apple's on-device translation. Install the languages first in System Settings > General > Language & Region > Translation Languages."
        )
    ) var translate: String?

    @Flag(
        help: "With --engine whisper, show the hiragana reading of each final line that has kanji."
    ) var reading: Bool = false

    @Option(
        help: ArgumentHelp(
            "Play an audio or video file through the live pipeline instead of capturing system audio.",
            discussion: "For trying changes on the same recording. Plays in real time unless --input-speed says otherwise. MKV and other formats AVFoundation can't read need ffmpeg."
        )
    ) var input: String?

    @Option(
        help: "With --input, how many times faster than real time to play the file."
    ) var inputSpeed: Double = 1

    func validate() throws {
        if translate != nil, engine != .whisper {
            throw ValidationError("--translate requires --engine whisper.")
        }
        if reading, engine != .whisper {
            throw ValidationError("--reading requires --engine whisper.")
        }
        if inputSpeed <= 0 {
            throw ValidationError("--input-speed must be greater than 0.")
        }
    }

    @MainActor mutating func run() async throws {
        var contextualStrings: [String] = []
        if let vocabulary {
            let contents: String
            do {
                contents = try String(contentsOfFile: vocabulary, encoding: .utf8)
            } catch {
                throw ListenError.unreadableVocabulary(vocabulary)
            }
            contextualStrings = contents
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }

        if engine == .whisper {
            try await runWhisper(vocabulary: contextualStrings)
            return
        }

        try await reserveSpeechAssets(for: locale)

        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: censor ? [.etiquetteReplacements] : [],
            reportingOptions: fast ? [.volatileResults, .fastResults] : [.volatileResults],
            attributeOptions: outputFormat.needsAudioTimeRange ? [.audioTimeRange] : []
        )
        let modules: [any SpeechModule] = [transcriber]

        try await installSpeechAssets(for: locale, modules: modules)

        let analyzer = SpeechAnalyzer(modules: modules)
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try await analyzer.setContext(context)
        }

        // Set up streaming input
        let (inputSequence, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)

        // Get target audio format from the analyzer
        guard let targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
            throw ListenError.noCompatibleAudioFormat
        }

        let source = try await makeAudioSource(input: input, speed: inputSpeed, format: targetFormat) {
            inputContinuation.yield(AnalyzerInput(buffer: $0))
        }

        // Load the model up front so the first words aren't delayed
        try await analyzer.prepareToAnalyze(in: targetFormat)

        let shutdown = once {
            await source.stop()
            inputContinuation.finish()
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        try await source.start(onEnd: shutdown)

        // Start the analyzer with streaming input
        try await analyzer.start(inputSequence: inputSequence)

        onInterrupt(shutdown)

        // Stream results as they arrive
        let format = outputFormat
        let sentenceMaxLength = maxLength
        if format == .txt {
            var line = LiveLine()
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                line.show(text, isFinal: result.isFinal)
            }
            print()
        } else {
            if let header = format.header(locale: locale) {
                print(header)
            }
            let includeWords = wordTimestamps
            var segmentIndex = 0
            for try await result in transcriber.results {
                guard result.isFinal else { continue }
                for chunk in result.text.splitAtTimeGaps(threshold: 1.5) {
                    let allWords = includeWords ? chunk.wordTimestamps() : nil
                    for sentence in chunk.sentences(maxLength: sentenceMaxLength) {
                        guard let timeRange = sentence.audioTimeRange else { continue }
                        let text = String(sentence.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        let words = allWords?.filter {
                            $0.timeRange.start.seconds >= timeRange.start.seconds
                                && $0.timeRange.end.seconds <= timeRange.end.seconds
                        }
                        if segmentIndex > 0, let sep = format.segmentSeparator {
                            print(sep, terminator: "")
                        }
                        segmentIndex += 1
                        print(format.formatSegment(index: segmentIndex, timeRange: timeRange, text: text, words: words), terminator: "")
                        fflush(stdout)
                    }
                }
            }
            if segmentIndex > 0 { print() }
            if let footer = format.footer {
                print(footer)
            }
        }
    }
}

// MARK: - Shared live capture helpers

enum ListenEngine: String, ExpressibleByArgument, CaseIterable {
    case apple
    case whisper
}

/// Checks that the Speech framework supports `locale` and reserves its assets.
func reserveSpeechAssets(for locale: Locale) async throws {
    guard SpeechTranscriber.isAvailable else {
        throw Transcribe.Error.speechTranscriberNotAvailable
    }

    let supportedLocales = await SpeechTranscriber.supportedLocales
    guard supportedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
        throw Transcribe.Error.unsupportedLocale
    }

    for locale in await AssetInventory.reservedLocales {
        await AssetInventory.release(reservedLocale: locale)
    }
    try await AssetInventory.reserve(locale: locale)
}

/// Downloads the Speech framework assets for `modules` if they aren't installed yet.
func installSpeechAssets(for locale: Locale, modules: [any SpeechModule]) async throws {
    let installedLocales = await SpeechTranscriber.installedLocales
    if !installedLocales.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
        let piped = isatty(STDOUT_FILENO) == 0
        struct DevNull: StandardPipelining { func write(content _: String) {} }
        let noora = if piped {
            Noora(standardPipelines: .init(output: DevNull()))
        } else {
            Noora()
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await noora.progressBarStep(
                message: "Downloading required assets…"
            ) { @Sendable progressCallback in
                struct ReportProgress: @unchecked Sendable {
                    let callAsFunction: (Double) -> Void
                }
                let reportProgress = ReportProgress(callAsFunction: progressCallback)
                try await withThrowingDiscardingTaskGroup { group in
                    group.addTask {
                        while !Task.isCancelled, !request.progress.isFinished {
                            reportProgress.callAsFunction(request.progress.fractionCompleted)
                            try await Task.sleep(for: .seconds(0.1))
                        }
                    }
                    try await request.downloadAndInstall()
                    group.cancelAll()
                }
            }
        }
    }
}

/// Creates a ScreenCaptureKit stream that delivers system audio to `delegate`.
/// Requires Screen Recording permission for the terminal app.
func makeSystemAudioStream(format: AVAudioFormat, delegate: AudioStreamDelegate) async throws -> SCStream {
    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    } catch {
        throw ListenError.screenRecordingPermissionDenied
    }
    guard let display = content.displays.first else {
        throw ListenError.screenRecordingPermissionDenied
    }

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let streamConfig = SCStreamConfiguration()
    streamConfig.capturesAudio = true
    streamConfig.sampleRate = Int(format.sampleRate)
    streamConfig.channelCount = Int(format.channelCount)
    streamConfig.excludesCurrentProcessAudio = true
    // Minimal video settings since we only need audio
    streamConfig.width = 2
    streamConfig.height = 2
    streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)

    let stream = SCStream(filter: filter, configuration: streamConfig, delegate: nil)
    try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: delegate.queue)
    return stream
}

/// Suppresses the ^C echo, prints the "Listening…" hint, and runs `shutdown` once on Ctrl+C.
func onInterrupt(_ shutdown: @escaping @Sendable () async -> Void) {
    var signalPipe: [Int32] = [0, 0]
    pipe(&signalPipe)
    let signalReadFD = signalPipe[0]
    listenSignalWriteFD = signalPipe[1]

    var originalTermios = termios()
    let hasTerminal = isatty(STDIN_FILENO) != 0
    if hasTerminal {
        tcgetattr(STDIN_FILENO, &originalTermios)
        var raw = originalTermios
        raw.c_lflag &= ~UInt(ECHOCTL)
        tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    }

    signal(SIGINT) { _ in
        _ = write(listenSignalWriteFD, "x", 1)
    }

    if isatty(STDERR_FILENO) != 0 {
        FileHandle.standardError.write(Data("Listening… Press Ctrl+C to stop.\n".utf8))
    }

    nonisolated(unsafe) var savedTermios = originalTermios
    Task.detached {
        var buf: UInt8 = 0
        _ = read(signalReadFD, &buf, 1)
        close(signalReadFD)
        close(listenSignalWriteFD)
        if hasTerminal {
            tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
        }
        await shutdown()
    }
}

/// Prints live text output. A line holds final text followed by dimmed tentative text, redrawn in
/// place as either changes. Final text can be added to a line without ending it, so the tentative
/// text continues right after it on the same line. When stdout is not a terminal, only final text
/// is printed, one line at a time.
struct LiveLine {
    private let redraw = isatty(STDOUT_FILENO) != 0
    /// Terminal rows the current line occupies.
    private var rows = 0
    /// Final text on the current line, which hasn't ended yet.
    private var open = ""
    private var tentative = ""

    /// Number of final characters on the current line.
    var openLength: Int { open.count }

    mutating func show(_ text: String, isFinal: Bool) {
        if isFinal {
            appendFinal(text, endsLine: true)
        } else {
            tentative = text
            draw(endingLine: false)
        }
    }

    /// Adds final text to the current line, ending the line if `endsLine`. Returns the ended line's text.
    @discardableResult
    mutating func appendFinal(_ text: String, endsLine: Bool) -> String? {
        // Japanese needs no space between the pieces of a line, but English words do
        if let last = open.last, let first = text.first, last.isASCII, first.isASCII,
           last.isLetter || last.isNumber || last.isPunctuation, first.isLetter || first.isNumber {
            open += " "
        }
        open += text
        guard endsLine else {
            draw(endingLine: false)
            return nil
        }
        let ended = open
        tentative = ""
        draw(endingLine: true)
        return ended
    }

    /// Removes the tentative text, keeping the line's final text.
    mutating func clear() {
        guard !tentative.isEmpty else { return }
        tentative = ""
        draw(endingLine: false)
    }

    /// Ends the current line if it has final text. Returns the ended line's text.
    @discardableResult
    mutating func endLine() -> String? {
        guard !open.isEmpty else { return nil }
        let ended = open
        tentative = ""
        draw(endingLine: true)
        return ended
    }

    /// Prints a note line (such as a translation) under the last ended line, in a different color.
    /// The current line, if any, is drawn again below it.
    /// Prints `note` (like a translation) on its own line in `color` (an ANSI color code), above the open line.
    mutating func printNote(_ note: String, color: Int = 36) {
        defer { fflush(stdout) }
        guard redraw else {
            print(note)
            return
        }
        if rows > 1 { print("\u{1B}[\(rows - 1)A", terminator: "") }
        print("\r\u{1B}[J\u{1B}[\(color)m\(note)\u{1B}[0m")
        rows = 0
        draw(endingLine: false)
    }

    private mutating func draw(endingLine: Bool) {
        defer { fflush(stdout) }
        guard redraw else {
            if endingLine {
                print(open)
                open = ""
            }
            return
        }
        // Erase the line, which may have wrapped over several rows: move up to its first row,
        // return to column 0, and clear to the end of the screen. Then draw it again.
        if rows > 1 { print("\u{1B}[\(rows - 1)A", terminator: "") }
        print("\r\u{1B}[J\(open)", terminator: "")
        if !tentative.isEmpty {
            print("\u{1B}[2m\(tentative)\u{1B}[0m", terminator: "")
        }
        if endingLine {
            print()
            open = ""
            rows = 0
        } else {
            rows = open.isEmpty && tentative.isEmpty ? 0 : terminalRows(for: open + tentative)
        }
    }
}

/// Number of terminal rows `text` occupies once wrapped, counting East Asian wide characters as two columns.
func terminalRows(for text: String) -> Int {
    var size = winsize()
    let columns = ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 80
    let width = text.unicodeScalars.reduce(0) { $0 + displayWidth(of: $1) }
    return max(1, (width + columns - 1) / columns)
}

func displayWidth(of scalar: Unicode.Scalar) -> Int {
    let v = scalar.value
    if scalar.properties.generalCategory == .nonspacingMark || (0x200B...0x200F).contains(v)
        || (0xFE00...0xFE0F).contains(v) { return 0 }
    switch v {
    case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
         0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
         0xFFE0...0xFFE6, 0x1F000...0x1FAFF, 0x20000...0x3FFFD:
        return 2
    default:
        return 1
    }
}

// MARK: - AudioStreamDelegate

final class AudioStreamDelegate: NSObject, SCStreamOutput, @unchecked Sendable {
    // MARK: Lifecycle

    init(targetFormat: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        self.targetFormat = targetFormat
        self.onBuffer = onBuffer
    }

    convenience init(targetFormat: AVAudioFormat, inputContinuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.init(targetFormat: targetFormat) { inputContinuation.yield(AnalyzerInput(buffer: $0)) }
    }

    // MARK: Internal

    let targetFormat: AVAudioFormat
    let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    var converter: AVAudioConverter?
    /// Serial queue for sample buffers and silence padding.
    let queue = DispatchQueue(label: "yap.listen.audio")
    private var lastInputTime = DispatchTime.now()
    private var silenceTimer: DispatchSourceTimer?

    /// ScreenCaptureKit stops delivering buffers while nothing is playing, which stalls the
    /// analyzer on the last utterance until new audio arrives. Feed silence during such gaps
    /// so short lines are transcribed and finalized promptly.
    func startSilencePadding(interval: Double = 0.1) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let gap = Double(DispatchTime.now().uptimeNanoseconds - lastInputTime.uptimeNanoseconds) / 1e9
            guard gap >= interval * 2 else { return }
            let frames = AVAudioFrameCount(targetFormat.sampleRate * interval)
            guard let silence = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frames) else { return }
            silence.frameLength = frames
            for buffer in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            onBuffer(silence)
            lastInputTime = lastInputTime + interval
        }
        silenceTimer = timer
        timer.resume()
    }

    func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }

        guard let formatDescription = sampleBuffer.formatDescription,
              let sourceStreamDescription = formatDescription.audioStreamBasicDescription else { return }

        guard let sourceFormat = AVAudioFormat(
            standardFormatWithSampleRate: sourceStreamDescription.mSampleRate,
            channels: sourceStreamDescription.mChannelsPerFrame
        ) else { return }

        if converter == nil || converter?.inputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }

        guard let converter else { return }

        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let sourcePCMBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    bufferListNoCopy: audioBufferList.unsafePointer
                ) else { return }

                let frameCapacity = AVAudioFrameCount(
                    ceil(Double(sourcePCMBuffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate)
                )
                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else { return }

                var error: NSError?
                nonisolated(unsafe) var consumed = false
                nonisolated(unsafe) let sourceBuffer = sourcePCMBuffer
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    if consumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    consumed = true
                    outStatus.pointee = .haveData
                    return sourceBuffer
                }

                if error == nil, convertedBuffer.frameLength > 0 {
                    onBuffer(convertedBuffer)
                    lastInputTime = .now()
                }
            }
        } catch {
            // Skip malformed audio buffers
        }
    }
}

// MARK: - ListenError

enum ListenError: Swift.Error, LocalizedError {
    case screenRecordingPermissionDenied
    case noCompatibleAudioFormat
    case unreadableVocabulary(String)
    case unreadableInput(String, reason: String)

    // MARK: Internal

    var errorDescription: String? {
        switch self {
        case .screenRecordingPermissionDenied:
            "Screen Recording permission is required. Grant it to your terminal app in System Settings > Privacy & Security > Screen Recording, then restart the terminal."
        case .noCompatibleAudioFormat:
            "No compatible audio format available for speech recognition."
        case let .unreadableVocabulary(path):
            "Could not read vocabulary file at \(path)."
        case let .unreadableInput(path, reason):
            "Could not read \(path). \(reason)"
        }
    }
}
