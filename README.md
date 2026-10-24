# 🗣️ yap

A CLI for on-device speech transcription using [Speech.framework](https://developer.apple.com/documentation/speech) on macOS 26.

![Demo](https://github.com/user-attachments/assets/326de51d-5a58-4c96-9d6c-98b07e6d9e58)

### Usage

```
USAGE: yap transcribe [--locale <locale>] [--censor] <input-file> [--txt] [--srt] [--vtt] [--json] [--output-file <output-file>] [--max-length <max-length>] [--word-timestamps]

ARGUMENTS:
  <input-file>            Path to an audio or video file to transcribe.

OPTIONS:
  -l, --locale <locale>   (default: current)
  --censor                Replaces certain words and phrases with a redacted form.
  --txt/--srt/--vtt/--json
                          Output format for the transcription. (default: --txt)
  -o, --output-file <output-file>
                          Path to save the transcription output. If not provided,
                          output will be printed to stdout.
  -m, --max-length <max-length>
                          Maximum sentence length in characters. (default: 40)
  --word-timestamps       Include word-level timestamps in JSON output.
  -h, --help              Show help information.
```

### Installation

This is a fork of [finnvoor/yap](https://github.com/finnvoor/yap) that adds a Whisper engine, live captions and vocabulary files to `yap listen`. It isn't published to Homebrew or Mint, so build it from source. You need macOS 26 and Xcode 26 or its Command Line Tools.

```bash
git clone https://github.com/dgg32/yap.git
cd yap
swift build -c release
```

The binary is `.build/release/yap`. Run it from there, or copy it onto your `PATH`:

```bash
sudo cp .build/release/yap /usr/local/bin/yap
```

To update, run `git pull` and `swift build -c release` again, then repeat the copy if you installed it to `/usr/local/bin`.

> `brew install yap` and `mint install finnvoor/yap` install the original yap, without this fork's features. If you have one of them installed, uninstall it, or make sure `which yap` points to this build.

### Examples

#### Transcribe a YouTube video using yap and [yt-dlp](https://github.com/yt-dlp/yt-dlp)

```bash
yt-dlp "https://www.youtube.com/watch?v=ydejkIvyrJA" -x --exec yap
```

#### Summarize a video using yap and [llm](https://llm.datasette.io/en/stable)

```bash
yap video.mp4 | uvx llm -m mlx-community/Llama-3.2-1B-Instruct-4bit 'Summarize this transcript:'
```

#### Create SRT captions for a video

```bash
yap video.mp4 --srt -o captions.srt
```

#### Generate WebVTT subtitles

```bash
yap video.mp4 --vtt -o subtitles.vtt
```

#### Export JSON with word-level timestamps

```bash
yap video.mp4 --json --word-timestamps -o transcript.json
```

### Live System Audio

`yap listen` transcribes system audio in real time — anything playing on your computer.

```
USAGE: yap listen [--locale <locale>] [--censor] [--txt] [--srt] [--vtt] [--json] [--max-length <max-length>] [--word-timestamps] [--fast] [--no-fast] [--vocabulary <vocabulary>] [--engine <engine>] [--whisper-model <whisper-model>] [--preview] [--no-preview]

OPTIONS:
  -l, --locale <locale>   (default: current)
  --censor                Replaces certain words and phrases with a redacted form.
  --txt/--srt/--vtt/--json
                          Output format for the transcription. (default: --txt)
  -m, --max-length <max-length>
                          Maximum sentence length in characters for timed output
                          formats. (default: 40)
  --word-timestamps       Include word-level timestamps in JSON output.
  --fast/--no-fast        Favor responsiveness over accuracy. Use --no-fast for
                          more accurate but slower results. (default: --fast)
  --vocabulary <vocabulary>
                          Path to a text file of names and terms to expect, one
                          per line (lines starting with # are ignored).
  --engine <engine>       Speech recognition engine: apple (on-device Speech
                          framework) or whisper (WhisperKit, more accurate).
                          (values: apple, whisper; default: apple)
  --whisper-model <whisper-model>
                          WhisperKit model variant used with --engine whisper.
                          Downloaded on first use. (default:
                          openai_whisper-large-v3-v20240930)
  --preview/--no-preview  With --engine whisper, stream Apple's word-by-word
                          results while Whisper finishes each sentence.
                          (default: --preview)
  -h, --help              Show help information.
```

> Screen Recording permission is required. Grant it to your terminal app in System Settings > Privacy & Security > Screen Recording, then restart the terminal.

#### Live captions

In the default text output, captions appear while someone is still speaking. The in-progress text is shown dimmed and redrawn in place as the transcription improves, and it's replaced by normal text once it's final. When the output is piped or redirected, only final lines are written.

With `--engine whisper`, the dimmed text comes from Apple's engine, so words appear as soon as they're heard. When the speaker pauses, Whisper's corrected sentence replaces them, usually about 1.5–2 s after the speaker stops. If Whisper's output for a stretch of audio is missing most of what Apple heard (for example because Whisper looped or recited the vocabulary and was filtered out), Apple's text is kept as the final line, so nothing is lost. Use `--no-preview` to show only Whisper's output; its in-progress text then updates about once a second.

#### Engines

| | `--engine apple` (default) | `--engine whisper` |
|---|---|---|
| Model | Apple Speech framework, built into macOS | OpenAI Whisper large-v3-turbo via [WhisperKit](https://github.com/argmaxinc/WhisperKit) |
| Setup | Language assets download automatically | ~1.6 GB model download on first run, plus Apple's language assets for the preview |
| Captions | Word by word, very responsive | Apple's words as you listen, replaced by Whisper's sentence at each pause |
| Accuracy | Good | Better, especially for names and non-English speech |
| `--vocabulary` | Accepted, but has little visible effect | Steers spelling of the listed terms |
| `--fast`, `--censor`, `--word-timestamps` | Supported | Ignored |

#### Setting up Whisper

There is nothing to install separately. The first time you run with `--engine whisper`, yap downloads the model from Hugging Face with a progress bar:

```bash
yap listen --engine whisper -l ja-JP
```

- **Download:** about 1.6 GB, stored in `~/Library/Application Support/yap/whisper`. Later runs work offline.
- **First load:** after the download, yap prints "Loading Whisper model…". The first load can take a minute or two while macOS optimizes the model for your chip. It's faster after that, but macOS may redo this after a system update.
- **Hardware:** an Apple Silicon Mac. The default model uses about 2–3 GB of memory. On a Mac with 8 GB of memory, use the smaller model:

  ```bash
  yap listen --engine whisper --whisper-model openai_whisper-large-v3-v20240930_turbo_632MB
  ```

  Other models are listed at [argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml).
- **Removing it:** delete `~/Library/Application Support/yap/whisper`.

Set `-l` to the language being spoken; Whisper uses its language code (`ja-JP` → Japanese). With the Whisper engine, a line becomes final after about 0.5 s of quiet. Scenes with continuous background music have fewer quiet gaps, so lines there may take longer to become final.

#### Vocabulary files

A vocabulary file lists names and terms to expect, one per line. Blank lines and lines starting with `#` are ignored:

```
# Saint Seiya terms
アテナ
ハーデス
聖闘士
十二宮
```

With `--engine whisper`, the list is passed to the model as a prompt, which steers it toward these spellings. This fixes most misheard character names and invented terms. A longer list adds a little time to each update, so keep it to the terms that actually come out wrong. [`seiya.txt`](seiya.txt) is an example.

#### Examples

```bash
# Transcribe system audio live
yap listen

# Live Japanese captions with Whisper and a vocabulary file
yap listen -l ja-JP --engine whisper --vocabulary seiya.txt

# Apple engine, trading some speed for accuracy
yap listen -l ja-JP --no-fast

# Pipe live transcription to another tool (only final lines are sent)
yap listen | uvx llm 'Translate this to French:'

# Save system audio as VTT subtitles
yap listen --vtt > captions.vtt

# Save Whisper subtitles as SRT
yap listen -l ja-JP --engine whisper --srt > captions.srt
```

### Listen and Dictate

`yap listen-and-dictate` transcribes both system audio and microphone input simultaneously — perfect for meeting transcription.

```
USAGE: yap listen-and-dictate [--locale <locale>] [--censor] [--txt] [--srt] [--vtt] [--json] [--max-length <max-length>] [--mic-label <mic-label>] [--system-label <system-label>] [--word-timestamps]

OPTIONS:
  -l, --locale <locale>   (default: current)
  --censor                Replaces certain words and phrases with a redacted form.
  --txt/--srt/--vtt/--json
                          Output format for the transcription. (default: --txt)
  -m, --max-length <max-length>
                          Maximum sentence length in characters for timed output
                          formats. (default: 40)
  --mic-label <mic-label> Speaker label for microphone audio in timed output
                          formats. (default: Mic)
  --system-label <system-label>
                          Speaker label for system audio in timed output
                          formats. (default: System)
  --word-timestamps       Include word-level timestamps in JSON output.
  -h, --help              Show help information.
```

> Both Screen Recording and Microphone permissions are required. Grant them to your terminal app in System Settings > Privacy & Security.

#### Examples

```bash
# Transcribe a video call (both sides)
yap listen-and-dictate

# Save a meeting transcript
yap listen-and-dictate > meeting.txt

# Save a meeting transcript as VTT with speaker labels
yap listen-and-dictate --vtt > meeting.vtt

# Use custom speaker labels
yap listen-and-dictate --vtt --mic-label Alice --system-label Bob > meeting.vtt
```

### Dictation

`yap dictate` transcribes microphone input in real time.

```
USAGE: yap dictate [--locale <locale>] [--censor] [--txt] [--srt] [--vtt] [--json] [--max-length <max-length>] [--word-timestamps]

OPTIONS:
  -l, --locale <locale>   (default: current)
  --censor                Replaces certain words and phrases with a redacted form.
  --txt/--srt/--vtt/--json
                          Output format for the transcription. (default: --txt)
  -m, --max-length <max-length>
                          Maximum sentence length in characters for timed output
                          formats. (default: 40)
  --word-timestamps       Include word-level timestamps in JSON output.
  -h, --help              Show help information.
```

> Microphone permission is required. Grant it to your terminal app in System Settings > Privacy & Security > Microphone.

#### Examples

```bash
# Dictate from your microphone
yap dictate

# Dictate and save to a file
yap dictate > notes.txt
```

### MCP Server

yap includes an [MCP](https://modelcontextprotocol.io) server that exposes a `transcribe` tool, allowing any MCP-compatible agent to transcribe audio and video files.

#### Claude Code

```bash
claude mcp add yap -- yap mcp
```

#### Codex

```bash
codex mcp add yap -- yap mcp
```
