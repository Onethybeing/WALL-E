"""Speech in and out, via Gemini's free API.

STT: send recorded audio to a multimodal Gemini model, ask for a transcript.
TTS: ask a Gemini TTS model to speak text, get back base64 WAV audio.

Both are plain HTTP calls -- no SDK, no extra dependencies beyond `requests`.
"""

import base64
import os

import requests

import settings

API_BASE = "https://generativelanguage.googleapis.com/v1beta/models"
STT_MODEL = "gemini-3.5-flash-lite"  # more reliably available than 3.8-flash
TTS_MODEL = "gemini-3.8-flash-lite-tts"
VOICE_NAME = "Kore"


def _api_key() -> str:
    key = settings.load()["voice_api_key"] or os.environ.get("GEMINI_API_KEY")
    if not key:
        raise RuntimeError(
            "Set voice_api_key in settings.json, or export GEMINI_API_KEY, "
            "with a key from https://aistudio.google.com/apikey"
        )
    return key


def transcribe(audio_path: str) -> str:
    """Transcribe a wav/audio file on disk to text."""
    with open(audio_path, "rb") as f:
        audio_b64 = base64.b64encode(f.read()).decode()

    resp = requests.post(
        f"{API_BASE}/{STT_MODEL}:generateContent",
        params={"key": _api_key()},
        json={
            "contents": [
                {
                    "parts": [
                        {"text": "Transcribe this audio exactly. Reply with only the transcript."},
                        {"inline_data": {"mime_type": "audio/wav", "data": audio_b64}},
                    ]
                }
            ]
        },
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    return data["candidates"][0]["content"]["parts"][0]["text"].strip()


def speak(text: str, out_path: str) -> str:
    """Synthesize speech for `text`, writing a wav file to `out_path`."""
    resp = requests.post(
        f"{API_BASE}/{TTS_MODEL}:generateContent",
        params={"key": _api_key()},
        json={
            "contents": [{"parts": [{"text": text}]}],
            "generationConfig": {
                "responseModalities": ["AUDIO"],
                "speechConfig": {
                    "voiceConfig": {"prebuiltVoiceConfig": {"voiceName": VOICE_NAME}}
                },
            },
        },
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    audio_b64 = data["candidates"][0]["content"]["parts"][0]["inlineData"]["data"]
    with open(out_path, "wb") as f:
        f.write(base64.b64decode(audio_b64))
    return out_path
