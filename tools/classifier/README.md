# Zay Safety Classifier Tool

A standalone, high-performance REST safety classifier service for Zay Agent shell tool execution.

## Quickstart

### 1. Run via `uv` (Recommended)

```bash
# Run with default ModernBERT ONNX model:
uv run -m tools.classifier.server --port 8765

# Or run zero-ML rules mock engine:
uv run -m tools.classifier.server --model rules --port 8765
```

### 2. Configure Zay Agent

Set the endpoint in your environment or config:

```bash
# In your shell profile (.bashrc, .zshrc, or PowerShell $PROFILE):
export ZAY_BASH_CLASSIFIER_URL="http://127.0.0.1:8765/classify"
```

Or in `~/.config/zay/config.json`:

```json
{
  "bashClassifierUrl": "http://127.0.0.1:8765/classify"
}
```

### 3. Model source & overrides

The `modernbert` preset downloads weights from the upstream HuggingFace repo
`nova-agent/ModernBERT-bash-classifier`, which is currently **private** —
anonymous downloads fail, and the loader falls back to the legacy
`vendor/local-models/ModernBERT-bash-classifier/` snapshot (if present) or
to the rules engine. Both the source and the revision are overridable so an
install can target a public mirror without code changes (the model is
Apache-2.0, so re-hosting with notices is permitted):

```bash
export ZAY_CLASSIFIER_REPO_ID="ozgurulukir/zay-bash-classifier"  # any accessible mirror
export ZAY_CLASSIFIER_REVISION="main"                            # pin a commit hash in production
```

### 4. Docker Deployment

```bash
docker build -t zay-classifier -f tools/classifier/Dockerfile tools/classifier
docker run -d -p 8765:8765 --name zay-classifier zay-classifier
```

For complete documentation, model architectures, and custom classifier development guides, see [Wiki: Command Safety & Classifier Guide](../../docs/wiki/SAFETY_CLASSIFIER.md).
