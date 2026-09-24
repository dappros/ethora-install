# Load-testing observability (Prometheus + Grafana)

Self-contained monitoring stack for load tests. Separate compose project — it
does NOT touch the app deploy (`update.sh`, nginx). Bring it up only when you
want resource graphs alongside a load run.

## What's in it

| Service | Port (host) | Role |
|---|---|---|
| Prometheus | 9090 | scrapes + stores metrics |
| Grafana | 3001 | dashboards (`Ethora / Ethora Load Testing`) |
| cAdvisor | 8081 | per-container CPU/mem/net/disk |
| node_exporter | 9100 | host CPU/mem/load/disk (covers backend pm2 + system) |

Prometheus also scrapes the load tool's own metrics from the uptime container's
host-published port (`host.docker.internal:8099/metrics`) — load RPS / latency /
errors / in-flight — so the dashboard overlays **load vs resources** on one
timeline.

## Bring up / tear down

```bash
cd <deploy root>          # the dir containing deploy/
# optional: set a real Grafana admin password
export GRAFANA_ADMIN_PASSWORD='choose-a-strong-one'
docker compose -f deploy/monitoring/docker-compose.monitoring.yml up -d

# stop
docker compose -f deploy/monitoring/docker-compose.monitoring.yml down
```

## Access

- Grafana: `http://<server-ip>:3001` (login `admin` / `$GRAFANA_ADMIN_PASSWORD`,
  default `admin`). Open dashboard **Ethora → Ethora Load Testing**.
- Prometheus: `http://<server-ip>:9090` (targets at `/targets`).

Ports 3001/9090 are not behind nginx — open them in the security group only to
your IP, or add an nginx vhost (e.g. `grafana.<stage>`) later. Anonymous access
is OFF.

## Workflow

1. Bring the stack up.
2. Open the Grafana dashboard, set the time range to "last 30m", refresh 5s.
3. Run a load test from `uptime.<stage>/load.html`.
4. Watch load RPS/latency/errors next to host CPU/mem and per-container CPU/mem —
   you can see *which* service saturates first.

## Notes / caveats

- This runs ON THE SAME box as the load target, so the monitoring containers add
  overhead and slightly skew numbers. For clean results, run Prometheus/Grafana
  on a separate host and point `prometheus.yml` at this box's published ports.
- The `ethora_load` scrape target assumes the uptime container publishes 8099 on
  the host (default). If your uptime port differs, edit `prometheus/prometheus.yml`.
- For deeper host/container views you can also import community dashboards in
  Grafana: **1860** (Node Exporter Full) and **14282** (cAdvisor) — both work
  with the provisioned Prometheus datasource.
- The backend runs under pm2 on the host (not a container), so it does not appear
  in cAdvisor. Its load shows up in the node_exporter **host** CPU/mem.
