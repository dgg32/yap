import Testing
@testable import yap

@Suite struct CaptionTests {
    @Test func shortCaptionIsUnchanged() {
        let pieces = splitCaption("さあ、その布を取りなさい。", start: 1, end: 3, maxLength: 40)
        #expect(pieces.count == 1)
        #expect(pieces.first?.text == "さあ、その布を取りなさい。")
    }

    @Test func longCaptionSplitsAtWordsWithinLimit() {
        let text = "もしアテナの首を取ってくるのなら、死の世界から解き放ち、永遠の命を与えよう。我らは未来永劫、逆賊のそしりを受けることになるが、それでも良いか。"
        let pieces = splitCaption(text, start: 0, end: 12, maxLength: 20)
        #expect(pieces.count > 1)
        #expect(pieces.allSatisfy { $0.text.count <= 24 })
        #expect(pieces.map(\.text).joined() == text)
        #expect(pieces.first?.start == 0)
        #expect(abs((pieces.last?.end ?? 0) - 12) < 0.001)
        #expect(zip(pieces, pieces.dropFirst()).allSatisfy { abs($0.end - $1.start) < 0.001 })
    }

    @Test func slightlyLongCaptionSplitsEvenly() {
        // 42 characters with a 40-character limit: two halves, not 40 + 2
        let text = "もしアテナの首を取ってくるのなら死の世界から解き放ち永遠の命を与えよう我らは未来永劫"
        let pieces = splitCaption(text, start: 0, end: 8, maxLength: 40)
        #expect(pieces.count == 2)
        #expect(pieces.allSatisfy { $0.text.count >= 15 })
    }

    @Test func splitPrefersPunctuation() {
        let pieces = splitCaption("私たちはその誘いに乗ったふりをして、この十二宮に戻ってきたのだ。", start: 0, end: 6, maxLength: 20)
        #expect(pieces.first?.text == "私たちはその誘いに乗ったふりをして、")
    }

    /// Terminal columns: CJK and emoji (including those above U+1F64F) take two, variation selectors none.
    @Test(arguments: [("あいう", 6), ("漢字", 4), ("abc", 3), ("🔥🚀🚲🩰", 8), ("🇯🇵", 4), ("❤\u{FE0F}", 1)])
    func displayWidth(text: String, columns: Int) {
        #expect(text.unicodeScalars.reduce(0) { $0 + yap.displayWidth(of: $1) } == columns)
    }
}
