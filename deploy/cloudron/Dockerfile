# syntax=docker/dockerfile:1.7
# Ethora Core as one Cloudron app.
#
# Nothing is built here: every payload is copied out of the release images
# the compose bundle and the Helm chart run (deploy/compose), onto the
# Cloudron base image, and one supervisord runs the processes those images
# would run as containers:
#
#   api, jobs   ethora-api (Node 24 with the API's V8 bytecode; the node
#               binary is the image's own, which the bytecode is bound to)
#   init        first-boot steps (base app, admin, ejabberd accounts, migrations)
#   xmpp        ejabberd from ethora-xmpp (an Alpine build: its musl loader
#               and libraries come along in /opt/musl)
#   centrifugo, minio, caddy   the upstream binaries (static Go)
#   web app     the ethora-frontend bundle, served by caddy
#
# ethora-compose-init is the ethora-xmpp image plus the compose bundle's
# renderer, templates and Caddyfile, so it provides both ejabberd and the
# configuration step (start.sh runs the renderer on every start).
#
# Build with `cloudron builder build` from this directory, or plain docker:
#   docker build -t ethora-cloudron deploy/cloudron
# The image ARGs are the release build pinned by pin.sh (tag@digest); override
# them with --build-arg, e.g. to test a compose-init built from a branch.
ARG API_IMAGE=docker.io/dappros/ethora-api:2610.8@sha256:a9fcfa47df2a10de2da473e998ae49d507e5bd5d63751035145c50c2f5049ca6
ARG FRONTEND_IMAGE=docker.io/dappros/ethora-frontend:2610.8@sha256:dde2aa9831b3b3a311d3b18d8be9282d0af924fd586aff07884be9fad6a63460
ARG INIT_IMAGE=docker.io/dappros/ethora-compose-init:2610.8@sha256:5dec58c7b4157e88264d1266b3fcb0096f6703f74f7dce451adb8203fe88d295
ARG MINIO_IMAGE=docker.io/dappros/minio:RELEASE.2025-09-07T16-13-09Z@sha256:624bad2fe79a8613aa3c5c9b765ebcab365080b8445cf1b05c357cc7753725f0
ARG CENTRIFUGO_IMAGE=docker.io/centrifugo/centrifugo:v6.9.7@sha256:d014d3e99e0e9e58c45e656a7ea4ab97c3f79f96c82a3614ea0f810b4dd0e461
ARG CADDY_IMAGE=docker.io/library/caddy:2.10.2-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d

FROM ${API_IMAGE} AS api
FROM ${FRONTEND_IMAGE} AS frontend
FROM ${MINIO_IMAGE} AS minio
FROM ${CENTRIFUGO_IMAGE} AS centrifugo
FROM ${CADDY_IMAGE} AS caddy

# ejabberd's runtime: the musl loader and every library its binaries and
# NIFs link, found with musl's ldd so a new ejabberd release needs no edit.
FROM ${INIT_IMAGE} AS xmpp
USER root
RUN mkdir -p /musl/lib \
 && find /opt/ejabberd-*/ -type f \( -name '*.so' -o -perm -u+x \) -exec ldd {} \; 2>/dev/null \
    | awk '$2 == "=>" && $3 ~ /^\// { print $3 }' | sort -u \
    | while read -r lib; do cp -L "$lib" /musl/lib/; done \
 && cp -L /lib/ld-musl-*.so.1 /musl/ \
 && ls /musl /musl/lib

FROM cloudron/base:6.0.0@sha256:9bed4c8fa880645f8e669041ee28febe941481d00e9445e3e5a5483cb541d09b

# API: /app/dist, /app/node_modules, /app/package.json, where the bundle's
# scripts expect them (/app/data, Cloudron's storage, sits next to them).
COPY --from=api /usr/local/bin/node /usr/local/bin/node
COPY --from=api /app/ /app/
# The API writes request uploads here before they go to MinIO, and the base
# app's token next to its code on start.
RUN rm -rf /app/dist/uploads && ln -s /tmp/ethora-uploads /app/dist/uploads \
 && ln -s /run/ethora/BaseAppJwt.txt /app/dist/BaseAppJwt.txt

# Web app bundle and its renderer.
COPY --from=frontend /usr/share/nginx/html/ /app/code/frontend/html/
COPY --from=frontend /usr/local/bin/ethora-frontend /usr/local/bin/ethora-frontend

# ejabberd. /opt/ejabberd (its home: conf, database, logs) must be writable,
# and the image's root is not, so it is a link into /run that start.sh
# assembles on every start from the pristine copy in /app/code/ejabberd.
COPY --from=xmpp /musl/ld-musl-x86_64.so.1 /lib/ld-musl-x86_64.so.1
COPY --from=xmpp /musl/lib/ /opt/musl/lib/
COPY --from=xmpp /opt/ /opt/
COPY --from=xmpp /usr/local/bin/ejabberdctl /usr/local/bin/ejabberdctl
COPY --from=xmpp /entrypoint.sh /entrypoint.sh
COPY --from=xmpp /ethora-dist/ /ethora-dist/
# The compose bundle's renderer, scripts, templates and Caddyfile.
COPY --from=xmpp /ethora/ /ethora/
# Fails the build if the musl side misses a library (NIFs' enif_* symbols
# resolve against the running VM, so only missing libraries count).
RUN echo /opt/musl/lib > /etc/ld-musl-x86_64.path \
 && for f in /opt/ejabberd-*/erts-*/bin/beam.smp /opt/ejabberd-*/lib/crypto-*/priv/lib/crypto.so; do \
      if /lib/ld-musl-x86_64.so.1 --list "$f" 2>&1 | grep 'Error loading shared library'; then exit 1; fi; done \
 && mv /opt/ejabberd /app/code/ejabberd \
 && rm -f /app/code/ejabberd/bin && ln -s /usr/local/bin /app/code/ejabberd/bin \
 && ln -s /run/ethora/ejabberd /opt/ejabberd \
 && ln -s /opt/ejabberd /home/ejabberd

COPY --from=minio /usr/bin/minio /usr/local/bin/minio
COPY --from=centrifugo /usr/local/bin/centrifugo /usr/local/bin/centrifugo
COPY --from=caddy /usr/bin/caddy /usr/local/bin/caddy

# Licence texts of the release (the same in every Ethora image).
COPY --from=api /licenses/ /licenses/

COPY start.sh /app/code/start.sh
COPY supervisor/ /etc/supervisor/conf.d/
RUN chmod 755 /app/code/start.sh \
 && sed -e 's,^logfile=.*$,logfile=/run/supervisord.log,' \
        -e 's,^childlogdir=.*$,childlogdir=/run,' \
        -i /etc/supervisor/supervisord.conf

LABEL org.opencontainers.image.title="ethora-core-cloudron" \
      org.opencontainers.image.description="Ethora Core chat platform packaged for Cloudron" \
      org.opencontainers.image.vendor="Dappros Ltd" \
      org.opencontainers.image.source="https://github.com/dappros/ethora-monoserver" \
      org.opencontainers.image.licenses="LicenseRef-Ethora-Core-1.0" \
      com.ethora.license.url="https://ethora.com/legal/ethora-core-license"

CMD [ "/app/code/start.sh" ]
