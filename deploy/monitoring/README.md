# Monitoring of an Ethora host

The monitoring stack of one server: what it runs is set by
`services.monitoring.mode` in `deploy.yml`, and `update.sh` starts it. A
separate compose project (`docker-compose.monitoring.yml`), so it never
touches the app deploy.

| Mode | On this host | Where to look |
|---|---|---|
| `off` | nothing | – |
| `local` | Prometheus, Grafana, cAdvisor, node_exporter, pm2-exporter (under pm2); VictoriaLogs + Vector with `logs.enabled` | `https://<uptime domain>/grafana/` (uptime basic-auth) |
| `remote` | cAdvisor, node_exporter, pm2-exporter (under pm2), Prometheus in agent mode; Vector with `logs.enabled` | the central monitoring server (`services.monitoring.remote.url`) |

`deploy.yml` files that still have `services.monitoring.enabled: true` run
the local mode.

## Local mode

```yaml
services:
  monitoring:
    mode: local
    alerts:
      emails: ops@example.com      # Grafana alert e-mails; empty = no e-mail
    screenshots: false             # panel screenshot in each e-mail (renderer container)
    logs:
      enabled: false               # VictoriaLogs + Vector on this host, 7 days
```

Needs `services.uptime`: the UIs are served on the uptime domain at
`/grafana/` and `/prometheus/` behind its basic-auth. Dashboards: **Ethora
Load Testing** (host and per-container CPU/memory next to the load tool's
RPS/latency/errors) and, with logs, **Ethora Logs** (service, level and
text filters; LogsQL in Explore, e.g. `service:backend AND level:error`).
Alerts (host CPU/memory, container CPU, API 5xx rate and latency, a pm2
process in a restart loop or left errored, pm2 metrics gone) go to the
addresses in `alerts.emails` through the Postmark token of
`integrations.postmark`, or through `alerts.smtp_*`.

## Remote mode

```yaml
services:
  monitoring:
    mode: remote
    remote:
      url: https://monitoring.example.com
      token: <token>               # from the central server's config (its tenants list)
      tenant: qa                   # this host's name on the central dashboards
    logs:
      enabled: true                # ship the logs too; false keeps them on-site
```

Only agents run here. The Prometheus agent scrapes the same targets as the
local mode and pushes every sample to `<url>/ingest/metrics` with
`Authorization: Bearer <token>`; it stamps the `tenant` label on all of
them, which is what the central dashboards and alerts group by. With
`logs.enabled`, Vector sends the lines to `<url>/ingest/logs/` with the same
token; the central server stamps the tenant on them itself. While the server
is unreachable the agent keeps up to four hours of samples and Vector a disk
buffer, both catch up afterwards.

Check on the host: `curl -s 127.0.0.1:9090/api/v1/targets | grep -o '"health":"[a-z]*"'`
lists the scrape targets, and
`docker logs ethora-prometheus-agent` / `docker logs ethora-vector` show
push errors (a 401 means the token is not the one the server has for this
host).

## Logs

Vector reads the output of every docker container and the pm2 log files of
the Node services (the API writes JSON lines, so their levels are exact).
For container output the level comes from a JSON field, a bracketed word,
logfmt `level=`, klog's leading letter or PostgreSQL's `WARNING:` /
`ERROR:` prefix; a line with none of these is info.
Every line gets the stream fields `source` (docker / pm2),
`service`, `stream` (out / error) and `level`; everything else stays text.
Vector keeps its read positions and a disk buffer in a volume, so restarts
neither lose nor repeat lines. On its very first start it tails the pm2
files from their end.

## Errors

The Node services (API, backend-jobs, backend-bc-worker, push, push-worker,
ai-service) and the web apps can report their exceptions to Bugsink on the
central monitoring server over the Sentry protocol. `services.monitoring.errors`
in `deploy.yml` holds one DSN per component (`api`, `push`, `ai`, `web`),
copied from the project pages on that server (one project per component and
server). An empty DSN keeps that component silent, which is the default; the
host's own `mode` does not matter.

An event always carries the exception with its stack trace and the source
lines around each frame, the service name, the release (the deploy's build
version) and commit, this host's tenant name (`services.monitoring.remote.tenant`,
else the API domain) as the environment and, for a request, the request id,
method, path, user id and app id. What else goes along is
`services.monitoring.errors.pii`:

- `true` (the default): the request's headers, cookies, query string and
  body (capped at 64 KB), the client IP and the user's e-mail, so an issue
  can be read without the server's logs;
- `false`: none of those; the request keeps its method and bare path, the
  user is an id, and JWT-looking strings and token query parameters in the
  error text are redacted before sending.

Reporting costs a normal request nothing: there is no per-request
middleware, one HTTPS request leaves per escaped error, and the central
server caps every project at 500 events per 5 minutes and 2000 per hour.

An install whose data must stay on-site leaves every DSN empty, the same
rule as `logs.enabled: false` in remote mode. A customer install that is
given a DSN runs with `pii: false`.

## Files

| Path | Role |
|---|---|
| `docker-compose.monitoring.yml` | all services; compose profiles `local`, `remote`, `victorialogs`, `logs`, `renderer` |
| `prometheus/scrape.yml` | the scrape jobs, shared by both modes |
| `prometheus/prometheus.yml` | the local Prometheus (15 days of data) |
| `prometheus/agent.yml.template` | the agent: tenant label and remote_write; rendered by `setup-nginx.sh` |
| `vector/vector.yaml` | Vector sources and transforms |
| `vector/sink-local.yaml`, `vector/sink-remote.yaml.template` | where Vector sends the lines, per mode |
| `grafana/` | provisioning (datasources, alerting) and dashboards of the local mode |
| `pm2-exporter/pm2-exporter.js` | CPU / memory / restarts per pm2 process, scrape job `pm2` on host port 9209; `setup-node-services.sh` starts it under pm2 with the mode, no dependencies |
| `.env` | written by `setup-nginx.sh` from `deploy.yml`: mode, profiles, alert settings, rendered config paths |

`setup-nginx.sh` renders the per-mode files into `deploy/generated/monitoring/`;
`update.sh` starts the profiles of the mode, removes containers of the other
mode, and restarts Prometheus, the agent, Grafana or Vector when their config
files changed.

## Manual use

For a load test on a box without `deploy.yml`:

```bash
COMPOSE_PROFILES=local docker compose -f deploy/monitoring/docker-compose.monitoring.yml up -d
# Grafana http://127.0.0.1:3001 (admin/admin unless GRAFANA_ADMIN_PASSWORD is set),
# Prometheus http://127.0.0.1:9090/prometheus/
docker compose -f deploy/monitoring/docker-compose.monitoring.yml down
```

The ports bind to loopback only; reach them through an SSH tunnel. The
`ethora_load` scrape job expects the uptime container on host port 8099.
The Node services run under pm2 on the host, so they are not containers in
cAdvisor: `pm2-exporter.js` reports their CPU / memory per process (panels
"PM2 — CPU % by process" and "PM2 — memory (MB) by process"), and their load is
part of the node_exporter **host** CPU/memory as well. The exporter answers
loopback and private-range clients only; keep port 9209 closed in the firewall.
