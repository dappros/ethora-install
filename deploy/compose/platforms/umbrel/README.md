# Ethora Core on umbrelOS

`ethora/` is the Umbrel app package, ready to be copied into
[getumbrel/umbrel-apps](https://github.com/getumbrel/umbrel-apps) as the
directory `ethora/`. It is generated; do not edit it by hand:

```bash
deploy/compose/platforms/pin-images.sh 2610.8     # after a release build: exact images, tag@digest
deploy/compose/platforms/umbrel/build.sh           # regenerate ethora/ from single/docker-compose.yml
```

`build.sh` takes the single-file compose form and:

- puts Umbrel's `app_proxy` in front of the bundled Caddy (container
  `ethora_caddy_1`, port 80), which serves everything on one origin by path
  (`PUBLIC_URL=http://${DEVICE_DOMAIN_NAME}:8456`, manifest port 8456);
- keeps Umbrel's login in front of the web UI and whitelists the paths SDK
  and mobile clients call without an Umbrel session (`/v1`, `/v2`,
  `/api-docs`, `/ws`, `/bosh`, `/connection/`, `/files/`); Ethora's own
  authentication protects them;
- turns every named volume into a bind mount under `${APP_DATA_DIR}/data`
  (with `data/<volume>/.gitkeep`);
- pins every image from `../images.env`;
- sets the admin account to `umbrel@umbrel.local` with `${APP_PASSWORD}`
  (`deterministicPassword: true`, so Umbrel shows it) and derives every other
  secret per install in `exports.sh` with `derive_entropy`;
- uses `restart: on-failure`, and no restart for the three one-shot steps
  (`config`, `mongo-init`, `init`).

## Verified

On umbrelOS 2.0.0, run as the containerized umbrelOS their test guide
describes (`ghcr.io/getumbrel/umbrelos:2.0.0`, privileged, host network, on an
amd64 Ubuntu host), with the package synced into the official app-store
directory and installed through Umbrel (`umbreld client apps.install.mutate
--appId ethora`), 2026-09-30:

- install through Umbrel: state `ready`, all services healthy, one-shot
  steps exited 0;
- through `app_proxy`: the bundle's `verify` check (admin login with the
  Umbrel-derived password, licence `core, unlicensed`, a room created and a
  message round trip over `ws://<device>.local:8456/ws`, a file uploaded and
  read back from `/files/`);
- in a browser opened at `http://<device>.local:8456`: Umbrel's login, then
  the Ethora admin login, the chat list, and the web client's own XMPP
  session (SASL success, resource bound);
- restart through Umbrel (`apps.restart.mutate`): state and logins kept;
- `npm run lint:apps -- ethora --check-images` in umbrel-apps: every image
  pullable and multi-arch; the remaining findings are listed below.

Not verified: an Umbrel device (Raspberry Pi / Umbrel Home), arm64, the app
store UI's install button, the update path (there is no earlier release), and
Umbrel backup and restore.

Expected linter findings until submission:

- `submission` is empty until the pull request exists (fill in its URL);
- `ethora-compose-init` is `@sha256:PENDING` until the first release build
  that publishes it (then `pin-images.sh` and `build.sh`);
- warnings that `config`, `mongo-init` and `init` have no restart policy:
  they are intentional one-shot steps.

## Submitting to the Umbrel App Store

1. After a release build: `pin-images.sh <build>` and `build.sh`, commit.
2. Fork `getumbrel/umbrel-apps`, create a branch, copy
   `deploy/compose/platforms/umbrel/ethora/` to `ethora/` at the repository
   root (keep the `data/**/.gitkeep` files).
3. In the fork: `npm ci` and `npm run lint:apps -- ethora --check-images`;
   fix every error except `submission`.
4. Test on umbrelOS as their `.claude/skills/umbrel-test-app/SKILL.md`
   describes (sync the directory into
   `~/umbrel/app-stores/getumbrel-umbrel-apps-github-53f74447/ethora/`,
   `umbreld client apps.install.mutate --appId ethora`, open it at
   `http://umbrel.local:8456`, sign in with the credentials Umbrel shows,
   send a message, restart the app, check the data stayed).
5. Open the pull request with the app version, the upstream links
   (https://ethora.com, https://github.com/dappros/ethora-install), the
   images (Docker Hub `dappros/*`), what was tested and on which
   architecture, the default credentials (Umbrel's deterministic password
   for `umbrel@umbrel.local`), the `app_proxy` whitelist and why, a logo and
   screenshots in the PR body (not committed; Umbrel hosts the gallery).
6. Set `submission:` in `umbrel-app.yml` (here in `umbrel-app.in.yml`, then
   `build.sh`) to the pull request URL and push it to the PR branch.
