"""Picks which LLM client to hand the agent loop, based on settings.json.

Every client exposes the same `.chat(messages)` interface, so the agent
loop never needs to know which one it's talking to -- this is the one
place that decides.
"""

import settings
from gemini_client import GeminiClient
from groq_client import GroqClient
from nemotron_client import NemotronClient


class _FallbackClient:
    """Tries a primary client first, falling back to a secondary one if the
    primary raises -- e.g. Groq is fast and generous on its free tier but
    can still hit a rate limit or outage, and Gemini (already configured
    for vision/STT/TTS fallback) is a sensible safety net.
    """

    def __init__(self, primary, fallback):
        self.primary = primary
        self.fallback = fallback

    def chat(self, messages: list[dict], temperature: float = 0.4) -> str:
        try:
            return self.primary.chat(messages, temperature=temperature)
        except Exception as e:
            print(f"primary LLM ({type(self.primary).__name__}) failed, "
                  f"falling back to Gemini: {e}")
            return self.fallback.chat(messages, temperature=temperature)


def get_llm_client():
    s = settings.load()
    provider = s["llm_provider"]
    api_key = s["llm_api_key"] or None  # fall back to each client's own env var
    model = s["llm_model"] or None

    if provider == "nemotron":
        return NemotronClient(api_key=api_key, model=model)
    if provider == "gemini":
        return GeminiClient(api_key=api_key, model=model)
    if provider == "groq":
        groq = GroqClient(api_key=s["groq_api_key"] or None, model=model)
        # Gemini key is separate from Groq's -- reuse the existing
        # voice_api_key (same Gemini account used for vision/STT/TTS).
        gemini = GeminiClient(api_key=s["voice_api_key"] or None)
        return _FallbackClient(primary=groq, fallback=gemini)
    raise ValueError(f"Unknown llm_provider in settings.json: {provider!r}")
