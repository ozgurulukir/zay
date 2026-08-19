from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Callable
from huggingface_hub import snapshot_download

from .models.base import BaseClassifier
from .models.onnx_classifier import OnnxClassifier
from .models.rules_engine import RulesEngineClassifier
from .models.llm_proxy import LlmProxyClassifier


@dataclass(frozen=True)
class ModelSpec:
    name: str
    description: str
    repo_id: str | None
    onnx_file: str
    factory: Callable[[Path], BaseClassifier]


CACHE_DIR = Path(os.environ.get("NOVA_CLASSIFIER_CACHE_DIR", Path.home() / ".cache" / "nova-classifier"))


def build_onnx_factory(onnx_file: str, max_length: int = 512) -> Callable[[Path], BaseClassifier]:
    def _create(model_dir: Path) -> BaseClassifier:
        onnx_path = model_dir / onnx_file
        return OnnxClassifier(model_dir=model_dir, onnx_path=onnx_path, max_length=max_length)
    return _create


CATALOG: dict[str, ModelSpec] = {
    "modernbert": ModelSpec(
        name="modernbert",
        description="ModernBERT-bash-classifier (~450MB) - High accuracy fine-tuned ONNX model",
        repo_id="nova-agent/ModernBERT-bash-classifier",
        onnx_file="model.onnx",
        factory=build_onnx_factory("model.onnx", 512),
    ),
    "rules": ModelSpec(
        name="rules",
        description="Built-in regex & token heuristic mock engine (<1MB, zero-ML)",
        repo_id=None,
        onnx_file="",
        factory=lambda _: RulesEngineClassifier(),
    ),
    "llm-proxy": ModelSpec(
        name="llm-proxy",
        description="Remote LLM proxy classifier (OpenAI / Ollama / OpenRouter)",
        repo_id=None,
        onnx_file="",
        factory=lambda _: LlmProxyClassifier(),
    ),
}


def download_model(model_name: str) -> Path:
    """Download model files from HuggingFace to local cache."""
    if model_name not in CATALOG:
        raise ValueError(f"Unknown model preset '{model_name}'. Available: {list(CATALOG.keys())}")

    spec = CATALOG[model_name]
    if not spec.repo_id:
        return CACHE_DIR / model_name

    target_dir = CACHE_DIR / model_name
    target_dir.mkdir(parents=True, exist_ok=True)

    print(f"[*] Downloading '{model_name}' weights from {spec.repo_id} to {target_dir}...")
    snapshot_download(
        repo_id=spec.repo_id,
        local_dir=str(target_dir),
        local_dir_use_symlinks=False,
    )
    print(f"[✓] Download completed for '{model_name}'.")
    return target_dir


def load_classifier(model_name: str, local_path: str | None = None) -> BaseClassifier:
    """Instantiate a classifier by preset name or custom local directory."""
    if local_path:
        path = Path(local_path)
        onnx_file = "model.onnx"
        if not (path / onnx_file).exists():
            # Check if local_path points directly to an .onnx file
            if path.suffix == ".onnx":
                return OnnxClassifier(model_dir=path.parent, onnx_path=path)
        return OnnxClassifier(model_dir=path, onnx_path=path / onnx_file)

    if model_name not in CATALOG:
        raise ValueError(f"Unknown model '{model_name}'. Choices: {list(CATALOG.keys())}")

    spec = CATALOG[model_name]
    if spec.repo_id:
        model_dir = CACHE_DIR / model_name
        onnx_path = model_dir / spec.onnx_file
        if not onnx_path.exists():
            # If not yet downloaded, check if legacy vendor folder exists first, otherwise download
            legacy_path = Path("vendor/local-models/ModernBERT-bash-classifier")
            if model_name == "modernbert" and legacy_path.exists() and (legacy_path / "model.onnx").exists():
                model_dir = legacy_path
            else:
                try:
                    download_model(model_name)
                except Exception as e:
                    print(f"[!] Warning: Could not download {model_name} ({e}). Falling back to rules engine.")
                    return RulesEngineClassifier()
        return spec.factory(model_dir)

    return spec.factory(CACHE_DIR / model_name)
