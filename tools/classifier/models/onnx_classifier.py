from __future__ import annotations

import os
import time
from pathlib import Path
from typing import Literal, TypedDict
import numpy as np
import onnxruntime as ort

from .base import BaseClassifier, ClassifyResponse

# Passive wait policy for CPU threadpool to avoid idle spin
os.environ.setdefault("OMP_WAIT_POLICY", "PASSIVE")

type ProviderName = Literal[
    "CUDAExecutionProvider",
    "CPUExecutionProvider",
]

class CoreMLProviderOptions(TypedDict):
    MLComputeUnits: Literal["CPUAndGPU"]
    ModelCacheDirectory: str

type CoreMLProvider = tuple[Literal["CoreMLExecutionProvider"], CoreMLProviderOptions]
type Provider = ProviderName | CoreMLProvider


def softmax(values: np.ndarray) -> np.ndarray:
    shifted = values - np.max(values)
    exp = np.exp(shifted)
    return exp / np.sum(exp)


def create_session(onnx_path: Path) -> ort.InferenceSession:
    available = ort.get_available_providers()
    providers: list[Provider] = []
    if "CUDAExecutionProvider" in available:
        providers.append("CUDAExecutionProvider")
    if "CoreMLExecutionProvider" in available:
        cache_dir = onnx_path.parent / ".onnxruntime-coreml-cache"
        cache_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
        providers.append(("CoreMLExecutionProvider", {"MLComputeUnits": "CPUAndGPU", "ModelCacheDirectory": str(cache_dir)}))
    if "CPUExecutionProvider" not in providers:
        providers.append("CPUExecutionProvider")

    options = ort.SessionOptions()
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    options.intra_op_num_threads = min(4, max(1, os.cpu_count() or 1))
    options.inter_op_num_threads = 1

    try:
        return ort.InferenceSession(str(onnx_path), sess_options=options, providers=providers)
    except Exception:
        return ort.InferenceSession(str(onnx_path), sess_options=options, providers=["CPUExecutionProvider"])


class OnnxClassifier(BaseClassifier):
    """ONNX Runtime based command safety classifier."""

    def __init__(self, model_dir: Path, onnx_path: Path, max_length: int = 512) -> None:
        from transformers import AutoTokenizer

        self.tokenizer = AutoTokenizer.from_pretrained(str(model_dir))
        self.max_length = max_length
        self.session = create_session(onnx_path)
        self.input_names = {item.name for item in self.session.get_inputs()}
        self.warm()

    def warm(self) -> None:
        self.classify("printf hello", cwd=".")

    def classify(self, command: str, cwd: str) -> ClassifyResponse:
        started = time.perf_counter()
        encoded = self.tokenizer(
            command,
            return_tensors="np",
            truncation=True,
            max_length=self.max_length,
        )
        inputs = {
            name: value.astype(np.int64, copy=False)
            for name, value in encoded.items()
            if name in self.input_names
        }
        logits = self.session.run(["logits"], inputs)[0][0]
        probabilities = softmax(logits)
        # Probabilities: index 0 is unsafe, index 1 is safe (or depending on fine-tune weights)
        unsafe_score = float(probabilities[0])
        label: Literal["safe", "unsafe"] = "unsafe" if unsafe_score >= 0.5 else "safe"
        latency = (time.perf_counter() - started) * 1000.0

        return ClassifyResponse(
            label=label,
            score=unsafe_score,
            latency_ms=latency,
        )
