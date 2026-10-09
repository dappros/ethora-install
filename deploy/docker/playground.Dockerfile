# syntax=docker/dockerfile:1.7
# Ethora SDK playground (Next.js). Context: the ethora-sdk-playground checkout.
#   docker build -f ../deploy/docker/playground.Dockerfile -t ethora-playground .
# The Next bundle is built at first start from the container's environment
# (NEXT_PUBLIC_* are build-time values); see playground-entrypoint.sh.
ARG NODE_VERSION=24
FROM node:${NODE_VERSION}-bookworm-slim
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1
# `upgrade` picks up Debian security fixes published after the base image was
# built (the release workflow blocks on fixable CRITICAL CVEs).
RUN apt-get update && apt-get upgrade -y --no-install-recommends && apt-get install -y --no-install-recommends ca-certificates curl tini && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY package.json package-lock.json ./
# Full install: `next build` runs inside the container and needs devDependencies.
RUN NPM_CONFIG_PRODUCTION=false npm ci --no-audit --no-fund
COPY . .
RUN rm -rf .next .env.local && mkdir -p .next && chown -R node:node /app
COPY --chmod=755 <<'ENTRY' /usr/local/bin/ethora-playground
#!/bin/sh
# Next.js inlines NEXT_PUBLIC_* at build time, so the bundle is built on first
# start for this install's environment (rebuilt only when those values change)
# and then served with `next start`. .next is a volume so restarts are instant.
set -eu
cd /app
PORT="${PORT:-3020}"
hash="$(env | grep -E '^(NEXT_PUBLIC_|ETHORA_CHAT_)' | sort | sha256sum | cut -c1-16)"
if [ ! -f .next/BUILD_ID ] || [ "$(cat .next/.ethora-env-hash 2>/dev/null)" != "$hash" ]; then
  echo "[ethora-playground] building for this environment (hash $hash)..."
  npx next build
  echo "$hash" > .next/.ethora-env-hash
fi
exec npx next start -p "$PORT"
ENTRY
USER node
EXPOSE 3020
VOLUME ["/app/.next"]
ENTRYPOINT ["tini", "--", "/usr/local/bin/ethora-playground"]
