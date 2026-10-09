# syntax=docker/dockerfile:1.7
# Ethora push service image (FCM/APNs server + queue worker).
# Context: monoserver root.
#   docker build -f deploy/docker/push.Dockerfile [--build-arg BYTECODE=1] -t ethora-push .
# Commands: server (default) | worker
ARG NODE_VERSION=24
FROM node:${NODE_VERSION}-bookworm-slim AS build
ARG BYTECODE=0
RUN apt-get update && apt-get install -y --no-install-recommends python3 make g++ ca-certificates && rm -rf /var/lib/apt/lists/*
COPY deploy/docker/compile-bytecode.js /build/compile-bytecode.js
WORKDIR /build/push
COPY ethora-backend/services/push/package.json ethora-backend/services/push/package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY ethora-backend/services/push/ ./
RUN rm -f .env README.md && mkdir -p /build/bytenode && if [ "$BYTECODE" = "1" ]; then \
      npm install --no-save --no-audit --no-fund bytenode@1.7.0 \
   && NODE_PATH=/build/push/node_modules node /build/compile-bytecode.js . \
   && cp -R node_modules/bytenode/. /build/bytenode/ && rm -rf node_modules/bytenode ; fi

FROM node:${NODE_VERSION}-bookworm-slim AS runtime
ARG ETHORA_BUILD_VERSION="" 
ARG ETHORA_BUILD_COMMIT=""
ENV NODE_ENV=production ETHORA_BUILD_VERSION=${ETHORA_BUILD_VERSION} ETHORA_BUILD_COMMIT=${ETHORA_BUILD_COMMIT}
# `upgrade` picks up Debian security fixes published after the base image was
# built (the release workflow blocks on fixable CRITICAL CVEs).
RUN apt-get update && apt-get upgrade -y --no-install-recommends && apt-get install -y --no-install-recommends ca-certificates curl tini && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build --chown=node:node /build/push ./push
COPY --from=build --chown=node:node /build/bytenode ./node_modules/bytenode
COPY --chown=node:node deploy/docker/loader.js ./loader.js
COPY --chmod=755 deploy/docker/push-entrypoint.sh /usr/local/bin/ethora-push
RUN if [ -z "$(ls -A /app/node_modules/bytenode)" ]; then rm -rf /app/node_modules; fi \
 && mkdir -p /app/push/uploads && chown node:node /app/push/uploads
USER node
EXPOSE 8098
LABEL org.opencontainers.image.title="ethora-push" org.opencontainers.image.vendor="Dappros Ltd" \
      org.opencontainers.image.revision=${ETHORA_BUILD_COMMIT} org.opencontainers.image.version=${ETHORA_BUILD_VERSION}
ENTRYPOINT ["tini", "--", "/usr/local/bin/ethora-push"]
CMD ["server"]
