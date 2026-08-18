FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir uv

COPY pyproject.toml .
RUN uv pip install --system --no-cache -e .

COPY . .

ENV OMP_WAIT_POLICY=PASSIVE
EXPOSE 8765

CMD ["python", "-m", "tools.classifier.server", "serve", "--host", "0.0.0.0", "--port", "8765", "--model", "modernbert"]
