import Testing
@testable import yap

@Suite struct JapaneseReadingTests {
    @Test func kanjiBecomeHiragana() {
        #expect(JapaneseReading.hiragana("原因は東京の本社です。") == "げんいんはとうきょうのほんしゃです。")
    }

    @Test func kanaLettersAndDigitsAreKept() {
        #expect(JapaneseReading.hiragana("OK、じゃあ3時にダメージを確認。") == "OK、じゃあ3じにダメージをかくにん。")
    }

    @Test func onlyTextWithKanjiHasAReading() {
        #expect(JapaneseReading.hasKanji("人々"))
        #expect(!JapaneseReading.hasKanji("クビにならないみたいです"))
    }
}
