FROM python:3.11-slim

WORKDIR /app

RUN pip install --no-cache-dir uv

COPY pyproject.toml .
RUN uv pip install --system -e .

COPY . .

EXPOSE 8766

ENTRYPOINT ["python", "-m", "tools.db_server.server"]
CMD ["--host", "0.0.0.0", "--port", "8766", "--backend", "sqlite", "--db-path", "/data/zay_server.db"]
