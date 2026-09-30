# Ethora Core in one compose file

`docker-compose.yml` here is the compose bundle with nothing else on disk:
save it in an empty directory, add a `.env` with `ROOT_DOMAIN` (or
`PUBLIC_URL`) and `ADMIN_EMAIL`, run `docker compose up -d`. Everything else,
including how to check, update, back up and route it, is in the bundle's
[README](../README.md) ("One file instead of this directory").

It is generated: `build.sh` takes `../docker-compose.yml` and changes only
the `config` service, which runs the `ethora-compose-init` image (the xmpp
image plus the bundle's `scripts/`, `templates/` and `Caddyfile`) instead of
mounting those from the checkout. Edit the bundle and run

    deploy/compose/single/build.sh

`deploy/scripts/tests/compose-bundle.test.sh` fails when this file is out of
date.
