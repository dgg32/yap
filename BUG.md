# yap — bug hunt & suggestions

Focus: **Japanese caption quality** and **response time** for `yap listen`, with both the Apple
and the Whisper engine. The target workload is
`yap listen -l ja-JP --engine whisper --vocabulary seiya.txt`: live Japanese captions of an anime
with background music.

Four review rounds so far (2026-10-24 to 2026-10-26). This file lists what is **still open**,
then a one-line record of what was fixed, then what was checked and is *not* a bug. The full
write-ups of fixed findings, with their measurements, are in git history (`git log -p BUG.md`).

Severity: **High** = visible quality or latency damage in a normal workflow · **Medium** = wrong
under specific conditions · **Low** = minor, cosmetic or hygiene.

---

## Open

Nothing High is open.

| ID | Severity | Area | One line |
|---|---|---|---|
| [A3](#a3) | Medium | Quality · filters | A line said twice in a row is dropped as a Whisper loop |
| [J4](#j4) | Medium | Quality · alignment | Volatile preview text is still cut by counting characters; kanji vs kana can shift the cut |
| [L7](#l7) | Medium | Latency · startup | `prewarm: false`: the first decode of a session pays for Core ML specialisation |
| [S4](#s4) | Medium | Quality · filters | The filters can't be turned off, and the confidence thresholds are tuned for English |
| [L2](#l2) | Low | Latency | Speech with no pause gets no final text for 10 s |
| [L6](#l6) | Low | Latency · compute | The text decoder stays on the Neural Engine; the GPU hasn't been measured |
| [P1](#p1) | Low | Latency · translation | The translation is awaited in the caption loop: ~25 ms + 2 ms/char, once per ended line |
| [A5](#a5) | Low | Quality · output | Text output and subtitle output read and translate different units (also R10) |
| [A6](#a6) | Low | Quality · translation | A cue can end up with no translation when the translation is short |
| [R7](#r7) | Low | Output | With `--reading` and `--translate`, an SRT cue has three lines; many players show two |
| [R11](#r11) | Low | Memory | `--input` decodes the whole file into memory (≈96 MB for 25 minutes) |
| [R12](#r12) | Low | Quality · VAD | With `--vad energy`, dialogue quieter than 2× the music bed isn't detected (old N1/N2) |
| [R13](#r13) | Low | Output | Whisper's timestamps for a very short utterance are short: a 0.4 s 「はい」 becomes a 0.2 s cue |
| [B4](#b4) | Low | Translation | The translation source language always comes from `--locale` |
| [S1](#s1) | Low | Suggestion | Show which model was resolved; make the "No models found" error friendlier |
| [S7](#s7) | Low | Testing | CI doesn't run the tests, and `ApplePreview.settle` has no tests |

<a id="a3"></a>
### A3 — Medium: a line said twice in a row is dropped

Whisper is prompted with the previous line, which is the right idea but also nudges it to repeat
that line. `isNearDuplicate` (bigram overlap ≥ 0.8, length ratio ≥ 0.8, compared against the
last 3 finals) then drops the repeat as a loop. So a character who says the same thing twice in
a row, which is common in anime, gets one caption instead of two.

Worth a regression test first: feed the same utterance twice, separated by a pause, and check
that both appear. One possible fix is to treat a near-duplicate as a loop only when it comes from
the *same* audio (overlapping time ranges), not from a later utterance.

<a id="j4"></a>
### J4 — Medium: volatile preview text is still cut by counting characters

`ApplePreview.settle` cuts Apple's *final* results by time, but *volatile* results only have one
time range for the whole text, so the cut is found by counting Whisper's characters into it.
Apple and Whisper spell the same words with different lengths (黄金聖闘士 vs おうごんせいとうし),
which was measured at ±5 characters of drift in round 1 (`harness/settle/`).

Since then, the cut snaps to punctuation within ±3 characters and to a match of Whisper's last
3 characters within ±4. That handles the common case, but drift beyond the window still
swallows a few characters (positive drift) or repeats them on the next line (negative drift).
Not re-measured since the tail match was added. To fix it properly, prefer the time-based
estimate `settle` already computes (`estimatedCut`) and use character counting only to refine
it.

<a id="l7"></a>
### L7 — Medium: `prewarm: false`

`WhisperModelStore.load` passes `prewarm: false`. After an OS update, Core ML specialises the
models for the chip on first use, and without a prewarm that cost lands on the first caption
rather than at load time. WhisperKit documents the trade-off as "load time will be multiplied
by 2". For a live captioning tool, a slower start is better than a slow first caption. Measure
both on a fresh specialisation before switching.

<a id="s4"></a>
### S4 — Medium: the filters aren't configurable

The loop, duplicate, hallucination and vocabulary-recitation filters have been tuned so they no
longer delete ordinary Japanese (J1, J2, J6, J7). But there is still no way to turn them off when
they're wrong, and the `avgLogprob < -1` / `< -1.2` thresholds are English numbers. Japanese
transcriptions have systematically lower log-probabilities (about 2.3× more tokens per
character). A `--no-filter` flag, plus measuring the threshold on the CER clips, would cover both.

<a id="l2"></a>
### L2 — Low: no final text for 10 s of speech without a pause

With the preview running, an utterance is cut at a detected pause, and only after 10 s if there
is none. The Silero VAD finds pauses under music, so this only affects genuinely continuous
speech. The README documents it. Kept as a known trade-off: cutting earlier gives Whisper less
context.

<a id="l6"></a>
### L6 — Low: the text decoder stays on the Neural Engine

`ModelComputeOptions(audioEncoderCompute: .cpuAndGPU)` moves only the encoder. The default model
has a 4-layer decoder, so this matters less than it would for full large-v3. Worth a single
measurement with `textDecoderCompute: .cpuAndGPU`.

<a id="p1"></a>
### P1 — Low: the translation is awaited in the caption loop

`CaptionOutput` awaits `translator.translate` when a line *ends* (text output) or once per
Whisper line (subtitle output), so translation doesn't run on every 100 ms tick. Measured cost is
~25 ms + 2 ms per character: a 30–40 character line stalls the loop for 70–105 ms, once per
sentence. Round 2's "doubles the caption latency" overstated it. The model load on the first
request (163–524 ms) is now done at start-up (`CaptionTranslator.make` translates a dummy
string).

Moving translation off the critical path would remove the remaining stall. It needs care: a
note printed late lands under whatever line is current, so translations must be queued in order
and printed before the next line ends.

<a id="a5"></a>
### A5 / R10 — Low: text and subtitle output use different units

Text output reads and translates the whole assembled line (a sentence). Subtitle output
translates each Whisper line and splits the English over its cues at word boundaries, and reads
each cue separately. So the same audio gets different translations and readings in `yap listen`
and `yap listen --srt`.

<a id="a6"></a>
### A6 — Low: some cues have no translation

`splitEvenly` pads with `nil` when the translation has fewer words than there are cues (for
example "Yes." over two cues). Repeating the last piece, or merging the cue's translation into
its neighbour, would avoid an untranslated cue.

<a id="r7"></a>
### R7 — Low: three-line SRT cues

With `--reading` and `--translate`, a cue is text + reading + translation. Three-line cues are
valid SRT, but many players render only two. Consider keeping the reading in the terminal only.

<a id="r11"></a>
### R11 — Low: `--input` holds the whole recording in memory

`FileAudioSource` decodes the file into one `[Float]` (16 kHz mono), which is ≈96 MB for a
25-minute episode. Fine for clips; a streaming decoder would avoid it.

<a id="r12"></a>
### R12 — Low: `--vad energy` still has N1/N2

Silero is the default and doesn't care how loud the music is. The energy fallback's threshold is
`floor * 2`, so dialogue must be at least twice the quietest recent frame:

```
speechPeak=0.30 musicPeak=0.10  threshold=0.1132  found
speechPeak=0.17 musicPeak=0.10  threshold=0.1135  MISSED
```

The same threshold also finds false pauses in the dips of continuous speech without music. The
fix is two thresholds: a more sensitive one (≈ `floor * 1.2`) for speech, and the current one
for pauses.

<a id="r13"></a>
### R13 — Low: very short utterances get very short cues

Found while verifying the R2 fix. With `--input` on a 0.43 s 「はい」, the SRT cue is
`00:00:00,000 --> 00:00:00,199`: Whisper places the segment end too early for audio this short.
The text is right, but a 0.2 s cue barely flashes on screen. A minimum cue duration (for example
extending to the next cue's start, up to ~1 s) would fix it.

<a id="b4"></a>
### B4 — Low: the translation source is `--locale`

`CaptionTranslator.make(from: locale, …)` uses the recognition locale as the source language.
That's consistent, because Whisper is told the same language, but there's no way to translate
from a language other than the one being recognised. Fine until someone asks for it.

<a id="s1"></a>
### S1 — Low: model naming

In `argmaxinc/whisperkit-coreml`, `openai_whisper-large-v3_turbo` is the *full* 32-layer
decoder, while the default `openai_whisper-large-v3-v20240930` is turbo (4 layers; see
[Withdrawn](#withdrawn)). Printing the resolved variant and its decoder depth at start-up would
prevent the confusion. A mistyped `--whisper-model` gives WhisperKit's raw
`No models found matching "*openai*bogus-model/*" in Repo(…)`, which is readable but could list
the shortcuts instead.

<a id="s7"></a>
### S7 — Low: tests in CI

`Tests/yapTests/` has 27 tests in 5 suites, all passing. But `.github/workflows/Release.yml`
only builds on tags and doesn't run them. `ApplePreview.settle`, where J4 lives, has no tests
because it needs a live `SpeechAnalyzer`. Extracting its cut logic into a pure function would
make it testable.

---

## Fixed

| ID | Round | Was | Fix |
|---|---|---|---|
| R1 | 4 | The Apple preview was never finalized: the trailing text was lost at the end of `--input` and on Ctrl+C | `ApplePreview.flush()` finalizes the analyzer and waits for its last results, called as soon as the input ends and before the last commit. Verified: a clip ending in 「そうだぞ」 loses it before the fix and keeps it after, and so does a session interrupted mid-word. |
| R2 | 4 | Whisper returned nothing for utterances ≤ 1 s. Round 3 blamed the model, but the cause is WhisperKit's `windowClipTime` (default 1.0 s): its decode loop `while seek < end - windowClipTime` never runs for ≤ 1 s of audio | `DecodingOptions(windowClipTime: 0.2)`. Verified: 「はい」 (0.43 s), 「そうだぞ」 (0.81 s) and 「アテナよ」 (0.77 s) get no caption before the fix and the right one after, even with `--no-preview`. |
| — | 4 | Found while fixing R2: Whisper can put a short segment's end past the audio it was given, so cues overlapped (はい 2.94–4.94 vs the next cue at 4.22) | Segment ends are clamped to the length of the decoded audio. |
| R3 / A2 | 4 | The 80-character line break let Japanese lines wrap at 160 columns | Breaks at 80 *columns*: `LiveLine.openWidth` and `displayWidth(of: String)`, with a test. |
| R5 | 4 | The CER script's alignment kept the whole integer DP matrix: 2.4 GiB for 8 000 characters | Replaced by rapidfuzz's C++ `Levenshtein.opcodes`: 8 000 characters in 6 ms with negligible memory. The same error count as the old DP on 5 000 random pairs; when several alignments are equally short, the S/D/I split can differ (it matched in 82 % of pairs). Round 3's timings (5.6 s / 122 s) were inflated by `tracemalloc`; untraced, the old code took 0.6 s for 2 000 characters. |
| R6 | 4 | `--reading` / `--translate` in a CER `--config` would be scored as transcription | The script rejects them, and the README says so. |
| R8 | 4 | `harness/tokens/__pycache__/*.pyc` was tracked | Untracked; `.gitignore` covers it. |
| R9 | 4 | `--input nope.wav` could report a locale error first | `validate()` checks that the file exists before anything is set up. |
| N3 | 3 | `splitCaption` could exceed `--max-length` (43 for 40) | Enforced; `maxLengthIsNeverExceeded` tests Latin, Japanese and unbroken text. |
| P1 (part) | 3 | The translation model loaded on the first caption | Warmed up in `CaptionTranslator.make`. |
| P2 | 3 | The previous-line prompt was 40 tokens | 16 tokens. |
| A1 | 3 | The wrong-script rule replaced an English "OK" with Apple's 「はい」 | Also requires `previewLetters >= 4`. |
| A4 | 3 | `hasJapanese` treated 、。 differently from ・ー | One range set: U+3000–30FF, CJK, halfwidth katakana, Ext. B+. |
| B1 | 3 | Translation failures were silent | The first failure is reported on stderr. |
| B2 | 3 | An invalid target (`english`) gave a confusing message | The error lists the supported codes. |
| B3 | 3 | Error messages followed the system locale | Language names are always in English. |
| B5 | 3 | `commit` shadowed `end` | Renamed to `commitEnd`. |
| P3 | 3 | `EnergyActivity.threshold` copied 20 s of levels before checking its cache | Cache first, and injected silence filtered out. |
| N1, N2 | 2 | The adaptive noise floor missed speech under music and invented pauses | Silero VAD is the default. Still true for `--vad energy` ([R12](#r12)). |
| J1 | 1 | The loop filter deleted なるほどなるほど, はいはいはい | ≥ 3 repeats, ≥ 20 characters and ≥ 50 % of the line. |
| J2 | 1 | The vocabulary filter deleted vocabulary-heavy lines | Detects recitation: ≥ 4 distinct terms in vocabulary order. |
| J3 | 1 | Filtered lines vanished in SRT/VTT/JSON | The preview runs in every format and supplies the fallback. |
| J5 | 1 | 「はい」「そう」 were dropped | Fallback threshold `previewLetters >= 2`, with a filler check. |
| J6 | 1 | 「字幕を消してください」 was treated as a hallucination | Patterns anchored to whole stock phrases, ≥ 80 % coverage. |
| J7 | 1 | Two different lines were treated as duplicates | Needs near-equal length and 0.8 bigram overlap. |
| J8 | 1 | The preview didn't get the vocabulary | `ApplePreview.start` sets `contextualStrings`. |
| J9 | 1 | Emoji above U+1F64F were measured as one column | U+1F000–U+1FAFF and variation selectors covered. |
| L1 | 1 | Without the preview, the whole utterance was re-decoded every tick (8.7×) | Decode once per utterance except `--no-preview` on a terminal (0.8×). |
| L3 | 1 | A fixed −40 dBFS silence threshold never found pauses under music | Adaptive floor, then Silero. |
| L4 | 1 | Audio during the model load was lost | Capture starts first and the buffer is replayed. |
| L8 | 1 | Without the preview, nothing was final until 25 s | Only on `--no-preview` now. |
| S6 | 1 | `--max-length` was ignored by Whisper | `splitCaption` splits cues at word boundaries. |
| D1–D4 | 1 | README inaccuracies, a stale patch file | Fixed or deleted. |

<a id="withdrawn"></a>
### Withdrawn

* **L5 / S1 / D1 (original form):** "the default model is full large-v3, not turbo" was wrong. The
  downloaded `config.json` has `"decoder_layers": 4` and
  `"_name_or_path": "/raid/yoach/tmp_whisper_turbo"`. In `argmaxinc/whisperkit-coreml`:

  | variant | decoder layers | what it is |
  |---|---|---|
  | `openai_whisper-large-v3-v20240930` (default) | 4 | turbo |
  | `openai_whisper-large-v3-v20240930_turbo` | 4 | turbo |
  | `openai_whisper-large-v3-v20240930_626MB` / `_632MB` | 4 | turbo, smaller build |
  | `openai_whisper-large-v3` | 32 | full large-v3 |
  | `openai_whisper-large-v3_turbo` | **32** | **full large-v3, despite the name** |

---

## Checked and not bugs

Recorded so they aren't re-investigated.

* **`NLTokenizer` handles Japanese.** Sentence splitting on 。！？ and word segmentation are
  correct with and without `setLanguage(.japanese)`.
* **The vocabulary prompt isn't echoed.** WhisperKit uses `promptTokens` as a decoder prefill
  (`TextDecoder.swift`), so it conditions the decoder and doesn't appear in the output.
* **The audio hot paths are cheap.** `firstSpeech`/`firstPause` take 0.3 ms per tick, the Silero
  VAD 0.3 % of one core, and `hasRepeatedPhrase` 1.6 ms per 240-character line.
  `PendingAudio.snapshot()` is copy-on-write: the cost is a memmove on `drop()`, a few percent of
  a core even at a 5-minute `--input` backlog. Fix decode *schedules*, not these.
* **The Apple and Translation API usage is correct.** `ContextualStringsTag` has only `.general`.
  `status(from:to:)` gates on installed languages, the `TranslationSession` is created once, and
  `targetText` is non-optional.
* **The `LiveLine` redraw composes correctly.** Escape sequences were replayed through a terminal
  emulator, including the wrapped (`rows > 1`) case and notes under a line.
* **Colours match the README.** Final text is cyan (`ESC[36m`) when translating, the reading is
  yellow (`ESC[33m`), and the translation uses the default colour.
* **The Whisper model path is right.** `localFolder` matches WhisperKit's
  `downloadBase/models/<repo>/<variant>`.
* **`once()` is correct**, called both sequentially and from 50 concurrent tasks.
* **`JapaneseReading` is accurate and cheap.** 黄金聖闘士 → おうごんせいとうし, 十二宮 →
  じゅうにぐう, at 0.5 ms per line.
* **AVFoundation doesn't truncate `--input` files.** 48 kHz and 44.1 kHz stereo both decode to
  the full length.
* **`windowClipTime: 0.2` doesn't change longer utterances.** It only decides whether WhisperKit
  starts another 30 s window near the end of the audio. Utterances here are under 30 s, so the
  first window always covers the whole utterance; the only difference is that audio of 0.2–1 s
  is now decoded at all.

---

## Reproductions

* `Tests/yapTests/`: filters, VAD (real `say -v Kyoko` speech under a music bed), caption
  splitting, display width and line width, the hiragana reading. Run it with:

  ```bash
  swift test -Xswiftc -plugin-path -Xswiftc \
    /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
  ```

* `harness/`: standalone Swift programs that copy an algorithm out of `Sources/yap/`, for what the
  test target can't reach. `settle/` covers preview alignment drift (J4), `decode/` the decode
  schedule (L1), `nl/` and `nl2/` NLTokenizer on Japanese, and `tokens/` tokens per character,
  Japanese vs English (1.20 vs 0.54).

  ```bash
  for d in settle decode nl nl2; do
    (cd harness/"$d" && swiftc -O main.swift -o "/tmp/yap-$d" && "/tmp/yap-$d")
  done
  python3 harness/tokens/tokens.py     # needs the cached Whisper tokenizer
  ```

* Short-utterance checks (R1, R2, R13): make clips with
  `say -v Kyoko -o clip.wav --data-format=LEI16@16000 "はい"` and run
  `yap listen -l ja-JP --engine whisper --input clip.wav --srt`.
