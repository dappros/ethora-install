# Security policy

**Reporting a vulnerability.** Please e-mail [security@ethora.com](mailto:security@ethora.com)
rather than opening a public issue. Include the version (`Ethora Core v…`
in the admin panel footer, or `/v1/ping/version`), what you found, and how
to reproduce it. We acknowledge reports within three business days and
publish a fix or mitigation before public disclosure where possible.

**Supported versions.** The current release line and the previous one (see
[docs/RELEASE_NOTES_OPERATORS.md](docs/RELEASE_NOTES_OPERATORS.md)) receive
security fixes; update with `sudo deploy/scripts/update.sh --ref <line>`.

**Images.** Every published image is scanned for known vulnerabilities in
its packages before release; fixable critical findings block the release.
Base images are refreshed with each build.

**Your install.** `deploy.yml` and `.deploy.env` hold every secret of the
install; keep them at mode 600 and never paste them into an issue or e-mail.
