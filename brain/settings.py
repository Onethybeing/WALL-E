"""Runtime-editable settings, stored as plain JSON.

The point of this file being separate from code: later, the Flutter app's
settings screen can read/write settings.json (or call a tiny local HTTP
endpoint that does) to let the user switch providers or paste in a new API
key without touching any Python.
"""

import json
from pathlib import Path

SETTINGS_PATH = Path(__file__).parent / "settings.json"

DEFAULTS = {
    "llm_provider": "groq",         # "groq" (falls back to Gemini automatically), "gemini", or "nemotron"
    "llm_api_key": "",
    "llm_model": "",                # empty = use the provider's own default
    "groq_api_key": "",             # Groq's free, fast inference API -- primary reasoning model
    "voice_provider": "gemini",     # unused now -- kept so old settings.json files still load
    "voice_api_key": "",            # Gemini key -- used for vision, Groq's fallback, and Gemini-fallback STT/TTS
    "stt_provider": "gradium",      # STT: "gradium" or "gemini"
    "tts_provider": "gradium",      # TTS: "gradium" or "gemini"
    "gradium_api_key": "",          # one key covers both Gradium STT and TTS (shared credit pool)
    "tts_voice_id": "NbpkqMVS3CJeq2j8",  # Gradium's "Zoey" (US, conversational)
    "firecrawl_api_key": "",        # real web_search results (see GitHub issue #11); falls back to DDG if empty
}


def load() -> dict:
    if not SETTINGS_PATH.exists():
        save(DEFAULTS)
        return dict(DEFAULTS)
    with open(SETTINGS_PATH, "r", encoding="utf-8") as f:
        data = json.load(f)
    # Fill in any keys added since this settings file was first created.
    merged = dict(DEFAULTS)
    merged.update(data)
    return merged


def save(settings: dict) -> None:
    with open(SETTINGS_PATH, "w", encoding="utf-8") as f:
        json.dump(settings, f, indent=2)


def update(**changes) -> dict:
    settings = load()
    settings.update(changes)
    save(settings)
    return settings
