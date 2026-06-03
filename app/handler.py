"""
AWS Lambda handler for a RAG question-answering endpoint.

Flow per request:
  1. Read the user question from the API Gateway event.
  2. Load the prebuilt embedding index (chunks + vectors) from S3.
  3. Embed the question with Gemini (text-embedding-004) over plain HTTPS.
  4. Rank chunks by cosine similarity, keep the top K.
  5. Ask Gemini (gemini-2.5-flash) to answer using only those chunks.
  6. Return the answer as JSON.

Design notes:
  - No third-party packages. boto3 ships in the Lambda runtime; everything
    else is the Python standard library. That keeps the deploy a single
    zip of this file, with no native-wheel packaging.
  - The model runs on Google's API, not on AWS, so the AWS side stays inside
    the free tier (Lambda + API Gateway + S3 only).
"""

import json
import math
import os
import urllib.request
import urllib.error

import boto3

GEMINI_API_KEY = os.environ["GEMINI_API_KEY"]
INDEX_BUCKET = os.environ["INDEX_BUCKET"]
INDEX_KEY = os.environ.get("INDEX_KEY", "index.json")
TOP_K = int(os.environ.get("TOP_K", "4"))

GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta/models"
EMBED_MODEL = "gemini-embedding-001"
CHAT_MODEL = "gemini-2.5-flash"

s3 = boto3.client("s3")

# The index is small, so we cache it for the lifetime of the warm container
# instead of fetching from S3 on every invocation.
_INDEX_CACHE = None


def _load_index():
    global _INDEX_CACHE
    if _INDEX_CACHE is None:
        obj = s3.get_object(Bucket=INDEX_BUCKET, Key=INDEX_KEY)
        _INDEX_CACHE = json.loads(obj["Body"].read())
    return _INDEX_CACHE


def _gemini_post(url, payload):
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"Gemini API error {e.code}: {e.read().decode()}") from e


def _embed(text):
    url = f"{GEMINI_BASE}/{EMBED_MODEL}:embedContent?key={GEMINI_API_KEY}"
    payload = {"model": f"models/{EMBED_MODEL}", "content": {"parts": [{"text": text}]}}
    return _gemini_post(url, payload)["embedding"]["values"]


def _generate(prompt):
    url = f"{GEMINI_BASE}/{CHAT_MODEL}:generateContent?key={GEMINI_API_KEY}"
    payload = {"contents": [{"parts": [{"text": prompt}]}]}
    out = _gemini_post(url, payload)
    return out["candidates"][0]["content"]["parts"][0]["text"]


def _cosine(a, b):
    dot = sum(x * y for x, y in zip(a, b))
    na = math.sqrt(sum(x * x for x in a))
    nb = math.sqrt(sum(y * y for y in b))
    if na == 0 or nb == 0:
        return 0.0
    return dot / (na * nb)


def _retrieve(question, index):
    q_vec = _embed(question)
    scored = [
        (_cosine(q_vec, item["embedding"]), item["text"], item.get("source", ""))
        for item in index
    ]
    scored.sort(key=lambda x: x[0], reverse=True)
    return scored[:TOP_K]


def _build_prompt(question, top_chunks):
    context = "\n\n".join(f"[{src}] {text}" for _, text, src in top_chunks)
    return (
        "Answer the question using only the context below. "
        "If the context does not contain the answer, say you don't know.\n\n"
        f"Context:\n{context}\n\nQuestion: {question}\nAnswer:"
    )


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event, context):
    # Accept the question from a JSON body (POST) or a query string (GET).
    question = None
    if event.get("body"):
        try:
            question = json.loads(event["body"]).get("question")
        except json.JSONDecodeError:
            return _response(400, {"error": "Body must be valid JSON."})
    if not question:
        params = event.get("queryStringParameters") or {}
        question = params.get("q")
    if not question:
        return _response(400, {"error": "Provide a 'question' (POST body) or 'q' (query string)."})

    try:
        index = _load_index()
        top_chunks = _retrieve(question, index)
        answer = _generate(_build_prompt(question, top_chunks))
    except Exception as e:  # surface the cause instead of a bare 500
        return _response(500, {"error": str(e)})

    return _response(
        200,
        {
            "question": question,
            "answer": answer,
            "sources": list(dict.fromkeys(src for _, _, src in top_chunks if src)),
        },
    )
