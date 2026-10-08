// verify.js - end-to-end check of a running compose bundle, through the
// public URLs (the same path a browser or SDK takes):
//
//   docker compose --profile verify run --rm verify
//
// 1. https://app., https://api./api-docs/, https://files. answer 200 with a
//    certificate Node trusts (the system CA store; no --insecure).
// 2. The platform admin logs in (PLATFORM_ACCOUNT_EMAIL / _PASSWORD from
//    backend.env, or VERIFY_EMAIL / VERIFY_PASSWORD) and the licence state
//    is read.
// 3. A chat room is created, joined over wss://xmpp.<root>/ws with the
//    login's XMPP JWT, and a message sent to it comes back from the room.
// 4. A file is uploaded and read back through https://files.<root>, then
//    deleted.
// 5. A chat attachment is uploaded to the room (POST /v2/files/secure) and
//    read back from https://secure-files.<root> with the login's fileToken;
//    the same URL without a token is refused. On an install without the
//    secure files host (one origin) the route must answer 503, which the
//    web client treats as "use the public bucket".
//
// Exits non-zero on the first failure. The room it creates is left in place
// (named "verify <timestamp>").
const { client, xml } = require('/app/node_modules/@xmpp/client')

const env = process.env
const hostOf = (url, fallback) => { try { return new URL(url).host } catch { return fallback } }
// Public entry points as the config service rendered them (ETHORA_PUBLIC_*
// in backend.env): four https hosts, or one origin (PUBLIC_URL). VERIFY_*
// overrides them, e.g. to reach a LAN install by IP from this container.
const origin = (u) => String(u || '').replace(/\/+$/, '')
const WEB_URL = origin(env.VERIFY_WEB_URL || env.ETHORA_PUBLIC_WEB_URL)
const API_URL = origin(env.VERIFY_API_URL || env.ETHORA_PUBLIC_API_URL)
const FILES_URL = origin(env.VERIFY_FILES_URL || env.ETHORA_PUBLIC_FILES_URL)
const SECURE_FILES_URL = origin(env.VERIFY_SECURE_FILES_URL || env.ETHORA_PUBLIC_SECURE_FILES_URL)
const XMPP_WS = env.VERIFY_XMPP_WS_URL || env.ETHORA_PUBLIC_XMPP_WS_URL
const WEB = hostOf(WEB_URL, '')
const API = hostOf(API_URL, '')
const FILES = hostOf(FILES_URL, '')
const SECURE_FILES = hostOf(SECURE_FILES_URL, '')
const XMPP = env.XMPP_HOST
const ONE_ORIGIN = WEB_URL === API_URL
const EMAIL = env.VERIFY_EMAIL || env.PLATFORM_ACCOUNT_EMAIL
const PASSWORD = env.VERIFY_PASSWORD || env.PLATFORM_ACCOUNT_PASSWORD
const SLUG = env.BASE_APP_DOMAIN_NAME
// VERIFY_SKIP=web skips the web page check, for a web UI behind a platform
// login (Umbrel's app_proxy); the other checks use the API and XMPP paths.
const SKIP = new Set(String(env.VERIFY_SKIP || '').split(',').map((x) => x.trim()).filter(Boolean))

let failures = 0
const ok = (msg) => console.log(`  ok    ${msg}`)
const fail = (msg) => { failures++; console.log(`  FAIL  ${msg}`) }
const die = (msg) => { fail(msg); summary(); }
function summary() {
  console.log(failures ? `\n${failures} check(s) failed` : '\nall checks passed')
  process.exit(failures ? 1 : 0)
}

async function http(url, opts = {}) {
  const res = await fetch(url, { redirect: 'manual', ...opts })
  const text = await res.text()
  let json = null
  try { json = JSON.parse(text) } catch { /* not JSON */ }
  return { status: res.status, text, json, headers: res.headers }
}

async function expect200(label, url) {
  try {
    const r = await http(url)
    if (r.status === 200) ok(`${label} ${url}`)
    else fail(`${label} ${url} -> HTTP ${r.status}`)
  } catch (e) {
    fail(`${label} ${url} -> ${e.cause ? e.cause.code || e.cause.message : e.message}`)
  }
}

