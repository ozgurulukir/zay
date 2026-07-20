# Nova Local Models

A FastAPI server (`server.py`) hosting the local models Nova spawns at startup:

- **Bash classifier** — a ModernBERT fine-tune that classifies bash commands as safe or unsafe (`POST /classify`). Served via ONNX Runtime from `ModernBERT-bash-classifier/`.

The server binds immediately and loads models in a background thread; endpoints return 503 until ready. `GET /health` reports load status.
