#!/usr/bin/env node
// Ethora.com platform, copyright: Dappros Ltd (c) 2026, all rights reserved
//
// pm2-exporter.js - Prometheus metrics for the Node services that run under
// pm2 on the host (backend, backend-jobs, backend-bc-worker, push,
// push-worker, ai-service, frontend, ...).
//
// cAdvisor sees containers and node_exporter sees the host as a whole; the
// pm2 processes are neither, so their CPU and memory per process come from
// pm2 itself (`pm2 jlist`). setup-node-services.sh starts this file under pm2
// as `pm2-exporter` when services.monitoring.mode is local or remote, and
// prometheus/scrape.yml scrapes it as job `pm2` on host port 9209. The Grafana
// panels "PM2 - CPU % by process" and "PM2 - memory (MB) by process" read it.
//
// No dependencies: Node's http module and the pm2 CLI of the same user.
// `pm2 jlist` is cached for PM2_EXPORTER_CACHE_MS, so a scrape every few
// seconds costs one pm2 call per window.
//
// Env: PM2_EXPORTER_PORT (9209), PM2_EXPORTER_BIND (0.0.0.0),
//      PM2_EXPORTER_CACHE_MS (5000), PM2_BIN (pm2)
//
// Prometheus reaches the host from the docker bridge, so the port is bound on
// all interfaces like the API port; only loopback and private-range clients
// are answered, everything else gets 403. Keep 9209 closed in the firewall.
//
// By hand:  curl -s http://127.0.0.1:9209/metrics
//           node pm2-exporter.js --print        (one refresh, no server)
'use strict'

const http = require('http')
const { execFile } = require('child_process')

const PORT = Number(process.env.PM2_EXPORTER_PORT) || 9209
const BIND = process.env.PM2_EXPORTER_BIND || '0.0.0.0'
const CACHE_MS = Number(process.env.PM2_EXPORTER_CACHE_MS) || 5000
const PM2_BIN = process.env.PM2_BIN || 'pm2'

// ---------------------------------------------------------------- pm2
function pm2List() {
  return new Promise((resolve, reject) => {
    const opts = { timeout: 15000, maxBuffer: 16 * 1024 * 1024, env: { ...process.env, PM2_SILENT: 'true' } }
    execFile(PM2_BIN, ['jlist'], opts, (err, stdout) => {
      if (err) return reject(err)
      // Some pm2 versions print notices before the JSON; take the array itself.
      const text = String(stdout)
      const start = text.indexOf('[')
      const end = text.lastIndexOf(']')
      if (start < 0 || end < start) return reject(new Error('pm2 jlist: no JSON array in the output'))
      try {
        resolve(JSON.parse(text.slice(start, end + 1)))
      } catch (e) {
        reject(new Error('pm2 jlist: ' + e.message))
      }
    })
  })
}

let cache = { at: 0, text: '', pending: null }

async function refresh() {
  const started = Date.now()
  let list = []
  let ok = 1
  try {
    list = await pm2List()
  } catch (e) {
    ok = 0
    console.error('[pm2-exporter] ' + (e && e.message ? e.message : e))
  }
  return render(list, ok, (Date.now() - started) / 1000)
}

function metrics() {
  const now = Date.now()
  if (cache.text && now - cache.at < CACHE_MS) return Promise.resolve(cache.text)
  if (!cache.pending) {
    cache.pending = refresh().then(
      (text) => {
        cache = { at: Date.now(), text, pending: null }
        return text
      },
      (e) => {
        cache.pending = null
        throw e
      },
    )
  }
  return cache.pending
}

// ---------------------------------------------------------------- format
function esc(value) {
  return String(value).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n')
}

function labels(obj) {
  return '{' + Object.entries(obj).map(([k, v]) => `${k}="${esc(v)}"`).join(',') + '}'
}

function num(value) {
  const n = Number(value)
  return Number.isFinite(n) ? n : 0
}

