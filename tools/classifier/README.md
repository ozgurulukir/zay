# Nova Safety Classifier Tool

A standalone, high-performance REST safety classifier service for Nova Agent shell tool execution.

## Quickstart

### 1. Run via `uv` (Recommended)

```bash
# Run with default ModernBERT ONNX model:
uv run -m tools.classifier.server --port 8765

# Or run zero-ML rules mock engine:
uv run -m tools.classifier.server --model rules --port 8765
```

### 2. Configure Nova Agent

Set the endpoint in your environment or config:

```bash
# In your shell profile (.bashrc, .zshrc, or PowerShell $PROFILE):
export NOVA_BASH_CLASSIFIER_URL="http://127.0.0.1:8765/classify"
```

Or in `~/.config/nova/config.json`:

```json
{
  "bashClassifierUrl": "http://127.0.0.1:8765/classify"
}
```

### 3. Docker Deployment

```bash
docker build -t nova-classifier -f tools/classifier/Dockerfile tools/classifier
docker run -d -p 8765:8765 --name nova-classifier nova-classifier
```

For complete documentation, model architectures, and custom classifier development guides, see [Wiki: Command Safety & Classifier Guide](../../docs/wiki/SAFETY_CLASSIFIER.md).
