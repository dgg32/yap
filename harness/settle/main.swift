import Foundation

// Reproduction of the NEW ApplePreview.settle() (Sources/yap/WhisperListen.swift),
// to measure how the kanji/kana drift behaves after the punctuation-snapping change.

final class Preview {
    var finals: [String] = []
    var volatile = ""
    var volatileConsumed = 0

    func isPunctuation(_ c: Character) -> Bool { c.isPunctuation || c.isWhitespace || c.isSymbol }
    func letters(_ text: String) -> Int { text.filter { !isPunctuation($0) }.count }

    /// Mirrors the current settle().
    func settle(_ whisperText: String, from start: Double, to end: Double) -> (consumed: Int, fallback: String?) {
        let finalsText = finals.joined()
        let characters = Array(volatile)
        volatileConsumed = min(volatileConsumed, characters.count)
        let previewText = finalsText + String(characters[volatileConsumed..<characters.count])
        let previewLetters = letters(previewText)
        let previewContent = previewText.filter { !isPunctuation($0) }
        let fillers = Set("んンーっッ〜")
        if previewLetters >= 2, !previewContent.allSatisfy(fillers.contains),
           letters(whisperText) * 2 < previewLetters {
            volatileConsumed = characters.count
            return (volatileConsumed, previewText.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var remaining = letters(whisperText) - letters(finalsText)
        var index = volatileConsumed
        while index < characters.count, remaining > 0 {
            if !isPunctuation(characters[index]) { remaining -= 1 }
            index += 1
        }
        let nearby = max(volatileConsumed, index - 3)..<min(characters.count, index + 3)
        if let punctuation = nearby
            .filter({ isPunctuation(characters[$0]) && !characters[$0].isWhitespace })
            .min(by: { abs($0 + 1 - index) < abs($1 + 1 - index) }) {
            index = punctuation + 1
        }
        while index < characters.count, isPunctuation(characters[index]) {
            index += 1
        }
        volatileConsumed = index
        return (volatileConsumed, nil)
    }
}

print("=== Preview/final alignment drift, NEW settle() ===")
print("Apple's ja-JP model and Whisper pick different orthography for the same words,")
print("so the character counts differ and the cut lands in the wrong place.\n")

struct Case {
    let name: String
    let apple: String
    let whisper: String
    let tail: String
}

let cases: [Case] = [
    Case(name: "kanji (Apple) vs kana (Whisper)",
         apple: "黄金聖闘士アテナが十二宮に立った",
         whisper: "おうごせんとしあてながじゅうにゅうにたった",
         tail: "次の戦いが始まる"),
    Case(name: "kana (Apple) vs kanji (Whisper)",
         apple: "おうごせんとしがじゅうにゅうにたった",
         whisper: "黄金聖闘士が十二宮に立った",
         tail: "次の戦いが始まる"),
    Case(name: "control: identical orthography",
         apple: "黄金聖闘士が十二宮に立った",
         whisper: "黄金聖闘士が十二宮に立った",
         tail: "次の戦いが始まる"),
]

for c in cases {
    let p = Preview()
    p.volatile = c.apple + "。" + c.tail
    let appleLetters = p.letters(c.apple)
    let whisperLetters = p.letters(c.whisper)
    let (consumed, fallback) = p.settle(c.whisper, from: 0, to: 1)
    let cut = String(Array(p.volatile).prefix(consumed))
    print("  \(c.name)")
    print("    Apple letters=\(appleLetters)  Whisper letters=\(whisperLetters)  drift=\(whisperLetters - appleLetters)")
    print("    consumed=\(consumed)/\(p.volatile.count)  fallback=\(fallback != nil)")
    print("    cut ends at: …\(cut.suffix(12))")
    let swallowed = consumed >= p.volatile.count
    print("    -> tail \"\(c.tail)\" \(swallowed ? "SWALLOWED (never captioned)" : "kept for the next line")")
    print("")
}

print("=== Same, but with a 。after the sentence (real speech has one) ===")
for c in cases {
    let p = Preview()
    p.volatile = c.apple + "。" + c.tail
    let (consumed, _) = p.settle(c.whisper, from: 0, to: 1)
    let cut = String(Array(p.volatile).prefix(consumed))
    print("  \(c.name): consumed=\(consumed)/\(p.volatile.count) cut=…\(cut.suffix(14))")
}
