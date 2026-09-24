# MinIO Object Migration

Mirroring file objects between two MinIO instances with `mc`.

Use this flow when you want to migrate file objects from an older environment into a newer QA or staging environment.

Example source and target domains:

- source app: `app.example.com`
- source files host: `files.example.com`
- target app: `app.chat.example.com`
- target files host: `files.chat.example.com`

Important behavior:

- MinIO object migration is separate from MongoDB and Ejabberd snapshot restore.
- `mc mirror` copies object data and preserves object keys; it does not rewrite URLs stored in MongoDB or Ejabberd.
- If object copy succeeds but restored apps still point at old file hosts, run the generated `mongo-post-restore.js` from the stateful migration pack to rewrite supported file URL fields.

## Step 1: Install `mc` on the target server

```bash
curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o /tmp/mc
chmod +x /tmp/mc
sudo mv /tmp/mc /usr/local/bin/mc
mc --version
```

## Step 2: Configure the target alias

On the target server, the deploy system exposes the MinIO root credentials via `.deploy.env`:

```bash
cd ~/ethora-install-shared/deploy
source .deploy.env

mc alias set target http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD"
mc ls target
```

The default target bucket in this deploy stack is `files`.

## Step 3A: Configure the source alias directly

If the source MinIO API endpoint is reachable directly, use it with source MinIO credentials:

```bash
mc alias set source http://minio.example.com:9000 <SOURCE_MINIO_USER> <SOURCE_MINIO_PASSWORD>
mc ls source
```

If the source uses TLS directly on the MinIO API endpoint, use `https://` instead.

## Step 3B: Configure the source alias through SSH tunnel

If the public files host is behind Nginx, CDN, or another proxy and does not expose the raw S3-compatible MinIO API, tunnel to the source MinIO port instead.

In one terminal on the target server:

```bash
ssh -N -L 19000:127.0.0.1:9000 <SSH_USER>@<SOURCE_SSH_HOST>
```

In another terminal on the target server:

```bash
mc alias set source http://127.0.0.1:19000 <SOURCE_MINIO_USER> <SOURCE_MINIO_PASSWORD>
mc ls source
```

## Step 4: Mirror objects

```bash
mc mb target/files 2>/dev/null || true
mc mirror --overwrite --preserve --summary source/files target/files
```

This keeps object keys unchanged, which is important because restored MongoDB and Ejabberd records typically refer to those existing paths.

## Step 5: Verify

```bash
mc du source/files
mc du target/files
mc ls target/files | head
```

Then test in the target app:

1. app logos
2. user profile images
3. old chat attachments
4. document or NFT file links, if used

## When URL rewrite is still needed

If files exist in the target bucket but the app still requests `files.example.com` instead of `files.chat.example.com`, the remaining work is URL rewrite, not object copy.

For stateful restores, the recommended approach is:

1. generate a stateful migration pack with `prepare-stateful-migration.sh`
2. restore MongoDB and Ejabberd snapshots
3. mirror MinIO objects with `mc`
4. run the generated `mongo-post-restore.js`
5. retest logos and attachments

The generated Mongo rewrite covers common runtime file URL fields including:

- app logos
- user profile images
- file/chat media URLs
- selected NFT/document URL fields
