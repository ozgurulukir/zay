from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Literal
from pydantic import BaseModel, Field


class ClassifyRequest(BaseModel):
    command: str = Field(min_length=1, description="Shell command string to classify")
    cwd: str = Field(min_length=1, description="Working directory context")


class ClassifyResponse(BaseModel):
    label: Literal["safe", "unsafe"] = Field(description="Safety classification verdict")
    score: float = Field(default=0.0, description="Confidence score for unsafe classification (0.0 - 1.0)")
    latency_ms: float = Field(default=0.0, description="Inference execution latency in milliseconds")


class BaseClassifier(ABC):
    """Abstract base class for all command safety classifiers."""

    @abstractmethod
    def classify(self, command: str, cwd: str) -> ClassifyResponse:
        """Evaluate a shell command and return a safety verdict."""
        raise NotImplementedError
