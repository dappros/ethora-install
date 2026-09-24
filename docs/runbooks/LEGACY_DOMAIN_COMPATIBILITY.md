# Legacy Domain Compatibility

Keeping old API / web / files hostnames answering after a domain move.

When you move a production deployment from `app.example.com` / `files.example.com` to `app.chat.example.com` / `files.chat.example.com`, the deploy system can generate temporary compatibility vhosts for the old web and files hosts.

Recommended use:

- old web host: redirect to the new canonical web host
- old files host: redirect if URLs are already rewritten, or temporary proxy if old file URLs still exist in restored data
- old API host: not recommended unless you have unmanaged legacy clients
- old XMPP host: not recommended as a normal compatibility layer because JID/XMPP migration is not equivalent to HTTP redirect

Example config:

```yaml
domains:
  api: api.chat.example.com
  web: app.chat.example.com
  xmpp: xmpp.chat.example.com
  files: files.chat.example.com
  hosted_apps_root: chat.example.com

legacy_domains:
  enabled: true
  web: app.example.com
  web_mode: redirect
  files: files.example.com
  files_mode: proxy
```

Compatibility mode behavior:

- `web_mode: redirect` creates a temporary HTTPS redirect from the old web host to the new web host.
- `files_mode: redirect` redirects old file URLs to the new files host.
- `files_mode: proxy` serves old file URLs through the new stack without changing object keys.

Operational notes:

- Legacy compatibility requires DNS and TLS certificates for the old compatibility hosts as well as the new canonical hosts.
- Compatibility hosts are meant for transition periods only. Update docs, frontend config, widgets, and any managed clients to the canonical `*.chat.example.com` hosts and remove the legacy hosts later.
- If you still rely on old `files.example.com` URLs embedded in restored data, prefer `files_mode: proxy` first, then move to `redirect` after DB rewrites are complete.
