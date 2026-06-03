"""
Build the embedding index and upload it to S3.

Run this locally (not in Lambda). It reads .txt files from sample_docs/,
splits them into overlapping chunks, embeds each chunk with Gemini, and
writes index.json. With --upload it also pushes the file to your S3 bucket.

Usage:
    python ingest/build_index.py
    python ingest/build_index.py --upload --bucket my-bucket --key index.json

Env:
    GEMINI_API_KEY must be set.
"""

import argparse
import glob
import json
import os
import urllib.request
import urllib.error

GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY")
EMBED_MODEL = "gemini-embedding-001"
GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/models"

CHUNK_SIZE = 800      # characters
CHUNK_OVERLAP = 150   # characters


def embed(text):
    url = f"{GEMINI_BASE}/{EMBED_MODEL}:embedContent?key={GEMINI_API_KEY}"
    payload = {"model": f"models/{EMBED_MODEL}", "content": {"parts": [{"text": text}]}}
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())["embedding"]["values"]
    except urllib.error.HTTPError as e:
        # surface the API's actual error instead of a bare HTTP code
        raise SystemExit(f"Gemini embed failed ({e.code}): {e.read().decode()}") from e


def chunk(text):
    chunks = []
    start = 0
    while start < len(text):
        end = start + CHUNK_SIZE
        chunks.append(text[start:end])
        start += CHUNK_SIZE - CHUNK_OVERLAP
    return chunks


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--docs", default="sample_docs")
    parser.add_argument("--out", default="index.json")
    parser.add_argument("--upload", action="store_true")
    parser.add_argument("--bucket")
    parser.add_argument("--key", default="index.json")
    args = parser.parse_args()

    if not GEMINI_API_KEY:
        raise SystemExit("Set GEMINI_API_KEY in your environment first.")

    index = []
    for path in sorted(glob.glob(os.path.join(args.docs, "*.txt"))):
        source = os.path.basename(path)
        with open(path, encoding="utf-8") as f:
            text = f.read()
        for piece in chunk(text):
            piece = piece.strip()
            if piece:
                index.append({"text": piece, "source": source, "embedding": embed(piece)})
        print(f"embedded {source}")

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(index, f)
    print(f"wrote {args.out} with {len(index)} chunks")

    if args.upload:
        if not args.bucket:
            raise SystemExit("--upload needs --bucket")
        import boto3

        boto3.client("s3").upload_file(args.out, args.bucket, args.key)
        print(f"uploaded to s3://{args.bucket}/{args.key}")


if __name__ == "__main__":
    main()
