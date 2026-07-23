#!/usr/bin/env python3
"""Download and deterministically convert WikiText-2 or TinyStories to JSONL.

The output is intentionally limited by default: the induction baseline is a
bounded research parser, not a web-scale batch parser. Python performs only
text segmentation/tokenization and never assigns CCG categories.
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import urllib.request
from collections.abc import Iterable, Iterator
from pathlib import Path

WIKITEXT_URLS = {
    "train": "https://cosmo.zip/pub/datasets/wikitext-2-raw/wiki.train.raw",
    "validation": "https://cosmo.zip/pub/datasets/wikitext-2-raw/wiki.valid.raw",
    "test": "https://cosmo.zip/pub/datasets/wikitext-2-raw/wiki.test.raw",
}
TINYSTORIES_URLS = {
    "train": (
        "https://huggingface.co/datasets/roneneldan/TinyStories/"
        "resolve/main/TinyStories-train.txt"
    ),
    "validation": (
        "https://huggingface.co/datasets/roneneldan/TinyStories/"
        "resolve/main/TinyStories-valid.txt"
    ),
}
TOKEN_RE = re.compile(r"""[A-Za-z]+(?:'[A-Za-z]+)?|\d+(?:[.,]\d+)*|[^\w\s]""")
SENTENCE_RE = re.compile(r"(?<=[.!?])(?:[\"']*)\s+")
WIKI_HEADING_RE = re.compile(r"^\s*=+.*=+\s*$")


def download(url: str, destination: Path, force: bool = False) -> Path:
    """Download atomically, reusing an existing nonempty file."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and destination.stat().st_size > 0 and not force:
        return destination
    temporary = destination.with_suffix(destination.suffix + ".part")
    request = urllib.request.Request(url, headers={"User-Agent": "ccg-induction/0.1"})
    with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as out:
        shutil.copyfileobj(response, out)
    temporary.replace(destination)
    return destination


def tokenize(text: str) -> list[str]:
    """A dependency-free, deterministic English surface tokenizer."""
    return TOKEN_RE.findall(text)


def split_sentences(text: str) -> Iterator[str]:
    normalized = re.sub(r"\s+", " ", text).strip()
    if normalized:
        yield from (part.strip() for part in SENTENCE_RE.split(normalized) if part.strip())


def wikitext_sentences(path: Path) -> Iterator[str]:
    with path.open("r", encoding="utf-8") as source:
        for line in source:
            text = line.strip()
            if not text or WIKI_HEADING_RE.match(text):
                continue
            yield from split_sentences(text.replace("@-@", "-").replace("@,@", ",").replace("@.@", "."))


def tinystories_sentences(path: Path) -> Iterator[str]:
    # Stories are separated by <|endoftext|>; streaming avoids loading the
    # multi-gigabyte training file into memory.
    buffer = ""
    with path.open("r", encoding="utf-8") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), ""):
            buffer += chunk
            stories = buffer.split("<|endoftext|>")
            buffer = stories.pop()
            for story in stories:
                yield from split_sentences(story)
    yield from split_sentences(buffer)


def write_jsonl(
    sentences: Iterable[str],
    output: Path,
    source_name: str,
    split: str,
    max_sentences: int,
    min_tokens: int,
    max_tokens: int,
) -> int:
    output.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with output.open("w", encoding="utf-8", newline="\n") as target:
        for text in sentences:
            tokens = tokenize(text)
            if not min_tokens <= len(tokens) <= max_tokens:
                continue
            count += 1
            record = {
                "sentence_id": f"{source_name}_{split}_{count:07d}",
                "tokens": tokens,
                "metadata": {"source": source_name, "split": split},
            }
            target.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
            if count >= max_sentences:
                break
    return count


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dataset", choices=("wikitext2", "tinystories"))
    parser.add_argument("--split", choices=("train", "validation", "test"), default="train")
    parser.add_argument("--raw-dir", type=Path, default=Path("data/raw"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--max-sentences", type=int, default=1000)
    parser.add_argument("--min-tokens", type=int, default=2)
    parser.add_argument("--max-tokens", type=int, default=20)
    parser.add_argument("--force-download", action="store_true")
    return parser


def main() -> None:
    args = build_parser().parse_args()
    if args.max_sentences < 1 or args.min_tokens < 1 or args.max_tokens < args.min_tokens:
        raise SystemExit("invalid sentence/token limits")
    if args.dataset == "wikitext2":
        raw = download(
            WIKITEXT_URLS[args.split],
            args.raw_dir / f"wikitext-2-raw-{args.split}.txt",
            args.force_download,
        )
        sentences = wikitext_sentences(raw)
    else:
        if args.split == "test":
            raise SystemExit("TinyStories provides train and validation splits, not test")
        raw = download(
            TINYSTORIES_URLS[args.split],
            args.raw_dir / f"TinyStories-{args.split}.txt",
            args.force_download,
        )
        sentences = tinystories_sentences(raw)
    count = write_jsonl(
        sentences, args.output, args.dataset, args.split,
        args.max_sentences, args.min_tokens, args.max_tokens,
    )
    print(f"wrote {count} sentences to {args.output}")


if __name__ == "__main__":
    main()
