#!/usr/bin/env -S uv run --script
# /// script
# dependencies = ["pykakasi", "rapidfuzz"]
# ///
"""Score yap's transcripts of read-aloud text against the text that was read, by character error rate.

The input is a plain-text file of passages, each with the original text and one or more yap runs
(format described at the top of Tests/readings.txt):

    === kensatsu
    --- original
    員面調書を読み終えた円は小さく嘆息した。…
    --- yap: --engine whisper --vocabulary law.txt
    陰面聴書を読み終えた円は小さく短足した。…

    scripts/reading_cer.py Tests/readings.txt             # table of CER per passage and run
    scripts/reading_cer.py Tests/readings.txt --errors    # also each error, …[original → heard]…

Text is normalized as in caption_cer.py (only letters and digits, NFKC), so CER and reading CER
here mean the same as there. Unlike TV subtitles, the reference is exactly what was spoken, so
these rates are closer to absolute. Lines without any kana, such as --translate output, are left out.
"""

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from caption_cer import align, differences, normalize, reading  # noqa: E402

KANA = re.compile(r"[぀-ヿ]")


def read_passages(path):
    """{passage: {"original": [lines], "runs": [(settings, [lines])]}}, in file order."""
    passages = {}
    lines = None
    for number, raw in enumerate(Path(path).read_text(encoding="utf-8-sig").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("==="):
            name = line[3:].strip() or f"passage {len(passages) + 1}"
            passage = passages.setdefault(name, {"original": [], "runs": []})
            lines = None
        elif line.startswith("---"):
            if not passages:
                sys.exit(f"{path}:{number}: '---' before the first '=== <passage>'")
            section = line[3:].strip()
            if section == "original":
                lines = passage["original"]
            else:
                # Any other header is a run, labelled by whatever follows: the settings, or the
                # whole command line pasted from the terminal
                label = re.sub(r"^yap\s*:\s*", "", section)
                label = re.sub(r"^(\w+=\S*\s+)*(\S*/)?yap\s+listen\s+", "", label)
                lines = []
                passage["runs"].append((label or "(settings not given)", lines))
        elif lines is None:
            sys.exit(f"{path}:{number}: text outside a '--- original' or '--- yap' section")
        else:
            lines.append(line)
    return passages


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("file", help="passages file, e.g. Tests/readings.txt")
    parser.add_argument("--errors", action="store_true", help="list each error under its run")
    args = parser.parse_args()

    passages = read_passages(args.file)
    print(f"{'passage':<14} {'ref':>5} {'sub':>4} {'del':>4} {'ins':>4} {'CER':>7} {'reading':>8}  settings")
    totals = {}
    for name, passage in passages.items():
        reference = normalize("".join(passage["original"]))
        if not reference:
            print(f"{name:<14} no original text", file=sys.stderr)
            continue
        for settings, lines in passage["runs"]:
            hypothesis = normalize("".join(line for line in lines if KANA.search(line)))
            operations = align(reference, hypothesis)
            counts = {kind: sum(op[0] == kind for op in operations) for kind in "SDI"}
            errors = sum(counts.values())
            reading_ops = align(reading(reference), reading(hypothesis))
            reading_errors = sum(op[0] != "=" for op in reading_ops)
            reading_length = len(reading(reference))
            print(f"{name:<14} {len(reference):>5} {counts['S']:>4} {counts['D']:>4} {counts['I']:>4} "
                  f"{errors / len(reference):>7.1%} {reading_errors / reading_length:>8.1%}  {settings}")
            if args.errors:
                for difference in differences(operations):
                    print(f"{'':<16}{difference}")
            total = totals.setdefault(settings, [0, 0, 0, 0])
            total[0] += errors
            total[1] += len(reference)
            total[2] += reading_errors
            total[3] += reading_length
    if len(passages) > 1:
        print("\nOver all passages, by settings:")
        for settings, (errors, length, reading_errors, reading_length) in totals.items():
            print(f"{errors / length:>7.1%} {reading_errors / reading_length:>8.1%}  {settings}")


if __name__ == "__main__":
    main()
