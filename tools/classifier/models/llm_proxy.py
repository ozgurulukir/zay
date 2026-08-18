from __future__ import annotations

import json
import os
import time
from typing import Literal
import httpx
from .base import BaseClassifier, ClassifyResponse


class LlmProxyClassifier(BaseClassifier):
    """Zero-shot command safety classifier via external LLM endpoint."""

    def __init__(self, api_url: str | None = None, api_key: str | None = None, model: str = "gpt-4o-mini") -> None:
        self.api_url = api_url or os.environ.get("OPENAI_BASE_URL", "https://api.openai.com/v1/chat/completions")
        self.api_key = api_key or os.environ.get("OPENAI_API_KEY", "")
        self.model = model

    def classify(self, command: str, cwd: str) -> ClassifyResponse:
        started = time.perf_counter()

        system_prompt = (
            "You are a shell command safety evaluator. Your task is to determine if a bash or powershell "
            "command is destructive or catastrophic (e.g. wiping root disk, formatting drives, fork bombs, "
            "overwriting system partitions, irreversible data destruction). "
            "Respond ONLY with a JSON object: {\"label\": \"safe\" | \"unsafe\", \"score\": float, \"reason\": string}"
        )
        user_prompt = f"CWD: {cwd}\nCommand: {command}"

        try:
            with httpx.Client(timeout=5.0) as client:
                headers = {
                    "Authorization": f"Bearer {self.api_key}",
                    "Content-Type": "application/json",
                }
                payload = {
                    "model": self.model,
                    "messages": [
                        {"role": "system", "content": system_prompt},
                        {"role": "user", "content": user_prompt},
                    ],
                    "response_format": {"type": "json_object"},
                    "temperature": 0.0,
                }
                resp = client.post(self.api_url, headers=headers, json=payload)
                resp.raise_for_status()
                data = resp.json()
                content = data["choices"][0]["message"]["content"]
                result = json.loads(content)

                label: Literal["safe", "unsafe"] = "unsafe" if result.get("label") == "unsafe" else "safe"
                score = float(result.get("score", 0.99 if label == "unsafe" else 0.01))
        except Exception:
            # Fallback on LLM failure: default to safe so local built-in regex handles it
            label = "safe"
            score = 0.0

        latency = (time.perf_counter() - started) * 1000.0
        return ClassifyResponse(
            label=label,
            score=score,
            latency_ms=latency,
        )