async function xmppRoundTrip({ username, token, roomJid }) {
  // Rooms accept a member under its registered nick, the XMPP localpart (as
  // the web client joins).
  const nick = username
  const body = `verify message ${new Date().toISOString()}`
  const xmpp = client({ service: XMPP_WS, domain: XMPP, username, password: token, resource: `verify-${Date.now()}` })
  xmpp.on('error', () => {})
  const waitFor = (what, match) => new Promise((resolve, reject) => {
    const t = setTimeout(() => { xmpp.removeListener('stanza', on); reject(new Error(`${what}: no answer within 20 s`)) }, 20000)
    function on(st) {
      const err = st.attrs.type === 'error' && st.attrs.from && st.attrs.from.startsWith(roomJid) && st.getChild('error')
      if (err) { clearTimeout(t); xmpp.removeListener('stanza', on); reject(new Error(`${what}: ${err.toString().slice(0, 300)}`)); return }
      if (match(st)) { clearTimeout(t); xmpp.removeListener('stanza', on); resolve(st) }
    }
    xmpp.on('stanza', on)
  })
  await xmpp.start()
  ok(`xmpp login over ${XMPP_WS} as ${nick}`)
  try {
    // Join, and wait for our own presence back (MUC status 110).
    const joined = waitFor(`join ${roomJid}`, (st) => st.is('presence') && st.attrs.from === `${roomJid}/${nick}`)
    await xmpp.send(xml('presence', { to: `${roomJid}/${nick}` }, xml('x', { xmlns: 'http://jabber.org/protocol/muc' }, xml('history', { maxstanzas: '0' }))))
    await joined
    const echoed = waitFor('message', (st) => st.is('message') && st.attrs.type === 'groupchat' && st.getChildText('body') === body)
    await xmpp.send(xml('message', { to: roomJid, type: 'groupchat', id: `verify-${Date.now()}` }, xml('body', {}, body)))
    await echoed
    ok(`joined ${roomJid}, sent a message and received it back`)
  } finally {
    await xmpp.stop().catch(() => {})
  }
}

