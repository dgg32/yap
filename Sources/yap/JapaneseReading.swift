import Foundation

// MARK: - JapaneseReading

/// The reading of Japanese text in hiragana, from macOS's own Japanese word segmentation. Only words
/// containing kanji are converted; kana, Latin letters, digits and punctuation are kept as written.
/// Names and unusual readings can come out wrong (一輝 as いっき rather than かずき).
enum JapaneseReading {
    static func hiragana(_ text: String) -> String {
        let string = text as NSString
        let tokenizer = CFStringTokenizerCreate(
            nil,
            string,
            CFRange(location: 0, length: string.length),
            kCFStringTokenizerUnitWordBoundary,
            Locale(identifier: "ja") as CFLocale
        )
        var result = ""
        var position = 0
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            result += string.substring(with: NSRange(location: position, length: range.location - position))
            let word = string.substring(with: NSRange(location: range.location, length: range.length))
            // The tokenizer gives readings in romaji; turn them back into kana
            if hasKanji(word),
               let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                let reading = NSMutableString(string: latin)
                CFStringTransform(reading, nil, kCFStringTransformLatinHiragana, false)
                result += reading as String
            } else {
                result += word
            }
            position = range.location + range.length
        }
        return result + string.substring(from: position)
    }

    /// True when `text` contains kanji (including 々), so its reading differs from how it's written.
    static func hasKanji(_ text: String) -> Bool {
        text.unicodeScalars.contains {
            switch $0.value {
            case 0x3005, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3FFFD:
                true
            default:
                false
            }
        }
    }
}
