// Ethora.com platform, copyright: Dappros Ltd (c) 2026, all rights reserved
//
// updater: the compose bundle's update service (profile `updater`). The API
// calls it over the compose network for the admin panel's "Update now" and
// "Roll back"; it publishes no port. It starts ../update.sh in a one-off
// container of its own image (ethora-update-job), so the update keeps going
// while `docker compose up -d` recreates this service, and reads the job's
// progress back from <bundle>/.update/. Contract: README.md next to this file.
//
// Env: UPDATER_SECRET (required; every /v1 call sends it as X-Updater-Secret),
// UPDATER_IMAGE (this image, for the job container), ETHORA_HOST_ROOT and
// ETHORA_BUNDLE_DIR (host paths, mounted at the same paths here),
// ETHORA_DOCKER_CONFIG (the host's docker login, for private module images),
// PORT (8090).
'use strict'
const http = require('http')
const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const { execFile } = require('child_process')

const PORT = Number(process.env.PORT || 8090)
const SECRET = process.env.UPDATER_SECRET || ''
const IMAGE = process.env.UPDATER_IMAGE || ''
const ROOT = process.env.ETHORA_HOST_ROOT || '/opt/ethora'
const BUNDLE = process.env.ETHORA_BUNDLE_DIR || path.join(ROOT, 'deploy/compose')
const DOCKER_CONFIG = process.env.ETHORA_DOCKER_CONFIG || '/root/.docker'
const STATE_DIR = path.join(BUNDLE, '.update')
const JOB_NAME = 'ethora-update-job'
const BUILD_RE = /^\d{4}\.\d+$/
const BEFORE_RESTART = new Set(['bundle', 'configure', 'pull', 'waiting'])

const run = (cmd, args, opts = {}) =>
  new Promise((resolve) => {
    execFile(cmd, args, { cwd: BUNDLE, timeout: 20000, maxBuffer: 4 << 20, ...opts }, (err, stdout, stderr) =>
      resolve({ ok: !err, code: err ? err.code : 0, out: String(stdout || '').trim(), err: String(stderr || '').trim() })
    )
  })

