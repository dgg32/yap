# yap — bug hunt & suggestions

Focus: **Japanese caption quality** and **response time** for `yap listen` (both the Apple
and the Whisper engine). Target of the hunt: `yap listen -l ja-JP --engine whisper --vocabulary seiya.txt`,
i.e. live Japanese captions of an anime with background music.

Every finding below was verified against the code at `fc33b4c` and, where possible, with an
executable reproduction. Reproductions live in `harness/` and are described in
[Appendix A](#appendix-a--reproductions).

Severity key: **Critical** = captions are wrong or missing in a normal workflow ·
**High** = visible quality/latency damage · **Medium** = wrong under specific conditions ·
**Low** = cosmetic / hygiene.

> **Status update (review of the fixes, 2026-10-24):** most of the quality findings have been
> addressed and the first caption now appears much sooner. See
> [§ Status after the fixes](#status-after-the-fixes) for what is fixed, what is still open,
> and the two new problems the fixes introduced. **L5 was wrong — see the correction.**
>
> **Status update 2 (review of the translation / Silero round, 2026-10-24):** the Silero VAD is
> an excellent addition and largely retires N1/N2. The translation feature works. The new
> findings for that round are in
> [§ Round 2 — translation, Silero VAD, line-based output](#round-2--translation-silero-vad-line-based-output):
> **P1 (High)** — the translation is awaited inside the caption loop and roughly doubles the
> caption latency; **A1 (High)** — the new "wrong script" rule replaces short English
> utterances with Apple's Japanese text; **A2 (Medium)** — the line-length limit counts
> characters, so Japanese lines wrap.

---

## Summary

| ID | Severity | Area | One line |
|---|---|---|---|
| [J1](#j1--critical) | Critical | Quality | The "Whisper is looping" filter deletes ordinary Japanese lines (なるほどなるほど, はいはいはい) |
| [J2](#j2--critical) | Critical | Quality | The vocabulary-echo filter deletes legitimate vocabulary-heavy Japanese lines |
| [J3](#j3--high) | High | Quality | Filtered lines are silently dropped in SRT/VTT/JSON mode but survive in TXT mode |
| [J4](#j4--high) | High | Quality · alignment | Preview/final alignment counts characters — kanji vs kana drift swallows or duplicates text |
| [J5](#j5--high) | High | Quality · alignment | Short Japanese replies (はい / そう / だぞ) are dropped entirely |
| [J6](#j6--medium) | Medium | Quality · filters | "字幕" / "チャンネル登録" / "最後までご視聴" are hard-coded as hallucinations and match real speech |
| [J7](#j7--medium) | Medium | Quality · filters | Two different Saint Seiya lines are treated as duplicates; the second is dropped |
| [J8](#j8--medium) | Medium | Quality · vocabulary | The Apple preview never receives the vocabulary, so the fallback re-introduces the misheard names |
| [J9](#j9--medium) | Medium | Quality · terminal | `displayWidth` misses emoji outside U+1F300–U+1F64F → wrong row count → garbled redraw |
| [L1](#l1--critical) | Critical | Latency · decode | Without the preview, Whisper re-decodes the whole pending utterance every tick — 8.7× amplification |
| [L2](#l2--critical) | Critical | Latency · decode | The preview path refuses to emit anything until 10 s of audio has accumulated |
| [L3](#l3--high) | High | Latency · VAD | A fixed 0.01 RMS silence threshold means pauses are never found under a music bed |
| [L4](#l4--high) | High | Latency · startup | The Whisper model is loaded *before* capture starts → the first minutes of audio are lost |
| [L5](#l5--high) | ~~High~~ | Latency · model | **Withdrawn — the default already is turbo; my finding was wrong** |
| [L6](#l6--medium) | Medium | Latency · compute | `textDecoderCompute` is left on the Neural Engine; the GPU is only used for the encoder |
| [L7](#l7--medium) | Medium | Latency · startup | `prewarm: false` leaves the first decode of a session paying Core ML specialisation |
| [L8](#l8--medium) | Medium | Latency · decode | Non-preview path: nothing is final until 25 s of audio accumulate |
| [S1](#s1--high) | High | Suggestion · model | Default to `large-v3-turbo`; expose a `--turbo` / smaller-model default |
| [S2](#s2--high) | High | Suggestion · decode | Decode once per utterance instead of re-decoding; cache the encoder window |
| [S3](#s3--high) | High | Suggestion · VAD | Replace the fixed RMS threshold with an adaptive noise floor |
| [S4](#s4--medium) | Medium | Suggestion · filters | Make the loop/hallucination filters language-aware or configurable |
| [S5](#s5--medium) | Medium | Suggestion · alignment | Use the time-range estimate that `settle()` already computes instead of character counting |
| [S6](#s6--medium) | Medium | Suggestion · output | Apply `--max-length` to the Whisper engine |
| [S7](#s7--low) | Low | Suggestion · testing | Add a unit-test target; there are currently no tests at all |
| [D1](#d1--medium) | Medium | Docs | The engine table advertises large-v3-turbo; the code defaults to large-v3 |
| [D2](#d2--low) | Low | Docs | "final after about 0.5 s of quiet" does not hold under music |
| [D3](#d3--low) | Low | Docs | The "ignored flags" row omits `--max-length` |
| [D4](#d4--low) | Low | Hygiene | `yap-listen-live.patch` is a stale, already-applied patch left in the repo root |
| [P1](#p1--high) | High | Latency · translation | The translation is awaited inside the caption loop — it roughly doubles the caption latency |
| [P2](#p2--low) | Low | Latency · prompt | The vocabulary + previous-line prompt is re-prefilled on every decode (88 tokens) |
| [P3](#p3--low) | Low | Performance · VAD | `EnergyActivity.threshold` copies a 20-second window per frame before checking the cache |
| [P4](#p4--info) | Info | Performance | The rest of the hot path is fine — the Silero VAD costs 0.3 % of one core |
| [A1](#a1--high) | High | Quality · script | The "wrong script" rule replaces short English utterances with Apple's Japanese text |
| [A2](#a2--medium) | Medium | Quality · layout | The line-length limit counts characters, not columns, so Japanese lines wrap |
| [A3](#a3--medium) | Medium | Quality · prompt | The previous-line prompt can make Whisper echo the previous line, which the duplicate filter deletes |
| [A4](#a4--low) | Low | Quality · script | `hasJapanese` classifies Japanese punctuation inconsistently (・ー yes, 、。 no) |
| [A5](#a5--low) | Low | Quality · translation | Text output and subtitle output translate different units |
| [A6](#a6--low) | Low | Quality · translation | Some cues can end up with no translation |
| [B1](#b1--medium) | Medium | Bug · translation | Translation failures are swallowed — the user gets silence and no message |
| [B2](#b2--medium) | Medium | Bug · translation | An invalid target language produces a confusing message |
| [B3](#b3--low) | Low | Bug · translation | The error message language follows the system locale |
| [B4](#b4--low) | Low | Bug · translation | The translation source language is inferred from `--locale` |
| [B5](#b5--low) | Low | Bug · style | `CaptionOutput.commit` shadows `end` in its loop |

---

## Status after the fixes

Reviewed against the working tree of 2026-10-24 (the `bug fix` work on top of `fc33b4c`).

### Fixed

| ID | How it was fixed |
|---|---|
| J1 | `hasRepeatedPhrase` now needs ≥ 3 repeats **and** ≥ 20 characters **and** ≥ 50 % of the line, so 「なるほどなるほどなるほど」 survives while a 68-character Whisper loop is still caught. |
| J2 | `echoesVocabulary` → `recitesVocabulary`: now requires ≥ 4 *distinct* terms, in vocabulary order, with ≤ 10 % unmatched characters. Longest term wins, so 黄金聖闘士 is no longer also counted as 聖闘士. |
| J3 | The Apple preview now runs in **every** output format, so `Captions.settle` supplies a fallback in SRT/VTT/JSON and piped text too. |
| J4 | *Partly* — `settle` now snaps the cut to nearby punctuation. See "still open" below. |
| J5 | The guard is now `previewLetters >= 2` with a filler check, so 「はい」「そう」 are no longer dropped. |
| J6 | The patterns are anchored to full stock phrases and must cover ≥ 80 % of the line; 「字幕を消してください」 is kept. |
| J7 | `isNearDuplicate` now also requires near-equal length (80 %) and raises the bigram overlap to 0.8. |
| J8 | `ApplePreview.start` takes the vocabulary and sets `AnalysisContext.contextualStrings[.general]`. |
| J9 | `displayWidth` covers U+1F000–U+1FAFF and variation selectors. |
| L1 | `oncePerUtterance = preview != nil \|\| !live` — the whole-buffer re-decode is gone from every path except `--no-preview` on a terminal. Amplification drops from **8.7× to 0.8×**. |
| L2 | Largely: a detected pause now ends the utterance early, and the 10 s floor only applies to genuinely continuous speech. |
| L3 | Replaced by an adaptive `NoiseFloor`. See the new finding below — it is a trade, not a free win. |
| L4 | Capture now starts before the model load, the Apple transcriber is started first, and the buffered audio is replayed into it, so nothing said during the download is lost. |
| L6 | Not addressed. |
| L7 | Not addressed. |
| L8 | Only reachable on the `--no-preview` path now. |
| S6 | `splitCaption` splits Whisper cues at word boundaries and divides the time range proportionally. |
| S7 | `Tests/yapTests/` added — now 21 tests in 4 suites, all passing. |
| D1–D4 | README updated (engine table, `--max-length` row, pause timing, development section); `yap-listen-live.patch` deleted. |
| N1, N2 | **Largely retired by the Silero VAD**, which is now the default and does not care whether the dialogue is louder than the music bed. Both problems remain on the `--vad energy` fallback. See [Round 2](#round-2--translation-silero-vad-line-based-output). |

### Still open

| ID | Note |
|---|---|
| **J4** | The kanji/kana drift is reduced but not eliminated. The punctuation window is only ±3 characters, while the measured drift is ±5. See [harness/settle/](../harness/settle/). |
| **L2** | The `guard duration >= 10` floor is still there for speech with no pause. Defensible, but it means a single long sentence produces no final text for 10 s. |
| **L6** | `textDecoderCompute` is still `.cpuAndNeuralEngine` (default); only the encoder was moved to the GPU. |
| **L7** | `prewarm: false` is unchanged, so the first decode of a session still pays Core ML specialisation. |
| **S4** | The filters are still not configurable — there is no way to turn them off when they are wrong. |
| **S7** | There are no tests yet for `ApplePreview.settle` (it needs a live `SpeechAnalyzer`), and the CI workflow still does not run them. |
| **P1** | New in round 2 — the translation is awaited inside the caption loop. |
| **A1** | New in round 2 — the wrong-script rule replaces short English utterances. |

### New problems introduced by the fixes

<a id="n1--high"></a>
#### N1 — High: the adaptive noise floor can rise above the speech level and drop the audio entirely

`NoiseFloor.threshold` is `min(max(floor * 2, 0.005), 0.15)`, where `floor` is the 10th percentile
of the frame RMS over the last 20 s. `firstSpeech` and `firstPause` share that threshold.

The consequence: **speech is only detected if it is at least twice as loud as the quietest recent
frame.** In a continuous-music scene the quietest frames *are* the music, so the threshold becomes
2× the music level — and dialogue mixed below that ratio is not "speech" at all. Measured:

```
speechRMS=0.17 musicRMS=0.10  threshold=0.1156  speechFound=false
speechRMS=0.10 musicRMS=0.10  threshold=0.1122  speechFound=false
```

When `firstSpeech` returns nil the code discards the audio:

```swift
guard let speechStart = AudioLevel.firstSpeech(in: samples, threshold: threshold) else {
    audio.drop(upTo: end - Int(sampleRate * 0.3))
    output.commit(upTo: Double(end) / sampleRate - 0.3)
    …
}
```

So a loud scene produces **no Whisper transcription at all** — only the Apple fallback keeps any
text, and with `--no-preview` the scene is silently lost.

Two related effects:

* The 0.15 ceiling is reached quickly in a loud scene (`threshold after 20 s of loud speech = 0.15`),
  and it then decays back over the 20 s window. A quiet passage right after a loud one is
  invisible for several seconds (`threshold=0.0688 speechFound=false`).
* The floor is measured over a stream that **includes the digital silence the delegate injects
  during gaps**. The 10th percentile sits exactly at the boundary where 10 % padding zeroes it
  (measured: 18 s of audio + 2 s of padding → floor 0.106, one more second of padding → 0), so
  the adaptation switches itself off precisely when the scene is most broken up.

**Fix.** Use two thresholds, not one:

* speech detection wants to be *sensitive*: `firstSpeech` should use roughly `floor * 1.2`, or a
  fraction of the observed peak;
* pause detection wants to be *conservative*: `firstPause` should keep the current `floor * 2`.

Measured, with the same scene that fails today:

```
threshold = 0.1131
speech found at threshold      = false
speech found at threshold * 0.6 = true
speech found at threshold * 0.4 = true
```

Also worth doing: bound the threshold relative to the observed peak (`min(threshold, peak * 0.5)`)
instead of the absolute 0.15 ceiling, and exclude the injected padding from the floor estimate.

> **Resolved in practice by the Silero VAD** (round 2). The energy detector is now the fallback
> rather than the default, and a neural voice detector does not care whether the dialogue is
> louder than the music bed. The same applies to N2 below. The fixes above are still worth
> making for `--vad energy`.

<a id="n2--medium"></a>
#### N2 — Medium: the adaptive threshold invents pauses inside continuous speech

The other side of the same threshold. When there is no music, the floor is estimated from the
speech's *own* quiet moments, so the dips between syllables and phrases fall below it and are
reported as pauses. Measured on amplitude-modulated speech (5 Hz syllables, phrase-level dips):

```
modulated speech: threshold=0.0440 falsePause=4.02
```

A pause is reported at t = 4.02 s inside a continuous 10-second sentence, so the utterance is cut
mid-sentence and each half is transcribed separately — worse accuracy and a wrong caption break.
The minimum pause length was also lowered from 500 ms to 400 ms, which makes this more likely.

**Fix.** As in N1, derive the pause threshold from the *speech* level rather than from the
background: a frame should count as a pause only if it is quiet **and** clearly below the
surrounding speech, not merely below a background-relative threshold. Comparing the candidate
pause's level with the level of the speech burst before it is the usual approach.

> **Resolved in practice by the Silero VAD** (round 2) — see N1. The energy detector still has
> this problem, so `--vad energy` inherits it.

<a id="n3--low"></a>
#### N3 — Low: `splitCaption` can exceed `--max-length`

`--max-length` is now honoured by the Whisper engine, but the cut is placed at the nearest word
boundary to an even target, and nothing constrains the result. Measured with `--max-length 40`:

```
latin -> 9 pieces, max len 43
   piece(32): abcdefghij abcdefghij abcdefghij
   piece(43): abcdefghij abcdefghij abcdefghij abcdefghij
   …
```

Japanese overshoots less (the existing test allows 24 characters for a limit of 20), but it does
overshoot. The option is documented as a maximum, so either enforce it (fall back to a hard cut
when no boundary is close enough) or document it as approximate.

---

## Round 2 — translation, Silero VAD, line-based output

Reviewed against the working tree of 2026-10-24 (the translation / Silero round on top of
`c24cb8c`).

### What got better

* **The Silero VAD retires N1 and N2.** It is the default now, and it is the right answer to both
  problems: a neural voice detector does not care whether the dialogue is louder than the music
  bed, so neither the "speech below the threshold" failure (N1) nor the "false pause inside
  speech" failure (N2) can happen. The `energy` fallback still has both problems, so
  `--vad energy` inherits them.
* **It is cheap.** Measured: 10 s of audio analysed in **26 ms — 0.3 % of one core**. The VAD is
  not worth optimising.
* **The tests are strong.** `SpeechActivityTests` generates real Japanese speech with
  `say -v Kyoko`, mixes it under a music bed, and asserts that the pause is found at the right
  place and that music alone is not speech. That is exactly the test this feature needed.
* **The Whisper model path, the previous-line prompt and the line-based output are all sound.**
  The previous-line prompt is exactly Whisper's "preceding text" mechanism, the model path matches
  WhisperKit's own `downloadBase/models/<repo>/<variant>` convention, and the `LiveLine` redraw
  composes correctly (I replayed its escape sequences through a terminal emulator to check).
* The Translation API usage is correct: `status(from:to:)` gates on the installed languages, the
  `TranslationSession` is created once and reused, and `Response.targetText` is a non-optional
  `String`.

### Performance

<a id="p1--high"></a>
#### P1 — High: the translation is awaited inside the caption loop, and it roughly doubles the caption latency

`CaptionOutput.write` awaits the translation before returning, and `commit` is awaited from the
main capture loop. The loop polls every 100 ms, so every millisecond spent translating is a
millisecond the audio is not being consumed.

Measured on this machine (Apple Translation, `ja → en`, the same session the app creates):

```
cold start (first ever)            163 ms  (38 chars)
same sentence again                69 ms  (38 chars)
short line                         30 ms  (2 chars)
medium line                        80 ms  (30 chars)
long line (85 chars)              183 ms
long line (170 chars)             339 ms
batch of 5 short lines            118 ms
```

That is roughly **2 ms per character plus a ~25 ms fixed cost**. A typical Japanese caption line
of 30–40 characters costs **70–105 ms**, which pushes the loop's effective period from 100 ms to
**170–205 ms** — the caption latency roughly doubles the moment `--translate` is used.

The first line is worse: the translation model is loaded on the first request, which measured
**163 ms in a warm process and 524 ms in a cold one**. That cost is paid at exactly the moment
the user is waiting for their first caption.

**Fix**, in order of value:

1. **Warm the session up at start-up.** Translate a short dummy string right after creating the
   session (in `CaptionTranslator.make`), so the model load happens during start-up instead of on
   the first caption. One line of code, removes the worst case.
2. **Translate off the critical path.** Keep a queue of finished lines; translate them in a
   background task and call `line.printNote(...)` when each result arrives. `printNote` already
   redraws the current line correctly, so a late note still lands in the right place.
3. **Use the batch API.** `TranslationSession.translate(batch:)` translated 5 short lines in
   118 ms versus ~150 ms one at a time, and it is one round trip instead of five.

<a id="p2--low"></a>
#### P2 — Low: the prefill prompt grew, and it is re-done on every decode

The prompt is now the vocabulary **plus** the previous line. Measured with the real Whisper
tokenizer on `seiya.txt`:

```
vocabulary (10 terms, joined with 、)   58 tokens
previous line (30 Japanese characters)  30 tokens
total prefill                          88 tokens   (WhisperKit caps the prompt at 223)
```

The vocabulary is tokenised once ✓, but the whole prompt is re-prefilled on every decode, and
WhisperKit prefills in slices of 3 — so ~30 sequential decoder steps per utterance. The
previous line roughly doubles the prefill relative to the vocabulary alone.

Not a bottleneck (the audio encoder is ~0.4 s), but the previous line only needs its tail for
context — `limit: 40` could be `limit: 16` with no loss of usefulness.

<a id="p3--low"></a>
#### P3 — Low: `EnergyActivity.threshold(at:)` copies a 20-second window on every frame, before checking the cache

```swift
func threshold(at frame: Int) -> Float {
    let history = 20 * 16000 / frameLength
    let window = levels[max(0, frame - history)...frame]   // ← copy, up to 667 Floats
    guard window.count >= 16000 / frameLength else { return AudioLevel.silenceThreshold }
    let bucket = frame / (16000 / frameLength)
    if let cached = thresholdCache[bucket] { return cached }  // ← consulted too late
    …
}
```

The slice copy happens on every call; the per-second cache is only consulted afterwards.
Measured: 10 full scans of a 30 s buffer = **12.3 ms**, i.e. 1.2 ms per scan and ~1.2 % of a
core. Small, but the copy is pure waste for every cached frame — move the cache lookup above
the copy and it disappears.

<a id="p4--info"></a>
#### P4 — Info: the rest of the hot path is fine

* `PendingAudio.snapshot()` still copies the whole pending buffer every 100 ms (~19 MB/s at a
  30 s buffer). Measured earlier as negligible next to a decode; recorded only so it is not
  mistaken for a hotspot.
* The Silero VAD costs **0.3 % of one core** — no work needed.
* The `hasRepeatedPhrase` scan costs 1.6 ms for a 240-character Japanese line.

### Accuracy

<a id="a1--high"></a>
#### A1 — High: the "wrong script" rule replaces short English utterances with Apple's Japanese text

The new rule in `ApplePreview.settle`:

```swift
let wrongScript = Self.hasJapanese(previewText) && !Self.hasJapanese(whisperText)
    && letters(whisperText) <= 12
if previewLetters >= 2, !previewContent.allSatisfy(WhisperFilter.fillerCharacters.contains),
   letters(whisperText) * 2 < previewLetters || wrongScript {
```

`wrongScript` **bypasses** the "Whisper heard much less than Apple" check entirely, so any short
non-Japanese Whisper line is overwritten by Apple's Japanese transcription. Measured:

```
preview=はい       whisper=OK           -> wrongScript=true
preview=はい       whisper=Okay         -> wrongScript=true
preview=未来永劫   whisper=Mira,Diego   -> wrongScript=true   ← the intended case
preview=未来永劫の戦士 whisper=Mira Diego and more -> wrongScript=false
```

The first case is the bug: the speaker says "OK", Apple's Japanese-mode transcriber hears 「はい」,
and the correct English "OK" is replaced by the Japanese 「はい」. That is a realistic anime
situation — English words dropped into Japanese dialogue are common, and this is a live
captioning tool for anime.

The rule also fires on `Okay`, `Yes`, `No`, `Right`, `Hey` — anything ≤ 12 letters that is not
Japanese, whenever Apple's preview heard *anything* Japanese.

**Fix.** Keep the length comparison as a precondition rather than an alternative:

```swift
let wrongScript = Self.hasJapanese(previewText) && !Self.hasJapanese(whisperText)
    && letters(whisperText) <= 12
    && letters(whisperText) * 2 < previewLetters
```

so that the preview must also be substantially longer than what Whisper heard. "Mira, Diego"
(10 letters) against 「未来永劫」 (4 letters) would then **not** fire — hmm, that breaks the
intended case, which is the harder one.

Better: keep the current condition but require the preview to be Japanese *and* the Whisper text
to look like a mishearing of a proper noun rather than a plausible short utterance. A cheap
version: require `previewLetters >= 4` (so 「はい」 alone does not trigger it) — that fixes the
"OK" case above without touching the "Mira, Diego" case:

```
preview=はい       whisper=OK           -> previewLetters=2  → no longer fires ✓
preview=未来永劫   whisper=Mira,Diego   -> previewLetters=4  → still fires ✓
```

<a id="a2--medium"></a>
#### A2 — Medium: the line-length limit counts characters, not columns, so Japanese lines wrap

```swift
let endsLine = endsLine || endsSentence || line.openLength + text.count > 80
```

80 **characters** of Japanese is 160 **display columns**, so the line wraps onto two rows of an
80-column terminal — while the Latin equivalent (80 characters ≈ 80 columns) fits exactly.
Everything else in `LiveLine` correctly measures *display width* (`terminalRows(for:)` uses
`displayWidth`), so only the break point is wrong.

Fix: compare the display width instead of the character count, e.g.

```swift
let width = displayWidth(of: line.open + text)
let endsLine = endsLine || endsSentence || width > 80
```

(`displayWidth` is currently `private` inside `Listen.swift`; it needs to be reachable from
`WhisperListen.swift`, or the limit needs to move into `LiveLine`.)

<a id="a3--medium"></a>
#### A3 — Medium: the previous-line prompt can make Whisper echo the previous line — and the near-duplicate filter then deletes it

The prompt is now literally the previous line, which is Whisper's documented "preceding text"
mechanism and is the right idea. But it also primes the model to continue or repeat that line,
and `isNearDuplicate` (bigram overlap ≥ 0.8, length ratio ≥ 0.8) drops a repeat as a loop.

So a genuinely repeated line — a character saying the same thing twice in a row, which happens
in anime — now *disappears* rather than being shown twice. Before the prompt existed, the second
copy was kept (or dropped only when it was an exact duplicate of one of the last 3 finals).

This is a plausible new failure mode of the prompt feature and worth a regression test: feed the
same line twice and check that it appears twice.

<a id="a4--low"></a>
#### A4 — Low: `hasJapanese` classifies Japanese punctuation inconsistently

```
hasJapanese(・ー) = true      ← U+30FB, U+30FC (katakana block)
hasJapanese(、。) = false     ← U+3001, U+3002 (CJK symbols block)
hasJapanese("")  = false
hasJapanese(Hello) = false
```

A line of only 「、。」 is not "Japanese", while a line of only 「・ー」 is. Halfwidth katakana
(U+FF66–U+FF9F) and CJK Extension B+ (U+20000+) are not covered either. Use one coherent set:

```swift
(0x3000...0x30FF).contains($0.value)    // CJK symbols, hiragana, katakana
    || (0x3400...0x4DBF).contains($0.value)
    || (0x4E00...0x9FFF).contains($0.value)
    || (0xF900...0xFAFF).contains($0.value)
    || (0xFF66...0xFF9F).contains($0.value)
    || (0x20000...0x3FFFD).contains($0.value)
```

<a id="a5--low"></a>
#### A5 — Low: text output and subtitle output translate different units

The text path translates the whole assembled line — a sentence ✓. The subtitle path translates
**each Whisper segment separately** and then splits that English translation over the cues at
word boundaries. Two consequences:

* The two output formats disagree about what a "line" is, so the same audio yields a different
  translation in text mode and in SRT mode.
* Splitting English at *word* boundaries to line up with Japanese *cue* boundaries is
  approximate: the English word distribution does not follow the Japanese character
  distribution. Splitting proportionally to each cue's length would line them up better.

<a id="a6--low"></a>
#### A6 — Low: some cues can end up with no translation

`splitEvenly` pads with `nil` when `splitCaption` returns fewer pieces than requested, so a cue
may carry no translation while its neighbours do. Better to distribute the translation over the
cues that actually exist.

### Bugs

<a id="b1--medium"></a>
#### B1 — Medium: translation failures are invisible

```swift
let translated = try? await session.translate(text).targetText
return translated?.trimmingCharacters(in: .whitespacesAndNewlines)
```

Every failure is swallowed. If the language pair is removed mid-session, or a request fails, the
user simply gets no translations and no message — indistinguishable from "the feature is
broken". Log the first failure to stderr (once), or surface it in the caption stream.

<a id="b2--medium"></a>
#### B2 — Medium: an invalid target language produces a confusing message

`Locale.Language(identifier:)` never fails — `"english"` is accepted and produces
`languageCode == "english"`. The user then gets *"Translation from Japanese to english isn't
supported."* instead of a list of what they could use. `LanguageAvailability().supportedLanguages`
is available and would make the error actionable:

```
ja -> en: installed
ja -> zh-Hans: installed
ja -> zh-Hant: supported      ← not installed
```

<a id="b3--low"></a>
#### B3 — Low: the error message language follows the system locale

`CaptionTranslatorError.name(_:)` uses `Locale.current.localizedString(forIdentifier:)`, so a
Japanese-locale user gets a Japanese error message from an otherwise English CLI. Pick one:
localise the whole CLI, or use the raw identifier.

<a id="b4--low"></a>
#### B4 — Low: the translation source language is inferred from `--locale`

`CaptionTranslator.make(from: locale, …)` takes the source from the recognition locale. On an
English-locale system, `yap listen --engine whisper --translate en` translates English→English
— which also means Whisper was told to transcribe as English (`options.language` comes from the
same place), so the captions were English to begin with. Consistent, but it means there is no way
to say "the audio is Japanese, translate from Japanese" independently of the recognition locale.

<a id="b5--low"></a>
#### B5 — Low: `CaptionOutput.commit` shadows `end` in its loop

```swift
let end = max(committedTime, time)
…
for (index, (text, start, end)) in lines.enumerated() {
    await write(text, start: start, end: end, endsLine: …)
}
pending = []
committedTime = end
```

The loop variable shadows the outer `end`. It happens to be correct — `committedTime = end` after
the loop refers to the outer binding — but it is exactly the kind of shadowing that breaks
silently the next time someone edits it. Rename one of them.

---

## Part A — Japanese caption quality

<a id="j1--critical"></a>
### J1 — Critical: the "Whisper is looping" filter deletes ordinary Japanese lines

`WhisperFilter.hasRepeatedPhrase` (`Sources/yap/WhisperListen.swift:616`) flags any phrase of
2–20 characters that repeats 3–4 times back to back. That rule was written for English, where
repetition is a strong hallucination signal. Japanese is full of **legitimate reduplication and
repeated short interjections**, so the rule fires on normal dialogue.

Measured with the exact algorithm (`harness/filters/`):

```
[FAIL] ordinary Japanese line is NOT flagged as a loop  — なるほどなるほどなるほど -> repeated=true
[FAIL] ordinary Japanese line is NOT flagged as a loop  — はいはいはいはい         -> repeated=true
[FAIL] ordinary Japanese line is NOT flagged as a loop  — そうそうそうそう         -> repeated=true
[FAIL] ordinary Japanese line is NOT flagged as a loop  — ゆらゆらゆらゆら         -> repeated=true
[FAIL] ordinary Japanese line is NOT flagged as a loop  — うんうんうんうん         -> repeated=true
```

「なるほどなるほどなるほど」 and 「はいはいはいはい」 are completely normal anime dialogue.
When flagged, `emitFinal` (`WhisperListen.swift:106`) returns without emitting the segment, so
the line **never appears in the captions at all**.

Note the rule also fires on 2-character phrases repeated 4 times, which in Japanese is only two
syllables repeated twice — far too aggressive.

**Fix.** Require the repeat to be *long* before believing it, and only when the repetition is
not plausible speech. Concretely:

* Raise the minimum phrase length for short repeats (e.g. only treat 2–3 character phrases as a
  loop at 6+ repeats, not 4).
* Require a repeat to be at least 4 characters *and* at least ~1.0 s of audio to be flagged.
* Or, better: drop the character heuristic and use Whisper's own signals — `avgLogprob` and
  `compressionRatio` are already computed and are much less language-specific.

---

<a id="j2--critical"></a>
### J2 — Critical: the vocabulary-echo filter deletes legitimate vocabulary-heavy lines

`WhisperFilter.echoesVocabulary` (`WhisperListen.swift:632`) drops a segment when 3 or more
distinct vocabulary terms appear in it and they cover ≥50 % of the text. With a domain vocabulary
like `seiya.txt` (聖闘士, 黄金聖闘士, 聖域, 十二宮, …) that is exactly what a *correct*
transcription of a Saint Seiya scene looks like.

```
[FAIL] legitimate vocabulary-heavy line is NOT dropped  — 黄金聖闘士聖闘士聖域 -> echoes=true
[FAIL] legitimate vocabulary-heavy line is NOT dropped  — アテナハーデス冥闘士   -> echoes=true
[FAIL] legitimate vocabulary-heavy line is NOT dropped  — 十二宮にアテナハーデス -> echoes=true
```

Two further problems with the implementation:

1. **Over-counting.** `matched += count * term.count` adds the character count of every matching
   term, so a line containing both 黄金聖闘士 and 聖闘士 counts the 聖闘士 characters twice.
2. **Non-overlapping counting.** `text.components(separatedBy: term)` cannot find overlapping
   occurrences, so the count is also under-estimated for repeated terms. The two errors partly
   cancel, which makes the threshold unpredictable rather than merely conservative.

The filter's intent is to catch Whisper *reciting the prompt back*. A recitation is
characterised by the terms appearing in **vocabulary order** and usually **all of them at once**,
not by density alone.

**Fix.** Detect recitation instead of density:

* Check whether the text is (nearly) the prompt itself, normalised — e.g. it starts with the
  first vocabulary term and the terms appear in the vocabulary's order.
* Or require *every* vocabulary term to be present (not 3 of 9), or require the matched share to
  be much higher (≥80 %) **and** the text to be shorter than the vocabulary itself.
* Deduplicate overlapping terms before counting (drop 黄金聖闘士 if 聖闘士 is also present).

---

<a id="j3--high"></a>
### J3 — High: filtered lines are dropped in SRT/VTT/JSON mode but survive in TXT mode

This is the interaction that turns J1/J2 from "wrong text" into "missing text".

* In **TXT mode on a terminal**, `Captions.commit` (`WhisperListen.swift:250`) asks the Apple
  preview for a fallback when Whisper produced nothing usable:
  ```swift
  if let fallback = preview?.settle(whisperText, from: committedTime, to: end) { … }
  ```
  The preview text is then printed, so a line that Whisper's filter rejected still reaches the
  screen — in Apple's (less accurate) wording.
* In **SRT / VTT / JSON mode, or whenever stdout is piped**, the preview is never started
  (`WhisperListen.swift:52`: `if self.preview, format == .txt, isatty(STDOUT_FILENO) != 0`).
  There is no fallback, so `emitFinal` simply returns and **the caption line is silently lost**.

Consequence: the same audio produces *more* captions in `yap listen` than in
`yap listen --srt > out.srt`, and the difference is exactly the set of lines the (over-eager,
see J1/J2) filters rejected. The user sees "missing subtitles" in the file they actually keep.

**Fix.** Never silently drop a segment. Options:

* Keep the segment and mark it low-confidence instead of removing it.
* At minimum, log dropped segments to stderr (`FileHandle.standardError`) with the reason, so the
  loss is visible and diagnosable. Add a `--verbose` / `--debug-filters` flag for this.
* Once J1/J2 are fixed the drops should mostly disappear, but the "drop without trace" behaviour
  is itself a bug.

---

<a id="j4--high"></a>
### J4 — High: preview/final alignment counts characters, and kanji vs kana breaks it

`ApplePreview.settle()` (`WhisperListen.swift:401`) decides where Whisper's sentence ends inside
Apple's preview text by **counting characters**:

```swift
var remaining = letters(whisperText) - letters(finalsText)
var index = volatileConsumed
while index < characters.count, remaining > 0 { … index += 1 }
```

The comment above it acknowledges the assumption: *"both transcribers write roughly the same
number of characters, ignoring punctuation"*. **For Japanese that assumption does not hold.**
Apple's on-device ja-JP model and Whisper choose different orthography for the same words —
kanji vs kana — and the two differ in length:

| Apple writes | Whisper writes | letter drift |
|---|---|---|
| 黄金聖闘士アテナが十二宮に立った (16) | おうごせんとしあてながじゅうにゅうにたった (21) | **+5** |
| おうごせんとしがじゅうにゅうにたった (18) | 黄金聖闘士が十二宮に立った (13) | **−5** |

Reproduced (`harness/settle/`):

```
  kanji (Apple) vs kana (Whisper)
    Apple letters=16  Whisper letters=21  drift=5
    consumed=18 of 18 chars   fallbackUsed=false
    -> tail "次の" SWALLOWED (never captioned)

  kana (Apple) vs kanji (Whisper)
    Apple letters=18  Whisper letters=13  drift=-5
    consumed=13 of 20 chars   fallbackUsed=false
    -> tail "次の" kept in the next line
```

* **Positive drift** → the cut overshoots into text that belongs to the *next* utterance. That
  text is consumed and never captioned: words silently disappear.
* **Negative drift** → the cut undershoots, so 5 characters of stale preview text survive and are
  re-printed at the start of the next line: duplicated / garbled captions.

Both directions are visible in the same session, because the two engines flip between kanji and
kana depending on the sentence.

**Fix.** See [S5](#s5--medium) — use the time-range estimate that `settle()` already computes
(it is computed and then *discarded*, see below) and only fall back to character counting when
the time estimate is unavailable.

---

<a id="j5--high"></a>
### J5 — High: short Japanese replies are dropped entirely

`Captions.commit` falls back to the preview text only when the preview heard at least 4
non-punctuation characters (`WhisperListen.swift:426`):

```swift
if previewLetters >= 4, letters(whisperText) * 2 < previewLetters { … }
```

In Japanese, 2–3 characters is a complete, meaningful utterance — 「はい」「そう」「ねえ」「だぞ」.
All of them fall below the threshold, so nothing is printed and the line is lost:

```
  reply "はい" (letters=2): fallback=false -> NOTHING PRINTED (line lost)
  reply "そう" (letters=2): fallback=false -> NOTHING PRINTED (line lost)
  reply "ねえ" (letters=2): fallback=false -> NOTHING PRINTED (line lost)
  reply "だぞ" (letters=2): fallback=false -> NOTHING PRINTED (line lost)
```

The threshold was clearly chosen for English ("yes"/"no" are 3 letters, "okay" is 4). For
Japanese it should be **1** character, or the check should be "any preview text at all".

**Fix.** Change the guard to `previewLetters >= 1`, or make the threshold locale-dependent
(e.g. 4 for Latin scripts, 1 for CJK).

---

<a id="j6--medium"></a>
### J6 — Medium: the hallucination list matches real Japanese speech

`WhisperFilter.knownHallucinations` (`WhisperListen.swift:582`) contains bare substrings:

```swift
"最後までご視", "チャンネル登録", "字幕",
```

These are not anchored, so they match ordinary speech:

```
[FAIL] legit Japanese line containing a keyword is NOT a hallucination  — 字幕を消してください   -> hallucination=true
[FAIL] legit Japanese line containing a keyword is NOT a hallucination  — 最後までご視聴ください -> hallucination=true
[FAIL] legit Japanese line containing a keyword is NOT a hallucination  — チャンネル登録お願いします -> hallucination=true
```

For a YouTube-style video whose speaker says 「字幕を消してください」 the caption line is deleted.
The list was clearly derived from a *specific* video's outro, but it is applied to all audio.

Note also that `isLikelyHallucination` is applied to **tentative** segments as well
(`WhisperListen.swift:99`), even though `isUnreliable` is deliberately restricted to final text
("tentative guesses on partial speech are often low-confidence, and hiding them would delay the
captions", `WhisperListen.swift:605-606`). The two filters disagree about that policy.

**Fix.**

* Anchor the patterns to the *whole* segment (e.g. `^最後までご視聴谢谢.*$`) and require them to
  cover most of the segment, not just appear in it.
* Move the YouTube-outro patterns into an opt-in list (`--filter-outro` / a file) rather than
  hard-coding them for every user.
* Apply `isLikelyHallucination` to final segments only, matching `isUnreliable`'s policy.

---

<a id="j7--medium"></a>
### J7 — Medium: the near-duplicate filter eats different lines that look alike

`WhisperFilter.isNearDuplicate` (`WhisperListen.swift:648`) compares bigram sets and the longest
common substring. Two *different* Saint Seiya lines that share most of their characters are
treated as a duplicate, and `emitFinal` drops the second one:

```
[FAIL] different Japanese sentences are NOT near-duplicates  — 十二宮の聖闘士たち vs 十二宮の黄金聖闘士たち -> dup=true
```

That is a perfectly plausible pair of consecutive lines in the anime. The second one disappears.

Related: `recentFinals` keeps only the last 3 finals (`WhisperListen.swift:108`), so a line that
repeats after four other lines slips through, while one that repeats immediately is dropped —
the filter's coverage is arbitrary.

**Fix.**

* Compare against a *token* level for languages without spaces (use `NLTokenizer` with
  `.japanese`, or compare kana-normalised forms) instead of raw character bigrams.
* Raise the LCS threshold (0.7 → 0.85) and require the two lines to be near-identical in
  *length* as well.
* Keep more history (`suffix(8)`) so repeated lines are caught consistently.

---

<a id="j8--medium"></a>
### J8 — Medium: the Apple preview never receives the vocabulary

The vocabulary is applied in two places:

* Apple engine — `Listen.swift:95-98` sets `AnalysisContext.contextualStrings[.general]` ✓
* Whisper engine — `WhisperListen.swift:28-36` builds a Whisper prefill prompt ✓

But the **Apple preview inside the Whisper engine gets neither**:

```swift
preview = try await ApplePreview.start(locale: locale, sourceFormat: targetFormat) { … }
```

`ApplePreview.start` never calls `analyzer.setContext(...)`. Consequences:

1. The words the user sees flash by are the *un-vocabularised* ones — the exact character names
   the vocabulary exists to fix (「アテナ」→「アテネ」, 「ハーデス」→「ハーデズ」, …).
2. Worse, the fallback path in `Captions.commit` prints the **Apple** text when Whisper's output
   is rejected. So a line that Whisper got right can be replaced by Apple's mishearing of it —
   the vocabulary is effectively undone for exactly the lines where it was needed most.

**Fix.** Pass the vocabulary into `ApplePreview.start` and set the same `AnalysisContext` there.
This is a small, high-value change: it makes the preview agree with the final text, which also
reduces the visual churn that J4's mis-alignment produces.

---

<a id="j9--medium"></a>
### J9 — Medium: `displayWidth` under-measures emoji, corrupting the live redraw

`displayWidth` (`Listen.swift:349`) uses a hard-coded range table. The emoji ranges stop at
U+1F64F, so everything above that is counted as 1 column although terminals render it as 2:

| Scalar | Rendered width | `displayWidth` |
|---|---|---|
| U+1F525 🔥 | 2 | 2 ✓ (`0x1F300...0x1F64F`) |
| U+1F680 🚀 | 2 | **1 ✗** |
| U+1F6B2 🚲 | 2 | **1 ✗** |
| U+1FA70 🩰 | 2 | **1 ✗** |
| U+1F1EF 🇯 (regional indicator) | 2 | **1 ✗** |

`LiveLine.show` uses `terminalRows(for:)` to decide how many rows to erase before redrawing
(`Listen.swift:322`). If the count is too small, the previous tentative text is not fully erased
and the new text is drawn over it — the caption line becomes a visible smear. Too large and the
redraw eats the previous *final* line.

**Fix.** Use a proper East-Asian-width implementation, or at minimum extend the ranges to cover
U+1F650–U+1F6FF, U+1F900–U+1F9FF (already there), U+1FA70–U+1FAFF and the regional indicators
U+1F1E6–U+1F1FF, plus treat the whole U+1F000–U+1FAFF block as wide.

---

## Part B — Response time

<a id="l1--critical"></a>
### L1 — Critical: without the preview, the whole pending utterance is re-decoded every tick

`runWhisper` has two branches. With the preview active (TXT on a terminal) Whisper runs only on
completed utterances. **Without** it — i.e. for `--srt`, `--vtt`, `--json`, or whenever stdout is
piped — the code takes `WhisperListen.swift:185`:

```swift
let segments = try await transcribe(samples)   // samples = the ENTIRE pending utterance
```

`samples` is everything accumulated since the last flush, so every iteration re-runs the audio
encoder and the text decoder over the whole buffer. The loop is entered whenever 0.3 s of new
audio has arrived (`WhisperListen.swift:132`), so the decode happens roughly every 300 ms — but
each decode takes longer than that, so the loop becomes permanently decode-bound and the buffer
keeps growing towards the 25 s cap.

Simulating the exact schedule (`harness/decode/`, 60 s session):

```
  non-preview (--srt/--vtt/--json, or piped output)
    decodes                 = 53
    audio-seconds decoded   = 520.2  (session is 60 s)
    amplification           = 8.7x
    largest buffer decoded  = 19.2 s

  preview (txt + tty)
    decodes                 = 5
    audio-seconds decoded   = 50.5  (session is 60 s)
    amplification           = 0.8x
```

**8.7× the audio is pushed through the model**, and the amplification grows with the buffer
length. With `large-v3` the audio encoder alone is ~0.4 s (per the source's own comment at
`WhisperListen.swift:731`) and the text decoder scales with the token count. For Japanese that
token count is much higher: measured with the same Whisper tokenizer WhisperKit uses
(`harness/tokens/`), the same content costs **1.20 tokens per character in Japanese versus 0.52
in English — 2.3× more tokens for the decoder to emit**. The practical effect: the caption lags
further and further behind the audio, the fan spins up, and the battery drains.

**Fix.** See [S2](#s2--high). At minimum, never re-decode audio that has already been decoded:
keep the decoded text and only decode the *new* tail. WhisperKit does not expose an incremental
API, but the audio buffer can be trimmed so that only the newest window is decoded, and the
already-decoded prefix can be reused as the `promptTokens` context (which is exactly what
Whisper's "previous text" prompt is for).

---

<a id="l2--critical"></a>
### L2 — Critical: the preview path will not emit a final caption before 10 s of audio

`WhisperListen.swift:166-183`:

```swift
if preview != nil, !finished {
    lastDecodedEnd = end - Int(sampleRate * 0.2)
    guard duration >= 10 else { continue }        // ← WhisperListen.swift:171
    …
}
```

`duration` is the length of the pending utterance. Whisper is not run at all until it reaches
10 seconds. The only thing that can produce a caption earlier is a detected pause
(`firstPause`, ≥ 500 ms of silence) — see [L3](#l3--high) for why that rarely happens.

Simulated (`harness/latency/`), with a realistic speech/pause pattern:

```
  music  -60.0 dBFS -> first final caption at t = 10.0 s
  music  -30.0 dBFS -> first final caption at t = 10.0 s
  music  -25.0 dBFS -> first final caption at t = 10.0 s
```

**The first final caption always lands at t = 10.0 s**, regardless of how clear the pauses are.
For live captions that is far too slow: the user watches the anime for 10 seconds before the
first correctly-spelled line appears.

The Apple preview does show *tentative* words during that window, so the screen is not empty —
but tentative text is the un-vocabularised Apple text (J8) and it is replaced by a Whisper
sentence only after 10 s.

**Fix.** Lower the floor substantially (2–3 s) and rely on the pause detection to cut the
utterance early. The 10 s value is presumably there to give Whisper enough context, but Whisper
handles short utterances fine — it just has less context to work with. A better rule: decode as
soon as either (a) a pause is detected, or (b) the utterance is ≥ 2 s **and** has been stable
(no new speech) for ~0.5 s.

---

<a id="l3--high"></a>
### L3 — High: a fixed 0.01 RMS threshold means pauses are never found under a music bed

`AudioLevel.silenceThreshold` (`WhisperListen.swift:519`) is a hard-coded absolute RMS of 0.01,
i.e. **−40 dBFS**. Any continuous music is louder than that, so `firstPause` never reports a
pause and the 10 s / 25 s floors always win.

Measured (`harness/latency/`, synthetic speech + music bed):

```
  music  -60.0 dBFS (rms 0.0010): pause detected = YES   quietest frame rms = 0.0005
  music  -50.0 dBFS (rms 0.0032): pause detected = YES   quietest frame rms = 0.0016
  music  -40.0 dBFS (rms 0.0100): pause detected = YES   quietest frame rms = 0.0049
  music  -35.0 dBFS (rms 0.0178): pause detected = NO    quietest frame rms = 0.0088
  music  -30.0 dBFS (rms 0.0316): pause detected = NO    quietest frame rms = 0.0158
  music  -25.0 dBFS (rms 0.0562): pause detected = NO    quietest frame rms = 0.0281
  music  -20.0 dBFS (rms 0.1000): pause detected = NO    quietest frame rms = 0.0499
```

Anime background music mixed at −25 dBFS RMS is completely normal, so the practical threshold
is somewhere between −40 dBFS and −35 dBFS — i.e. the detector works only on near-silent
material. This single constant is the root cause of L2, L8 and the README's inaccurate
"final after about 0.5 s of quiet" claim.

**Fix.** See [S3](#s3--high) — estimate the noise floor from the buffer instead of assuming it.
**Update:** this has since been implemented as `NoiseFloor`; it fixes the pause detection but
introduces [N1](#n1--high) and [N2](#n2--medium), which need a second threshold for speech
detection.

---

<a id="l4--high"></a>
### L4 — High: the Whisper model is loaded before capture starts, so the first audio is lost

`runWhisper` (`WhisperListen.swift:16`) loads the model first:

```swift
nonisolated(unsafe) let whisper = try await WhisperModelStore.load(variant: whisperModel)
```

and only then creates the `SCStream` and calls `startCapture()` (`WhisperListen.swift:68-74`).

On the first run that is a **1.6 GB download plus a one-to-two-minute Core ML load**
(`WhisperModelStore.load` even prints "Loading Whisper model (the first run can take a few
minutes)…"). Every word spoken during that time is simply not captured — there is no buffer to
replay it from, because the stream does not exist yet.

Even on later runs the model load takes a second or two, and the Apple language-asset download
(`ApplePreview.start` → `installSpeechAssets`) happens *after* the Whisper load as well, so the
whole startup is serial: model → assets → preview → capture.

**Fix.** Reorder to: start capture (and buffer) → load the model → install assets → start the
preview → drain the buffer. The `PendingAudio` buffer already exists, so a modest refactor
("start capture first, then build the engine") is enough. The user then sees the captions for
everything that was said during the load.

Bonus: downloading the small Apple assets *before* the 1.6 GB model would let the preview start
(and show tentative words) much sooner.

---

<a id="l5--high"></a>
### L5 — **WITHDRAWN — this finding was wrong.** The default model *is* turbo.

> **Correction.** I claimed the default `openai_whisper-large-v3-v20240930` was the full
> large-v3 (32 decoder layers) and that the README was wrong. **It is the other way round.**
> The `config.json` shipped inside the model folder says:
>
> ```json
> { "_name_or_path": "/raid/yoach/tmp_whisper_turbo",
>   "encoder_layers": 32, "decoder_layers": 4, "d_model": 1280 }
> ```
>
> Upstream, `openai/whisper-large-v3` has 32 encoder + **32** decoder layers and
> `openai/whisper-large-v3-turbo` has 32 encoder + **4** decoder layers. The default variant
> therefore already has turbo's 4-layer decoder, and the README's engine table was right.
>
> The naming in `argmaxinc/whisperkit-coreml` is genuinely confusing, which is what misled me:
>
> | variant | encoder | decoder | what it actually is |
> |---|---|---|---|
> | `openai_whisper-large-v3-v20240930` (default) | 32 | **4** | turbo ✅ |
> | `openai_whisper-large-v3-v20240930_turbo` | 32 | **4** | turbo ✅ |
> | `openai_whisper-large-v3-v20240930_626MB` / `_632MB` | 32 | **4** | turbo, smaller build |
> | `openai_whisper-large-v3` | 32 | 32 | full large-v3 |
> | `openai_whisper-large-v3_turbo` | 32 | **32** | **full large-v3, despite the name** |
>
> So `openai_whisper-large-v3_turbo` is the *slow* model, and the default is the fast one. The
> README's clarification is correct and worth keeping; it would be even clearer with the table
> above. Nothing needs changing in the code — the remaining suggestion is only to expose the
> smaller `_626MB`/`_632MB` builds more prominently, since those are the same turbo
> architecture in less memory.

`Listen.swift:55`:

```swift
) var whisperModel: String = "openai_whisper-large-v3-v20240930"
```

**Fix.** None needed for the model choice. See [S1](#s1--high) for the (now smaller) suggestion.

---

<a id="l6--medium"></a>
### L6 — Medium: the GPU is used for the encoder but not for the decoder

`WhisperListen.swift:732`:

```swift
computeOptions: ModelComputeOptions(audioEncoderCompute: .cpuAndGPU),
```

`ModelComputeOptions`'s defaults (`WhisperKit/Core/Models.swift:92`) are
`melCompute: .cpuAndGPU`, `audioEncoderCompute: .cpuAndNeuralEngine`, `textDecoderCompute: .cpuAndNeuralEngine`.
So the encoder is moved to the GPU (deliberately, per the comment) but the **text decoder stays on
the Neural Engine**. For Japanese, where the decoder has to emit many tokens, that is the wrong
place to be conservative.

**Fix.** Try `textDecoderCompute: .cpuAndGPU` and measure; keep whichever is faster on the target
hardware. Make it a flag (`--decoder-on-gpu`) so users on different chips can choose.

---

<a id="l7--medium"></a>
### L7 — Medium: `prewarm: false` leaves the first decode of a session paying for specialisation

`WhisperListen.swift:735` sets `prewarm: false`. Per WhisperKit's own documentation
(`WhisperKit/Core/Configurations.swift:48-74`), Core ML specialises the `.mlmodelc` files for the
host chip the first time they are loaded after an OS update, and the specialisation cost is paid
on the first inference. `prewarm: true` loads each model once and unloads it, so the
specialisation happens at load time rather than on the user's first sentence.

The trade-off is documented as "load time will be multiplied by 2", which is the right trade for
a live-captioning tool: a slow start is much better than a slow first caption.

**Fix.** Set `prewarm: true`, or at least prewarm in the background after startup.

---

<a id="l8--medium"></a>
### L8 — Medium: the non-preview path does not settle anything until 25 s of audio

`WhisperListen.swift:188`:

```swift
let settled = finished || duration >= 25
let finalCount = settled ? segments.count : max(0, segments.count - 1)
```

`finished` is only true when the user presses Ctrl+C. So in `--srt`/`--vtt`/`--json` mode, a
segment only becomes final once 25 seconds of speech have accumulated — or when Whisper itself
happens to split the buffer into two segments. Given L3 (no pauses detected under music), the
25 s cap is the norm, not the exception.

Combined with L1, the result is: a 60-second session produces captions that arrive in one batch
at the very end, with ~25 s of lag.

**Fix.** Lower the cap to something like 8–10 s (Whisper's own 30 s window is the hard limit) and
combine it with the pause detection from S3.

---

## Part C — Suggestions

<a id="s1--high"></a>
### S1 — ~~Default to the turbo model~~ → **the default already is turbo**; surface the smaller build instead

The original suggestion was wrong ([L5](#l5--high)). What is still worth doing:

* The `_626MB` / `_632MB` variants are the *same* turbo architecture in a smaller build
  (626 MB vs 1.6 GB on disk). They are currently only mentioned as an "8 GB of memory"
  fallback in the README; they deserve a clearer mention, since they cost nothing in accuracy
  and a lot in memory.
* The naming in `argmaxinc/whisperkit-coreml` is a trap: `openai_whisper-large-v3_turbo` is
  the **full 32-layer** model, while the default `openai_whisper-large-v3-v20240930` is turbo.
  Printing the resolved variant name and its decoder depth at startup would save the next
  person an hour.
* Also worth adding a friendly error when the model name is invalid — the current code fails
  with a raw WhisperKit error.

<a id="s2--high"></a>
### S2 — Decode once per utterance; do not re-decode

Three changes, in increasing order of effort:

1. **Cheap.** In the non-preview branch, do not re-decode the whole buffer: decode only the audio
   since the last decode and pass the previous text as `promptTokens` so Whisper keeps the context.
   This alone removes the 8.7× amplification.
2. **Cheap.** Raise the decode interval from 0.3 s of new audio to something adaptive (e.g. decode
   at most every 1–2 s while speech is continuous).
3. **Better.** Make the preview path work for *all* output formats, not just TXT-on-a-terminal.
   The preview currently carries the text; it could just as well drive the SRT/VTT/JSON writers
   (Apple's `audioTimeRange` gives real timestamps). That would give low-latency captions in every
   format — the current asymmetry (TXT is fast, SRT is slow) is surprising.

<a id="s3--high"></a>
### S3 — Replace the fixed silence threshold with an adaptive noise floor

Instead of `silenceThreshold = 0.01` (absolute), estimate the floor from the buffer itself:

* Compute the RMS of every 30 ms frame, take a low percentile (e.g. the 10th) as the noise floor,
  and call a frame "silent" when it is within ~6 dB of that floor **and** below an absolute
  ceiling.
* Or use a spectral-flux / energy-ratio VAD instead of raw energy, which separates speech from
  steady music much better.
* Keep a small absolute floor (e.g. 0.002) so pure digital silence is still silence.

This single change makes pause detection work under a music bed, which in turn fixes L2, L8 and
the README claim in D2.

**Update:** implemented as `NoiseFloor`. It works for pause detection, but the resulting
threshold is too high for speech detection — see [N1](#n1--high) and
[N2](#n2--medium) for the two problems that need a *separate*, more sensitive threshold.

<a id="s4--medium"></a>
### S4 — Make the filters language-aware, and configurable

* Add a `--filter` / `--no-filter` switch so the user can turn the loop / duplicate / hallucination
  heuristics off when they are wrong (they are for Japanese).
* Scale the heuristics by script: the `previewLetters >= 4` guard in J5 should be 1 for CJK.
* Prefer Whisper's own signals (`avgLogprob`, `compressionRatio`, `noSpeechProb`) over the
  character heuristics. They are already available on `TranscriptionSegment` and are computed by
  the model, not guessed from the text.
* The fixed `avgLogprob < -1` / `< -1.2` thresholds (`WhisperListen.swift:609-610`) are English
  numbers. Japanese transcriptions systematically have lower `avgLogprob` (more tokens, more
  entropy). Worth measuring on a Japanese sample and making the threshold configurable — a
  `--min-confidence` flag would do.

<a id="s5--medium"></a>
### S5 — Use the time estimate that `settle()` already computes

`ApplePreview.settle` computes a time-based cut:

```swift
estimatedCut = rangeEnd <= end
    ? characters.count
    : max(volatileConsumed, Self.cutIndex(in: characters, at: (end - rangeStart) / (rangeEnd - rangeStart)))
```

…and then **throws it away** whenever it falls strictly inside the volatile text, in favour of
the character-counting path (`WhisperListen.swift:431-445`). The time-based estimate is the more
robust of the two — it does not care about kanji vs kana, which is exactly the problem J4
describes.

**Fix.** Prefer `estimatedCut`. Use character counting only as a fallback when the volatile
result has no `audioTimeRange` at all. And when both are available, cross-check them and prefer
the one that lands on a punctuation boundary (pauses in Japanese land on 。、!?).

<a id="s6--medium"></a>
### S6 — Apply `--max-length` to the Whisper engine

`--max-length` is honoured by `transcribe`, `listen` (Apple), `dictate` and `listen-and-dictate`,
but the Whisper branch never reads it — `grep -rn maxLength Sources/` shows no hit in
`WhisperListen.swift`. With `--srt`, a whole 25-second Japanese sentence becomes a single cue,
which most players render unreadably.

**Fix.** Split the emitted Whisper segment into cues of at most `maxLength` characters, using
`NLTokenizer` (which handles Japanese correctly — verified) and the segment timestamps to
sub-divide the time range.

<a id="s7--low"></a>
### S7 — Add a test target

There are no tests in the repository (only a `Release.yml` workflow that builds and publishes).
Every filter in `WhisperFilter`, every width calculation in `displayWidth`, and the whole
`AudioLevel` VAD are pure functions that are trivially testable — and are exactly where the
Japanese bugs live. A `Tests/yapTests` target with the fixtures in `harness/` would prevent
regressions and make the fixes above safe.

Also worth adding: a CI job that runs `swift build` on every push (the current workflow only
runs on tags).

---

## Part D — Documentation & repository hygiene

<a id="d1--medium"></a>
### D1 — ~~README says turbo, the code says large-v3~~ → **resolved; the README was right**

My original claim here was wrong, as in [L5](#l5--high): the default model already has turbo's
4-layer decoder, so the engine table was correct.

The README now explains the naming (`WhisperKit calls it openai_whisper-large-v3-v20240930; its
_turbo variants are a different, Argmax-specific optimization`). The table in
[L5](#l5--high) makes the whole family unambiguous and would be worth adding to the README.

<a id="d2--low"></a>
### D2 — "final after about 0.5 s of quiet" does not hold → **resolved**

The README now says *"a line becomes final after a pause of about 0.4 s. Pauses are measured
against the background level of the last 20 seconds, so they're found under steady background
music too. Speech that runs on without any pause is split at its quietest moment after 10
seconds."* That matches the implementation — and it documents the 10 s floor that L2 is about.

<a id="d3--low"></a>
### D3 — The "ignored flags" row is incomplete → **resolved**

The engine table now has a `--max-length` row.

<a id="d4--low"></a>
### D4 — `yap-listen-live.patch` is a stale artifact → **resolved**

The file has been deleted from the repository root.

---

## Appendix A — Reproductions

The Swift Testing suite in `Tests/yapTests/` now covers the filters, the voice-activity detector
and the caption splitting. The harnesses below cover what a test target cannot reach —
`ApplePreview` has a private initialiser and needs a live `SpeechAnalyzer` — plus the decode
schedule and the tokenizer measurement. Each is a standalone Swift program that copies the
relevant algorithm verbatim out of `Sources/yap/`, so it can be run without the app, without
Microphone / Screen Recording permissions and without the Whisper model.

| Directory | Question it answers | Result |
|---|---|---|
| `harness/settle/` | How far does the preview/final alignment drift, and what does the punctuation snap recover? | drift of ±5 characters; the snap recovers the tail but still swallows 2 characters |
| `harness/decode/` | How much audio does Whisper decode in a session? | 8.7× with `--no-preview` on a terminal, 0.8× everywhere else |
| `harness/tokens/` | How many decoder tokens does Japanese need vs English? | 1.20 vs 0.54 tokens per character (2.3×) |
| `harness/nl/`, `harness/nl2/` | Does `NLTokenizer` handle Japanese? | **Yes** — sentence and word tokenisation are correct in every language mode; not a bug |
| `Tests/yapTests/` | The filters, the VAD (real Japanese speech under a music bed) and the caption splitting | 21 tests, all passing |

Measurements quoted in round 2 were taken with ad-hoc probes against the real modules
(`@testable import yap`) and the real Apple Translation session; they are quoted inline in the
findings rather than kept as harnesses, because they need the Translation framework's installed
language pair and a live `SpeechAnalyzer` to reproduce.

Run them all with:

```bash
for d in settle decode nl nl2; do
  (cd harness/"$d" && swiftc -O main.swift -o "/tmp/yap-$d" && "/tmp/yap-$d")
done
python3 harness/tokens/tokens.py     # needs the cached Whisper tokenizer
swift test -Xswiftc -plugin-path -Xswiftc \
  /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
```

### Things that were checked and are *not* bugs

Recorded here so they are not re-investigated:

* **The default Whisper model is turbo.** See the correction in [L5](#l5--high). The
  `config.json` inside the downloaded model has `"decoder_layers": 4` and
  `"_name_or_path": "/raid/yoach/tmp_whisper_turbo"`.
* **`NLTokenizer` and Japanese.** `NLTokenizer(unit: .sentence)` splits Japanese correctly on
  。！？ regardless of the tokenizer language, and `NLTokenizer(unit: .word)` produces a proper
  morphological segmentation. `setLanguage(.japanese)` and the default give identical results.
  The `--max-length` splitting in `AttributedString+Extensions.swift` is therefore sound.
* **The vocabulary prompt is not echoed into the output.** WhisperKit uses `promptTokens` as a
  decoder *prefill* (`WhisperKit/Core/TextDecoder.swift:198-207`), so the prompt conditions the
  KV cache and does not appear in the sampled text. No need to strip the vocabulary from the
  first caption.
* **The audio hot loops are not the bottleneck.** `AudioLevel.firstSpeech` / `firstPause` cost
  **0.3 ms per 100 ms tick** on a 25 s buffer (measured), and `PendingAudio.snapshot()` copies
  ~15 MB/s. Both are negligible next to a Whisper decode. Do not spend effort on `vDSP`
  optimisation or ring buffers — fix the decode *schedule* instead.
* **The Apple `AnalysisContext` API usage is correct.** `ContextualStringsTag` has exactly one
  case, `.general`, which is what `Listen.swift:97` and `ApplePreview.start` use.
* **The `LiveLine` redraw logic is sound** for wrapped text: the row count, the up-move and the
  `\r ESC[J` clear sequence all compose correctly (apart from the emoji width gap in J9).
* **`hasRepeatedPhrase` is cheap enough.** 1.6 ms for a 240-character Japanese line, once per
  final segment.
* **The Translation framework usage is correct.** `status(from:to:)` gates on the installed
  languages (`ja → en: installed`, `ja → zh-Hans: installed`, `ja → zh-Hant: supported`), the
  `TranslationSession` is created once and reused, and `Response.targetText` is a non-optional
  `String`.
* **The `LiveLine` redraw composes correctly.** I replayed its escape sequences through a
  terminal emulator: the final line, the cyan translation note below it, and the next line all
  land where they should, including the `rows > 1` wrap case.
* **The Whisper model path is right.** `WhisperKit.download` caches at
  `downloadBase/models/<repo>/<variant>`, which is exactly what `WhisperModelStore.localFolder`
  computes, so the "already downloaded" check works.
* **The Silero VAD is not a performance problem.** 10 s of audio analysed in 26 ms — 0.3 % of
  one core.
