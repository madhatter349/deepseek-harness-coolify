# syntax=docker/dockerfile:1
#
# DeepSeek Harness (dsh) — Coolify-ready, self-hosted production image.
#
# The official repository (https://github.com/deepseek-ai/deepseek-harness)
# publishes the complete harness as the npm package `@deepseek-ai/dsh`
# ("Run from npm" is the supported production path in the project README).
# Building the 14k-file pnpm monorepo here would add tens of minutes and GB of
# RAM to every deploy for no runtime benefit, so this image installs the
# published launcher and its official dependency closure instead.
#
# The launcher owns:
#   - the Web UI (`dsh web`), including the built frontend
#   - the agent loop, sessions, terminal, workspace/Git tools
#   - persistence under $DSH_HOME (mounted at /data/dsh-home)
#
# Coolify/Traefik terminates TLS and owns the public edge. The container port
# is never published to the host network.

ARG DSH_VERSION=0.2.0-rc.2
ARG PNPM_VERSION=11.7.0

# ─── stage 1: build the global toolchain ────────────────────────────────────
FROM node:22-bookworm-slim AS build

ARG DSH_VERSION
ARG PNPM_VERSION

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 make g++ ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Any native addon in the dependency closure compiles here, with build tools,
# and the compiled result is copied into the slim runtime stage.
RUN npm install -g --no-fund --no-audit \
      "@deepseek-ai/dsh@${DSH_VERSION}" \
      "pnpm@${PNPM_VERSION}" \
 && npm cache clean --force

# ─── stage 2: runtime ───────────────────────────────────────────────────────
FROM node:22-bookworm-slim AS runtime

ARG DSH_VERSION

LABEL org.opencontainers.image.title="deepseek-harness-coolify" \
      org.opencontainers.image.description="Self-hosted DeepSeek Harness (dsh) Web UI for Coolify" \
      org.opencontainers.image.source="https://github.com/deepseek-ai/deepseek-harness" \
      org.opencontainers.image.version="${DSH_VERSION}" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

# Runtime toolchain for the agent's terminal / Bash / Git tools:
#   git + openssh-client   → clone/push over HTTPS and SSH
#   ripgrep, jq, less      → the commands coding agents actually use
#   python3 + pip + venv   → scripts and data work
#   build-essential        → node-gyp / native pip wheels on demand
#   curl + tini            → healthcheck and PID-1 signal handling
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git openssh-client \
      jq ripgrep less procps tini \
      python3 python3-venv python3-pip \
      build-essential pkg-config \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/lib/node_modules /usr/local/lib/node_modules

# Recreate the global bin symlinks explicitly. COPY dereferences a single
# symlinked file, which would leave `/usr/local/bin/dsh` as a regular file and
# break Node's package resolution (imports resolve from /usr/local/bin).
RUN ln -sf ../lib/node_modules/@deepseek-ai/dsh/lib/bin.js /usr/local/bin/dsh \
 && ln -sf ../lib/node_modules/pnpm/bin/pnpm.mjs /usr/local/bin/pnpm \
 && ln -sf ../lib/node_modules/pnpm/bin/pnpx.mjs /usr/local/bin/pnpx

COPY deploy/ /opt/dsh-deploy/
RUN chmod 755 /opt/dsh-deploy/entrypoint.sh /opt/dsh-deploy/healthcheck.sh \
 && dsh --version

# Deployment defaults. Everything model- or site-specific is supplied at
# runtime through environment variables (see .env.example).
ENV NODE_ENV=production \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false \
    DSH_HOME=/data/dsh-home \
    DSH_WORKSPACE_DIR=/data/workspace \
    DSH_PUBLIC_URL="" \
    DSH_TRUSTED_HOSTS="" \
    DSH_COOKIE_MAX_AGE_DAYS=365 \
    DSH_TELEMETRY_DISABLED=1 \
    DSH_SESSION_LOG_UPLOAD=0 \
    PORT=3080

# One volume holds everything that must survive a redeploy:
#   /data/dsh-home    → config, credentials, sessions, agent state
#   /data/workspace   → repositories and working files
VOLUME ["/data"]
WORKDIR /data/workspace
EXPOSE 3080

# `GET /` is 401 before the browser-session cookie and 200 after; either proves
# the HTTP stack and the auth layer are alive.
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
  CMD ["/opt/dsh-deploy/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/dsh-deploy/entrypoint.sh"]