const readText = (f) => {
  try { return fs.readFileSync(f, 'utf8') } catch { return null }
}
const envValue = (key) => {
  const text = readText(path.join(BUNDLE, '.env')) || ''
  let v = null
  for (const line of text.split('\n')) {
    if (line.startsWith(key + '=')) v = line.slice(key.length + 1).replace(/^'(.*)'$/, '$1')
  }
  return v || null
}
const tail = (f, n) => {
  const t = readText(f)
  if (!t) return []
  return t.replace(/\x1b\[[0-9;]*[A-Za-z]/g, '').split('\n').filter(Boolean).slice(-n)
}

// The job is alive while it holds .update/lock (flock works across
// containers on the same bind-mounted file).
async function jobAlive() {
  const lock = path.join(STATE_DIR, 'lock')
  if (!fs.existsSync(lock)) return false
  const r = await run('flock', ['-n', lock, 'true'])
  return !r.ok
}

let runningCache = { at: 0, value: null }
async function runningBuild() {
  if (Date.now() - runningCache.at < 10000) return runningCache.value
  let value = null
  const ps = await run('docker', ['compose', 'ps', '-q', 'api'])
  const id = ps.ok ? ps.out.split('\n')[0] : ''
  if (id) {
    const r = await run('docker', ['inspect', '--format', '{{index .Config.Labels "org.opencontainers.image.version"}}', id])
    if (r.ok && BUILD_RE.test(r.out)) value = r.out
  }
  runningCache = { at: Date.now(), value }
  return value
}

async function readJob() {
  const raw = readText(path.join(STATE_DIR, 'state.json'))
  if (!raw) return null
  let job
  try { job = JSON.parse(raw) } catch { return null }
  if ((job.state === 'running' || job.state === 'scheduled') && !(await jobAlive())) {
    job.state = 'failed'
    job.error = job.error || 'the update job stopped unexpectedly; see the log'
  }
  job.log = tail(path.join(STATE_DIR, 'job.log'), 200)
  return job
}

async function status() {
  const tag = envValue('ETHORA_TAG')
  const running = await runningBuild()
  const commit = await run('git', ['-C', BUNDLE, 'rev-parse', '--short', 'HEAD'])
  const previous = (readText(path.join(STATE_DIR, 'previous')) || '').trim()
  const line = (tag || running || '').split('.')[0] || null
  return {
    ok: true,
    line,
    tag,
    running,
    previous: BUILD_RE.test(previous) ? previous : null,
    bundle: { commit: commit.ok ? commit.out : null, git: commit.ok },
    job: await readJob(),
  }
}

async function startJob(args) {
  if (await jobAlive()) return { code: 409, body: { code: 'UPDATE_IN_PROGRESS', error: 'An update is already running' } }
  if (!IMAGE) return { code: 500, body: { code: 'UPDATER_MISCONFIGURED', error: 'UPDATER_IMAGE is not set' } }
  await run('docker', ['rm', '-f', JOB_NAME])
  const id = 'u-' + new Date().toISOString().replace(/[-:]/g, '').replace(/\..*/, '').replace('T', '-')
  const r = await run('docker', [
    'run', '-d', '--rm', '--name', JOB_NAME, '--label', 'com.ethora.update-job=1',
    '-v', '/var/run/docker.sock:/var/run/docker.sock',
    '-v', `${ROOT}:${ROOT}`,
    '-v', `${DOCKER_CONFIG}:/root/.docker`,
    '-w', BUNDLE,
    '-e', 'ETHORA_UPDATE_RUNNER=container',
    IMAGE, 'bash', path.join(BUNDLE, 'update.sh'), '--yes', '--job-id', id, ...args,
  ], { timeout: 60000 })
  if (!r.ok) return { code: 500, body: { code: 'JOB_START_FAILED', error: (r.err || r.out).slice(0, 500) } }
  // update.sh writes state.json as soon as it holds the lock.
  for (let i = 0; i < 20; i++) {
    const job = await readJob()
    if (job && job.id === id) return { code: 202, body: { job } }
    await new Promise((res) => setTimeout(res, 250))
  }
  return { code: 202, body: { job: { id, state: 'running', step: null, steps: [], log: [] } } }
}

function notBeforeArg(body) {
  if (!body.notBefore) return { args: [] }
  const t = Date.parse(body.notBefore)
  if (Number.isNaN(t)) return { error: 'notBefore is not a date' }
  if (t > Date.now() + 24 * 3600 * 1000) return { error: 'notBefore is more than 24 hours away' }
  return { args: ['--at', String(Math.floor(t / 1000))] }
}

async function handle(req, body) {
  const url = req.url.split('?')[0]
  if (req.method === 'GET' && url === '/v1/status') return { code: 200, body: await status() }
  if (req.method === 'POST' && url === '/v1/update') {
    if (!BUILD_RE.test(String(body.target || ''))) return { code: 400, body: { code: 'BAD_TARGET', error: 'target must look like 2610.80' } }
    const nb = notBeforeArg(body)
    if (nb.error) return { code: 400, body: { code: 'BAD_NOT_BEFORE', error: nb.error } }
    return startJob(['--to', body.target, ...nb.args])
  }
  if (req.method === 'POST' && url === '/v1/rollback') {
    const previous = (readText(path.join(STATE_DIR, 'previous')) || '').trim()
    if (!BUILD_RE.test(previous)) return { code: 409, body: { code: 'NO_PREVIOUS_VERSION', error: 'There is no earlier build to roll back to' } }
    const nb = notBeforeArg(body)
    if (nb.error) return { code: 400, body: { code: 'BAD_NOT_BEFORE', error: nb.error } }
    return startJob(['--rollback', ...nb.args])
  }
  if (req.method === 'POST' && url === '/v1/cancel') {
    const job = await readJob()
    if (!job || !(job.state === 'running' || job.state === 'scheduled')) return { code: 409, body: { code: 'NO_ACTIVE_JOB', error: 'No update is running' } }
    if (!BEFORE_RESTART.has(job.step)) return { code: 409, body: { code: 'TOO_LATE', error: 'The services are already restarting' } }
    fs.writeFileSync(path.join(STATE_DIR, 'cancel'), new Date().toISOString())
    return { code: 200, body: { job } }
  }
  return { code: 404, body: { code: 'NOT_FOUND' } }
}

function authorized(req) {
  const given = Buffer.from(String(req.headers['x-updater-secret'] || ''))
  const want = Buffer.from(SECRET)
  return given.length === want.length && crypto.timingSafeEqual(given, want)
}

const server = http.createServer((req, res) => {
  const send = (code, body) => {
    res.writeHead(code, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' })
    res.end(JSON.stringify(body))
  }
  if (req.url === '/healthz') return send(200, { ok: true })
  if (!SECRET) return send(503, { code: 'UPDATER_NOT_CONFIGURED', error: 'UPDATER_SECRET is not set (re-run ./configure.sh)' })
  if (!authorized(req)) return send(401, { code: 'UNAUTHORIZED' })
  let raw = ''
  req.on('data', (c) => { raw += c; if (raw.length > 10000) req.destroy() })
  req.on('end', async () => {
    let body = {}
    if (raw) { try { body = JSON.parse(raw) } catch { return send(400, { code: 'BAD_JSON' }) } }
    try {
      const r = await handle(req, body)
      if (req.method === 'POST' && r.code < 300) console.log(`[updater] ${req.url} ${JSON.stringify(body)} -> ${r.code}`)
      send(r.code, r.body)
    } catch (e) {
      console.error('[updater]', e)
      send(500, { code: 'UPDATER_ERROR', error: String(e.message || e).slice(0, 300) })
    }
  })
})

if (require.main === module) {
  server.listen(PORT, () => console.log(`[updater] listening on :${PORT}, bundle ${BUNDLE}${SECRET ? '' : ' (UPDATER_SECRET missing: every call is refused)'}`))
  for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => server.close(() => process.exit(0)))
}
module.exports = { server, handle, status }
