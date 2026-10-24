import Testing
@testable import yap

@Suite struct WhisperFilterTests {
    let vocabulary = ["アテナ", "ハーデス", "聖闘士", "黄金聖闘士", "ゴールドセイント", "冥闘士", "聖域", "城戸沙織", "十二宮"]

    @Test(arguments: ["なるほどなるほどなるほど", "はいはいはいはい", "そうそうそうそう", "うんうんうんうん", "ハーデス様、ハーデス様"])
    func ordinaryReduplicationIsNotALoop(_ line: String) {
        #expect(!WhisperFilter.hasRepeatedPhrase(WhisperFilter.letters(line)))
    }

    @Test func whisperLoopIsDetected() {
        let loop = "アテナ、ハーデス、ローリコン、サイト、ハーデス、ローリコン、サイト、ハーデス、ローリコン、サイト、ハーデス、ローリコン、サイト"
        #expect(WhisperFilter.hasRepeatedPhrase(WhisperFilter.letters(loop)))
    }

    @Test(arguments: ["黄金聖闘士聖闘士聖域", "アテナハーデス冥闘士", "十二宮にアテナハーデス", "アテナとハーデスと聖闘士と十二宮"])
    func vocabularyHeavyDialogueIsKept(_ line: String) {
        #expect(!WhisperFilter.recitesVocabulary(WhisperFilter.letters(line), vocabulary: vocabulary))
    }

    @Test func recitedVocabularyIsDetected() {
        let echo = "アテナ、ハーデス、聖闘士、黄金聖闘士、冥闘士、聖域"
        #expect(WhisperFilter.recitesVocabulary(WhisperFilter.letters(echo), vocabulary: vocabulary))
    }

    @Test(arguments: ["ご視聴ありがとうございました", "ご視力ありがとうございました", "チャンネル登録よろしくお願いします", "Thank you for watching!"])
    func stockPhrasesAreHallucinations(_ line: String) {
        #expect(WhisperFilter.isLikelyHallucination(line))
    }

    @Test(arguments: ["字幕を消してください", "最後までご視聴ください", "チャンネル登録者が百万人を超えたんだって", "はい", "そう"])
    func speechContainingStockWordsIsKept(_ line: String) {
        #expect(!WhisperFilter.isLikelyHallucination(line))
    }

    @Test(arguments: ["ん", "んー", "っ。", "…"])
    func fillersAreHallucinations(_ line: String) {
        #expect(WhisperFilter.isLikelyHallucination(line))
    }

    @Test func sameSentenceTwiceIsDuplicate() {
        #expect(WhisperFilter.isNearDuplicate(
            "はい、俺たちは、俺たちは、何も知らず、いや、知ろうともせずに…",
            "はい、俺たちは、何も知らず、いや、知ろうともせずに…"
        ))
        #expect(WhisperFilter.isNearDuplicate("アーッ!", "アーッ!"))
    }

    @Test func similarButDifferentLinesAreNotDuplicates() {
        #expect(!WhisperFilter.isNearDuplicate("十二宮の聖闘士たち", "十二宮の黄金聖闘士たち"))
        #expect(!WhisperFilter.isNearDuplicate("教えてくれ、シオン!俺達は何をすればいいんだ!?", "アテナさえも死んだ今、俺たちは…一体何を…"))
        #expect(!WhisperFilter.isNearDuplicate("はい", "いいえ"))
    }
}
