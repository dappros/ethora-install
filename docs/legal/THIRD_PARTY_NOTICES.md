# Third-party notices

Open-source software distributed with or used by the Ethora server images and
installer, with the licence each is under. These components keep their own
licences; the Ethora Core Software License does not apply to them. Version
1.0 draft, 28 September 2026. The full inventory of npm and OS packages inside
each image is produced by the scanner at build time (`docker sbom` on the
published image lists it).

| Component | Licence | Source | Notes |
|---|---|---|---|
| MinIO (`dappros/minio`, unmodified copy of `RELEASE.2025-09-07T16-13-09Z`) | GNU AGPL v3.0 | https://github.com/minio/minio/tree/RELEASE.2025-09-07T16-13-09Z | Republished unmodified after MinIO withdrew its public images; MinIO is a trademark of MinIO, Inc. |
| ejabberd 26.04 (base of `ethora-xmpp`) | GNU GPL v2, with the ProcessOne exception permitting proprietary modules | https://github.com/processone/ejabberd | The Ethora modules are separate works loaded under that exception. |
| MongoDB 6.0 | SSPL v1 | https://github.com/mongodb/mongo | Run unmodified as a service to the install itself. |
| MySQL 8.1 | GNU GPL v2 | https://github.com/mysql/mysql-server | Unmodified. |
| Redis 7 | BSD 3-clause (RSALv2/SSPL for 7.4+) | https://github.com/redis/redis | Unmodified. |
| Centrifugo v6 | Apache 2.0 | https://github.com/centrifugal/centrifugo | Unmodified. |
| pgvector / PostgreSQL 16 (enterprise AI module) | PostgreSQL Licence | https://github.com/pgvector/pgvector | Unmodified. |
| nginx 1.27 (base of `ethora-frontend`) | BSD 2-clause | https://nginx.org | Unmodified. |
| Node.js 24 (base of `ethora-api`, `ethora-ai`, `ethora-push`) | MIT | https://github.com/nodejs/node | Unmodified. |
| Erlang/OTP 28 | Apache 2.0 | https://github.com/erlang/otp | Unmodified. |
| Debian and Alpine base images and packages | various (see each image's package metadata) | | |
| npm dependencies of the Node services | various, predominantly MIT, ISC, Apache 2.0, BSD | listed in each service's `package-lock.json`; the image SBOM carries the full list | |

Source offers: for any GPL or AGPL component above, the source of the exact
version distributed is at the linked repository; Dappros makes no
modifications to them. Requests: [legal@ethora.com].
