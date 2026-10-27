import Foundation

// MARK: - DebugTiming

/// With `YAP_DEBUG_TIMING=1`, reports on stderr how long each final line took: from the end of its
/// speech, through waiting for the pause, to Whisper's decode (and its temperature fallbacks), to the
/// line being written. A summary follows at the end of the session.
@MainActor
final class DebugTiming {
    static let isEnabled = ProcessInfo.processInfo.environment["YAP_DEBUG_TIMING"] == "1"

    private let start = Date()
    private let sampleRate: Double
    /// Seconds of audio per second of wall time (`--input-speed`; 1 for live capture).
    private let speed: Double
    private var decodeStart = Date()
    private var decode = 0.0
    private var fallbacks = 0
    private var speculationsUsed = 0
    private var speculationsWasted = 0
    private var lines: [(latency: Double, wait: Double, decode: Double, fallbacks: Int)] = []

    init(sampleRate: Double, speed: Double) {
        self.sampleRate = sampleRate
        self.speed = speed
    }

    /// Wall time since the sample at `sample` was captured.
    private func age(of sample: Int) -> Double {
        Date().timeIntervalSince(start) - Double(sample) / sampleRate / speed
    }

    func decodeBegan() {
        decodeStart = Date()
    }

    /// `temperatures` are those of the decoded segments: each fallback raises it by 0.2.
    func decodeEnded(temperatures: [Float]) {
        decode = Date().timeIntervalSince(decodeStart)
        fallbacks = Int(((temperatures.max() ?? 0) / 0.2).rounded())
    }

    /// The line's transcription was made during its pause, so its decode didn't add to the wait.
    func speculationUsed() {
        decode = 0
        speculationsUsed += 1
    }

    func speculationWasted() {
        speculationsWasted += 1
    }

    /// Call after the line for speech ending at `speechEnd` (a sample index) has been written.
    func lineWritten(speechEnd: Int, audioLength: Int, reason: String) {
        let latency = age(of: speechEnd)
        let wait = max(0, latency - decode)
        lines.append((latency, wait, decode, fallbacks))
        FileHandle.standardError.write(Data(String(
            format: "[timing] %-6@ %5.1f s of audio · waited %.2f s · decode %.2f s%@ · line %.2f s after speech ended\n",
            reason, Double(audioLength) / sampleRate, wait, decode,
            fallbacks > 0 ? " (\(fallbacks) fallback\(fallbacks == 1 ? "" : "s"))" : "", latency
        ).utf8))
    }

    func summary() {
        guard !lines.isEmpty else { return }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        let withFallback = lines.filter { $0.fallbacks > 0 }
        FileHandle.standardError.write(Data(String(
            format: "[timing] %d lines · median %.2f s after speech ended (wait %.2f s, decode %.2f s) · worst %.2f s · %d with fallbacks, %.1f s of decoding in them · speculative decodes %d used, %d wasted\n",
            lines.count, median(lines.map(\.latency)), median(lines.map(\.wait)), median(lines.map(\.decode)),
            lines.map(\.latency).max() ?? 0, withFallback.count, withFallback.map(\.decode).reduce(0, +), speculationsUsed, speculationsWasted
        ).utf8))
    }
}

// MARK: - DebugFilters

/// With `YAP_DEBUG_FILTERS=1`, reports on stderr each final Whisper line that was dropped and why,
/// each final decode that heard no words, and each time Apple's transcriber supplied the text
/// instead. Tentative and discarded speculative decodes aren't reported: they never became lines.
enum DebugFilters {
    static let isEnabled = ProcessInfo.processInfo.environment["YAP_DEBUG_FILTERS"] == "1"

    static func dropped(_ text: String, reason: String) {
        report([dropNote(text, reason: reason)])
    }

    static func dropNote(_ text: String, reason: String) -> String {
        "dropped (\(reason)): \(text)"
    }

    /// Prints notes collected during a decode, once the decode is used for a line.
    static func report(_ notes: [String]) {
        guard isEnabled else { return }
        for note in notes {
            FileHandle.standardError.write(Data("[filter] \(note)\n".utf8))
        }
    }

    static func replaced(_ whisperText: String, with previewText: String) {
        guard isEnabled else { return }
        let whisper = whisperText.isEmpty ? "nothing" : "「\(whisperText)」"
        FileHandle.standardError.write(Data("[filter] Apple's text used, Whisper had \(whisper): \(previewText)\n".utf8))
    }
}
