FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir uv

# Install only the runtime dependencies declared in pyproject.toml — the
# project itself is never built/installed (flat layout, hatchling would
# reject it); the service runs from source as tools.classifier.server.
COPY pyproject.toml ./
RUN uv pip install --system --no-cache -r pyproject.toml

# The classifier's imports are package-relative (tools.classifier.*), so the
# image re-creates that layout: the build context is tools/classifier itself,
# copied one level below /app so `python -m tools.classifier.server` resolves.
COPY . /app/tools/classifier/

ENV OMP_WAIT_POLICY=PASSIVE
EXPOSE 8765

CMD ["python", "-m", "tools.classifier.server", "serve", "--host", "0.0.0.0", "--port", "8765", "--model", "modernbert"]
