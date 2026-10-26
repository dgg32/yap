import ArgumentParser
import CoreML
import Foundation

// MARK: - SpeechActivity

/// Which detector decides where speech starts and pauses with `--engine whisper`.
enum VoiceActivityDetector: String, ExpressibleByArgument, CaseIterable {
    /// Silero VAD, a small neural network that tells speech from silence, noise and music
    case silero
    /// Loudness compared with the recent background level
    case energy
}

/// Frame-by-frame speech detection over the captured audio. Positions are absolute sample indices
/// from the start of capture, so they stay valid as finalized audio is dropped.
protocol SpeechActivity: AnyObject {
    /// Samples per frame.
    var frameLength: Int { get }
    /// Number of complete frames analyzed so far.
    var frameCount: Int { get }
    /// Analyzes the next captured samples, continuing from the previous call.
    func add(_ samples: ArraySlice<Float>)
    /// True for speech, false for silence, nil when undecided (the frame keeps the state before it).
    func isSpeech(frame: Int) -> Bool?
    /// How speech-like a frame is; lower is quieter. Used to pick a split point.
    func level(frame: Int) -> Float
}

extension SpeechActivity {
    private func frames(in range: Range<Int>) -> Range<Int> {
        let first = (range.lowerBound + frameLength - 1) / frameLength
        let last = min(range.upperBound / frameLength, frameCount)
        return first..<max(first, last)
    }

    /// Start of the first speech frame in `range`, or nil if there's no speech.
    func firstSpeech(in range: Range<Int>) -> Int? {
        frames(in: range).first { isSpeech(frame: $0) == true }.map { $0 * frameLength }
    }

    /// The first run of silence at least `minimumLength` samples long that follows speech in `range`.
    func firstPause(in range: Range<Int>, minimumLength: Int) -> Range<Int>? {
        let frames = frames(in: range)
        var heardSpeech = false
        var silenceStart: Int?
        for frame in frames {
            switch isSpeech(frame: frame) {
            case true:
                if let silenceStart, frame * frameLength - silenceStart >= minimumLength {
                    return silenceStart..<(frame * frameLength)
                }
                heardSpeech = true
                silenceStart = nil
            case false:
                if heardSpeech, silenceStart == nil { silenceStart = frame * frameLength }
            case nil:
                break
            }
        }
        let analyzedEnd = frames.upperBound * frameLength
        if let silenceStart, analyzedEnd - silenceStart >= minimumLength {
            return silenceStart..<analyzedEnd
        }
        return nil
    }

    /// Start of the silence after the last speech in `range`, if it lasts to the end of the analyzed
    /// audio: a pause that may still be growing. Matches the start `firstPause` would report for it.
    func trailingSilence(in range: Range<Int>) -> Int? {
        let frames = frames(in: range)
        guard let lastSpeech = frames.last(where: { isSpeech(frame: $0) == true }) else { return nil }
        return frames[(lastSpeech + 1)...].first { isSpeech(frame: $0) == false }.map { $0 * frameLength }
    }

    /// Middle of the least speech-like 300 ms within `range`, the best place to split speech without a pause.
    func quietestPoint(in range: Range<Int>) -> Int {
        let frames = Array(frames(in: range))
        let window = max(1, 4800 / frameLength)
        guard frames.count > window else { return range.upperBound }
        var best = 0
        var bestLevel = Float.infinity
        for index in 0...(frames.count - window) {
            let level = frames[index..<(index + window)].reduce(0) { $0 + self.level(frame: $1) }
            if level < bestLevel {
                bestLevel = level
                best = index
            }
        }
        return min((frames[best] + window / 2) * frameLength, range.upperBound)
    }
}

// MARK: - EnergyActivity

/// Speech is anything louder than the background level of the last 20 seconds, so that steady
/// background music counts as silence and pauses in the dialogue over it can still be found.
final class EnergyActivity: SpeechActivity {
    let frameLength = 480
    private var levels: [Float] = []
    private var remainder: [Float] = []

    var frameCount: Int { levels.count }

    func add(_ samples: ArraySlice<Float>) {
        remainder.append(contentsOf: samples)
        let frames = remainder.count / frameLength
        guard frames > 0 else { return }
        for frame in 0..<frames {
            levels.append(AudioLevel.rms(remainder, from: frame * frameLength))
        }
        remainder.removeFirst(frames * frameLength)
    }

    func isSpeech(frame: Int) -> Bool? {
        levels[frame] >= threshold(at: frame)
    }

    func level(frame: Int) -> Float {
        levels[frame]
    }

    /// 6 dB above the quietest tenth of the 20 seconds before `frame`, with limits so near-digital
    /// silence still counts as silence and loud speech is never mistaken for it. Until there's a
    /// second of audio to measure, a fixed threshold is used.
    func threshold(at frame: Int) -> Float {
        let second = 16000 / frameLength
        guard frame + 1 >= second else { return AudioLevel.silenceThreshold }
        // Recomputing for every frame would be slow; the floor changes slowly, so sample it once a second
        let bucket = frame / second
        if let cached = thresholdCache[bucket] { return cached }
        // Leave out digital silence (the padding injected while nothing plays), which isn't background
        let window = levels[max(0, frame - 20 * second)...frame].filter { $0 > 0.0005 }
        guard window.count >= second else {
            thresholdCache[bucket] = AudioLevel.silenceThreshold
            return AudioLevel.silenceThreshold
        }
        let floor = window.sorted()[window.count / 10]
        let threshold = min(max(floor * 2, 0.005), 0.15)
        thresholdCache[bucket] = threshold
        return threshold
    }

