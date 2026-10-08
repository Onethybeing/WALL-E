"""Picks which LLM client to hand the agent loop, based on settings.json.

Both GeminiClient and NemotronClient expose the same `.chat(messages)`
interface, so the agent loop never needs to know which one it's talking to --
this is the one place that decides.
"""

import settings
from gemini_client import GeminiClient
from nemotron_client import NemotronClient


def get_llm_client():
    s = settings.load()
    provider = s["llm_provider"]
    api_key = s["llm_api_key"] or None  # fall back to each client's own env var
    model = s["llm_model"] or None

    if provider == "nemotron":
        return NemotronClient(api_key=api_key, model=model)
    if provider == "gemini":
        return GeminiClient(api_key=api_key, model=model)
    raise ValueError(f"Unknown llm_provider in settings.json: {provider!r}")
