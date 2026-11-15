#!/usr/bin/env python3
"""ReaderFlow's local two-host Kokoro renderer.

The caller supplies a dialogue where lines begin with HOST_A: or HOST_B:. The
model stays warm for the whole episode so turns do not each pay startup cost.
"""

import argparse
import re
import unicodedata
import warnings
from pathlib import Path

import numpy as np
import soundfile as sf
from kokoro import KPipeline

warnings.filterwarnings("ignore", category=UserWarning, module="torch")
warnings.filterwarnings("ignore", category=FutureWarning, module="torch")


def turns(dialogue: str):
    # Be tolerant of drafts made by Qwen3 before ReaderFlow stripped its
    # optional reasoning trace. It is never spoken to the listener.
    dialogue = re.sub(r"(?is)<think>.*?</think>", "", dialogue)
    active_host = "A"
    for raw_line in dialogue.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        match = re.match(r"^HOST_([AB]):\s*(.*)$", line, re.IGNORECASE)
        if match:
            active_host, line = match.group(1).upper(), match.group(2).strip()
        if line:
            yield active_host, line


def speech_chunks(text: str, maximum_characters: int = 260):
    """Keep the English G2P input small and free of web/markdown punctuation."""
    text = unicodedata.normalize("NFKC", text)
    text = (text.replace("%", " percent")
                .replace("&", " and ")
                .replace("→", " leads to ")
                .replace("—", ", ")
                .replace("–", " to ")
                .replace("“", '"').replace("”", '"')
                .replace("‘", "'").replace("’", "'"))
    # The bundled Misaki G2P occasionally yields an invalid phoneme for an
    # apostrophe after a proper noun or in a contraction. Expand these before
    # synthesis instead of dropping an entire sentence.
    #
    # Irregular "n't" forms first: the generic rule below strips exactly
    # "n't" and keeps whatever precedes it, which is correct for regular
    # forms ("doesn't" -> "does not") but wrong for irregular ones
    # ("won't" -> "wo not", "can't" -> "ca not").
    text = re.sub(r"\bwon't\b", "will not", text, flags=re.IGNORECASE)
    text = re.sub(r"\bcan't\b", "cannot", text, flags=re.IGNORECASE)
    text = re.sub(r"\bshan't\b", "shall not", text, flags=re.IGNORECASE)
    text = re.sub(r"\bain't\b", "is not", text, flags=re.IGNORECASE)
    text = re.sub(r"\b([A-Za-z]+)n't\b", r"\1 not", text)
    text = re.sub(r"\b([A-Za-z]+)'m\b", r"\1 am", text)
    text = re.sub(r"\b([A-Za-z]+)'re\b", r"\1 are", text)
    text = re.sub(r"\b([A-Za-z]+)'ve\b", r"\1 have", text)
    text = re.sub(r"\b([A-Za-z]+)'ll\b", r"\1 will", text)
    text = re.sub(r"\b([A-Za-z]+)'d\b", r"\1 would", text)
    text = re.sub(r"\blet's\b", lambda match: "Let us" if match.group(0)[0].isupper() else "let us", text, flags=re.IGNORECASE)
    # "'s" after these words is the "is" contraction, not a possessive —
    # expanding it keeps the sentence's meaning instead of silently
    # dropping "is" ("it's raining" must not become "it raining").
    text = re.sub(r"\b(it|that|this|what|who|here|there|he|she|how|when|where|why)'s\b", r"\1 is", text, flags=re.IGNORECASE)
    # Any other "'s" is a possessive Misaki cannot reliably pronounce;
    # dropping the apostrophe keeps the noun itself intact rather than
    # losing the whole word to the letter-by-letter fallback below.
    text = re.sub(r"\b([A-Za-z]+)'s\b", r"\1", text)
    # A bare trailing possessive apostrophe with no following "s" (e.g.
    # "James' book").
    text = re.sub(r"\b([A-Za-z]+)'(?=\s|$)", r"\1", text)
    text = re.sub(r"[*_`#]", "", text)
    text = re.sub(r"\s+", " ", text).strip()
    sentences = re.split(r"(?<=[.!?])\s+", text)
    chunk = ""
    for sentence in sentences:
        if not sentence:
            continue
        if chunk and len(chunk) + len(sentence) + 1 > maximum_characters:
            yield chunk
            chunk = sentence
        else:
            chunk = f"{chunk} {sentence}".strip()
    if chunk:
        yield chunk


def synthesize(pipeline, text: str, voice: str, speed: float):
    """Render a chunk, bisecting only if Misaki rejects an uncommon token."""
    try:
        return [audio for _, _, audio in pipeline(text, voice=voice, speed=speed) if audio is not None]
    except TypeError as error:
        words = text.split()
        if len(words) > 1:
            midpoint = len(words) // 2
            return (synthesize(pipeline, " ".join(words[:midpoint]), voice, speed)
                    + synthesize(pipeline, " ".join(words[midpoint:]), voice, speed))
        # Proper names and acronyms can be absent from Misaki's dictionary.
        # Spell an offending token rather than discarding its sentence.
        spelled = " ".join(character for character in text if character.isalnum())
        if spelled and spelled != text:
            return synthesize(pipeline, spelled, voice, speed)
        raise RuntimeError(f"Kokoro could not pronounce: {text}") from error


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--host-a", default="af_bella")
    parser.add_argument("--host-b", default="am_michael")
    parser.add_argument("--speed", type=float, default=1.0)
    parser.add_argument("--device", choices=("cpu", "mps"), default="mps")
    args = parser.parse_args()

    dialogue = args.input.read_text(encoding="utf-8").strip()
    if not dialogue:
        raise SystemExit("Dialogue is empty.")

    pipeline = KPipeline(lang_code="a", device=args.device)
    segments = []
    for host, text in turns(dialogue):
        voice = args.host_a if host == "A" else args.host_b
        for chunk in speech_chunks(text):
            segments.extend(synthesize(pipeline, chunk, voice, args.speed))
    if not segments:
        raise SystemExit("Kokoro produced no audio.")

    args.output.parent.mkdir(parents=True, exist_ok=True)
    sf.write(args.output, np.concatenate(segments), 24000)
    print(f"Wrote {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
