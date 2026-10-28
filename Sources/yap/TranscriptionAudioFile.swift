import AVFoundation

// MARK: - TranscriptionAudioFile

/// An audio file prepared for `SpeechAnalyzer`.
///
/// Some files can't be decoded all the way through by AVFoundation: some MP3 files report one more
/// packet than they can decode, and some meeting recordings have AAC packets it rejects partway
/// through. `SpeechAnalyzer` then fails with an error from `ExtAudioFileRead`. So the file is read
/// through once first (about 2 seconds for 4 hours of audio), and a file that doesn't decode
/// completely is converted to a temporary file: with ffmpeg if it's installed, whose decoder is
/// more tolerant, otherwise with AVFoundation's exporter.
struct TranscriptionAudioFile {
    let audioFile: AVAudioFile

    private let temporaryURL: URL?

    static func prepare(_ url: URL) async throws -> Self {
        let audioFile = try AVAudioFile(forReading: url)
        guard try !decodesCompletely(url, expectedLength: audioFile.length) else {
            return Self(audioFile: audioFile, temporaryURL: nil)
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: "yap-\(UUID().uuidString)")
        do {
            if let converted = try convertWithFFmpeg(url, to: temporaryURL.appendingPathExtension("wav")) {
                return Self(audioFile: try AVAudioFile(forReading: converted), temporaryURL: converted)
            }
            let converted = temporaryURL.appendingPathExtension("m4a")
            let asset = AVURLAsset(url: url)
            guard let exportSession = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetAppleM4A
            ) else {
                throw TranscriptionError.audioConversionFailed
            }
            try await exportSession.export(to: converted, as: .m4a)
            let exported = try AVAudioFile(forReading: converted)
            // The exporter uses the same decoder, so it can't repair packets AVFoundation rejects
            guard try decodesCompletely(converted, expectedLength: exported.length) else {
                throw TranscriptionError.unreadableAudio(
                    url.path,
                    "AVFoundation can't decode all of it. Install ffmpeg (brew install ffmpeg), which can."
                )
            }
            return Self(audioFile: exported, temporaryURL: converted)
        } catch {
            for pathExtension in ["wav", "m4a"] {
                try? FileManager.default.removeItem(at: temporaryURL.appendingPathExtension(pathExtension))
            }
            throw error
        }
    }

    func removeTemporaryFile() {
        guard let temporaryURL else { return }
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    /// Whether AVFoundation can decode every frame of the file.
    private static func decodesCompletely(_ url: URL, expectedLength: AVAudioFramePosition) throws -> Bool {
        // Use a separate file because reading changes the decoder's position.
        let probe = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: probe.processingFormat, frameCapacity: 1 << 16) else {
            throw TranscriptionError.audioConversionFailed
        }
        var decoded: AVAudioFramePosition = 0
        do {
            while probe.framePosition < expectedLength {
                try probe.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                decoded += AVAudioFramePosition(buffer.frameLength)
            }
        } catch {
            return false
        }
        return decoded >= expectedLength
    }

    /// Converts the file's audio to a mono WAV with ffmpeg. Returns nil if ffmpeg isn't installed.
    private static func convertWithFFmpeg(_ url: URL, to output: URL) throws -> URL? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/env")
        process.arguments = [
            "ffmpeg", "-nostdin", "-loglevel", "error", "-i", url.path,
            "-vn", "-ac", "1", "-c:a", "pcm_s16le", "-y", output.path,
        ]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errors
        try process.run()
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        if process.terminationStatus == 127 { return nil }
        guard process.terminationStatus == 0 else {
            throw TranscriptionError.unreadableAudio(url.path, message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }
}
