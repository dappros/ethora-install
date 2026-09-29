#!/usr/bin/env node
// Ethora first-boot setup, web skin.
//
// One page, six questions, no dependencies. Collects the same answers as
// deploy/scripts/setup.sh, calls it in --yes mode, then runs install.sh --yes
// and streams the log. After a successful install it writes a marker and
// exits, and the systemd unit's ConditionPathExists keeps it from ever
// starting again. It never exposes the generated deploy.yml or secrets.
//
// Env:
//   ETHORA_SOURCE_ROOT   monoserver checkout (default: two levels up from here)
//   SETUP_PORT           default 8888
//   SETUP_BIND           default 0.0.0.0
//   SETUP_PASSWORD       basic-auth password; default: EC2 instance id via IMDSv2,
//                        else a random one printed to the journal
//   SETUP_USER           basic-auth user (default "admin")
//   SETUP_TLS_CERT/KEY   serve https when both are set
//   SETUP_DONE_FILE      marker written on success (default /etc/ethora/setup-done)
//   SETUP_LOG            default /var/log/ethora-setup.log
//   SETUP_DEFAULT_MODE   source | image, prefills the run-mode fields (default image)
//   SETUP_DRY_RUN=1      test hook: run setup.sh --dry-run and skip install.sh
'use strict'
const http = require('http')
const https = require('https')
const fs = require('fs')
const path = require('path')
const crypto = require('crypto')
const { spawn, execFileSync } = require('child_process')

const SOURCE_ROOT = process.env.ETHORA_SOURCE_ROOT || path.resolve(__dirname, '..', '..')
const SETUP_SH = path.join(SOURCE_ROOT, 'deploy', 'scripts', 'setup.sh')
const INSTALL_SH = path.join(SOURCE_ROOT, 'deploy', 'scripts', 'install.sh')
const CONFIG_FILE = path.join(SOURCE_ROOT, 'deploy', 'config', 'deploy.yml')
const PORT = parseInt(process.env.SETUP_PORT || '8888', 10)
const BIND = process.env.SETUP_BIND || '0.0.0.0'
const USER = process.env.SETUP_USER || 'admin'
const DONE_FILE = process.env.SETUP_DONE_FILE || '/etc/ethora/setup-done'
const LOG_FILE = process.env.SETUP_LOG || '/var/log/ethora-setup.log'
const DEFAULT_MODE = process.env.SETUP_DEFAULT_MODE || 'image'
const DRY_RUN = process.env.SETUP_DRY_RUN === '1'

// ------------------------------------------------------------ password ----
async function imdsInstanceId() {
  const req = (opts, body) =>
    new Promise((resolve, reject) => {
      const r = http.request({ host: '169.254.169.254', timeout: 1500, ...opts }, (res) => {
        let buf = ''
        res.on('data', (c) => (buf += c))
        res.on('end', () => resolve(res.statusCode === 200 ? buf : null))
      })
      r.on('error', reject)
      r.on('timeout', () => r.destroy(new Error('timeout')))
      if (body) r.write(body)
      r.end()
    })
  try {
    const token = await req({ method: 'PUT', path: '/latest/api/token', headers: { 'X-aws-ec2-metadata-token-ttl-seconds': '60' } })
    if (!token) return null
    return await req({ method: 'GET', path: '/latest/meta-data/instance-id', headers: { 'X-aws-ec2-metadata-token': token } })
  } catch (_) {
    return null
  }
}

let PASSWORD = process.env.SETUP_PASSWORD || ''
let passwordSource = 'SETUP_PASSWORD'

function checkAuth(req) {
  const h = req.headers.authorization || ''
  if (!h.startsWith('Basic ')) return false
  const [u, p] = Buffer.from(h.slice(6), 'base64').toString('utf8').split(':')
  const a = Buffer.from(`${u}:${p}`)
  const b = Buffer.from(`${USER}:${PASSWORD}`)
  return a.length === b.length && crypto.timingSafeEqual(a, b)
}

