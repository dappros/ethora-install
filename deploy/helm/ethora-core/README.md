# Ethora Core Helm chart

[Ethora](https://ethora.com) Core on Kubernetes: the API, the web chat and
admin panel, the XMPP server (ejabberd with the Ethora modules) and file
storage, with MongoDB, MySQL, Redis, MinIO and Centrifugo, behind one Ingress
per public host with cert-manager TLS.

It is the Kubernetes form of the compose bundle (`deploy/compose/`): the
same images, the same settings and the same configuration templates. Every
pod renders its configuration with the `ethora-compose-init` image into an
`emptyDir`, and the first-boot steps run as a Job.

## Install

Needs Kubernetes 1.25+, an ingress controller (ingress-nginx by default),
cert-manager with a ClusterIssuer, a default StorageClass, and about 2 GB of
memory for the pods (two 4 GB nodes are comfortable).

```bash
helm install ethora oci://docker.io/dappros/ethora-core \
  --namespace ethora --create-namespace \
  --set rootDomain=chat.example.com \
  --set admin.email=you@example.com \
  --set ingress.clusterIssuer=letsencrypt-prod
```

Point five DNS records at the ingress controller's external address:
`api.`, `app.`, `xmpp.`, `files.` and `secure-files.chat.example.com` (or one
wildcard record). `secure-files.` serves chat attachments, gated by chat
membership; `hosts.secureFiles=off` drops it and attachments go to the
public files bucket.
No domain yet: `rootDomain=<ingress IP with dashes>.sslip.io` resolves
everywhere and gets real certificates. With `publicUrl=https://chat.example.com`
instead of `rootDomain`, everything is served on that one host, routed by path.

The pods are up and the init Job has created the base app and the admin
account a few minutes later; `helm install` does not wait for that. Then:

```bash
kubectl -n ethora get secret ethora-ethora-core-secrets -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d; echo
helm test -n ethora ethora --logs
```

`helm test` runs the compose bundle's end-to-end check through the public
URLs: web app, API docs, admin login, licence, a chat room created and a
message sent over `wss://xmpp.<root>/ws`, a file uploaded and read back.

A ClusterIssuer for Let's Encrypt through ingress-nginx, if the cluster has
none:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: you@example.com
    privateKeySecretRef:
      name: letsencrypt-prod-account
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

## What runs

| Component | Kind | Image | Role |
|---|---|---|---|
| `mongo` | StatefulSet, PVC | `mongo:6.0.8` | apps, users, chats, message archive (single-node replica set) |
| `mysql` | StatefulSet, PVC | `mysql:8.1.0` | ejabberd: XMPP accounts, rooms, history |
| `redis` | StatefulSet, PVC | `redis:7.4-alpine` | cache and queues |
| `minio` | StatefulSet, PVC | `dappros/minio` | uploaded files |
| `centrifugo` | Deployment | `centrifugo/centrifugo:v6.9.7` | real-time counters (in memory) |
| `xmpp` | Deployment (1) | `dappros/ethora-xmpp` | ejabberd with the Ethora modules |
| `api`, `jobs` | Deployments | `dappros/ethora-api` | HTTP API, cron and queue workers |
| `frontend` | Deployment | `dappros/ethora-frontend` | web chat and admin panel |
| `init-<revision>` | Job | `dappros/ethora-api` | first-boot steps, after every install and upgrade (idempotent) |

Ingresses: `api.` (all paths; `/metrics` is sent to the web app, so the
API's metrics stay internal), `app.` (plus `/connection/websocket` to
Centrifugo), `xmpp.` (`/ws` and `/bosh` only, never ejabberd's `/api` or
`/admin`), `files.` (MinIO). The API and files ingresses take uploads of
any size and the WebSocket ones keep connections for an hour (ingress-nginx
annotations in `ingress.uploadAnnotations` / `websocketAnnotations`; set your
controller's equivalents there).

## Values

The commonly set ones; `values.yaml` documents every key.

| Key | Default | |
|---|---|---|
| `rootDomain` | | five hosts: api., app., xmpp., files., secure-files.<rootDomain> |
| `hosts.api` / `web` / `xmpp` / `files` / `secureFiles` | derived | per-host overrides (`secureFiles: off` for no attachments host) |
| `publicUrl` | | one origin instead, e.g. `https://chat.example.com` |
| `admin.email` | | platform admin and base app owner (required) |
| `admin.password` | generated | initial password of that account |
| `displayName` | `Ethora` | product name in the web app |
| `license.key` | | empty: Ethora Core, unregistered |
| `extraSettings` | `{}` | any variable of the installer's templates, e.g. `POSTMARK_ENABLED` |
| `secrets.existingSecret` | | use your own Secret (keys as in `templates/secret.yaml`) |
| `secrets.*` | generated | individual secrets |
| `images.*.tag` | appVersion | image tags (`2610` = the release line) |
| `ingress.className` | `nginx` | |
| `ingress.clusterIssuer` | | cert-manager ClusterIssuer name |
| `<db>.persistence.size` / `storageClass` | 10/5/1/20 Gi | per database |
| `<component>.resources` | sized for 4 GB nodes | requests and limits |
| `mongo.enabled` ... `minio.enabled` | `true` | `false` plus `external.*` for managed services |

Secrets are generated on the first install, kept on upgrades, and kept by
`helm uninstall` together with the PVCs (the databases were initialised with
them); a value given in `secrets.*` wins. To remove an install completely,
delete the PVCs and `<release>-ethora-core-secrets` after uninstalling.

## External databases

[`values-external-databases.yaml`](values-external-databases.yaml) switches
the bundled StatefulSets off and points the API and ejabberd at managed
services, with what each must provide (a MongoDB replica set, MySQL 8 with
an `ejabberd_db` database, Redis without a password, S3-compatible storage
over plain HTTP). That file is rendered in CI but has not been run against
managed services.

## Upgrade

```bash
helm upgrade ethora oci://docker.io/dappros/ethora-core -n ethora --reuse-values
```

The default image tags follow the release line (`2610`), a moving tag that
nodes cache (`imagePullPolicy: IfNotPresent`). To update deterministically,
pin a release build on upgrade (`--set images.api.tag=2610.9`, likewise
`frontend`, `xmpp`, `composeInit`); or set `imagePullPolicy=Always` and
`kubectl -n ethora rollout restart deploy`. The init Job of the new revision
runs the migrations.

## Backup

The data is in four PVCs (`data-<release>-ethora-core-{mongo,mysql,redis,minio}-0`)
and the Secret. Use your cluster's volume snapshots, or dump the databases:

```bash
kubectl -n ethora exec ethora-ethora-core-mongo-0 -- mongodump --archive --gzip > mongo.archive.gz
kubectl -n ethora exec ethora-ethora-core-mysql-0 -c mysql -- sh -c 'mysqldump -uroot -p"$(cat /ethora/config/mysql/root-password)" --single-transaction --databases ejabberd_db' | gzip > mysql.sql.gz
kubectl -n ethora get secret ethora-ethora-core-secrets -o yaml > secrets.yaml
```

## Publishing (maintainers)

The chart version is CalVer, `YY.M.patch` for the month it ships (see
CLAUDE.md); `appVersion` is the image release line.

```bash
helm lint deploy/helm/ethora-core -f deploy/helm/ethora-core/ci/hosts-values.yaml
helm package deploy/helm/ethora-core                     # ethora-core-<version>.tgz
helm registry login registry-1.docker.io -u <docker hub user>
helm push ethora-core-<version>.tgz oci://registry-1.docker.io/dappros
```

The repository `dappros/ethora-core` on Docker Hub must be public, as the
images' are. Artifact Hub:

1. On artifacthub.io, Control Panel > Add repository: kind Helm charts, URL
   `oci://registry-1.docker.io/dappros/ethora-core`, owner Dappros.
2. Put the repository ID it shows into `deploy/helm/artifacthub-repo.yml`
   and push that file as the OCI artifact Artifact Hub reads (verified
   publisher and ownership claim):

   ```bash
   oras push registry-1.docker.io/dappros/ethora-core:artifacthub.io \
     --config /dev/null:application/vnd.cncf.artifacthub.config.v1+yaml \
     deploy/helm/artifacthub-repo.yml:application/vnd.cncf.artifacthub.repository-metadata.layer.v1.yaml
   ```

3. The listing takes its metadata from `Chart.yaml` (description, keywords,
   `artifacthub.io/*` annotations: licence, links, images) and this README.

CI (`.github/workflows/deploy-tests.yml`, job `helm-chart`) runs
`deploy/scripts/tests/helm-chart.test.sh`: `helm lint`, `helm template` and
kubeconform on the `ci/` fixtures, plus checks on the rendered manifests.

## Licence

Ethora Core: free, with per-server limits (5 apps and 500 user accounts; 10
and 5,000 after registering for free on the admin panel's License page).
Installing it accepts the Ethora Core Software License:
https://ethora.com/legal/ethora-core-license/. The MinIO image is an
unmodified copy of MinIO under AGPL-3.0; the other third-party images keep
their own licences.
