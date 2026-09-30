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
//
// Exits non-zero on the first failure. The room it creates is left in place
// (named "verify <timestamp>").
const { client, xml } = require('/app/node_modules/@xmpp/client')

const env = process.env
const hostOf = (url, fallback) => { try { return new URL(url).host } catch { return fallback } }
const WEB = env.VERIFY_WEB_DOMAIN || hostOf(env.DEFAULT_APP_URL, '')
const API = env.VERIFY_API_DOMAIN || hostOf((env.OAUTH_ISSUER || ''), '') || (env.ETHORA_LICENSED_HOSTS || '').split(',')[0]
const FILES = env.VERIFY_FILES_DOMAIN || hostOf(env.MINIO_URL, '')
const XMPP = env.XMPP_HOST
const EMAIL = env.VERIFY_EMAIL || env.PLATFORM_ACCOUNT_EMAIL
const PASSWORD = env.VERIFY_PASSWORD || env.PLATFORM_ACCOUNT_PASSWORD
const SLUG = env.BASE_APP_DOMAIN_NAME

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
  const xmpp = client({ service: `wss://${XMPP}/ws`, domain: XMPP, username, password: token, resource: `verify-${Date.now()}` })
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
  ok(`xmpp login over wss://${XMPP}/ws as ${username}`)
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
  console.log(`Ethora Core compose bundle: verify (web=${WEB} api=${API} xmpp=${XMPP} files=${FILES})\n`)
  if (!WEB || !API || !XMPP || !FILES || !EMAIL || !PASSWORD) die('could not derive the hosts or admin credentials from backend.env')

  // 1. public endpoints and certificates
  await expect200('web app', `https://${WEB}/`)
  await expect200('API docs', `https://${API}/api-docs/`)
  await expect200('API ping', `https://${API}/v1/ping`)
  await expect200('file storage', `https://${FILES}/minio/health/live`)
  if (failures) summary()

  // 2. login + licence
  const cfg = await http(`https://${API}/v1/apps/get-config?domainName=${encodeURIComponent(SLUG)}`)
  const appToken = cfg.json && cfg.json.result && cfg.json.result.appToken
  if (!appToken) die(`get-config for base app "${SLUG}" returned no appToken (HTTP ${cfg.status})`)
  const login = await http(`https://${API}/v2/users/login-with-email`, {
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

  const lic = await http(`https://${API}/v2/license`, { headers: auth })
  const l = lic.json && lic.json.license
  if (lic.status === 200 && l) {
    const desc = [l.edition, l.tier, l.state, l.registered === false ? 'unregistered' : l.registered ? 'registered' : ''].filter(Boolean).join(', ')
    ok(`licence: ${desc || JSON.stringify(l).slice(0, 160)}`)
  } else fail(`GET /v2/license -> HTTP ${lic.status}`)

  // 3. chat room + message over XMPP
  const created = await http(`https://${API}/v2/chats`, {
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
  const up = await http(`https://${API}/v2/files`, { method: 'POST', headers: auth, body: form })
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
    if (file._id) await http(`https://${API}/v2/files/${file._id}`, { method: 'DELETE', headers: auth }).catch(() => {})
  }

  summary()
}

main().catch((e) => die(e.stack || e.message))
