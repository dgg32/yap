# yap — bug hunt & suggestions

Focus: **Japanese caption quality** and **response time** for `yap listen`, with both the Apple
and the Whisper engine. The target workload is
`yap listen -l ja-JP --engine whisper --vocabulary seiya.txt`: live Japanese captions of an anime
with background music.

Four review rounds so far (2026-10-24 to 2026-10-26), plus a latency round measured on four
clips of an NHK drama (8.8 minutes of dialogue, with reference subtitles). A fifth round (2026-10-27)
was a code read-through for errors, stray edits and logic errors rather than a feature review;
round 6 fixed what it found, except C6, C8 and C9. This
file lists what is **still open**, then a one-line record of what was fixed, then what was checked
and is *not* a bug. The full write-ups of fixed findings, with their measurements, are in git
history (`git log -p BUG.md`).

Severity: **High** = visible quality or latency damage in a normal workflow · **Medium** = wrong
under specific conditions · **Low** = minor, cosmetic or hygiene.

---

## Open

Nothing High is open.

| ID | Severity | Area | One line |
|---|---|---|---|
| [C6](#c6) | Medium | Latency | `--no-preview` on a terminal still re-decodes the whole pending buffer every tick (+37 % CPU) |
| [A3](#a3) | Medium | Quality · filters | A line said twice in a row is dropped as a Whisper loop |
| [J4](#j4) | Medium | Quality · alignment | Volatile preview text is still cut by counting characters; kanji vs kana can shift the cut |
| [S4](#s4) | Medium | Quality · filters | The filters can't be turned off, and the confidence thresholds are tuned for English |
| [L9](#l9) | Medium | Quality | Reported: long lines occasionally go missing. Not reproduced yet |
| [L2](#l2) | Low | Latency | Speech with no pause gets no final text for 10 s |
| [A5](#a5) | Low | Quality · output | Text output and subtitle output read and translate different units (also R10) |
| [A6](#a6) | Low | Quality · translation | A cue can end up with no translation when the translation is short |
| [R7](#r7) | Low | Output | With `--reading` and `--translate`, an SRT cue has three lines; many players show two |
| [R11](#r11) | Low | Memory | `--input` decodes the whole file into memory (≈96 MB for 25 minutes) |
| [R12](#r12) | Low | Quality · VAD | With `--vad energy`, dialogue quieter than 2× the music bed isn't detected (old N1/N2) |
| [R13](#r13) | Low | Output | Whisper's timestamps for a very short utterance are short: a 0.4 s 「はい」 becomes a 0.2 s cue |
| [B4](#b4) | Low | Translation | The translation source language always comes from `--locale` |
| [S1](#s1) | Low | Suggestion | Show which model was resolved; make the "No models found" error friendlier |
| [S7](#s7) | Low | Testing | CI doesn't run the tests, and `ApplePreview.settle` has no tests |
| [C8](#c8) | Low | Robustness | `MCP_Command` hard-codes the server version |
| [C9](#c9) | Low | Output | A space is only inserted between two ASCII pieces of a line |

<a id="c6"></a>
### C6 — Medium: `--no-preview` on a terminal still re-decodes the whole pending buffer

L1 was fixed by `oncePerUtterance = preview != nil || !live`, which covers the preview and every
non-live output (SRT, VTT, JSON, piped text). The one case left is `--no-preview` on a terminal,
where `preview == nil` and `live` is true — there, Whisper's own tentative text is the only live
feedback, so the loop falls through to `transcribe(samples)` with the **whole** pending buffer on
every pass.

Measured on a 30 s clip through a pty:

```
with the preview : 10.5 s user
--no-preview     : 14.4 s user   (+37 %)
```

Round 1's "8.7× amplification" was about audio-seconds re-decoded, not CPU; the CPU cost is
dominated by the encoder on the GPU, so +37 % is the honest number. It still grows with the
length of the pending utterance.

Fix: cap what is re-decoded for the tentative text (decode only the newest window, or keep the
last decode's text and refresh it on a timer), or make `--no-preview` fall back to the
non-live schedule and update the terminal text less often.

<a id="c8"></a>
### C8 — Low: `MCP_Command` hard-codes the server version

`MCP.swift` reports `version: "1.0.0"` to clients. The package has no version of its own
(`Package.swift` names the executable `yap` and nothing else), so this number can drift from the
tool's actual version without anything noticing.

<a id="c9"></a>
### C9 — Low: a space is only inserted between two ASCII pieces of a line

`LiveLine.appendFinal` joins the pieces of a line:

```swift
if let last = open.last, let first = text.first, last.isASCII, first.isASCII,
   last.isLetter || last.isNumber || last.isPunctuation, first.isLetter || first.isNumber {
    open += " "
}
```

The `isASCII` guard is right for Japanese (no space between 「。」 and the next word), but it also
means a line ending in a non-ASCII punctuation mark gets no space before an English word:
"…" + "Hello" becomes "…Hello".

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

<a id="l9"></a>
### L9 — Medium: long lines occasionally go missing (reported, not reproduced)

Seen in live use (anime with background music, `--vocabulary`, `--translate`). Checked on
2026-10-27 without reproducing it:

* **Four drama clips** (text output, `--translate en`): the longest stretch of the broadcast
  subtitles missing from the captions is 6–7 characters (short replies). Every line the filters
  dropped was decoded noise (「またね」「バイオー」).
* **Eight real 12–21 s lines**, clean and over a music bed with loud stings: 87–99 % of every
  line's characters reached the captions, and nothing was filtered.
* **Ruled out:** the compression-ratio filter. WhisperKit compresses token IDs rather than text,
  but real dialogue stays under 2.4 at any length (maximum 2.21 over 1 000 deduplicated lines).

**Fixed along the way:** WhisperKit gives every segment the *window's* confidence and compression
ratio, so one unclear stretch could get every line of a long utterance dropped. Segments are now
judged on their own tokens (drops on the four clips 32 → 14, the same CER). WhisperKit's
confidence is also numerically unreliable on noise: window averages of −10.86 = ln(1/51 866),
a uniform guess over the whole vocabulary, which an argmax token can't score.

**Still possible in live use:** Silero hearing no speech under loud music (that audio is discarded
untranscribed, and only Apple's text can cover it), or Apple's fallback arriving in fragments
(「すみ」, 「ませ」). `YAP_DEBUG_FILTERS=1` tells these apart. Next step: a log or a recording of a
scene where it happens.

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

`Tests/yapTests/` has 29 tests in 6 suites, all passing. But `.github/workflows/Release.yml`
only builds on tags and doesn't run them. `ApplePreview.settle`, where J4 lives, has no tests
because it needs a live `SpeechAnalyzer`. Extracting its cut logic into a pure function would
make it testable.

---

## Fixed

| ID | Round | Was | Fix |
|---|---|---|---|
| C1 | 6 | `yap transcribe` (and the MCP path) hung forever on a zero-length file: the analyzer never finishes without frames | Both check `audioFile.length > 0` first and report "*file* contains no audio". Verified: 0.55 s and an error instead of a hang. (Medium rather than High: an empty file isn't a normal workflow.) |
| C2 | 6 | `listen-and-dictate` gave ScreenCaptureKit the global concurrent queue, so `AVAudioConverter` could be used from two threads | Uses the delegate's serial queue, as `listen` does. |
| C3 | 6 | `listen-and-dictate` didn't feed silence during playback gaps, so a short last line could stay unfinalized | Calls `startSilencePadding()` like `listen`. |
| C4 | 6 | The per-segment judgement still tested `noSpeechProb`, which WhisperKit sets per window | Moot in practice — WhisperKit never computes it (`let noSpeechProb: Float = 0 // TODO`, TextDecoder.swift:821), so the test could never fire. Removed, with a comment, so it doesn't start dropping whole windows if WhisperKit implements it. |
| C5 | 6 | `YAP_DEBUG_FILTERS` also reported filtering from tentative and discarded speculative decodes, and empty decodes as "dropped" | Notes from a decode are held until the decode is used for a line, and discarded otherwise. An empty decode is reported as "Whisper heard no words in *n* s of speech". In practice the old log had 2 such entries over four clips, so earlier logs were nearly right. |
| C7 | 6 | The Speech-asset installation was copied out in five places, not three | `dictate` and `listen-and-dictate` call `reserveSpeechAssets` / `installSpeechAssets`; `transcribe` calls `installSpeechAssets` (its own locale check stays, because it lists the supported locales). The MCP path keeps its copy on purpose: the shared helper draws a progress bar on stdout, which is the MCP protocol channel. |
| C10 | 6 | Four force-unwrapped `AttributedString.Index` conversions in `sentences(maxLength:)` | `compactMap`, as in `wordTimestamps()`: an unconvertible range is skipped instead of crashing. |
| C11 | 6 | An empty translation added an empty line to an SRT cue | `CaptionTranslator.translate` returns nil for an empty result. |
| Latency | 5 | A final line appeared a median **1.6 s** after its speech ended: ~0.85 s waiting for the pause to be confirmed, then ~0.75 s of decoding | **Speculative decoding:** Whisper starts once the speaker has been quiet for 0.2 s, and the result is used when the pause is confirmed (128 of 130 lines). Median **1.6 s → 1.05 s**, with the same CER (8.2 % → 7.9 %, within run-to-run noise). About a quarter of speculative decodes are thrown away because the speaker went on. |
| Latency | 5 | Temperature fallbacks (up to 3 extra decodes) made the slowest lines take 3–5 s | `temperatureFallbackCount: 1`. The same CER (7.9 %), and lines over 2 s went from 6 of 130 to 3 (one of them is L2's 10 s split). |
| P1 | 5 | The translation was awaited in the caption loop | Translations are printed under their line when they arrive (text output) or written by an ordered queue (subtitles), so the captions don't wait. Only a line ending while the previous translation is still in flight waits for it, which keeps each translation under its own line. Measured with `--translate en`: translation added **40 ms** per line before and **17 ms** after. Round 2's "70–105 ms, doubles the latency" was far too high: it was measured cold, and drama lines are short. Verified in text, SRT and terminal output. |
| Tooling | 5 | No way to see where the latency goes | `YAP_DEBUG_TIMING=1` reports the wait, decode and fallbacks for each line, plus a summary (README, Development). |
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
* **Latency round, measured and rejected** (four drama clips, CER against the broadcast subtitles):
  * *Text decoder on the GPU (old L6):* decode times are the same as on the Neural Engine
    (median 0.74–0.84 s either way). It stays on the Neural Engine.
  * *A 0.6 s pause for short utterances instead of 0.8 s:* saves 0.15 s, but CER rises from
    8.2 % to 9.9 % as sentences get cut into fragments.
  * *`prewarm: true` (old L7):* prewarming loads every model twice on *every* start, while Core ML
    specialisation only happens once after an OS update. That's a bad trade for a tool that's
    started often, so it stays `false`. (It can't be measured on an already specialised model.)
  * *Temperature fallbacks as the main cost:* they're rare (1–3 lines per clip). Reducing them
    helps the worst case, not the median.
* **`windowClipTime: 0.2` doesn't change longer utterances.** It only decides whether WhisperKit
  starts another 30 s window near the end of the audio. Utterances here are under 30 s, so the
  first window always covers the whole utterance; the only difference is that audio of 0.2–1 s
  is now decoded at all.
* **Round 5, code read-through — no stray edits.** No `TODO`/`FIXME`, no leftover `print`/`dump`
  debugging, no dead branches. The two debug helpers (`DebugTiming`, `DebugFilters`) are
  deliberate and gated behind `YAP_DEBUG_TIMING=1` / `YAP_DEBUG_FILTERS=1`. `Tests/video/` (a
  1.6 GB NHK episode and the CER clips) is gitignored, not committed.
* **Round 5 — the per-segment `avgLogprob` is comparable to WhisperKit's own.** WhisperKit
  averages the log-probabilities of the tokens from `<|startoftranscript|>` to `<|endoftext|>`
  (`TextDecoder.swift`), which include the timestamp tokens; yap's per-segment average is over
  the segment's own tokens, which include the same kind of tokens. So the `-1` / `-1.2`
  thresholds mean the same thing before and after round 4 — they just apply to one segment
  instead of the whole window.
* **Round 5 — the compression ratio is the same measure as before.** yap recomputes it with
  `TextUtilities.compressionRatio(of: [Int])`, which is exactly what WhisperKit uses for its own
  final value (`TextDecoder.swift:813`); it compresses token IDs rather than text, in both
  cases. The `2.4` threshold is comparable.
* **Round 5 — the `AVAudioConverter` single-buffer pattern is the standard one.** Both
  `ApplePreview.feed` and `AudioStreamDelegate` pass one input buffer and return `.noDataNow`
  afterwards, which is the documented way to convert a buffer of unknown length.
* **Round 5 — a partial Silero download is cleaned up.** `SileroModelStore.load` downloads into a
  staging directory and only moves it into place once every file is there; an interrupted
  download leaves the staging directory, which the next run removes.

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

* Round 5 checks:

  ```bash
  # C1 — a zero-length file (hung before round 6; now reports "contains no audio")
  python3 -c "import wave; w=wave.open('/tmp/empty.wav','wb'); w.setnchannels(1); \
      w.setsampwidth(2); w.setframerate(16000); w.writeframes(b''); w.close()"
  yap transcribe -l ja-JP /tmp/empty.wav

  # C6 — the cost of --no-preview on a terminal (needs a pty for `live`)
  ffmpeg -v error -stream_loop 5 -i clip.wav -t 30 -c:a pcm_f32le long.wav -y
  time script -q /dev/null yap listen -l ja-JP --engine whisper --input long.wav
  time script -q /dev/null yap listen -l ja-JP --engine whisper --no-preview --input long.wav
  ```
