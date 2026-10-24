#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pykakasi"]
# ///
"""Score `yap listen` captions against reference subtitles by character error rate (CER).

Each clip is a WAV cut from a video, with the start and end time of the cut in the video. The script
plays the clip through `yap listen --input` with each configuration, takes the reference cues that
fall inside the cut, and compares the two texts character by character.

    scripts/caption_cer.py --reference episode.srt \\
        --clip clip1.wav 06:23 08:41 --clip clip2.wav 10:45 12:13 \\
        --config whisper="--engine whisper" --config apple="" --repeat 2

Both texts are normalized first: speaker names and sound descriptions in （…） are removed, ＜…＞
keeps its words, cues marked （外国語） are skipped, consecutive duplicate cues are counted once,
and only letters and digits are compared. Broadcast captions shorten speech, so even perfect
recognition doesn't reach 0%: compare configurations with each other rather than with zero.

Two rates are reported. CER compares the text as written, so a correct word spelled in kana on one
side and kanji on the other (しかた / 仕方) counts as an error. Reading CER compares the texts read as
hiragana (by pykakasi), so such spellings match, but so do homophones heard wrong (経緯 / 敬意).
The real rate lies between the two.

Run it with uv, which installs pykakasi on first use: `scripts/caption_cer.py …` or `uv run scripts/caption_cer.py …`.
"""

import argparse
import re
import shlex
import subprocess
import sys
import time
import unicodedata
from pathlib import Path

import pykakasi

ROOT = Path(__file__).resolve().parent.parent


def parse_time(value):
    """Seconds from 'SS', 'MM:SS' or 'HH:MM:SS', with optional fractions ('06:23.5' or '00:06:23,500')."""
    seconds = 0.0
    for part in value.replace(",", ".").split(":"):
        seconds = seconds * 60 + float(part)
    return seconds


def read_srt(path):
    """Cues as (start, end, text) in seconds."""
    content = Path(path).read_text(encoding="utf-8-sig")
    cues = []
    for block in re.split(r"\n\s*\n", content.replace("\r\n", "\n").strip()):
        lines = block.split("\n")
        timing = next((i for i, line in enumerate(lines) if "-->" in line), None)
        if timing is None:
            continue
        start, end = (parse_time(t.strip().split(" ")[0]) for t in lines[timing].split("-->"))
        cues.append((start, end, "\n".join(lines[timing + 1:])))
    return cues


def normalize(text):
    text = unicodedata.normalize("NFKC", text)
    text = re.sub(r"\([^)]*\)", "", text)
    return "".join(c for c in text.lower() if unicodedata.category(c)[0] in "LN")


_kakasi = pykakasi.kakasi()


def reading(text):
    """`text` in hiragana: kanji by their reading, katakana converted, other characters unchanged."""
    return "".join(item["hira"] for item in _kakasi.convert(text))


def reference_text(cues, start, end):
    """Normalized reference for cues whose midpoint lies in [start, end]."""
    pieces = []
    previous = None
    for cue_start, cue_end, text in cues:
        if not start <= (cue_start + cue_end) / 2 <= end:
            continue
        if "外国語" in text or text == previous:
            previous = text
            continue
        previous = text
        pieces.append(normalize(text))
    return "".join(pieces)


def hypothesis_text(path):
    return "".join(normalize(text) for _, _, text in read_srt(path))


def align(reference, hypothesis):
    """Edit operations turning reference into hypothesis: a list of (kind, ref_char, hyp_char)."""
    n, m = len(reference), len(hypothesis)
    previous_row = list(range(m + 1))
    rows = [previous_row]
    for i in range(1, n + 1):
        row = [i] + [0] * m
        r = reference[i - 1]
        for j in range(1, m + 1):
            row[j] = min(
                previous_row[j - 1] + (r != hypothesis[j - 1]),
                previous_row[j] + 1,
                row[j - 1] + 1,
            )
        rows.append(row)
        previous_row = row
    operations = []
    i, j = n, m
    while i > 0 or j > 0:
        if i > 0 and j > 0 and rows[i][j] == rows[i - 1][j - 1] + (reference[i - 1] != hypothesis[j - 1]):
            kind = "=" if reference[i - 1] == hypothesis[j - 1] else "S"
            operations.append((kind, reference[i - 1], hypothesis[j - 1]))
            i, j = i - 1, j - 1
        elif i > 0 and rows[i][j] == rows[i - 1][j] + 1:
            operations.append(("D", reference[i - 1], ""))
            i -= 1
        else:
            operations.append(("I", "", hypothesis[j - 1]))
            j -= 1
    return operations[::-1]


