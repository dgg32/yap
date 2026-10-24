"""Count Whisper BPE tokens for Japanese vs English text.

Uses the locally cached Whisper tokenizer (models/openai/whisper-large-v3/tokenizer.json),
the same tokenizer WhisperKit uses, so the token counts reflect what the text decoder
actually has to generate.
"""
import json
import os
import re
import sys

PATH = os.environ.get(
    "WHISPER_TOKENIZER",
    os.path.expanduser(
        "~/Library/Application Support/yap/whisper/models/openai/whisper-large-v3/tokenizer.json"
    ),
)

if not os.path.exists(PATH):
    sys.exit(f"tokenizer.json not found at {PATH}\n"
             "Run `yap listen --engine whisper` once, or set WHISPER_TOKENIZER.")

with open(PATH, encoding="utf-8") as f:
    data = json.load(f)

VOCAB = data["model"]["vocab"]
MERGES = {tuple(m) if isinstance(m, list) else tuple(m.split(" ")) for m in data["model"]["merges"]}
MERGE_RANK = {m: i for i, m in enumerate(MERGES)}

# GPT-2 style byte-level pre-tokenizer pattern (the "use_regex" split used by Whisper).
PAT = re.compile(
    r"'s|'t|'re|'ve|'m|'ll|'d| ?[^\W\d_]+| ?\d+| ?[^\s\w]+|\s+(?!\S)|\s+",
    re.UNICODE,
)


def bytes_to_unicode():
    bs = list(range(ord("!"), ord("~") + 1)) + list(range(ord("\xa1"), ord("\xac") + 1)) + list(range(ord("\xae"), ord("\xff") + 1))
    cs = bs[:]
    n = 0
    for b in range(2 ** 8):
        if b not in bs:
            bs.append(b)
            cs.append(2 ** 8 + n)
            n += 1
    return dict(zip(bs, (chr(c) for c in cs)))


BYTE_ENCODER = bytes_to_unicode()


def bpe(token):
    word = tuple(token)
    if len(word) == 1:
        return token
    while True:
        pairs = {(word[i], word[i + 1]) for i in range(len(word) - 1)}
        bigram = min(pairs, key=lambda p: MERGE_RANK.get(p, float("inf")))
        if bigram not in MERGE_RANK:
            break
        first, second = bigram
        new_word = []
        i = 0
        while i < len(word):
            try:
                j = word.index(first, i)
            except ValueError:
                new_word.extend(word[i:])
                break
            new_word.extend(word[i:j])
            i = j
            if word[i] == first and i < len(word) - 1 and word[i + 1] == second:
                new_word.append(first + second)
                i += 2
            else:
                new_word.append(word[i])
                i += 1
        word = tuple(new_word)
        if len(word) == 1:
            break
    return " ".join(word)


def encode(text):
    ids = []
    for tok in PAT.findall(text):
        mapped = "".join(BYTE_ENCODER[b] for b in tok.encode("utf-8"))
        for piece in bpe(mapped).split(" "):
            if piece in VOCAB:
                ids.append(VOCAB[piece])
    return ids


SAMPLES = [
    ("English", "The holy warriors of Athena gather at the sanctuary to fight Hades once again."),
    ("English", "I cannot let my friends die like this, I must fight with everything I have."),
    ("Japanese", "アテナが神聖な聖闘士 ONLY 的一些"),
    ("Japanese", "黄金聖闘士のアテナが十二宮に立つ。ハーデスとの戦いが始まる！"),
    ("Japanese", "そうそう、そうだSPECTRUM、なるほどなるほど。はいはい。"),
]

print(f"{'lang':9} {'chars':>6} {'tokens':>7} {'tokens/char':>12}")
print("-" * 40)
for lang, text in SAMPLES:
    n = len(encode(text))
    print(f"{lang:9} {len(text):6} {n:7} {n / len(text):12.3f}")

print()
jp = "黄金聖闘士のアテナが十二宮に立つ。ハーデスとの戦いが始まる！"
en = "The golden saint Athena stands in the十二宮. The battle with Hades begins!"
print("same content, two scripts:")
print(f"  Japanese: {len(encode(jp)):4} tokens for {len(jp)} chars  -> {len(encode(jp))/len(jp):.3f} tokens/char")
print(f"  English : {len(encode(en)):4} tokens for {len(en)} chars  -> {len(encode(en))/len(en):.3f} tokens/char")
