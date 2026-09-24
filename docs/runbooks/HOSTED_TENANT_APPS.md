# Hosted Tenant Apps

Serving tenant apps under wildcard subdomains from one install.

The hosted tenant app feature serves the same built frontend SPA for many tenant subdomains and resolves the tenant from the current hostname at runtime.

Example patterns:

- `customer.chat.example.com`
- `myclinic.chat.client-domain.com`
- `69cc666513643fb98a6147e6.chat.example.com`

When this feature is disabled, the deploy/runtime system should stay inert for this area:

- no hosted-app Nginx vhost is generated
- no hosted-app wildcard certificate is copied
- no extra hosted-app SSL handling is performed

Minimal config:

```yaml
domains:
  hosted_apps_root: chat.example.com

services:
  hosted_apps:
    enabled: true
```

Recommended SSL model:

- Keep the main stack on normal certbot-managed single-host certs:
  - `api.<domain>`
  - `app.<domain>`
  - `widget.<domain>`
  - `xmpp.<domain>`
- Use a separate public wildcard cert only for hosted apps:
  - `chat.example.com`
  - `*.chat.example.com`

Example mixed SSL config:

```yaml
ssl:
  method: certbot
  email: admin@example.com
  hosted_apps_cert_path: /etc/letsencrypt/live/chat.example.com/fullchain.pem
  hosted_apps_key_path: /etc/letsencrypt/live/chat.example.com/privkey.pem
```

DNS recommendations:

- Point both the hosted-app root and wildcard to the same server:
  - `chat.example.com`
  - `*.chat.example.com`
- For a direct public wildcard cert on the origin, prefer `DNS only`.
- If you proxy wildcard tenant domains through Cloudflare, ensure Cloudflare edge certificate coverage for that wildcard. Cloudflare Origin CA by itself is not enough for browsers.

Public wildcard cert via Let's Encrypt DNS-01:

```bash
sudo certbot certonly \
  --manual \
  --preferred-challenges dns \
  --agree-tos \
  --email admin@example.com \
  --cert-name chat.example.com \
  --force-renewal \
  -d chat.example.com \
  -d '*.chat.example.com'
```

Certbot will ask you to create `_acme-challenge.chat.example.com` TXT records. After issuance, point `ssl.hosted_apps_cert_path` and `ssl.hosted_apps_key_path` at the resulting certificate files and re-run `update.sh`.

Verification:

```bash
curl -I https://tenant.chat.example.com/
sudo nginx -t
```