// `list` is the parsed output of `pm2 jlist`. Exported so the format can be
// checked without pm2 (node -e "require('./pm2-exporter').render(sample)").
function render(list, ok = 1, duration = 0, now = Date.now()) {
  const rows = Array.isArray(list) ? list : []
  const out = []
  const family = (name, type, help, lines) => {
    out.push(`# HELP ${name} ${help}`, `# TYPE ${name} ${type}`, ...lines)
  }
  const id = (p) => ({ name: p.name || '', pm_id: p.pm_id === undefined || p.pm_id === null ? '' : p.pm_id })
  const env = (p) => p.pm2_env || {}
  const monit = (p) => p.monit || {}
  const online = (p) => env(p).status === 'online'

  family('pm2_process_cpu_percent', 'gauge', 'CPU usage of the process as pm2 reports it (percent of one core).',
    rows.map((p) => `pm2_process_cpu_percent${labels(id(p))} ${num(monit(p).cpu)}`))
  family('pm2_process_memory_bytes', 'gauge', 'Resident memory of the process in bytes.',
    rows.map((p) => `pm2_process_memory_bytes${labels(id(p))} ${num(monit(p).memory)}`))
  family('pm2_process_up', 'gauge', '1 when pm2 reports the process online, 0 otherwise.',
    rows.map((p) => `pm2_process_up${labels(id(p))} ${online(p) ? 1 : 0}`))
  family('pm2_process_restarts_total', 'counter', 'Restarts since the process was added to pm2.',
    rows.map((p) => `pm2_process_restarts_total${labels(id(p))} ${num(env(p).restart_time)}`))
  family('pm2_process_unstable_restarts_total', 'counter', 'Restarts pm2 counted as unstable (crash loops).',
    rows.map((p) => `pm2_process_unstable_restarts_total${labels(id(p))} ${num(env(p).unstable_restarts)}`))
  family('pm2_process_uptime_seconds', 'gauge', 'Seconds since the last (re)start; 0 when not online.',
    rows.map((p) => {
      const since = num(env(p).pm_uptime)
      const up = online(p) && since > 0 ? Math.max(0, Math.floor((now - since) / 1000)) : 0
      return `pm2_process_uptime_seconds${labels(id(p))} ${up}`
    }))
  family('pm2_process_info', 'gauge', 'Process details as labels: status, exec_mode, node_version, version.',
    rows.map((p) => {
      const e = env(p)
      return `pm2_process_info${labels({ ...id(p), status: e.status || '', exec_mode: e.exec_mode || '', node_version: e.node_version || '', version: e.version || '' })} 1`
    }))
  family('pm2_exporter_up', 'gauge', '1 when the last pm2 jlist succeeded.', [`pm2_exporter_up ${ok}`])
  family('pm2_exporter_refresh_duration_seconds', 'gauge', 'Time the last pm2 jlist took.', [`pm2_exporter_refresh_duration_seconds ${duration}`])
  family('pm2_exporter_processes', 'gauge', 'Processes pm2 listed on the last refresh.', [`pm2_exporter_processes ${rows.length}`])
  return out.join('\n') + '\n'
}

// ---------------------------------------------------------------- http
// Loopback, RFC 1918 ranges (docker bridges and VPCs live there) and IPv6
// loopback / unique-local addresses.
const PRIVATE_CLIENT = /^(127\.|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|::1$|f[cd][0-9a-f]{2}:)/i

function allowed(address) {
  return PRIVATE_CLIENT.test(String(address || '').replace(/^::ffff:/i, ''))
}

function serve(req, res) {
  if (!allowed(req.socket && req.socket.remoteAddress)) {
    res.writeHead(403, { 'Content-Type': 'text/plain' })
    return res.end('forbidden\n')
  }
  const path = String(req.url || '/').split('?')[0]
  if (path === '/health') {
    res.writeHead(200, { 'Content-Type': 'text/plain' })
    return res.end('ok\n')
  }
  if (path !== '/metrics') {
    res.writeHead(404, { 'Content-Type': 'text/plain' })
    return res.end('not found\n')
  }
  metrics().then(
    (text) => {
      res.writeHead(200, { 'Content-Type': 'text/plain; version=0.0.4; charset=utf-8' })
      res.end(text)
    },
    (e) => {
      res.writeHead(500, { 'Content-Type': 'text/plain' })
      res.end('pm2 jlist failed: ' + (e && e.message ? e.message : e) + '\n')
    },
  )
}

if (require.main === module) {
  if (process.argv.includes('--print')) {
    refresh().then((text) => {
      process.stdout.write(text)
      process.exit(0)
    })
  } else {
    http.createServer(serve).listen(PORT, BIND, () => {
      console.log(`[pm2-exporter] listening on ${BIND}:${PORT}, pm2 jlist cached ${CACHE_MS} ms`)
    })
  }
}

module.exports = { render, allowed }
