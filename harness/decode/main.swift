import Foundation

// ---------------------------------------------------------------------------
// Simulates the decode schedule of Sources/yap/WhisperListen.swift runWhisper()
// after the fixes, to count how much audio Whisper re-decodes during a session.
//
//   oncePerUtterance = (preview != nil) || !live
//
// With the Apple preview available (the default), or whenever the output is not
// a live terminal (--srt/--vtt/--json, piped text), Whisper runs once per
// utterance and never re-decodes. Only `--no-preview` on a terminal keeps the
// old re-decode loop.
// ---------------------------------------------------------------------------

let sampleRate = 16_000.0

struct DecodeStat {
    var decodes = 0
    var audioSecondsDecoded = 0.0
    var maxBufferSeconds = 0.0
}

/// The once-per-utterance schedule: decode at most every 10 s of pending audio.
func simulateOncePerUtterance(durationSeconds: Double, decodeTimePerAudioSecond: Double, fixedDecodeCost: Double) -> DecodeStat {
    var stat = DecodeStat()
    var pendingSeconds = 0.0
    var clock = 0.0
    let tick = 0.1
    while clock < durationSeconds {
        pendingSeconds += tick
        clock += tick
        if pendingSeconds >= 10 {
            stat.decodes += 1
            stat.audioSecondsDecoded += pendingSeconds
            stat.maxBufferSeconds = max(stat.maxBufferSeconds, pendingSeconds)
            clock += fixedDecodeCost + decodeTimePerAudioSecond * pendingSeconds
            pendingSeconds = 0
        }
    }
    return stat
}

/// The old re-decode loop, still reachable with --no-preview on a terminal.
func simulateReDecoding(durationSeconds: Double, decodeTimePerAudioSecond: Double, fixedDecodeCost: Double) -> DecodeStat {
    var stat = DecodeStat()
    var pendingSeconds = 0.0
    var lastDecodedEnd = 0.0
    var clock = 0.0
    let tick = 0.1
    while clock < durationSeconds {
        pendingSeconds += tick
        let end = pendingSeconds
        if end - lastDecodedEnd < 0.3 {
            clock += tick
            continue
        }
        lastDecodedEnd = end
        stat.decodes += 1
        stat.audioSecondsDecoded += pendingSeconds
        stat.maxBufferSeconds = max(stat.maxBufferSeconds, pendingSeconds)
        clock += fixedDecodeCost + decodeTimePerAudioSecond * pendingSeconds
        if pendingSeconds >= 25 {
            pendingSeconds = 0
            lastDecodedEnd = 0
        }
    }
    return stat
}

print("=== How much audio does Whisper decode in a 60 s session? ===")
print("  (counts decodes and audio-seconds pushed through the encoder)")
print("")
for (name, stat) in [
    ("once per utterance (preview on, or any non-live output)", simulateOncePerUtterance(durationSeconds: 60, decodeTimePerAudioSecond: 0.05, fixedDecodeCost: 0.4)),
    ("re-decode loop (--no-preview on a terminal)", simulateReDecoding(durationSeconds: 60, decodeTimePerAudioSecond: 0.05, fixedDecodeCost: 0.4)),
] {
    print("  \(name)")
    print("    decodes                 = \(stat.decodes)")
    print("    audio-seconds decoded   = \(String(format: "%.1f", stat.audioSecondsDecoded))  (session is 60 s)")
    print("    amplification           = \(String(format: "%.1fx", stat.audioSecondsDecoded / 60.0))")
    print("    largest buffer decoded  = \(String(format: "%.1f", stat.maxBufferSeconds)) s")
    print("")
}

print("=== Wall-clock effect (assumed decode cost: 0.4 s fixed + 50 ms per buffered second) ===")
for decodeRate in [0.03, 0.05, 0.10] {
    let once = simulateOncePerUtterance(durationSeconds: 60, decodeTimePerAudioSecond: decodeRate, fixedDecodeCost: 0.4)
    let re = simulateReDecoding(durationSeconds: 60, decodeTimePerAudioSecond: decodeRate, fixedDecodeCost: 0.4)
    print(String(format: "  %5.0f ms per buffered second: once-per-utterance %2d decodes / %5.1f s   vs   re-decode %2d decodes / %5.1f s",
                 decodeRate * 1000, once.decodes, once.audioSecondsDecoded, re.decodes, re.audioSecondsDecoded))
}

print("")
print("=== First-caption latency (preview path) ===")
print("  The preview path still requires `duration >= 10` before it will transcribe")
print("  anything (WhisperListen.swift: `guard duration >= 10 else { continue }`),")
print("  but a detected pause now ends the utterance early because the noise floor")
print("  makes pause detection work under a music bed.")
print("")
print("  => With pauses detected: final text ~0.4 s after the speaker stops.")
print("  => Without any pause:    final text after 10 s of accumulated speech.")
