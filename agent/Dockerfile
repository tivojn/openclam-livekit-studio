# syntax=docker/dockerfile:1
ARG PYTHON_VERSION=3.14
FROM ghcr.io/astral-sh/uv:python${PYTHON_VERSION}-bookworm-slim AS base

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy

FROM base AS build
RUN apt-get update && apt-get install -y gcc g++ python3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY pyproject.toml uv.lock ./
RUN mkdir -p src && uv sync --locked --no-dev
RUN uv run --module livekit.agents download-files

COPY agent.py ./
COPY src ./src
RUN uv sync --locked --no-dev

FROM base
ARG UID=10001
RUN adduser --disabled-password --gecos "" --home "/app" \
    --shell "/sbin/nologin" --uid "${UID}" appuser
COPY --from=build --chown=appuser:appuser /app /app
WORKDIR /app
USER appuser

CMD ["uv", "run", "--no-sync", "python", "agent.py", "start"]