def differences(operations, context=4):
    """Each run of errors as 'context [reference → hypothesis] context', one per line."""
    lines = []
    index = 0
    while index < len(operations):
        if operations[index][0] == "=":
            index += 1
            continue
        end = index
        # Merge errors separated by fewer than two matching characters
        while end < len(operations):
            if operations[end][0] != "=":
                end += 1
            elif end + 1 < len(operations) and operations[end + 1][0] != "=":
                end += 1
            else:
                break
        before = "".join(op[1] for op in operations[max(0, index - context):index])
        after = "".join(op[1] for op in operations[end:end + context])
        wrong = "".join(op[1] for op in operations[index:end]) or "∅"
        heard = "".join(op[2] for op in operations[index:end]) or "∅"
        lines.append(f"{before}[{wrong} → {heard}]{after}")
        index = end
    return lines


def score(reference, hypothesis, report_path):
    operations = align(reference, hypothesis)
    counts = {kind: sum(op[0] == kind for op in operations) for kind in "SDI"}
    report_path.write_text(
        f"reference:  {reference}\nhypothesis: {hypothesis}\n\n" + "\n".join(differences(operations)) + "\n",
        encoding="utf-8",
    )
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--reference", required=True, help="reference SRT for the whole video")
    parser.add_argument("--clip", nargs=3, action="append", required=True, metavar=("WAV", "START", "END"),
                        help="a clip and where it was cut from in the video (repeatable)")
    parser.add_argument("--config", action="append", metavar="NAME=ARGS",
                        help='a named set of yap listen options (repeatable), e.g. whisper="--engine whisper"; '
                             "default: apple and whisper")
    parser.add_argument("--locale", default="ja-JP", help="passed to every run (default: ja-JP)")
    parser.add_argument("--repeat", type=int, default=1, help="runs per clip and configuration (default: 1)")
    parser.add_argument("--speed", type=float, default=1, help="--input-speed for every run (default: 1)")
    parser.add_argument("--yap", default=str(ROOT / ".build/release/yap"), help="yap binary (default: release build)")
    parser.add_argument("--out", help="where captions and reports go (default: results/ next to the reference)")
    parser.add_argument("--no-run", action="store_true", help="rescore the captions saved by an earlier run")
    args = parser.parse_args()

    configs = []
    for spec in args.config or ["apple=", "whisper=--engine whisper"]:
        name, _, options = spec.partition("=")
        configs.append((name, shlex.split(options)))
    cues = read_srt(args.reference)
    out = Path(args.out) if args.out else Path(args.reference).parent / "results"
    out.mkdir(parents=True, exist_ok=True)

    rows = []
    for wav, start, end in args.clip:
        clip = Path(wav).stem
        reference = reference_text(cues, parse_time(start), parse_time(end))
        if not reference:
            sys.exit(f"No reference cues between {start} and {end}.")
        for name, options in configs:
            for run in range(1, args.repeat + 1):
                captions = out / f"{clip}.{name}.{run}.srt"
                seconds = None
                if not args.no_run:
                    command = [args.yap, "listen", "-l", args.locale, *options,
                               "--input", wav, "--input-speed", str(args.speed), "--srt"]
                    print(f"{clip} · {name} · run {run}: {shlex.join(command[1:])}", file=sys.stderr)
                    began = time.monotonic()
                    with captions.open("w", encoding="utf-8") as file:
                        result = subprocess.run(command, stdout=file, stderr=subprocess.PIPE, text=True)
                    seconds = time.monotonic() - began
                    if result.returncode != 0:
                        sys.exit(f"yap failed:\n{result.stderr}")
                elif not captions.exists():
                    sys.exit(f"No saved captions at {captions}; run without --no-run first.")
                hypothesis = hypothesis_text(captions)
                counts = score(reference, hypothesis, out / f"{clip}.{name}.{run}.diff.txt")
                reading_reference = reading(reference)
                reading_counts = score(reading_reference, reading(hypothesis), out / f"{clip}.{name}.{run}.reading.diff.txt")
                rows.append((clip, name, run, len(reference), counts, seconds,
                             len(reading_reference), sum(reading_counts.values())))

    print(f"\n{'clip':<10} {'config':<16} {'run':>3} {'ref':>5} {'sub':>5} {'del':>5} {'ins':>5} {'CER':>7} "
          f"{'reading':>8} {'time':>6}")
    for clip, name, run, length, counts, seconds, reading_length, reading_errors in rows:
        errors = sum(counts.values())
        elapsed = f"{seconds:.0f}s" if seconds is not None else ""
        print(f"{clip:<10} {name:<16} {run:>3} {length:>5} {counts['S']:>5} {counts['D']:>5} {counts['I']:>5} "
              f"{errors / length:>7.1%} {reading_errors / reading_length:>8.1%} {elapsed:>6}")

    print(f"\nOver all clips and runs:\n{'config':<16} {'CER':>7} {'reading':>8}")
    for name, _ in configs:
        mine = [row for row in rows if row[1] == name]
        errors = sum(sum(row[4].values()) for row in mine)
        reading_errors = sum(row[7] for row in mine)
        print(f"{name:<16} {errors / sum(row[3] for row in mine):>7.1%} "
              f"{reading_errors / sum(row[6] for row in mine):>8.1%}")
    print(f"\nCaptions and error lists: {out}")


if __name__ == "__main__":
    main()
