"""Thin client for Groq's free, fast inference API (OpenAI-compatible).
Get a key at https://console.groq.com/keys.
"""

import os
import requests

API_BASE = "https://api.groq.com/openai/v1"
# Tested against this project's Hermes-style <tool_call>{...}</tool_call>
# tag convention (see agent.py): openai/gpt-oss-120b ignored it entirely
# and fabricated a plausible-sounding answer instead of emitting the tag,
# even with the exact format spelled out in the system prompt -- confirmed
# by inspecting its raw (untagged) output directly. qwen/qwen3.8-27b
# reliably emits the correct tag, so that's the default.
MODEL = os.environ.get("GROQ_MODEL", "qwen/qwen3.8-27b")


class GroqClient:
    def __init__(self, api_key: str | None = None, model: str | None = None):
        self.api_key = api_key or os.environ.get("GROQ_API_KEY")
        self.model = model or MODEL
        if not self.api_key:
            raise RuntimeError(
                "Set GROQ_API_KEY (export GROQ_API_KEY=gsk_...) "
                "with a key from https://console.groq.com/keys"
            )

    def chat(self, messages: list[dict], temperature: float = 0.4) -> str:
        resp = requests.post(
            f"{API_BASE}/chat/completions",
            headers={
                "Authorization": f"Bearer {self.api_key}",
                "Content-Type": "application/json",
            },
            json={
                "model": self.model,
                "messages": messages,
                "temperature": temperature,
                "max_tokens": 1024,
            },
            timeout=60,
        )
        if not resp.ok:
            # Same reasoning as gemini_client.py -- raise_for_status() alone
            # discards the response body, which for a 400 usually explains why.
            raise RuntimeError(f"Groq API error {resp.status_code}: {resp.text}")
        data = resp.json()
        return data["choices"][0]["message"]["content"]
