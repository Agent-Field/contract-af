# AForge CLI — fetched from the public release mirror and verified against the
# release checksums (which hash the *uncompressed* binaries). Both ARGs are
# overridable so CI or a local mirror can serve the same layout elsewhere:
#   docker build --build-arg AFORGE_BASE_URL=... --build-arg AFORGE_VERSION=... .
ARG AFORGE_BASE_URL=https://agentfield.ai/downloads/aforge
ARG AFORGE_VERSION=v0.1.0

# Reuses the python:3.11-slim base (debian bookworm) already pulled for the
# builder/runtime stages rather than adding a second base image to the build.
FROM python:3.11-slim AS aforge

ARG AFORGE_BASE_URL
ARG AFORGE_VERSION
# TARGETARCH is populated by BuildKit; dpkg is the fallback for the legacy
# builder, where the build platform is always the target platform.
ARG TARGETARCH

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /out

RUN set -eu; \
    arch="${TARGETARCH:-$(dpkg --print-architecture)}"; \
    curl -fsSL "${AFORGE_BASE_URL}/${AFORGE_VERSION}/aforge-linux-${arch}.gz" -o aforge.gz; \
    gunzip -c aforge.gz > aforge; \
    rm aforge.gz; \
    curl -fsSL "${AFORGE_BASE_URL}/${AFORGE_VERSION}/checksums.txt" -o checksums.txt; \
    grep " aforge-linux-${arch}$" checksums.txt \
      | sed "s/  aforge-linux-.*/  aforge/" \
      | sha256sum -c -; \
    rm checksums.txt; \
    chmod +x aforge


FROM python:3.11-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git && \
    rm -rf /var/lib/apt/lists/*

COPY pyproject.toml README.md ./
COPY src/ src/

RUN pip install --no-cache-dir --prefix=/install \
    "agentfield>=0.1.145" \
    "pydantic>=2.0" \
    "httpx>=0.27" \
    "python-dotenv>=1.0" \
    "fastapi>=0.100" \
    "uvicorn>=0.20" && \
    pip install --no-cache-dir --prefix=/install --no-deps .


FROM python:3.11-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    AGENTFIELD_SERVER=http://agentfield:8080 \
    HARNESS_PROVIDER=aforge \
    AGENTFIELD_AFORGE_COMMAND=exec \
    HARNESS_MODEL=openrouter/moonshotai/kimi-k2.5 \
    AI_MODEL=openrouter/moonshotai/kimi-k2.5 \
    PORT=8004 \
    HOME=/home/contractaf \
    PYTHONPATH=/app/src \
    PATH=/home/contractaf/.opencode/bin:${PATH}

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git && \
    groupadd --gid 10001 contractaf && \
    useradd --uid 10001 --gid contractaf --create-home --home-dir /home/contractaf --shell /bin/sh contractaf && \
    su -s /bin/sh contractaf -c "curl -fsSL https://opencode.ai/install | bash" && \
    chown -R contractaf:contractaf /app /home/contractaf && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /home/contractaf/.config/opencode && \
    echo '{"$schema":"https://opencode.ai/config.json","model":"openrouter/moonshotai/kimi-k2.5","small_model":"openrouter/moonshotai/kimi-k2.5","provider":{"openrouter":{"options":{"apiKey":"{env:OPENROUTER_API_KEY}"},"models":{"moonshotai/kimi-k2.5":{}}}}}' \
    > /home/contractaf/.config/opencode/opencode.json && \
    chown -R contractaf:contractaf /home/contractaf/.config

COPY --from=builder /install /usr/local
COPY --from=aforge /out/aforge /usr/local/bin/aforge
# Stay on aforge on purpose until this product's separate CodeAF migration.
ENV AFORGE_BIN=/usr/local/bin/aforge
COPY src/ /app/src/

USER contractaf

EXPOSE 8004

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD curl -f http://localhost:8004/health || exit 1

CMD ["python", "-m", "contract_af.app"]
