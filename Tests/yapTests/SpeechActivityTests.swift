import AVFoundation
import Foundation
import Testing
@testable import yap

@Suite struct EnergyActivityTests {
    let sampleRate = 16000

    /// Noise-like "speech" bursts separated by pauses, over an optional steady music bed.
    func timeline(speech: [Double], pause: Double, musicLevel: Float) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        var samples: [Float] = []
        for (index, seconds) in speech.enumerated() {
            samples += (0..<Int(seconds * Double(sampleRate))).map { _ in Float.random(in: -0.3...0.3, using: &generator) }
            if index < speech.count - 1 {
                samples += [Float](repeating: 0, count: Int(pause * Double(sampleRate)))
            }
        }
        return samples.enumerated().map { index, sample in
            sample + musicLevel * sin(Float(index) * 0.05) * 1.4
        }
    }

    @Test(arguments: [Float(0), 0.01, 0.03, 0.06])
    func pauseIsFoundUnderMusic(musicLevel: Float) {
        let samples = timeline(speech: [3, 2], pause: 0.6, musicLevel: musicLevel)
        let activity = EnergyActivity()
        activity.add(samples[...])
        let pause = activity.firstPause(in: 0..<samples.count, minimumLength: sampleRate * 4 / 10)
        #expect(pause != nil)
        if let pause {
            #expect(abs(Double(pause.lowerBound) / Double(sampleRate) - 3) < 0.1)
        }
    }

    @Test func continuousSpeechHasNoPause() {
        let samples = timeline(speech: [6], pause: 0, musicLevel: 0.03)
        let activity = EnergyActivity()
        activity.add(samples[...])
        #expect(activity.firstPause(in: 0..<samples.count, minimumLength: sampleRate * 4 / 10) == nil)
    }

    @Test func digitalSilenceDoesNotLowerTheFloor() {
        // Music with stretches of injected digital silence: the music still counts as background
        let music = (0..<(sampleRate * 6)).map { Float(0.05) * sin(Float($0) * 0.05) * 1.4 }
        let silence = [Float](repeating: 0, count: sampleRate * 2)
        let samples = music + silence + music + silence + music
        let activity = EnergyActivity()
        activity.add(samples[...])
        #expect(activity.threshold(at: activity.frameCount - 1) > 0.05)
    }

    @Test func positionsAreAbsolute() {
        // Analyzing in pieces gives the same answer as all at once, and ranges can start later
        let samples = timeline(speech: [3, 2], pause: 0.6, musicLevel: 0)
        let activity = EnergyActivity()
        for start in stride(from: 0, to: samples.count, by: 1234) {
            activity.add(samples[start..<min(start + 1234, samples.count)])
        }
        let pause = activity.firstPause(in: 0..<samples.count, minimumLength: sampleRate * 4 / 10)
        #expect(pause != nil)
        let speech = activity.firstSpeech(in: (sampleRate * 3 + 100)..<samples.count)
        #expect(speech.map { abs(Double($0) / Double(sampleRate) - 3.6) < 0.1 } == true)
    }
}

/// These need the Silero model (downloaded on first run, under 1 MB) and the system's Japanese voice.
@Suite(.serialized) struct SileroActivityTests {
    let sampleRate = 16000

    func spokenJapanese(_ text: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appending(path: "yap-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Kyoko", "--file-format=WAVE", "--data-format=LEF32@16000", "-o", url.path, text]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    func music(seconds: Double, level: Float) -> [Float] {
        (0..<Int(seconds * Double(sampleRate))).map { index in
            let time = Float(index) / Float(sampleRate)
            return level * (0.6 * sin(2 * .pi * 220 * time) + 0.4 * sin(2 * .pi * 330 * time))
        }
    }

    @Test func findsPauseBetweenSentencesUnderMusic() async throws {
        let first = try spokenJapanese("さあ、その布を取りなさい")
        let second = try spokenJapanese("私たちはその誘いに乗ったふりをしたのだ")
        let gap = [Float](repeating: 0, count: sampleRate * 8 / 10)
        let speech = first + gap + second
        let bed = music(seconds: Double(speech.count) / Double(sampleRate), level: 0.05)
        let samples = zip(speech, bed).map { $0 + $1 }

        let activity = try await SileroModelStore.load()
        activity.add(samples[...])
        let pause = try #require(activity.firstPause(in: 0..<samples.count, minimumLength: sampleRate * 4 / 10))
        // The pause starts near the end of the first sentence
        let firstEnd = Double(first.count) / Double(sampleRate)
        #expect(abs(Double(pause.lowerBound) / Double(sampleRate) - firstEnd) < 0.4)
    }

    @Test func musicAloneIsNotSpeech() async throws {
        let samples = music(seconds: 5, level: 0.2)
        let activity = try await SileroModelStore.load()
        activity.add(samples[...])
        #expect(activity.firstSpeech(in: 0..<samples.count) == nil)
    }
}
