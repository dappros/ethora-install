# updater

The compose bundle's update service (profile `updater`, image
`dappros/ethora-updater`, built from `deploy/docker/updater.Dockerfile`). It
is what the admin panel's **Update now** and **Roll back** call. The steps
themselves are `../update.sh`, which an operator can also run from a shell.

## How it works

- `server.js` listens on port 8090 on the compose network only (no published
  port). The API reaches it at `ETHORA_UPDATER_URL` (`http://updater:8090`,
  rendered into the API's env when the profile is on) and sends
  `X-Updater-Secret: <UPDATER_SECRET>` with every call; anything else gets 401.
- An update or rollback runs `update.sh` in a one-off container of this same
  image (`ethora-update-job`), with the Docker socket, the install directory
  (mounted at its host path, so compose resolves every path the same way) and
  the host's docker login. That container outlives `docker compose up -d`
  recreating the `updater` service itself.
- Progress is in `<bundle>/.update/`: `state.json` (job, step, states),
  `job.log`, `previous` (the build a rollback returns to), `lock` (held by the
  running job; flock works across containers), `cancel` (written by a cancel).

## API

| call | answer |
|---|---|
| `GET /healthz` | `{ ok: true }`, no secret needed |
| `GET /v1/status` | `{ line, tag, running, previous, bundle: { commit, git }, job }`; `job` is the latest job with `state` (`running`, `succeeded`, `failed`, `cancelled`), `step`, `steps[]`, `notBefore`, `error` and the last 200 log lines |
| `POST /v1/update { target, notBefore? }` | 202 `{ job }`; 400 `BAD_TARGET` (not `<line>.<n>`) or `BAD_NOT_BEFORE` (unreadable, or more than 24 h away); 409 `UPDATE_IN_PROGRESS` |
| `POST /v1/rollback { notBefore? }` | 202 `{ job }`; 409 `NO_PREVIOUS_VERSION` or `UPDATE_IN_PROGRESS` |
| `POST /v1/cancel` | 200 `{ job }` before the restart step; 409 `TOO_LATE` or `NO_ACTIVE_JOB` |

## Security

The Docker socket is root on the host, so this service is as powerful as SSH
as root. It accepts only the four fixed actions above, only from a caller
with the secret, and only over the internal network. The admin panel
endpoints that call it require a super admin with write access, and every
call is in the API's audit log (`server_update_requested`,
`server_rollback_requested`, `server_update_cancelled`). Installs that would
rather not run it: `./configure.sh --no-updater` and update with
`./update.sh`.
