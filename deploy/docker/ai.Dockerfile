# syntax=docker/dockerfile:1.7
# Ethora AI module image: ai-service + docs-parse + the AI chat widget bundle.
#
# Build context is the MONOSERVER ROOT (the widget bundles the chat-component
# from the sibling checkout):
#   docker build -f deploy/docker/ai.Dockerfile [--build-arg BYTECODE=1] -t ethora-ai .
#
# Commands (see ai-entrypoint.sh): ai-service | docs-parse | widget-export /out
ARG NODE_VERSION=24

# ------------------------------------------------------------ toolchain ----
FROM node:${NODE_VERSION}-bookworm-slim AS base
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 make g++ ca-certificates git \
 && rm -rf /var/lib/apt/lists/*
COPY deploy/docker/compile-bytecode.js /build/compile-bytecode.js

# ------------------------------------------------------------ ai-service ----
FROM base AS ai-build
ARG BYTECODE=0
WORKDIR /build/ai-service
COPY ethora-backend/services/ai/ai-service/package.json ethora-backend/services/ai/ai-service/package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY ethora-backend/services/ai/ai-service/ ./
RUN npm run build && find dist -name '*.test.js' -delete
# bytenode lands in /build/bytenode (empty dir in a plain build) so the
# runtime stage can COPY it unconditionally.
RUN mkdir -p /build/bytenode && if [ "$BYTECODE" = "1" ]; then \
      npm install --no-save --no-audit --no-fund bytenode@1.7.0 \
   && NODE_PATH=/build/ai-service/node_modules node /build/compile-bytecode.js dist \
   && cp -R node_modules/bytenode/. /build/bytenode/ ; fi
RUN npm prune --omit=dev --no-audit --no-fund && rm -rf node_modules/bytenode src

# ------------------------------------------------------------ docs-parse ----
FROM base AS docs-build
ARG BYTECODE=0
WORKDIR /build/docs-parse
COPY ethora-backend/services/ai/docs-parse/package.json ethora-backend/services/ai/docs-parse/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY ethora-backend/services/ai/docs-parse/index.js ./
RUN if [ "$BYTECODE" = "1" ]; then \
      npm install --no-save --no-audit --no-fund bytenode@1.7.0 \
   && NODE_PATH=/build/docs-parse/node_modules node /build/compile-bytecode.js . \
   && rm -rf node_modules/bytenode ; fi

# ---------------------------------------------------------------- widget ----
# Built once with placeholders in place of the per-install VITE_WIDGET_*
# values; ai-entrypoint.sh substitutes them at export time.
FROM base AS widget-build
WORKDIR /build
COPY ethora-chat-component/package.json ethora-chat-component/package-lock.json ./ethora-chat-component/
# --ignore-scripts: the package's prepare script builds the library, which the
# widget does not need (it bundles the component from source via a Vite alias).
RUN cd ethora-chat-component && npm ci --no-audit --no-fund --ignore-scripts
COPY ethora-chat-component/ ./ethora-chat-component/
COPY ethora-ai-chat-widget/package.json ethora-ai-chat-widget/package-lock.json ./ethora-ai-chat-widget/
RUN cd ethora-ai-chat-widget && npm ci --no-audit --no-fund
COPY ethora-ai-chat-widget/ ./ethora-ai-chat-widget/
RUN cd ethora-ai-chat-widget \
 && printf 'VITE_WIDGET_API_URL=__ETHORA_WIDGET_API_URL__\nVITE_WIDGET_XMPP_DOMAIN=__ETHORA_WIDGET_XMPP_DOMAIN__\nVITE_WIDGET_XMPP_WS_URL=__ETHORA_WIDGET_XMPP_WS_URL__\nVITE_WIDGET_XMPP_CONFERENCE=__ETHORA_WIDGET_XMPP_CONFERENCE__\nVITE_WIDGET_QR_URL=__ETHORA_WIDGET_QR_URL__\n' > .env.production.local \
 && npm run build \
 && test -f dist/ethora_assistant.js \
 && grep -q __ETHORA_WIDGET_API_URL__ dist/ethora_assistant.js

# --------------------------------------------------------------- runtime ----
FROM node:${NODE_VERSION}-bookworm-slim AS runtime
ARG ETHORA_BUILD_VERSION=""
ARG ETHORA_BUILD_COMMIT=""
ENV NODE_ENV=production \
    ETHORA_BUILD_VERSION=${ETHORA_BUILD_VERSION} \
    ETHORA_BUILD_COMMIT=${ETHORA_BUILD_COMMIT}
# `upgrade` picks up Debian security fixes published after the base image was
# built (the release workflow blocks on fixable CRITICAL CVEs).
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && apt-get install -y --no-install-recommends ca-certificates curl tini \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=ai-build  --chown=node:node /build/ai-service/dist         ./ai-service/dist
COPY --from=ai-build  --chown=node:node /build/ai-service/node_modules ./ai-service/node_modules
COPY --from=ai-build  --chown=node:node /build/ai-service/package.json ./ai-service/package.json
COPY --from=ai-build  --chown=node:node /build/ai-service/drizzle      ./ai-service/drizzle
COPY --from=ai-build  --chown=node:node /build/bytenode                ./node_modules/bytenode
COPY --from=docs-build --chown=node:node /build/docs-parse             ./docs-parse
COPY --from=widget-build --chown=node:node /build/ethora-ai-chat-widget/dist ./widget
COPY --chown=node:node deploy/docker/loader.js ./loader.js
COPY deploy/docker/ai-entrypoint.sh /usr/local/bin/ethora-ai
RUN chmod +x /usr/local/bin/ethora-ai \
 && if [ -z "$(ls -A /app/node_modules/bytenode)" ]; then rm -rf /app/node_modules; fi
USER node
LABEL org.opencontainers.image.title="ethora-ai" org.opencontainers.image.vendor="Dappros Ltd" \
      org.opencontainers.image.revision=${ETHORA_BUILD_COMMIT} org.opencontainers.image.version=${ETHORA_BUILD_VERSION}
EXPOSE 8013 8201
ENTRYPOINT ["tini", "--", "/usr/local/bin/ethora-ai"]
CMD ["ai-service"]
