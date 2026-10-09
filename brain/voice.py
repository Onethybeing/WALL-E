"""Speech in and out.

STT: send recorded audio to a multimodal Gemini model, ask for a transcript.
TTS: Gradium by default (45k credits/month free, ~180x more headroom than
Gemini's TTS free tier of 10 requests/day -- see GitHub issue #9), with
Gemini TTS kept as a fallback path (set tts_provider: "gemini" in
settings.json to use it instead).
"""

import asyncio
import base64
import json
import os
import struct

import requests
import websockets

import settings

API_BASE = "https://generativelanguage.googleapis.com/v1beta/models"
STT_MODEL = "gemini-3.5-flash-lite"  # more reliably available than 3.8-flash
TTS_MODEL = "gemini-3.8-flash-lite-tts"
VOICE_NAME = "Kore"

GRADIUM_WS_URL = "wss://api.gradium.ai/api/speech/tts"


def _check(resp: requests.Response) -> None:
    """requests' default raise_for_status() discards the response body,
    which for a 400 is almost always the one piece of info that explains
    *why* -- surface it instead of a bare '400 Client Error'.
    """
    if not resp.ok:
        raise RuntimeError(f"Gemini API error {resp.status_code}: {resp.text}")


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
                        {
                            "text": "Transcribe this audio exactly, in whatever language is "
                            "spoken. Reply with only the transcript, no translation."
                        },
                        {"inline_data": {"mime_type": "audio/ogg", "data": audio_b64}},
                    ]
                }
            ]
        },
        timeout=30,
    )
    _check(resp)
    data = resp.json()
    return data["candidates"][0]["content"]["parts"][0]["text"].strip()


def speak(text: str, out_path: str) -> str:
    """Synthesize speech for `text`, writing a wav file to `out_path`."""
    provider = settings.load()["tts_provider"]
    if provider == "gradium":
        return _speak_gradium(text, out_path)
    return _speak_gemini(text, out_path)


def _speak_gemini(text: str, out_path: str) -> str:
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
    _check(resp)
    data = resp.json()
    audio_b64 = data["candidates"][0]["content"]["parts"][0]["inlineData"]["data"]
    with open(out_path, "wb") as f:
        f.write(base64.b64decode(audio_b64))
    return out_path


def _gradium_api_key() -> str:
    key = settings.load()["tts_api_key"] or os.environ.get("GRADIUM_API_KEY")
    if not key:
        raise RuntimeError(
            "Set tts_api_key in settings.json, or export GRADIUM_API_KEY, "
            "with a key from https://gradium.ai"
        )
    return key


def _fix_wav_header(data: bytes) -> bytes:
    """Gradium's streaming WAV output leaves the RIFF and data chunk sizes
    as the placeholder 0xFFFFFFFF (valid for a true streaming player that
    reads to EOF, since it doesn't know the final length upfront) -- but
    Android's MediaPlayer is stricter and refuses to even prepare() such a
    file ("Prepare failed.: status=0x1"), confirmed by testing a raw
    Gradium output through termux-media-player directly. We already have
    the complete file in memory by the time we write it, so just patch in
    the real sizes.
    """
    if len(data) < 44 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        return data  # not a RIFF/WAVE file we understand -- leave it alone
    data = bytearray(data)
    data[4:8] = struct.pack("<I", len(data) - 8)
    data_idx = data.find(b"data")
    if data_idx != -1:
        data[data_idx + 4:data_idx + 8] = struct.pack("<I", len(data) - (data_idx + 8))
    return bytes(data)


def _speak_gradium(text: str, out_path: str) -> str:
    """Synthesize speech via Gradium's WebSocket TTS API (see
    https://docs.gradium.ai/guides/text-to-speech). Each call opens its own
    connection and closes it once the audio is fully received -- simple,
    at the cost of a little connection-setup latency per utterance.
    """
    audio = asyncio.run(_gradium_ws_synthesize(text))
    audio = _fix_wav_header(audio)
    with open(out_path, "wb") as f:
        f.write(audio)
    return out_path


async def _gradium_ws_synthesize(text: str) -> bytes:
    voice_id = settings.load()["tts_voice_id"]
    setup = {
        "type": "setup",
        "voice_id": voice_id,
        "model_name": "default",
        "output_format": "wav",
    }
    audio_chunks = []

    async with websockets.connect(
        GRADIUM_WS_URL, additional_headers={"x-api-key": _gradium_api_key()}
    ) as ws:
        await ws.send(json.dumps(setup))
        ready = json.loads(await ws.recv())
        if ready.get("type") == "error":
            raise RuntimeError(f"Gradium TTS error: {ready.get('message')}")

        await ws.send(json.dumps({"type": "text", "text": text}))
        await ws.send(json.dumps({"type": "end_of_stream"}))

        while True:
            msg = json.loads(await ws.recv())
            if msg["type"] == "audio":
                audio_chunks.append(base64.b64decode(msg["audio"]))
            elif msg["type"] == "end_of_stream":
                break
            elif msg["type"] == "error":
                raise RuntimeError(f"Gradium TTS error: {msg.get('message')}")

    return b"".join(audio_chunks)
