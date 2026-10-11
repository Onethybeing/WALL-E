"""Speech in and out.

Both STT and TTS default to Gradium (45k free credits/month, shared across
STT+TTS -- see GitHub issue #9, where Gemini's TTS free tier turned out to
be a hard 10-requests/day wall). Gemini chat reasoning and vision are
unaffected by any of this -- see gemini_client.py / vision.py -- and Gemini
STT/TTS remain available as fallbacks (set stt_provider/tts_provider:
"gemini" in settings.json) since that quota is per-model, not account-wide.
"""

import asyncio
import base64
import json
import os
import struct
import subprocess
import tempfile
import time
from pathlib import Path

import requests
import websockets

import settings

API_BASE = "https://generativelanguage.googleapis.com/v1beta/models"
STT_MODEL = "gemini-3.5-flash-lite"  # more reliably available than 3.8-flash
TTS_MODEL = "gemini-3.8-flash-lite-tts"
VOICE_NAME = "Kore"

GRADIUM_TTS_WS_URL = "wss://api.gradium.ai/api/speech/tts"
GRADIUM_STT_REST_URL = "https://api.gradium.ai/api/post/speech/asr"
STT_TOTAL_DEADLINE_S = 45  # hard wall-clock cap, see _transcribe_gradium
TTS_TOTAL_DEADLINE_S = 45  # same idea for the TTS websocket, see _gradium_ws_synthesize


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
    """Transcribe a wav/ogg/etc audio file on disk to text."""
    provider = settings.load()["stt_provider"]
    if provider == "gradium":
        return _transcribe_gradium(audio_path)
    return _transcribe_gemini(audio_path)


_MIME_BY_EXT = {".wav": "audio/wav", ".ogg": "audio/ogg", ".m4a": "audio/mp4"}


def _transcribe_gemini(audio_path: str) -> str:
    with open(audio_path, "rb") as f:
        audio_b64 = base64.b64encode(f.read()).decode()
    mime_type = _MIME_BY_EXT.get(Path(audio_path).suffix.lower(), "audio/wav")

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
                        {"inline_data": {"mime_type": mime_type, "data": audio_b64}},
                    ]
                }
            ]
        },
        timeout=30,
    )
    _check(resp)
    data = resp.json()
    return data["candidates"][0]["content"]["parts"][0]["text"].strip()


def _transcribe_gradium(audio_path: str) -> str:
    """Gradium's REST STT endpoint wants raw WAV bytes as the body (see
    https://docs.gradium.ai/guides/speech-to-text-rest) -- our recordings
    are Ogg/Opus (see tools.py's mic_listen), so convert with ffmpeg first
    (already a dependency on-device for the VAD rewrite, see tools.py).
    """
    wav_path = str(Path(tempfile.gettempdir()) / f"{Path(audio_path).stem}_gradium.wav")
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-i", audio_path, wav_path],
        capture_output=True, timeout=15, check=True,
    )
    try:
        with open(wav_path, "rb") as f:
            wav_bytes = f.read()
    finally:
        Path(wav_path).unlink(missing_ok=True)

    # The response is application/x-ndjson, streamed line-by-line as the
    # server transcribes -- a plain (non-streaming) request blocked and hit
    # our 30s timeout waiting for the connection to close on its own
    # (confirmed by testing directly). stream=True + iter_lines matches
    # the docs' own example and reads results as they arrive instead.
    #
    # IMPORTANT: requests' `timeout` only bounds each individual socket
    # read, not the whole stream -- a server that keeps trickling bytes
    # (e.g. a long/ambiguous recording with music playing in the
    # background, confirmed to reproduce this) can stream well past any
    # reasonable wait without ever tripping it. STT_TOTAL_DEADLINE_S below
    # is a real wall-clock cap across the entire read.
    resp = requests.post(
        GRADIUM_STT_REST_URL,
        headers={"x-api-key": _gradium_api_key(), "Content-Type": "audio/wav"},
        # language="any" instead of pinning "en" -- matches this project's
        # multilingual-reply behavior (see agent.py's system prompt).
        params={"json_config": json.dumps({"language": "any"})},
        data=wav_bytes,
        timeout=30,
        stream=True,
    )
    if not resp.ok:
        raise RuntimeError(f"Gradium STT error {resp.status_code}: {resp.text}")

    pieces = []
    deadline = time.monotonic() + STT_TOTAL_DEADLINE_S
    for line in resp.iter_lines(decode_unicode=True):
        if time.monotonic() > deadline:
            resp.close()
            raise RuntimeError(
                f"Gradium STT stream exceeded {STT_TOTAL_DEADLINE_S}s without finishing"
            )
        if not line:
            continue
        msg = json.loads(line)
        if msg.get("type") == "text":
            pieces.append(msg["text"])
        elif msg.get("type") == "error":
            raise RuntimeError(f"Gradium STT error: {msg.get('message')}")
        elif msg.get("type") == "end_of_stream":
            break
    return " ".join(pieces).strip()


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
    key = settings.load()["gradium_api_key"] or os.environ.get("GRADIUM_API_KEY")
    if not key:
        raise RuntimeError(
            "Set gradium_api_key in settings.json, or export GRADIUM_API_KEY, "
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
    audio = asyncio.run(asyncio.wait_for(_gradium_ws_synthesize(text), timeout=TTS_TOTAL_DEADLINE_S))
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
        GRADIUM_TTS_WS_URL, additional_headers={"x-api-key": _gradium_api_key()}
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
