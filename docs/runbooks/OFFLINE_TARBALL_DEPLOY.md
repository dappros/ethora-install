# Deploying from a tarball (offline bundle)

Building and installing an offline bundle on a host without git access.

Use this flow when you want to build a self-contained snapshot of the repo (without `.git` / `node_modules`) and deploy it to a server.

## Build tarball (on your workstation)

From the monoserver root:

```bash
set -euo pipefail

BUNDLE_DATE=$(date -u +%Y-%m-%d)
BUNDLE_TIME=$(date -u +%H%M)
BUNDLE_NAME="ethora-deptest-${BUNDLE_DATE}-${BUNDLE_TIME}"
STAGE_DIR="/tmp/${BUNDLE_NAME}"
OUT_DIR="$(pwd)/_dist"
OUT_TGZ="${OUT_DIR}/${BUNDLE_NAME}.tar.gz"

mkdir -p "$OUT_DIR"
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"

common_excludes=(
  --exclude '.git'
  --exclude 'node_modules'
  --exclude 'docker-data'
  --exclude '**/docker-data'
)

# deploy (exclude local secret)
rsync -a --delete "${common_excludes[@]}" --exclude '.deploy.env' ./deploy "$STAGE_DIR/"

# services
rsync -a --delete "${common_excludes[@]}" ./ejabberd-docker "$STAGE_DIR/"
rsync -a --delete "${common_excludes[@]}" --exclude 'infra/docker/data' --exclude 'infra/docker/data/**' ./ethora-backend "$STAGE_DIR/"
rsync -a --delete "${common_excludes[@]}" ./ethora-app-reactjs "$STAGE_DIR/"

# manifest
{
  echo "Bundle: ${BUNDLE_NAME}"
  echo "Created (UTC): $(date -u)"
  echo
  echo "monoserver: $(git rev-parse --short HEAD 2>/dev/null || true)"
  echo "ethora-backend: $(cd ethora-backend && git rev-parse --short HEAD 2>/dev/null || true)"
  echo "ethora-app-reactjs: $(cd ethora-app-reactjs && git rev-parse --short HEAD 2>/dev/null || true)"
  echo "ejabberd-docker: $(cd ejabberd-docker && git rev-parse --short HEAD 2>/dev/null || true)"
  echo
  echo "Notes: .git and node_modules are intentionally excluded."
  echo "Notes: deploy/.deploy.env is intentionally excluded (local secret)."
  echo "Notes: ethora-backend/infra/docker/data is intentionally excluded (local docker volume data)."
} > "$STAGE_DIR/MANIFEST.txt"

rm -f "$OUT_TGZ"
tar -C /tmp -czf "$OUT_TGZ" "$BUNDLE_NAME"
( cd "$OUT_DIR" && sha256sum "${BUNDLE_NAME}.tar.gz" > "${BUNDLE_NAME}.tar.gz.sha256" )

echo "Created: $OUT_TGZ"
echo "SHA256:  ${OUT_TGZ}.sha256"
```

## Install from tarball (on the server)

Example target folders:
- Upload into: `/home/ubuntu/deptest_install/`
- Extract into: `/home/ubuntu/deptest/`

```bash
cd /home/ubuntu/deptest_install
sha256sum -c ethora-deptest-YYYY-MM-DD-HHMM.tar.gz.sha256

sudo rm -rf /home/ubuntu/deptest
sudo mkdir -p /home/ubuntu/deptest
sudo tar -xzf ethora-deptest-YYYY-MM-DD-HHMM.tar.gz -C /home/ubuntu/deptest --strip-components=1

cd /home/ubuntu/deptest/deploy
sudo ./scripts/install.sh --reset
./scripts/health-check.sh
```
