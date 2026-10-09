# Licensing

How Ethora license keys work, what operators see in each state, and how keys
are issued. Introduced in the `2610` line.

The mechanism is deliberately small: one signed key, three states, no
network required to verify. Everything an operator needs is in `deploy.yml`
or on the admin panel License page.

## The key

A license key is a single line of text:

```
ETHORA1.<payload>.<signature>
```

The payload is JSON, base64url-encoded, signed with Ed25519. The backend
verifies the signature against public keys compiled into the build, so an
air-gapped install validates keys with zero network access. A key cannot be
forged or altered without the private signing key, which is never shipped.

Payload fields:

| Field | Meaning |
|---|---|
| `lid` | License id, e.g. `L-2026-0142` |
| `customer` | Display name shown on the License page |
| `domain` | Parent domain the install must live under (see below) |
| `iat` / `exp` | Issued-at and expiry, unix seconds |
| `tier` | Free-form label such as `trial` or `enterprise` |
| `features` | Feature ids enabled by this key, or `["*"]` for everything |
| `limits` | Optional caps: `apps`, `users`, `instances` |
| `offline` | `true` for air-gapped installs that never call home |

Feature ids the backend understands: `ai`, `b2b`, `compliance`, `analytics`.
A key without a `features` field enables everything.

### Domain binding

The key names a parent domain. Every host configured under `domains:` in
`deploy.yml` (api, web, xmpp, files) must be that domain or a subdomain of it.
A key for `customer.com` therefore covers `dev.chat.customer.com`,
`qa.chat.customer.com` and `prod.chat.customer.com` alike, which is what makes
dev, qa and prod under one second-level domain a single license. A different
second-level domain needs a different key.

`localhost`, `127.0.0.1` and `*.test.ethora.com` always pass, so developer
machines, CI and QA never fight the check.

## States

There is no expiry for the free editions and nothing is ever locked. A key
only adds entitlements; without one the install is Ethora Core.

| State | When | What happens |
|---|---|---|
| `unlicensed` | No valid key ("no key", malformed, bad signature, wrong domain), or a key whose grace ran out | **Ethora Core, unregistered**: Core features, 5 apps and 500 user accounts per server, no countdown, no banner, nothing locked. The reason is shown on the License page so a rejected key is visible. |
| `licensed` | Valid signature, domain matches, before `exp`, call-home fresh | The key's tier, features and limits (below) |
| `grace` | The key expired less than 14 days ago, or an online key has not reached its license server for 30 days | The key's entitlements are kept. Yellow banner for admins, daily operator e-mail if outbound e-mail is configured, `X-Ethora-License: grace` on every response. When the grace ends the install continues as Core. |

### Editions (tiers)

| Tier | How you get it | Features | Apps per server | User accounts per server | Expiry |
|---|---|---|---|---|---|
| `core` (unregistered) | nothing to do | `core` | 5 | 500 | never |
| `core-registered` | free: admin panel License page, "Register", or `POST /v1/register` on the license server; key tier `core` | `core` | 10 | 5,000 | never (key is issued for 100 years) |
| `trial` | 14-day enterprise trial key | what the key lists (`*`) | unlimited | unlimited | key `exp`, then 14 days grace, then Core |
| `enterprise` | any other key | what the key lists | unlimited unless the key sets `limits` | unlimited unless the key sets `limits` | key `exp`, then 14 days grace, then Core |

A key's own `limits` always win over the tier defaults, so an enterprise
contract can cap a server and a Core key can be issued with other numbers.
A `core` key never grants more than the `core` feature, whatever its
`features` field says.

The caps apply to creation only: creating an app (`POST /v2/apps` and the
v1 route) and creating a user account (self sign-up, `POST /v2/users/batch`,
`POST /v2/apps/:appId/users/batch`) return `403 LICENSE_LIMIT_REACHED` with
`details.kind`, `limit`, `current` and `upgrade` (`register` for an
unregistered install, `enterprise` otherwise) once the count is at the cap.
Existing apps, users, logins, chat, files and every other endpoint are never
affected. Users are counted with `estimatedDocumentCount` and cached for 15
seconds, so a burst of sign-ups can overshoot the cap by a few accounts.

`GET /v2/license` reports `tier`, `limits` and `usage` (counts against the
caps) next to the state, which is what the License page and the footer show.

The grace length can be changed per install with `license.grace_days`.

## Where the key comes from

Two sources, in order of precedence:

1. `deploy.yml` `license.key` (or `license.key_file`), rendered into the
   backend env as `ETHORA_LICENSE_KEY`. Removing it from `deploy.yml` removes
   it on the next update.
2. The admin panel License page (`/app/admin/license`), where a super admin
   can paste a key. It is stored in Mongo (`installSettings`) and survives
   updates. A key from `deploy.yml` takes precedence over it.

Keys are also refreshed automatically by call-home when a license server is
configured (see below), so an online customer never handles a key after the
first one.

```yaml
license:
  key: "ETHORA1...."   # or:
  key_file: /home/ubuntu/ethora-license.txt
  call_home: true
  server_url: ""       # license server base URL; empty = no call-home
  grace_days: ""       # override the 14-day default
```

`deploy/scripts/validate.sh` refuses a key that does not look like a key, a
`key_file` that does not exist, and a non-URL `server_url`.

## What operators see

