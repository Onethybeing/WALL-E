"""Thin client for NVIDIA's free NIM API (OpenAI-compatible), talking to a
Nemotron model. Get a key at https://build.nvidia.com -> Settings -> API Keys.
"""

import os
import requests

API_BASE = "https://integrate.api.nvidia.com/v1"
MODEL = os.environ.get("NEMOTRON_MODEL", "nvidia/llama-3.1-nemotron-70b-instruct")


class NemotronClient:
    def __init__(self, api_key: str | None = None, model: str | None = None):
        self.api_key = api_key or os.environ.get("NEMOTRON_API_KEY")
        self.model = model or MODEL
        if not self.api_key:
            raise RuntimeError(
                "Set NEMOTRON_API_KEY (export NEMOTRON_API_KEY=nvapi-...) "
                "with a key from https://build.nvidia.com"
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
        resp.raise_for_status()
        data = resp.json()
        return data["choices"][0]["message"]["content"]
