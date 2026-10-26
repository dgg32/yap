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
        #expect(pieces.allSatisfy { $0.text.count <= 20 })
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

    @Test func translationIsSharedOutOverCues() {
        let english = "If you bring back the head of Athena, I will free you from the world of death and give you eternal life."
        let pieces = splitEvenly(english, into: 3)
        #expect(pieces.count == 3)
        #expect(pieces.compactMap { $0 }.joined(separator: " ") == english)
        #expect(splitEvenly("ハーデスを倒せ", into: 1) == ["ハーデスを倒せ"])
        #expect(splitEvenly("短い", into: 4).count == 4)
    }

    @Test(arguments: [20, 40])
    func maxLengthIsNeverExceeded(maxLength: Int) {
        let latin = Array(repeating: "abcdefghij", count: 30).joined(separator: " ")
        let japanese = "ハーデスと戦うには、アテナもクロスをまとわねば決して勝ち目はない。何としてでも、アテナにクロスをまとっていただかねばならん。"
        let unbroken = String(repeating: "あ", count: 95)
        for text in [latin, japanese, unbroken] {
            let pieces = splitCaption(text, start: 0, end: 10, maxLength: maxLength)
            #expect(pieces.allSatisfy { $0.text.count <= maxLength })
            #expect(pieces.map(\.text).joined().filter { !$0.isWhitespace } == text.filter { !$0.isWhitespace })
        }
    }

    /// Terminal columns: CJK and emoji (including those above U+1F64F) take two, variation selectors none.
    @Test(arguments: [("あいう", 6), ("漢字", 4), ("abc", 3), ("🔥🚀🚲🩰", 8), ("🇯🇵", 4), ("❤\u{FE0F}", 1)])
    func displayWidth(text: String, columns: Int) {
        #expect(yap.displayWidth(of: text) == columns)
    }

    /// The live line breaks at 80 columns, so 40 Japanese characters already fill it.
    @Test func lineWidthCountsColumns() {
        var line = LiveLine()
        line.appendFinal(String(repeating: "聖", count: 40), endsLine: false)
        #expect(line.openWidth == 80)
    }
}
