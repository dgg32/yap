import Foundation
import NaturalLanguage

// NLTokenizer picks its language from Locale.current, NOT from the --locale option.
// Simulate an en-US host transcribing ja-JP audio.

let japanese = "黄金聖闘士アテナは十二宮に立つ。ハーデスとの戦いが始まる！"

func tokens(_ text: String, language: NLLanguage?) -> [String] {
    let t = NLTokenizer(unit: .word)
    if let language { t.setLanguage(language) }
    t.string = text
    return t.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]) }
}

print("=== word tokenization of Japanese under different tokenizer languages ===")
for (name, lang) in [("japanese", NLLanguage.japanese), ("english", NLLanguage.english), ("simplified chinese", .simplifiedChinese)] {
    let result = tokens(japanese, language: lang)
    print("  \(name.padding(toLength: 20, withPad: " ", startingAt: 0)) -> \(result.count) tokens: \(result.joined(separator: "|"))")
}

print("")
print("=== sentence tokenization of Japanese under different tokenizer languages ===")
for (name, lang) in [("japanese", NLLanguage.japanese), ("english", NLLanguage.english)] {
    let t = NLTokenizer(unit: .sentence)
    t.setLanguage(lang)
    t.string = japanese
    let r = t.tokens(for: japanese.startIndex..<japanese.endIndex)
    print("  \(name.padding(toLength: 20, withPad: " ", startingAt: 0)) -> \(r.count) sentences: \(r.map { String(japanese[$0]) })")
}

print("")
print("=== Sentence tokenizer on a Japanese line with NO terminator but a long run ===")
let noStop = "これは日本語の文です句点がないので文が最後まで続いてしまいます"
let t = NLTokenizer(unit: .sentence)
t.string = noStop
print("  default: \(t.tokens(for: noStop.startIndex..<noStop.endIndex).map { String(noStop[$0]) })")
let t2 = NLTokenizer(unit: .sentence)
t2.setLanguage(.japanese)
t2.string = noStop
print("  japanese: \(t2.tokens(for: noStop.startIndex..<noStop.endIndex).map { String(noStop[$0]) })")
