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
    "llm_provider": "gemini",       # "gemini" or "nemotron"
    "llm_api_key": "",
    "llm_model": "",                # empty = use the provider's own default
    "voice_provider": "gemini",     # only gemini supported for now
    "voice_api_key": "",
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
