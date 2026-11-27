import sys
import types
from pathlib import Path

import pytest

# Stub optional heavy ML dependencies if not installed in lightweight test environments
for _mod in ("numpy", "onnxruntime", "tokenizers", "huggingface_hub"):
    if _mod not in sys.modules:
        try:
            __import__(_mod)
        except ImportError:
            stub = types.ModuleType(_mod)
            if _mod == "tokenizers":
                stub.Tokenizer = object  # type: ignore[attr-defined]
            elif _mod == "huggingface_hub":
                stub.hf_hub_download = lambda *a, **kw: ""  # type: ignore[attr-defined]
                stub.snapshot_download = lambda *a, **kw: ""  # type: ignore[attr-defined]
            sys.modules[_mod] = stub

# Ensure repo root is on sys.path so tools.classifier can be imported as a package
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from tools.classifier.models.llm_proxy import (
    DEFAULT_CHAT_COMPLETIONS_URL,
    LlmProxyClassifier,
    _normalize_chat_completions_url,
)


def test_normalize_chat_completions_url():
    assert _normalize_chat_completions_url("https://api.openai.com/v1") == "https://api.openai.com/v1/chat/completions"
    assert _normalize_chat_completions_url("https://api.openai.com/v1/") == "https://api.openai.com/v1/chat/completions"
    assert (
        _normalize_chat_completions_url("https://api.openai.com/v1/chat/completions")
        == "https://api.openai.com/v1/chat/completions"
    )
    assert (
        _normalize_chat_completions_url("https://api.openai.com/v1/chat/completions/")
        == "https://api.openai.com/v1/chat/completions"
    )
    assert _normalize_chat_completions_url("http://localhost:11434/v1") == "http://localhost:11434/v1/chat/completions"
    assert _normalize_chat_completions_url("") == DEFAULT_CHAT_COMPLETIONS_URL


def test_llm_proxy_normalizes_env_base_url(monkeypatch):
    monkeypatch.setenv("OPENAI_BASE_URL", "https://api.openai.com/v1")
    clf = LlmProxyClassifier()
    assert clf.api_url == "https://api.openai.com/v1/chat/completions"

    monkeypatch.setenv("OPENAI_BASE_URL", "https://gateway.example.com/v1/")
    clf2 = LlmProxyClassifier()
    assert clf2.api_url == "https://gateway.example.com/v1/chat/completions"

    monkeypatch.delenv("OPENAI_BASE_URL", raising=False)
    clf3 = LlmProxyClassifier()
    assert clf3.api_url == DEFAULT_CHAT_COMPLETIONS_URL


def test_classifier_server_has_no_unused_reload_flag(monkeypatch):
    from tools.classifier import server

    monkeypatch.setattr(sys, "argv", ["server.py", "serve", "--reload"])
    with pytest.raises(SystemExit):
        server.parse_args()