    private var thresholdCache: [Int: Float] = [:]
}

// MARK: - SileroActivity

/// Silero VAD (https://github.com/snakers4/silero-vad, MIT), via FluidInference's Core ML conversion.
/// It scores every 32 ms of audio as speech or not, and tells speech from music and noise far better
/// than loudness does.
final class SileroActivity: SpeechActivity {
    let frameLength = 512
    private static let contextLength = 64
    private static let stateLength = 128
    /// Silero's recommended thresholds: speech starts above 0.5 and ends below 0.35.
    private static let speechThreshold: Float = 0.5
    private static let silenceThreshold: Float = 0.35

    private let model: MLModel
    private let audioInput: MLMultiArray
    private var hiddenState: MLMultiArray
    private var cellState: MLMultiArray
    private var context = [Float](repeating: 0, count: contextLength)
    private var remainder: [Float] = []
    private var probabilities: [Float] = []

    var frameCount: Int { probabilities.count }

    init(modelURL: URL) throws {
        let configuration = MLModelConfiguration()
        // The model is tiny; the CPU avoids Neural Engine scheduling overhead for 32 ms steps
        configuration.computeUnits = .cpuOnly
        model = try MLModel(contentsOf: modelURL, configuration: configuration)
        audioInput = try MLMultiArray(shape: [1, NSNumber(value: Self.contextLength + 512)], dataType: .float32)
        hiddenState = try Self.zeros(Self.stateLength)
        cellState = try Self.zeros(Self.stateLength)
    }

    func add(_ samples: ArraySlice<Float>) {
        remainder.append(contentsOf: samples)
        let frames = remainder.count / frameLength
        guard frames > 0 else { return }
        for frame in 0..<frames {
            let chunk = remainder[(frame * frameLength)..<((frame + 1) * frameLength)]
            probabilities.append((try? predict(chunk)) ?? 0)
        }
        remainder.removeFirst(frames * frameLength)
    }

    func isSpeech(frame: Int) -> Bool? {
        let probability = probabilities[frame]
        if probability >= Self.speechThreshold { return true }
        if probability < Self.silenceThreshold { return false }
        return nil
    }

    func level(frame: Int) -> Float {
        probabilities[frame]
    }

    private func predict(_ chunk: ArraySlice<Float>) throws -> Float {
        let input = audioInput.dataPointer.assumingMemoryBound(to: Float.self)
        context.withUnsafeBufferPointer { input.update(from: $0.baseAddress!, count: Self.contextLength) }
        chunk.withUnsafeBufferPointer { (input + Self.contextLength).update(from: $0.baseAddress!, count: frameLength) }
        context = Array(chunk.suffix(Self.contextLength))

        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_input": audioInput,
            "hidden_state": hiddenState,
            "cell_state": cellState,
        ]))
        guard let probability = output.featureValue(for: "vad_output")?.multiArrayValue,
              let newHidden = output.featureValue(for: "new_hidden_state")?.multiArrayValue,
              let newCell = output.featureValue(for: "new_cell_state")?.multiArrayValue else {
            return 0
        }
        hiddenState = newHidden
        cellState = newCell
        return probability[0].floatValue
    }

    private static func zeros(_ count: Int) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, NSNumber(value: count)], dataType: .float32)
        array.dataPointer.assumingMemoryBound(to: Float.self).initialize(repeating: 0, count: count)
        return array
    }
}

// MARK: - SileroModelStore

/// Downloads the Silero model (under 1 MB) on first use to ~/Library/Application Support/yap/vad.
enum SileroModelStore {
    static let repo = "FluidInference/silero-vad-coreml"
    static let model = "silero-vad-unified-v6.0.0.mlmodelc"
    static let files = [
        "coremldata.bin",
        "metadata.json",
        "model.mil",
        "weights/weight.bin",
        "analytics/coremldata.bin",
    ]

    static var folder: URL {
        URL.applicationSupportDirectory.appending(path: "yap/vad/\(model)", directoryHint: .isDirectory)
    }

    static func load() async throws -> SileroActivity {
        let folder = folder
        let fileManager = FileManager.default
        if !files.allSatisfy({ fileManager.fileExists(atPath: folder.appending(path: $0).path) }) {
            let staging = folder.deletingLastPathComponent().appending(path: "\(model).download", directoryHint: .isDirectory)
            try? fileManager.removeItem(at: staging)
            for file in files {
                let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(model)/\(file)")!
                let (downloaded, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let destination = staging.appending(path: file)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.moveItem(at: downloaded, to: destination)
            }
            // Move into place only once complete, so an interrupted download is retried next time
            try? fileManager.removeItem(at: folder)
            try fileManager.moveItem(at: staging, to: folder)
        }
        return try SileroActivity(modelURL: folder)
    }
}
