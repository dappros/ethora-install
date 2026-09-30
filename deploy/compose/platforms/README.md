# Platform templates for the compose bundle

- `portainer-template.json`: a Portainer app template (format v3) that
  deploys `deploy/compose/docker-compose.yml` from the public installer
  repository. Add its raw URL under Settings > App Templates in Portainer,
  or submit it to the Portainer community templates. Every secret is a
  free-text field there; Portainer has no generator, so tell users to paste
  long random strings (for example the output of `openssl rand -hex 24`).
- `coolify/`: how to run the bundle on Coolify as a Docker Compose
  application from the public installer repository (the supported way,
  verified end to end), and `ethora-core.yaml`, a draft one-click service
  template generated from `coolify/ethora-core.in.yaml` by
  `coolify/build-template.sh` with the bundle's scripts and templates
  inline. See `coolify/README.md`.
- A Dokploy template is pending: the platform has its own conventions for
  generated secrets and per-service domains, and a template is only worth
  submitting after a run on a real instance of the platform.
