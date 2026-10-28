@preconcurrency import AVFoundation
import ScreenCaptureKit

// MARK: - LiveAudioSource

/// Where `yap listen` gets its audio: system audio, or a recording played back as if it were playing now.
protocol LiveAudioSource: AnyObject, Sendable {
    /// Serial queue that delivers the audio buffers.
    var queue: DispatchQueue { get }
    /// Starts delivering audio. `onEnd` runs once a recording has been played to the end.
    func start(onEnd: @escaping @Sendable () async -> Void) async throws
    func stop() async
}

/// The file at `input` played at `speed` times real time, or system audio when `input` is nil.
func makeAudioSource(
    input: String?,
    speed: Double,
    format: AVAudioFormat,
    onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void
) async throws -> LiveAudioSource {
    if let input {
        try FileAudioSource(path: input, format: format, speed: speed, onBuffer: onBuffer)
    } else {
        try await SystemAudioSource(format: format, onBuffer: onBuffer)
    }
}

/// Wraps `shutdown` so it runs only the first time, whether a recording ended or Ctrl+C was pressed.
func once(_ shutdown: @escaping @Sendable () async -> Void) -> @Sendable () async -> Void {
    let lock = NSLock()
    nonisolated(unsafe) var done = false
    return {
        let first = lock.withLock {
            defer { done = true }
            return !done
        }
        if first { await shutdown() }
    }
}

// MARK: - SystemAudioSource

/// System audio captured with ScreenCaptureKit.
final class SystemAudioSource: LiveAudioSource, @unchecked Sendable {
    private let delegate: AudioStreamDelegate
    private let stream: SCStream

    var queue: DispatchQueue { delegate.queue }

    init(format: AVAudioFormat, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) async throws {
        delegate = AudioStreamDelegate(targetFormat: format, onBuffer: onBuffer)
        stream = try await makeSystemAudioStream(format: format, delegate: delegate)
    }

    func start(onEnd _: @escaping @Sendable () async -> Void) async throws {
        do {
            try await stream.startCapture()
        } catch {
            throw ListenError.screenRecordingPermissionDenied
        }
        delegate.startSilencePadding()
    }

    func stop() async {
        try? await stream.stopCapture()
    }
}

// MARK: - FileAudioSource

/// An audio or video file played into the live pipeline in real time (or faster), so changes can be
/// tried on the same recording again and again. Files AVFoundation can't read, like MKV, are decoded
/// with ffmpeg.
final class FileAudioSource: LiveAudioSource, @unchecked Sendable {
    let queue = DispatchQueue(label: "yap.listen.file")
    private let format: AVAudioFormat
    private let speed: Double
    private let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    /// The whole recording, mono at the target sample rate.
    private let samples: [Float]
    private var position = 0
    private var timer: DispatchSourceTimer?
    private let floatFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    init(path: String, format: AVAudioFormat, speed: Double, onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ListenError.unreadableInput(path, reason: "No such file.")
        }
        guard let floatFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw ListenError.noCompatibleAudioFormat
        }
        self.format = format
        self.speed = speed
        self.onBuffer = onBuffer
        self.floatFormat = floatFormat
        converter = floatFormat == format ? nil : AVAudioConverter(from: floatFormat, to: format)
        let url = URL(filePath: path)
        samples = try (try? Self.decodeWithAVFoundation(url, to: floatFormat)) ?? Self.decodeWithFFmpeg(url, sampleRate: format.sampleRate)
    }

    func start(onEnd: @escaping @Sendable () async -> Void) async throws {
        let startTime = DispatchTime.now()
        let sampleRate = format.sampleRate
        let chunk = Int(sampleRate * 0.02)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.02)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1e9
            let due = min(samples.count, Int(elapsed * speed * sampleRate))
            while position < due {
                let count = min(chunk, due - position)
                if let buffer = buffer(from: position, count: count) { onBuffer(buffer) }
                position += count
            }
            if position >= samples.count {
                self.timer?.cancel()
                self.timer = nil
                Task { await onEnd() }
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() async {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    private func buffer(from start: Int, count: Int) -> AVAudioPCMBuffer? {
        guard let floats = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: AVAudioFrameCount(count)),
              let channel = floats.floatChannelData?[0] else { return nil }
        floats.frameLength = AVAudioFrameCount(count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress! + start, count: count) }
        guard let converter else { return floats }

        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { return nil }
        var error: NSError?
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let source = floats
        converter.convert(to: converted, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        return error == nil ? converted : nil
    }

    /// Reads and converts the file in pieces, so a long recording isn't held at its original sample rate.
    private static func decodeWithAVFoundation(_ url: URL, to format: AVAudioFormat) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        guard let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16384),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16384) else {
            throw ListenError.noCompatibleAudioFormat
        }
        converter.downmix = true
        var samples: [Float] = []
        nonisolated(unsafe) let source = input
        nonisolated(unsafe) var readError: Error?
        var status: AVAudioConverterOutputStatus
        repeat {
            output.frameLength = 0
            var error: NSError?
            status = converter.convert(to: output, error: &error) { _, inputStatus in
                do {
                    try file.read(into: source)
                } catch {
                    readError = error
                }
                guard readError == nil, source.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return source
            }
            if let error { throw error }
            if let channel = output.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
        } while status == .haveData
        // Some recordings have packets AVFoundation can't decode. Stopping there would quietly cut the
        // recording short, so fail instead and let ffmpeg read it.
        if let readError { throw readError }
        let expected = Double(file.length) * format.sampleRate / file.processingFormat.sampleRate
        if Double(samples.count) < expected - format.sampleRate {
            throw ListenError.unreadableInput(url.path, reason: "AVFoundation decoded only part of it.")
        }
        return samples
    }

    private static func decodeWithFFmpeg(_ url: URL, sampleRate: Double) throws -> [Float] {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-nostdin", "-loglevel", "error", "-i", url.path,
            "-vn", "-ac", "1", "-ar", String(Int(sampleRate)), "-f", "f32le", "-",
        ]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ListenError.unreadableInput(
                url.path,
                reason: process.terminationStatus == 127
                    ? "AVFoundation can't read all of it; install ffmpeg (brew install ffmpeg) to read MKV, other formats and recordings with damaged packets."
                    : message.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
