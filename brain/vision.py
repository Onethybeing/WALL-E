"""Image analysis via Gemini's multimodal generateContent -- same pattern as
voice.py's STT (upload bytes as inline_data, ask a question, get text back).
No separate vision model/key needed; Gemini already handles images.
"""

import base64
import os

import requests

import settings

API_BASE = "https://generativelanguage.googleapis.com/v1beta/models"
VISION_MODEL = "gemini-3.5-flash-lite"


def _api_key() -> str:
    key = settings.load()["voice_api_key"] or os.environ.get("GEMINI_API_KEY")
    if not key:
        raise RuntimeError(
            "Set voice_api_key in settings.json, or export GEMINI_API_KEY, "
            "with a key from https://aistudio.google.com/apikey"
        )
    return key


def analyze(image_path: str, prompt: str) -> str:
    """Ask a question about an image on disk, get a text answer back."""
    with open(image_path, "rb") as f:
        image_b64 = base64.b64encode(f.read()).decode()

    resp = requests.post(
        f"{API_BASE}/{VISION_MODEL}:generateContent",
        params={"key": _api_key()},
        json={
            "contents": [
                {
                    "parts": [
                        {"text": prompt},
                        {"inline_data": {"mime_type": "image/jpeg", "data": image_b64}},
                    ]
                }
            ]
        },
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    return data["candidates"][0]["content"]["parts"][0]["text"].strip()
