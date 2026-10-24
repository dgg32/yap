import Foundation
import NaturalLanguage

// Tests how the NaturalLanguage tokenizers used by
// Sources/yap/Extensions/AttributedString+Extensions.swift behave on Japanese
// text, with and without an explicit language.

let japanese = "黄金聖闘士アテナは十二宮に立つ。ハーデスとの戦いが始まる！Pandoraとはどう違うのか"

print("=== NLTokenizer(unit: .sentence) on Japanese ===")
let sentenceTokenizer = NLTokenizer(unit: .sentence)
sentenceTokenizer.string = japanese
let sentences = sentenceTokenizer.tokens(for: japanese.startIndex..<japanese.endIndex)
for range in sentences {
    print("  [\(range.lowerBound.utf16Offset(in: japanese)..<range.upperBound.utf16Offset(in: japanese))] \(japanese[range])")
}
print("  count = \(sentences.count)")

print("")
print("=== NLTokenizer(unit: .word) with the DEFAULT language (system locale) ===")
let wordTokenizer = NLTokenizer(unit: .word)
wordTokenizer.string = japanese
let words = wordTokenizer.tokens(for: japanese.startIndex..<japanese.endIndex)
print("  count = \(words.count)")
print("  first 25 words: \(words.prefix(25).map { String(japanese[$0]) }.joined(separator: "|"))")

print("")
print("=== NLTokenizer(unit: .word) with language set to ja ===")
let jaTokenizer = NLTokenizer(unit: .word)
jaTokenizer.setLanguage(.japanese)
jaTokenizer.string = japanese
let jaWords = jaTokenizer.tokens(for: japanese.startIndex..<japanese.endIndex)
print("  count = \(jaWords.count)")
print("  first 25 words: \(jaWords.prefix(25).map { String(japanese[$0]) }.joined(separator: "|"))")

print("")
print("=== Does the default (system-locale) tokenizer split Japanese at all? ===")
let cjkOnly = "黄金聖闘士アテナハーデス"
let t = NLTokenizer(unit: .word)
t.string = cjkOnly
let r = t.tokens(for: cjkOnly.startIndex..<cjkOnly.endIndex)
print("  default tokenizer on pure Japanese: \(r.count) token(s) -> \(r.map { String(cjkOnly[$0]) })")
let t2 = NLTokenizer(unit: .word)
t2.setLanguage(.japanese)
t2.string = cjkOnly
let r2 = t2.tokens(for: cjkOnly.startIndex..<cjkOnly.endIndex)
print("  ja tokenizer      on pure Japanese: \(r2.count) token(s) -> \(r2.map { String(cjkOnly[$0]) })")

print("")
print("=== sentence splitting with ja language set ===")
let st = NLTokenizer(unit: .sentence)
st.setLanguage(.japanese)
st.string = japanese
let sr = st.tokens(for: japanese.startIndex..<japanese.endIndex)
for range in sr {
    print("  \(japanese[range])")
}
print("  count = \(sr.count)")