// ----------------------------------------------------------------- state ----
const state = { phase: 'idle', startedAt: null, finishedAt: null, exitCode: null, error: null, appUrl: null, adminPassword: null }
let child = null
const logListeners = new Set()

function appendLog(chunk) {
  try { fs.appendFileSync(LOG_FILE, chunk) } catch (_) {}
  for (const res of logListeners) res.write(`data: ${JSON.stringify(chunk)}\n\n`)
}

function existingAnswers() {
  // Prefill from an existing deploy.yml via yq when present (best effort).
  if (!fs.existsSync(CONFIG_FILE)) return {}
  const get = (p) => {
    try { const v = execFileSync('yq', ['eval', `${p} // ""`, CONFIG_FILE], { encoding: 'utf8' }).trim(); return v === 'null' ? '' : v } catch (_) { return '' }
  }
  const web = get('.domains.web')
  return {
    domain: web.startsWith('app.') ? web.slice(4) : web,
    admin_email: get('.admin.email'),
    display_name: get('.base_app.display_name'),
    license_key: get('.license.key'),
    ssl: get('.ssl.method'),
    ai: get('.features.ai_service') === 'true' ? 'on' : 'off',
    blockchain: get('.features.blockchain') === 'true' ? 'on' : 'off',
    uptime: get('.services.uptime.enabled') === 'false' ? 'off' : 'on',
    hosted_apps: get('.domains.hosted_apps_root'),
    backend_mode: get('.services.backend.mode') || DEFAULT_MODE,
    frontend_mode: get('.services.frontend.mode') || DEFAULT_MODE,
    target: get('.paths.base'),
  }
}