- **Admin panel.** A banner at the top of every page for admins on the base
  app while the install is in grace or restricted, with a link to the License
  page. The License page shows state, reason, licensed customer and domain,
  expiry, grace end, enabled features, configured hosts, last license server
  contact and the instance id, and lets a super admin apply or remove a key.
- **Email.** Once a day at 09:00 server time while not licensed, to the
  platform account and base app owner addresses, if `features.postmark` is on.
- **Terminal.** `deploy/scripts/health-check.sh` (run by install and update)
  prints the license line, so every deploy ends with the current state.
- **API.** Every response carries `X-Ethora-License: licensed|grace|restricted`
  and, when not licensed, `X-Ethora-License-Grace-Ends`. `GET /ping` and
  `GET /v1/ping` include a `license` summary without authentication.
  `GET /v2/license` returns the full status to any authenticated user.

## Call-home and air-gapped installs

When `license.server_url` is set and `license.call_home` is true, the jobs
process posts a heartbeat once a day (and once shortly after boot): instance
id, license id, configured hosts, state, version, and app/user counts. The
server may answer with a refreshed key, which is stored if it verifies. A key
that is not marked `offline` must have reached the server within 30 days,
otherwise the install drops to grace; this is only enforced when a server URL
is configured.

Air-gapped customers set `call_home: false` and receive a key signed with
`offline: true`, typically for 12 months. No outbound attempt is ever made.

The server side lives in the private `dappros/ethora-license-server` repo:
heartbeat handling with instance counting, self-service trials (one per
domain and per email), and a bearer-token admin API for creating, renewing,
suspending and issuing keys. Its README carries the request and response
contract and curl examples. It holds the private signing key; the backend
only ever holds the public one.

Instance counting for `limits.instances` only works through call-home. Each
install generates a random instance id on first boot and keeps it in Mongo.

### Registry credential for the Enterprise module images

The Enterprise modules (AI first; push, playground and MCP follow) run from
private images on Docker Hub (`dappros/ethora-ai` and so on). Each customer
gets its own pull credential: an organisation access token on Docker Hub
with Image Pull on the module repositories, created per customer (or per
plan tier) and stored on the license with the admin API
(`PATCH /v1/admin/licenses/:lid {"registry": {"username": "dappros",
"token": "dckr_oat_..."}}`). Every heartbeat of a license in good standing
carries it; the install keeps it next to the key and the License page shows
it to super admins with the `docker login` command. Revoking a customer's
access is deleting the token on Docker Hub and clearing it on the license;
the install forgets it on its next heartbeat. Air-gapped customers receive
the token from sales with their offline key. Core installs never get one.

## Registration, trials and anti-abuse, honestly

Registering is one request from the admin panel (super admin): the backend
derives the install's parent domain from the configured hosts
(`api.chat.example.com` + `app.chat.example.com` gives `chat.example.com`),
sends it with the operator's e-mail to `license.ethora.com/v1/register`
(or `license.server_url` when set) and stores the returned key. Nothing
else is sent, and registration does not switch call-home on. One
registration per domain: the same e-mail gets the key re-issued (reinstalls),
another e-mail is refused. Installs without a public hostname (`localhost`,
`*.test.ethora.com`) cannot register; they get an enterprise or internal key
instead.

The caps are per server and the free tiers never expire, so there is no
clock to game. Someone splitting one product across many servers to stay
under 500 users per server is not a customer worth chasing, and nothing
client-side can stop them anyway. The backend still records the highest
wall-clock time it has seen and refuses to evaluate a key at an earlier
time, so setting the clock back does not extend an enterprise key.

Proper trials are enterprise keys issued for a domain with a short expiry
(`/trial` on the license server, one per domain and per e-mail). The license
server is the place to refuse a second trial for the same domain.

## Issuing keys

Tools live in `ethora-backend/services/api/tools/license/`. The private
signing key is not in any repository; the tools read it from
`ETHORA_LICENSE_PRIVATE_KEY_FILE`.

```bash
cd ethora-backend/services/api
ETHORA_LICENSE_PRIVATE_KEY_FILE=~/k/ethora-license/signing-key.pem \
node tools/license/sign.js --lid L-2026-0001 --customer "Example Ltd" \
  --domain example.com --days 90 --features ai,b2b,compliance --limits apps=50,instances=3

node tools/license/inspect.js "ETHORA1...."     # verify against this build's public keys
```

Rotation: add the new public key to `TRUSTED_PUBLIC_KEYS` in
`src/modules/license/constants.js` alongside the old one, ship that build,
then start signing with the new private key. Keys signed under the old one
keep verifying until they expire.

## Engineering reference

- Module: `ethora-backend/services/api/src/modules/license/`
  - `keyFormat.js` sign/parse, `domain.js` host matching, `state.js` the pure
    state machine, `store.js` Mongo persistence via `installSettings`,
    `service.js` process-wide singleton, `middleware.js` header and gates,
    `cron.js` call-home and notices, `controllers/` the `/v2/license` routes.
  - Unit tests next to each file; run with `npm run test:modules`.
- Gates wired today: `POST /v1/apps`, `POST /v2/apps` (`createApps`, also
  enforces `limits.apps`), `POST /v2/apps/:appId/users/batch` (`createUsers`),
  `POST /v2/agents` (feature `ai`).
- To gate another route: `licenseRestrictMw('createApps' | 'createUsers')`
  or `requireLicensedFeatureMw('<feature>')` from `modules/license/middleware`.
  To gate a code path: `licenseService.hasFeature('<feature>')`.
