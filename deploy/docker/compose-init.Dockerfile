# syntax=docker/dockerfile:1.7
# ethora-compose-init: renders the configuration of the Ethora Core compose
# bundle (deploy/compose) in its single-file form and in the Helm chart.
#
# It is the ethora-xmpp image of the same release plus the bundle's scripts,
# templates and Caddyfile: the renderer needs the ejabberd config template
# and schema that ship in /ethora-dist of the xmpp image that will run, so
# building on top of it keeps the two matched, and the only new layer is a
# few tens of KB (a stack pulls the xmpp layers anyway). The licence texts
# in /licenses come with the base.
#
#   docker build -f deploy/docker/compose-init.Dockerfile \
#     --build-arg XMPP_IMAGE=docker.io/dappros/ethora-xmpp:2610 -t ethora-compose-init .
#
# Context: the monoserver root (see .dockerignore).
ARG XMPP_IMAGE=docker.io/dappros/ethora-xmpp:2610
FROM ${XMPP_IMAGE}
USER root
COPY deploy/compose/scripts/ /ethora/scripts/
COPY deploy/compose/templates/ /ethora/templates/
COPY deploy/compose/Caddyfile /ethora/Caddyfile
RUN chmod 755 /ethora /ethora/scripts /ethora/templates \
 && chmod 644 /ethora/scripts/* /ethora/templates/* /ethora/Caddyfile
LABEL org.opencontainers.image.title="ethora-compose-init" \
      org.opencontainers.image.description="Renders the configuration of the Ethora Core compose bundle and Helm chart" \
      org.opencontainers.image.vendor="Dappros Ltd" \
      org.opencontainers.image.licenses="LicenseRef-Ethora-Core-1.0" \
      com.ethora.license.url="https://ethora.com/legal/ethora-core-license"
# Runs as root: it hands each rendered file to the user of the container
# that reads it.
ENTRYPOINT ["/bin/sh", "/ethora/scripts/render-config.sh"]
CMD []
