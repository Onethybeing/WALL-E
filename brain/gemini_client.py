"""Client for Gemini's generateContent API, used as the main reasoning model
(since it's the provider that's actually working with the keys on hand).

Gemini's API shape differs from OpenAI-style chat completions: there's no
"system" role in `contents`, and assistant turns are "model" not "assistant".
This class converts our OpenAI-ish message list into that shape so the rest
of the agent code doesn't need to care which provider is behind it.
"""

import os
import requests

API_BASE = "https://generativelanguage.googleapis.com/v1beta/models"
MODEL = os.environ.get("GEMINI_CHAT_MODEL", "gemini-3.5-flash-lite")


class GeminiClient:
    def __init__(self, api_key: str | None = None, model: str | None = None):
        self.api_key = api_key or os.environ.get("GEMINI_API_KEY")
        self.model = model or MODEL
        if not self.api_key:
            raise RuntimeError(
                "Set GEMINI_API_KEY (export GEMINI_API_KEY=...) with a key from "
                "https://aistudio.google.com/apikey"
            )

    def chat(self, messages: list[dict], temperature: float = 0.4) -> str:
        system_text = None
        contents = []
        for m in messages:
            if m["role"] == "system":
                system_text = m["content"]
                continue
            role = "model" if m["role"] == "assistant" else "user"
            contents.append({"role": role, "parts": [{"text": m["content"]}]})

        payload = {
            "contents": contents,
            "generationConfig": {"temperature": temperature, "maxOutputTokens": 1024},
        }
        if system_text:
            payload["systemInstruction"] = {"parts": [{"text": system_text}]}

        resp = requests.post(
            f"{API_BASE}/{self.model}:generateContent",
            params={"key": self.api_key},
            json=payload,
            timeout=60,
        )
        if not resp.ok:
            # requests' default HTTPError discards the response body, which
            # for a 400 is almost always the one piece of info that explains
            # *why* -- surface it instead of a bare "400 Client Error".
            raise RuntimeError(f"Gemini API error {resp.status_code}: {resp.text}")
        data = resp.json()
        return data["candidates"][0]["content"]["parts"][0]["text"]
