from __future__ import annotations

import argparse
import os
import time
from pathlib import Path
from typing import Literal, TypedDict

import numpy as np
import onnxruntime as ort
import uvicorn
from fastapi import FastAPI
from pydantic import BaseModel, Field
from transformers import AutoTokenizer


type ProviderName = Literal[
    "CUDAExecutionProvider",
    "CPUExecutionProvider",
]


class CoreMLProviderOptions(TypedDict):
    MLComputeUnits: Literal["CPUAndGPU"]
    ModelCacheDirectory: str


type CoreMLProvider = tuple[Literal["CoreMLExecutionProvider"], CoreMLProviderOptions]
type Provider = ProviderName | CoreMLProvider


class ClassifyRequest(BaseModel):
    command: str = Field(min_length=1)
    cwd: str = Field(min_length=1)


class ClassifyResponse(BaseModel):
    label: Literal["safe", "unsafe"]
    score: float
    latency_ms: float


class Classifier:
    def __init__(self, model_dir: Path, onnx_path: Path, max_length: int) -> None:
        self.tokenizer = AutoTokenizer.from_pretrained(model_dir)
        self.max_length = max_length

        self.session = create_session(onnx_path)
        self.provider = self.session.get_providers()[0]
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
        unsafe_score = float(probabilities[0])
        label: Literal["safe", "unsafe"] = "unsafe" if unsafe_score >= 0.5 else "safe"
        return ClassifyResponse(
            label=label,
            score=unsafe_score,
            latency_ms=(time.perf_counter() - started) * 1000,
        )


def softmax(values: np.ndarray) -> np.ndarray:
    shifted = values - np.max(values)
    exp = np.exp(shifted)
    return exp / np.sum(exp)


def create_session(onnx_path: Path) -> ort.InferenceSession:
    providers = preferred_providers(ort.get_available_providers(), onnx_path)
    try:
        return create_session_with_providers(onnx_path, providers)
    except Exception:
        if providers == ["CPUExecutionProvider"]:
            raise
        return create_session_with_providers(onnx_path, ["CPUExecutionProvider"])


def create_session_with_providers(
    onnx_path: Path,
    providers: list[Provider],
) -> ort.InferenceSession:
    options = ort.SessionOptions()
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    options.intra_op_num_threads = min(4, max(1, os.cpu_count() or 1))
    options.inter_op_num_threads = 1
    return ort.InferenceSession(
        onnx_path,
        sess_options=options,
        providers=providers,
    )


def preferred_providers(available: list[str], onnx_path: Path) -> list[Provider]:
    providers: list[Provider] = []
    if "CUDAExecutionProvider" in available:
        providers.append("CUDAExecutionProvider")
    if "CoreMLExecutionProvider" in available:
        providers.append(coreml_provider(onnx_path))
    if "CPUExecutionProvider" not in providers:
        providers.append("CPUExecutionProvider")
    return providers


def coreml_provider(onnx_path: Path) -> CoreMLProvider:
    cache_dir = onnx_path.parent / ".onnxruntime-coreml-cache"
    cache_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    return (
        "CoreMLExecutionProvider",
        {
            "MLComputeUnits": "CPUAndGPU",
            "ModelCacheDirectory": str(cache_dir),
        },
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Serve the bash classifier locally.")
    parser.add_argument("--model-dir", default="ModernBERT-bash-classifier")
    parser.add_argument("--onnx", default="ModernBERT-bash-classifier/model.onnx")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--max-length", type=int, default=512)
    return parser.parse_args()


def build_app(classifier: Classifier) -> FastAPI:
    app = FastAPI()

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok", "provider": classifier.provider}

    @app.post("/classify")
    def classify(request: ClassifyRequest) -> ClassifyResponse:
        return classifier.classify(request.command, request.cwd)

    return app


def main() -> None:
    args = parse_args()
    classifier = Classifier(
        model_dir=Path(args.model_dir),
        onnx_path=Path(args.onnx),
        max_length=args.max_length,
    )
    uvicorn.run(
        build_app(classifier),
        host=args.host,
        port=args.port,
        log_level="warning",
        access_log=False,
    )


if __name__ == "__main__":
    main()
