# ethora-updater: the compose bundle's update service (deploy/compose/updater).
# Node for its small HTTP server; the Docker CLI with the compose plugin, git,
# bash, curl, flock and GNU date for deploy/compose/update.sh, which it runs
# in a one-off container of this same image. Build from the monoserver root:
#   docker build -f deploy/docker/updater.Dockerfile -t ethora-updater .
FROM node:24-alpine
RUN apk add --no-cache bash coreutils curl git util-linux docker-cli docker-cli-compose \
 && git config --system --add safe.directory '*'
COPY deploy/compose/updater/server.js /app/server.js
WORKDIR /app
ENV PORT=8090
CMD ["node", "/app/server.js"]
