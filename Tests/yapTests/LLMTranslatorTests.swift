import Foundation
import Testing
@testable import yap

@Suite struct LLMTranslatorTests {
    @Test func dotEnvParsesKeysQuotesExportAndComments() {
        let values = DotEnv.parse("""
        # comment
        OPENCODE_API_KEY=
        export OPENCODE_MODEL="glm-5.3-flash"
        OPENCODE_REASONING_EFFORT=low # keep it quick
        OPENCODE_BASE_URL='https://example.com/v1'
        not a setting
        """)
        #expect(values["OPENCODE_API_KEY"] == nil)
        #expect(values["OPENCODE_MODEL"] == "glm-5.3-flash")
        #expect(values["OPENCODE_REASONING_EFFORT"] == "low")
        #expect(values["OPENCODE_BASE_URL"] == "https://example.com/v1")
        #expect(values.count == 3)
    }

    @Test func dotEnvDropsCommentAfterQuotedValue() {
        let values = DotEnv.parse("""
        OPENCODE_API_KEY="oc_sk_abc" # my key
        OPENCODE_MODEL='glm-5.3-flash'   # fast
        OPENCODE_BASE_URL="https://example.com/#anchor"
        """)
        #expect(values["OPENCODE_API_KEY"] == "oc_sk_abc")
        #expect(values["OPENCODE_MODEL"] == "glm-5.3-flash")
        #expect(values["OPENCODE_BASE_URL"] == "https://example.com/#anchor")
    }

    @MainActor @Test func failedRequestStaysInContext() async throws {
        // Nothing listens on port 9, so the request fails at once
        let config = LLMTranslator.Config(apiKey: "x", baseURL: URL(string: "http://127.0.0.1:9")!, model: "m", reasoningEffort: "low")
        let llm = LLMTranslator(config: config, source: Locale(identifier: "ja-JP"), target: "zh-Hans", corrects: true)
        await #expect(throws: (any Error).self) { try await llm.process("構成は十分可能") }
        #expect(llm.history.map(\.source) == ["構成は十分可能"])
    }

    @Test func correctRequiresJapanese() throws {
        #expect(throws: (any Error).self) { try Listen.parse(["--engine", "whisper", "--correct", "-l", "en-US"]) }
        _ = try Listen.parse(["--engine", "whisper", "--correct", "-l", "ja-JP"])
    }

    @Test func environmentWinsOverDotEnv() {
        let values = DotEnv.load(environment: ["OPENCODE_MODEL": "other-model", "EMPTY": ""])
        #expect(values["OPENCODE_MODEL"] == "other-model")
        #expect(values["EMPTY"] == nil)
    }

    @Test func cleanStripsReasoningAndWholeReplyQuotes() {
        #expect(LLMTranslator.clean("<think>hmm</think>\n今天有点冷。") == "今天有点冷。")
        #expect(LLMTranslator.clean("“谢谢。”") == "谢谢。")
        #expect(LLMTranslator.clean("「你好」") == "你好")
        #expect(LLMTranslator.clean("  请。 \n") == "请。")
        // Quotes that aren't around the whole reply stay
        #expect(LLMTranslator.clean("“好”他说，“走吧”") == "“好”他说，“走吧”")
    }

    @Test func soundAlikeCorrectionsAreKept() {
        #expect(LLMTranslator.soundsAlike("公地所や刑務所ではなく", "拘置所や刑務所ではなく"))
        #expect(LLMTranslator.soundsAlike("教育施設でなら構成は十分可能", "教育施設でなら更生は十分可能"))
        #expect(LLMTranslator.soundsAlike("彼を犯行に借り立てたのは", "彼を犯行に駆り立てたのは"))
        #expect(LLMTranslator.soundsAlike("だからこその公正主義ではありませんか", "だからこその更生主義ではありませんか"))
    }

    @Test func rewritesThatSoundDifferentAreRejected() {
        #expect(!LLMTranslator.soundsAlike("彼を犯行に借り立てたのは", "彼が罪を犯した理由は"))
        #expect(!LLMTranslator.soundsAlike("ありがとう", "どういたしまして"))
        // One sound off is still a different word
        #expect(!LLMTranslator.soundsAlike("だからこその公正主義ではありませんか", "だからこその公平主義ではありませんか"))
        #expect(!LLMTranslator.soundsAlike("すみ", "すみません"))
    }

    @Test func jsonObjectFindsFieldsInFencesAndReasoning() {
        #expect(LLMTranslator.jsonObject(in: #"{"corrected": "更生", "translation": "改造"}"#) == ["corrected": "更生", "translation": "改造"])
        #expect(LLMTranslator.jsonObject(in: "<think>…{x}</think>\n```json\n{\"corrected\": \"更生\"}\n```") == ["corrected": "更生"])
        #expect(LLMTranslator.jsonObject(in: "更生") == nil)
    }
}