async function main() {
  console.log(`Ethora Core compose bundle: verify (web=${WEB_URL} api=${API_URL} xmpp=${XMPP_WS} files=${FILES_URL} secure-files=${SECURE_FILES_URL || 'off'})\n`)
  if (!WEB_URL || !API_URL || !XMPP_WS || !FILES_URL || !XMPP || !EMAIL || !PASSWORD) die('could not derive the public URLs or admin credentials from backend.env')

  // 1. public endpoints and certificates
  if (!SKIP.has('web')) await expect200('web app', `${WEB_URL}/`)
  await expect200('API docs', `${API_URL}/api-docs/`)
  await expect200('API ping', `${API_URL}/v1/ping`)
  // One origin routes only /files/ to MinIO; the upload below covers it.
  if (!ONE_ORIGIN) await expect200('file storage', `${FILES_URL}/minio/health/live`)
  if (failures) summary()

  // 2. login + licence
  const cfg = await http(`${API_URL}/v1/apps/get-config?domainName=${encodeURIComponent(SLUG)}`)
  const appToken = cfg.json && cfg.json.result && cfg.json.result.appToken
  if (!appToken) die(`get-config for base app "${SLUG}" returned no appToken (HTTP ${cfg.status})`)
  const login = await http(`${API_URL}/v2/users/login-with-email`, {
    method: 'POST',
    headers: { Authorization: appToken, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: EMAIL, password: PASSWORD }),
  })
  if (login.status !== 200 || !login.json || !login.json.token) die(`admin login as ${EMAIL} -> HTTP ${login.status} ${login.text.slice(0, 200)}`)
  // user.xmppPassword in a login response is the short-lived XMPP JWT
  // (helpers/sanitizeUser.ts), the password the web client signs in with.
  const { token, user } = login.json
  ok(`admin login as ${EMAIL}`)
  const auth = { Authorization: token }

  const lic = await http(`${API_URL}/v2/license`, { headers: auth })
  const l = lic.json && lic.json.license
  if (lic.status === 200 && l) {
    const desc = [l.edition, l.tier, l.state, l.registered === false ? 'unregistered' : l.registered ? 'registered' : ''].filter(Boolean).join(', ')
    ok(`licence: ${desc || JSON.stringify(l).slice(0, 160)}`)
  } else fail(`GET /v2/license -> HTTP ${lic.status}`)

  // 3. chat room + message over XMPP
  const created = await http(`${API_URL}/v2/chats`, {
    method: 'POST',
    headers: { ...auth, 'Content-Type': 'application/json' },
    body: JSON.stringify({ title: `verify ${new Date().toISOString()}`, description: 'created by the compose bundle verify check', type: 'public' }),
  })
  const room = created.json && (created.json.result || created.json)
  const localpart = room && (room.name || room.roomJid || room.jid || room.chatId)
  if (!(created.status === 200 || created.status === 201) || !localpart) die(`create chat room -> HTTP ${created.status} ${created.text.slice(0, 200)}`)
  const roomJid = String(localpart).includes('@') ? String(localpart) : `${localpart}@conference.${XMPP}`
  ok(`chat room created: ${roomJid}`)
  try {
    await xmppRoundTrip({ username: user.xmppUsername, token: user.xmppPassword, roomJid })
  } catch (e) {
    fail(`xmpp: ${e.message}`)
  }

  // 4. file upload through files.<root>
  const payload = `verify ${Date.now()}\n`
  const form = new FormData()
  form.append('files', new Blob([payload], { type: 'text/plain' }), 'verify.txt')
  const up = await http(`${API_URL}/v2/files`, { method: 'POST', headers: auth, body: form })
  const file = up.json && ((up.json.results && up.json.results[0]) || (up.json.result && up.json.result[0]) || up.json.result)
  const location = file && (file.location || file.url)
  if (up.status !== 200 && up.status !== 201) fail(`file upload -> HTTP ${up.status} ${up.text.slice(0, 200)}`)
  else if (!location) fail(`file upload returned no location: ${up.text.slice(0, 200)}`)
  else {
    const host = hostOf(location, '')
    const got = await http(location).catch((e) => ({ status: 0, text: e.message }))
    if (host !== FILES) fail(`uploaded file is served from ${host}, expected ${FILES}`)
    else if (got.status === 200 && got.text === payload) ok(`file uploaded and read back from ${location}`)
    else fail(`uploaded file at ${location} -> HTTP ${got.status}`)
    if (file._id) await http(`${API_URL}/v2/files/${file._id}`, { method: 'DELETE', headers: auth }).catch(() => {})
  }

  // 5. chat attachment through secure-files.<root>
  const secureForm = new FormData()
  secureForm.append('files', new Blob([payload], { type: 'text/plain' }), 'verify-attachment.txt')
  secureForm.append('chatName', String(localpart).split('@')[0])
  const sup = await http(`${API_URL}/v2/files/secure`, { method: 'POST', headers: auth, body: secureForm })
  if (!SECURE_FILES) {
    if (sup.status === 503) ok('secure files off: /v2/files/secure answers 503 (attachments use the public bucket)')
    else fail(`secure files off, but /v2/files/secure -> HTTP ${sup.status} ${sup.text.slice(0, 160)} (expected 503)`)
  } else {
    const sfile = sup.json && ((sup.json.results && sup.json.results[0]) || sup.json.result)
    const sloc = sfile && (sfile.location || sfile.url)
    if (sup.status !== 200 && sup.status !== 201) fail(`attachment upload -> HTTP ${sup.status} ${sup.text.slice(0, 200)}`)
    else if (!sloc) fail(`attachment upload returned no location: ${sup.text.slice(0, 200)}`)
    else if (hostOf(sloc, '') !== SECURE_FILES) fail(`attachment is served from ${hostOf(sloc, '')}, expected ${SECURE_FILES}`)
    else {
      const anon = await http(sloc).catch((e) => ({ status: 0, text: e.message }))
      if (anon.status === 401 || anon.status === 403) ok(`attachment without a token is refused (HTTP ${anon.status})`)
      else fail(`attachment without a token -> HTTP ${anon.status} (expected 401 or 403)`)
      const fileToken = login.json.fileToken || ''
      if (!fileToken) fail('login response carries no fileToken to fetch the attachment with')
      else {
        const signed = new URL(sloc); signed.searchParams.set('ft', fileToken)
        const got = await http(signed.toString()).catch((e) => ({ status: 0, text: e.message }))
        if (got.status === 200 && got.text === payload) ok(`attachment uploaded and read back from ${sloc} with the fileToken`)
        else fail(`attachment at ${sloc} with the fileToken -> HTTP ${got.status}`)
      }
      if (sfile._id) await http(`${API_URL}/v2/files/${sfile._id}`, { method: 'DELETE', headers: auth }).catch(() => {})
    }
  }

  summary()
}

main().catch((e) => die(e.stack || e.message))
