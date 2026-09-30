# Ethora Core on CasaOS and ZimaOS

`docker-compose.yml` here is the app in the format of the CasaOS / ZimaOS
AppStore ([IceWhaleTech/CasaOS-AppStore](https://github.com/IceWhaleTech/CasaOS-AppStore),
`Apps/<App>/docker-compose.yml` with a top-level `x-casaos` block). It is
generated; do not edit it by hand:

```bash
deploy/compose/platforms/pin-images.sh 2610.8     # after a release build
deploy/compose/platforms/casaos/build.sh           # regenerate from single/docker-compose.yml
```

`build.sh` takes the single-file compose form and serves everything on one
origin over plain HTTP on port 8456 (the bundled Caddy routes by path), keeps
data under `/DATA/AppData/$AppID/`, pins the images to the release build in
`../images.env`, leaves every secret empty so each install generates its own
(kept in `/DATA/AppData/ethora/secrets`), and adds the `x-casaos` metadata
(`id: com.ethora.core`, `main: caddy`, `port_map: "8456"`, category
`Social`).

Two values are meant to be set in the install dialog (the tip says so):
`PUBLIC_URL`, the address the device is opened by with port 8456 (default
`http://casaos.local:8456`; it is also the XMPP domain and the base of shared
file links), and `ADMIN_PASSWORD` (the sign-in e-mail is `ADMIN_EMAIL`,
`admin@casaos.local`). Left empty, the password is generated and printed once
in the log of the `config` container.

## Install without the store

CasaOS: App Store > Custom Install > Import (paste this file), or on the
device:

```bash
casaos-cli app-management install -f docker-compose.yml
```

## Verified

On CasaOS v0.4.15 (its one-line installer on a fresh Ubuntu 24.04 droplet,
amd64), installed with `casaos-cli app-management install` with `PUBLIC_URL`
set to the droplet's address and an admin password, 2026-09-30:

- CasaOS lists the app as `ethora`, running, main service `caddy`, port 8456;
  all services healthy, one-shot steps exited 0, data in
  `/DATA/AppData/ethora/`;
- the bundle's `verify` check against `http://<ip>:8456` (admin login,
  licence `core, unlicensed`, a room created and a message round trip over
  `ws://<ip>:8456/ws`, a file uploaded and read back);
- a browser at `http://<ip>:8456`: admin login, chat list, and the web
  client's own XMPP session (SASL success, resource bound);
- restart through CasaOS (`casaos-cli app-management restart ethora`): users,
  chats and the generated secrets kept.

Not verified: ZimaOS, arm64, the AppStore's own build (`scripts/build_dist.sh`)
and install from a store listing, and the CasaOS web UI's install dialog
(the same API the CLI calls).

## Submitting to the CasaOS / ZimaOS AppStore

1. After a release build: `pin-images.sh <build>` and `build.sh`, commit.
2. Fork `IceWhaleTech/CasaOS-AppStore`, create a branch, add `Apps/Ethora/`
   with this `docker-compose.yml`, `icon.svg` (here), a `thumbnail.png` and
   `screenshot-1.png` ... from the running app. Point `icon`, `thumbnail`
   and `screenshot_link` in `x-casaos` at the files in that directory (the
   build rewrites them) and bump `x-casaos.version` for each new release.
3. In the fork: `./scripts/build_dist.sh` must finish without errors and
   produce `dist/apps/<id>/`; `docker compose -f Apps/Ethora/docker-compose.yml config -q`
   must pass (the repository CI runs both).
4. Open the pull request: new app, what it is, how it was validated (the
   list above), the default credentials and the two settings the tip asks
   for.