// ---------------------------------------------------------------- run ----
function startSetup(a) {
  if (state.phase === 'running') return { ok: false, error: 'an install is already running' }
  // Single use: once an install completed, this page must never run
  // another (a second submit would reconfigure a live server). Changes go
  // through deploy.yml and update.sh over SSH from here on.
  if (fs.existsSync(DONE_FILE)) return { ok: false, error: 'setup already completed on this server; further changes: edit deploy/config/deploy.yml and run update.sh over SSH' }
  // No --force: an existing deploy.yml (a retry after a failed install) is
  // reconfigured with its secrets kept by setup.sh itself.
  const args = ['--yes', '--out', CONFIG_FILE]
  const s = (v) => (typeof v === 'string' ? v.trim() : '')
  if (a.import_yaml && s(a.import_yaml)) {
    const tmp = path.join(require('os').tmpdir(), `ethora-import-${process.pid}.yml`)
    fs.writeFileSync(tmp, s(a.import_yaml), { mode: 0o600 })
    args.push('--from', tmp)
  } else if (fs.existsSync(CONFIG_FILE)) {
    args.push('--from', CONFIG_FILE)
  }
  if (s(a.domain)) args.push('--domain', s(a.domain))
  if (s(a.admin_email)) args.push('--admin-email', s(a.admin_email))
  if (s(a.admin_password)) args.push('--admin-password', s(a.admin_password))
  if (s(a.display_name)) args.push('--display-name', s(a.display_name))
  if (s(a.license_key)) args.push('--license-key', s(a.license_key))
  if (s(a.license_server)) args.push('--license-server', s(a.license_server))
  if (a.call_home === 'off') args.push('--no-call-home')
  if (s(a.ssl)) args.push('--ssl', s(a.ssl))
  if (s(a.cert)) args.push('--cert', s(a.cert))
  if (s(a.key)) args.push('--key', s(a.key))
  if (s(a.ai)) args.push('--ai', s(a.ai))
  if (s(a.ai_key)) args.push('--ai-key', s(a.ai_key))
  if (s(a.ai_url)) args.push('--ai-url', s(a.ai_url))
  if (s(a.blockchain)) args.push('--blockchain', s(a.blockchain))
  if (s(a.uptime)) args.push('--uptime', s(a.uptime))
  if (s(a.hosted_apps)) args.push('--hosted-apps', s(a.hosted_apps))
  if (s(a.backend_mode)) args.push('--backend-mode', s(a.backend_mode))
  if (s(a.frontend_mode)) args.push('--frontend-mode', s(a.frontend_mode))
  if (s(a.api_image)) args.push('--api-image', s(a.api_image))
  if (s(a.frontend_image)) args.push('--frontend-image', s(a.frontend_image))
  if (s(a.target)) args.push('--target', s(a.target))
  if (a.local === 'on') args.push('--local')
  if (DRY_RUN) args.push('--dry-run')
  const runInstall = a.run_install !== 'off' && !DRY_RUN

  state.phase = 'running'; state.startedAt = new Date().toISOString(); state.finishedAt = null
  state.exitCode = null; state.error = null; state.appUrl = null; state.adminPassword = null
  try { fs.writeFileSync(LOG_FILE, '') } catch (_) {}
  appendLog(`[setup-web] ${new Date().toISOString()} setup.sh ${args.map((x) => (x.startsWith('ETHORA1') || args[args.indexOf(x) - 1] === '--admin-password' || args[args.indexOf(x) - 1] === '--ai-key' ? '***' : x)).join(' ')}\n`)

  let out = ''
  child = spawn('bash', [SETUP_SH, ...args], { env: { ...process.env, HOME: process.env.HOME || '/root' } })
  child.stdout.on('data', (d) => { out += d; appendLog(d.toString()) })
  child.stderr.on('data', (d) => { out += d; appendLog(d.toString()) })
  child.on('close', (code) => {
    // Capture the generated admin password from setup.sh output once, for the
    // success page. It is also in deploy.yml.
    const m = out.match(/Admin password \(generated[^\n]*\n\s*([^\s]+)/)
    if (m) state.adminPassword = m[1]
    if (code !== 0) return finish(code, 'setup.sh failed; see log')
    if (!runInstall) return finish(0, null, a)
    appendLog(`[setup-web] ${new Date().toISOString()} install.sh --yes\n`)
    child = spawn('bash', [INSTALL_SH, '--yes'], { cwd: path.dirname(INSTALL_SH), env: { ...process.env, NON_INTERACTIVE: 'true', HOME: process.env.HOME || '/root' } })
    child.stdout.on('data', (d) => appendLog(d.toString()))
    child.stderr.on('data', (d) => appendLog(d.toString()))
    child.on('close', (c2) => finish(c2, c2 === 0 ? null : 'install.sh failed; see log', a))
  })
  return { ok: true }
}

function finish(code, error, a) {
  state.phase = code === 0 ? 'done' : 'failed'
  state.exitCode = code; state.error = error; state.finishedAt = new Date().toISOString()
  child = null
  if (code === 0 && a && a.domain && a.local !== 'on') state.appUrl = `https://app.${String(a.domain).trim().toLowerCase()}`
  appendLog(`[setup-web] ${new Date().toISOString()} ${state.phase}${error ? ': ' + error : ''}\n`)
  if (code === 0 && !DRY_RUN && a && a.run_install !== 'off') {
    try { fs.mkdirSync(path.dirname(DONE_FILE), { recursive: true }); fs.writeFileSync(DONE_FILE, new Date().toISOString() + '\n') } catch (e) { appendLog(`[setup-web] could not write ${DONE_FILE}: ${e.message}\n`) }
    // The page has done its job: keep it up long enough for the operator to
    // read the summary, then switch it off for good (port 8888 stays closed
    // on every later boot). SETUP_LINGER_SECONDS=0 disables the timer.
    const linger = Number(process.env.SETUP_LINGER_SECONDS ?? 900)
    if (linger > 0) {
      appendLog(`[setup-web] setup complete; this page switches itself off in ${Math.round(linger / 60)} minutes and will not start again\n`)
      setTimeout(() => {
        try { require('child_process').spawn('systemctl', ['disable', '--now', 'ethora-setup.service'], { detached: true, stdio: 'ignore' }).unref() } catch (_) {}
        setTimeout(() => process.exit(0), 30 * 1000).unref()
      }, linger * 1000).unref()
    }
  }
}

// ---------------------------------------------------------------- html ----
function page(pre) {
  const v = (k, d = '') => String(pre[k] ?? d).replace(/&/g, '&amp;').replace(/"/g, '&quot;')
  const sel = (k, val, d) => ((pre[k] || d) === val ? 'selected' : '')
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Ethora setup</title>
<style>
body{font:15px/1.45 system-ui,sans-serif;margin:0;background:#f6f7f9;color:#1b1f24}
main{max-width:760px;margin:32px auto;padding:0 16px}
h1{font-size:26px;margin:0 0 4px}.sub{color:#5a6270;margin:0 0 24px}
fieldset{border:1px solid #d9dde3;border-radius:12px;background:#fff;padding:16px 20px;margin:0 0 16px}
legend{font-weight:600;padding:0 6px}
label{display:block;margin:12px 0 4px;font-weight:600}
input[type=text],input[type=email],input[type=password],select,textarea{width:100%;box-sizing:border-box;padding:9px 10px;border:1px solid #c9ced6;border-radius:8px;font:inherit;background:#fff}
textarea{font-family:ui-monospace,monospace;font-size:12px;min-height:110px}
.hint{color:#5a6270;font-size:13px;margin-top:4px}.row{display:grid;grid-template-columns:1fr 1fr;gap:12px}@media(max-width:560px){.row{grid-template-columns:1fr}}
details summary{cursor:pointer;font-weight:600;padding:8px 0}
button{background:#2f6df6;color:#fff;border:0;border-radius:10px;padding:12px 20px;font:inherit;font-weight:600;cursor:pointer}
button[disabled]{opacity:.5}
pre{background:#0f1419;color:#d5dbe3;padding:14px;border-radius:12px;max-height:420px;overflow:auto;font-size:12px;white-space:pre-wrap}
.ok{color:#137333}.bad{color:#b3261e}.chk{display:flex;gap:8px;align-items:center;font-weight:400;margin:8px 0}
</style></head><body><main>
<h1>Ethora setup</h1>
<p class="sub">Six answers. Every host derives from the root domain; all secrets are generated. Advanced options keep their defaults unless you open them.</p>
<form id="f">
<fieldset><legend>Required</legend>
<label for="domain">Root domain</label>
<input id="domain" name="domain" type="text" required placeholder="chat.example.com" value="${v('domain')}">
<div class="hint">Gives api., app., xmpp., files. subdomains. DNS for those must point at this server before TLS can be issued.</div>
<label for="admin_email">Admin email</label>
<input id="admin_email" name="admin_email" type="email" required placeholder="ops@example.com" value="${v('admin_email')}">
<div class="hint">Platform admin login, base app owner, and Let's Encrypt contact. The admin password is generated and shown once at the end.</div>
</fieldset>

<fieldset><legend>License</legend>
<label for="license_key">License key</label>
<textarea id="license_key" name="license_key" placeholder="ETHORA1.…  (leave empty for a 14-day trial with every feature)">${v('license_key')}</textarea>
<div class="hint">Without a key the install runs every feature for 14 days, then restricts creating apps and users until a key is added on the admin panel License page. Chat keeps working either way.</div>
</fieldset>

<fieldset><legend>TLS</legend>
<label for="ssl">Certificates</label>
<select id="ssl" name="ssl">
<option value="certbot" ${sel('ssl', 'certbot', 'certbot')}>Let's Encrypt (DNS already points here)</option>
<option value="provided" ${sel('ssl', 'provided', 'certbot')}>I will provide certificate files</option>
<option value="none" ${sel('ssl', 'none', 'certbot')}>None (HTTP only, testing)</option>
</select>
<div class="row"><div><label for="cert">Certificate path (fullchain)</label><input id="cert" name="cert" type="text" placeholder="/etc/ssl/…/fullchain.pem"></div>
<div><label for="key">Private key path</label><input id="key" name="key" type="text" placeholder="/etc/ssl/…/privkey.pem"></div></div>
</fieldset>

<fieldset><legend>AI</legend>
<label for="ai">AI agents and document parsing</label>
<select id="ai" name="ai"><option value="on" ${sel('ai', 'on', 'on')}>On</option><option value="off" ${sel('ai', 'off', 'on')}>Off</option></select>
<label for="ai_key">AI provider API key</label>
<input id="ai_key" name="ai_key" type="password" placeholder="sk-… (OpenAI-compatible; empty for a self-hosted endpoint)">
<label for="ai_url">AI provider base URL</label>
<input id="ai_url" name="ai_url" type="text" placeholder="https://api.openai.com/v1">
</fieldset>

<details><summary>Advanced</summary><fieldset>
<label for="display_name">Product display name</label><input id="display_name" name="display_name" type="text" value="${v('display_name', 'Ethora')}">
<div class="row">
<div><label for="blockchain">Blockchain features</label><select id="blockchain" name="blockchain"><option value="off" ${sel('blockchain', 'off', 'off')}>Off</option><option value="on" ${sel('blockchain', 'on', 'off')}>On</option></select></div>
<div><label for="uptime">Uptime monitoring</label><select id="uptime" name="uptime"><option value="on" ${sel('uptime', 'on', 'on')}>On</option><option value="off" ${sel('uptime', 'off', 'on')}>Off</option></select></div>
</div>
<label for="hosted_apps">Hosted tenant apps root domain (optional)</label><input id="hosted_apps" name="hosted_apps" type="text" placeholder="chat.example.com" value="${v('hosted_apps')}">
<div class="row">
<div><label for="backend_mode">API runs from</label><select id="backend_mode" name="backend_mode"><option value="image" ${sel('backend_mode', 'image', DEFAULT_MODE)}>Prebuilt image</option><option value="source" ${sel('backend_mode', 'source', DEFAULT_MODE)}>Source build</option></select></div>
<div><label for="frontend_mode">Admin panel from</label><select id="frontend_mode" name="frontend_mode"><option value="image" ${sel('frontend_mode', 'image', DEFAULT_MODE)}>Prebuilt image</option><option value="source" ${sel('frontend_mode', 'source', DEFAULT_MODE)}>Source build</option></select></div>
</div>
<label for="license_server">License server URL (optional)</label><input id="license_server" name="license_server" type="text" placeholder="https://license.example.com">
<label class="chk"><input type="checkbox" name="call_home_off" id="call_home_off"> Air-gapped: never contact the license server</label>
<label for="admin_password">Admin password (optional; generated when empty)</label><input id="admin_password" name="admin_password" type="password">
<label for="target">Live install directory</label><input id="target" name="target" type="text" placeholder="(default: sibling 'ethora' of the source checkout)" value="${v('target')}">
<label for="import_yaml">Import an existing deploy.yml (optional)</label>
<textarea id="import_yaml" name="import_yaml" placeholder="Paste a deploy.yml to start from; the answers above override it."></textarea>
<label class="chk"><input type="checkbox" name="run_install_off" id="run_install_off"> Only write deploy.yml, do not run the installer</label>
</fieldset></details>

<p><button id="go" type="submit">Install Ethora</button></p>
</form>
<section id="progress" hidden>
<h2 id="status">Installing…</h2>
<pre id="log"></pre>
<p id="result"></p>
</section>
<script>
const f=document.getElementById('f'),go=document.getElementById('go'),logEl=document.getElementById('log'),statusEl=document.getElementById('status'),resultEl=document.getElementById('result');
f.addEventListener('submit',async(e)=>{e.preventDefault();go.disabled=true;
const fd=new FormData(f);const a=Object.fromEntries(fd.entries());
a.call_home=fd.get('call_home_off')?'off':'on';a.run_install=fd.get('run_install_off')?'off':'on';delete a.call_home_off;delete a.run_install_off;
const r=await fetch('/api/setup',{method:'POST',headers:{'content-type':'application/json'},body:JSON.stringify(a)});const j=await r.json();
if(!j.ok){alert(j.error||'failed');go.disabled=false;return}
document.getElementById('progress').hidden=false;f.querySelectorAll('input,select,textarea').forEach(x=>x.disabled=true);
const es=new EventSource('/api/log');es.onmessage=(m)=>{logEl.textContent+=JSON.parse(m.data);logEl.scrollTop=logEl.scrollHeight};
const poll=setInterval(async()=>{const s=await (await fetch('/api/state')).json();if(s.phase==='done'||s.phase==='failed'){clearInterval(poll);es.close();
statusEl.textContent=s.phase==='done'?'Done':'Failed';statusEl.className=s.phase==='done'?'ok':'bad';
let h='';if(s.phase==='done'){if(s.appUrl)h+='<b>Open <a href="'+s.appUrl+'">'+s.appUrl+'</a></b> and sign in as the admin email.<br>';if(s.adminPassword)h+='Generated admin password (shown once, also in deploy.yml): <code>'+s.adminPassword+'</code><br>';h+='This setup page switches itself off in 15 minutes.'}else{h+=(s.error||'')+' Fix and submit again.';go.disabled=false;f.querySelectorAll('input,select,textarea').forEach(x=>x.disabled=false)}
resultEl.innerHTML=h}},2000)});
</script></main></body></html>`
}

// -------------------------------------------------------------- server ----
function send(res, code, body, type = 'application/json') {
  res.writeHead(code, { 'content-type': type, 'cache-control': 'no-store' })
  res.end(typeof body === 'string' ? body : JSON.stringify(body))
}

function handler(req, res) {
  if (!checkAuth(req)) {
    res.writeHead(401, { 'www-authenticate': 'Basic realm="Ethora setup"', 'content-type': 'text/plain' })
    return res.end('Authentication required. User "' + USER + '"; password: see the console/journal (on EC2 it is the instance id).\n')
  }
  const url = new URL(req.url, 'http://x')
  if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/index.html')) return send(res, 200, page(existingAnswers()), 'text/html; charset=utf-8')
  if (req.method === 'GET' && url.pathname === '/api/state') return send(res, 200, state)
  if (req.method === 'GET' && url.pathname === '/api/log') {
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-store', connection: 'keep-alive' })
    try { res.write(`data: ${JSON.stringify(fs.readFileSync(LOG_FILE, 'utf8'))}\n\n`) } catch (_) {}
    logListeners.add(res)
    req.on('close', () => logListeners.delete(res))
    return
  }
  if (req.method === 'POST' && url.pathname === '/api/setup') {
    let body = ''
    req.on('data', (c) => { body += c; if (body.length > 1_000_000) req.destroy() })
    req.on('end', () => {
      let a
      try { a = JSON.parse(body || '{}') } catch (_) { return send(res, 400, { ok: false, error: 'invalid json' }) }
      const r = startSetup(a)
      return send(res, r.ok ? 202 : 409, r)
    })
    return
  }
  if (req.method === 'GET' && url.pathname === '/healthz') return send(res, 200, { ok: true, phase: state.phase })
  send(res, 404, { ok: false, error: 'not found' })
}

async function main() {
  if (!fs.existsSync(SETUP_SH)) { console.error(`[setup-web] not found: ${SETUP_SH}`); process.exit(2) }
  if (!PASSWORD) {
    const id = await imdsInstanceId()
    if (id) { PASSWORD = id; passwordSource = 'EC2 instance id' } else { PASSWORD = crypto.randomBytes(9).toString('base64url'); passwordSource = 'generated' }
  }
  try { fs.mkdirSync(path.dirname(LOG_FILE), { recursive: true }) } catch (_) {}
  const tls = process.env.SETUP_TLS_CERT && process.env.SETUP_TLS_KEY
  const srv = tls
    ? https.createServer({ cert: fs.readFileSync(process.env.SETUP_TLS_CERT), key: fs.readFileSync(process.env.SETUP_TLS_KEY) }, handler)
    : http.createServer(handler)
  srv.listen(PORT, BIND, () => {
    console.log(`[setup-web] listening on ${tls ? 'https' : 'http'}://${BIND}:${PORT}  user=${USER}  password=${passwordSource === 'generated' ? PASSWORD : '(' + passwordSource + ')'}  source=${SOURCE_ROOT}${DRY_RUN ? '  DRY RUN' : ''}`)
  })
}
main()
