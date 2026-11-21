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
}
