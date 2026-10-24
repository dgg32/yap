# Harnesses

Standalone reproductions for the findings in [`../BUG.md`](../BUG.md).

The Swift Testing suite in `../Tests/yapTests/` now covers the filters, the voice-activity
detector and the caption splitting, so only the pieces that cannot be reached from a test
target live here: the preview/final alignment (`ApplePreview` has a private initialiser and
needs a live `SpeechAnalyzer`), the decode schedule, the tokenizer measurement, and the
`NLTokenizer` checks.

Each directory holds a `main.swift` that copies the relevant algorithm **verbatim** out of
`Sources/yap/`, so the behaviour can be observed without running the app, without granting
Microphone / Screen Recording permissions and without downloading the Whisper model.

```bash
for d in settle decode nl nl2; do
  (cd "$d" && swiftc -O main.swift -o "/tmp/yap-$d" && "/tmp/yap-$d")
done
python3 tokens/tokens.py   # needs the cached Whisper tokenizer
```

| Directory | Question | Relevant findings |
|---|---|---|
| `settle/` | How far does the preview/final alignment drift when the two engines pick different orthography? | J4 |
| `decode/` | How much audio does Whisper decode during a session? | L1 |
| `tokens/` | How many decoder tokens does Japanese need compared to English? | L5 |
| `nl/` | Does `NLTokenizer` split Japanese into sentences and words? | verified **not** a bug |
| `nl2/` | Does the tokenizer's language setting change Japanese tokenisation? | verified **not** a bug |

`tokens/tokens.py` reimplements the Whisper byte-level BPE against the tokenizer that WhisperKit
downloads (`~/Library/Application Support/yap/whisper/models/openai/whisper-large-v3/tokenizer.json`),
so it counts exactly the tokens the text decoder has to emit. It needs that file to exist — run
`yap listen --engine whisper` once first, or set `WHISPER_TOKENIZER` to another `tokenizer.json`.
