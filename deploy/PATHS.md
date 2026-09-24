# Deployment Paths Configuration

This document explains how file paths are determined in the deployment system and how to customize them.

## Default Path Structure

By default, the deployment system assumes the following directory structure:

```
ethora-monoserver/
├── deploy/              # Deployment scripts and configs
├── ethora-backend/      # Backend services
│   ├── services/api/             # Main backend API (new layout)
│   ├── services/ai/ai-service/   # AI service (optional, new layout)
│   └── services/ai/docs-parse/   # Docs parse service (optional, new layout)
├── ethora-app-reactjs/  # Frontend application
└── ejabberd-docker/     # Ejabberd XMPP server
```

The deployment system calculates paths relative to the `deploy/` directory:
- **Base Directory**: `../` (parent of `deploy/`)
- **Backend Directory**: `{base}/ethora-backend`
- **Frontend Directory**: `{base}/ethora-app-reactjs`
- **Ejabberd Directory**: `{base}/ejabberd-docker`

## Files Created During Deployment

The deployment creates the following files:

### Environment Files
- `{base}/ethora-backend/services/api/.env` - Backend API environment variables
- `{base}/ethora-backend/services/ai/ai-service/.env` - AI service environment (if enabled)
- `{base}/ethora-backend/services/ai/docs-parse/.env` - Docs parse service environment (if enabled)
- `{base}/ethora-app-reactjs/.env` - Frontend environment variables

### Docker Data Volumes
- `{base}/ethora-backend/infra/docker/data/mongo/` - MongoDB data
- `{base}/ethora-backend/infra/docker/data/minio/` - MinIO data
- `{base}/ethora-backend/infra/docker/data/redis/` - Redis data
- `{base}/ejabberd-docker/docker-data/my-sql/` - MySQL data for Ejabberd
- Docker volume `ai_pgdata` - managed AI embeddings Postgres/pgvector data (when `services.ai_service.pg_url` is not overridden)

### Configuration Files
- `deploy/.deploy.env` - Shared environment variables for scripts
- `deploy/deploy.log` - Deployment log file
- `deploy/docker-compose.ai.yml` - Managed AI embeddings Postgres service definition
- `{base}/ejabberd-docker/docker/ejabberd.yml` - Ejabberd configuration (updated during deployment)

## Customizing Source And Target Paths

You can customize both the source checkout and the target install directory by adding a `paths` section to your `deploy.yml`:

```yaml
paths:
  source: /home/ubuntu/ethora-install-shared
  base: /home/ubuntu/ethora
```

Rules:

- `paths.source` is the canonical checkout / install package directory.
- `paths.base` is the target install/update directory.
- If `paths.base` is omitted, the system installs into `paths.source`.
- In split source/target installs, edit `deploy/config/deploy.yml` only under `paths.source`.
- The target install does not keep a `deploy/` directory.
- Always run deploy scripts from `paths.source/deploy`.

**Application paths are automatically calculated relative to the base:**
- Backend: `{base}/ethora-backend`
- Frontend: `{base}/ethora-app-reactjs`
- Ejabberd: `{base}/ejabberd-docker`

### Example: Deploying from a Different Location

If you want to keep the git checkout separate from the running install:

```yaml
paths:
  source: /home/ubuntu/ethora-install-shared
  base: /home/ubuntu/ethora
```

The system will automatically use:
- Source checkout: `/home/ubuntu/ethora-install-shared`
- Target backend: `/home/ubuntu/ethora/ethora-backend`
- Target frontend: `/home/ubuntu/ethora/ethora-app-reactjs`
- Target ejabberd: `/home/ubuntu/ethora/ejabberd-docker`

**Note**: 
- Both `source` and `base` paths must be absolute paths
- The source directory must exist and contain the monoserver checkout or unpacked install bundle
- The base directory will be created during install if needed

## Docker Compose Paths

The `docker-compose.enterprise.yml` file uses relative paths for volumes. These are relative to where `docker-compose` is executed (typically the base directory).

If you need to customize Docker volume paths, you'll need to:
1. Modify `docker-compose.enterprise.yml` directly, or
2. Use environment variables in the compose file (future enhancement)

## Current Limitations

- Docker volume paths in `docker-compose.enterprise.yml` are hardcoded as relative paths
- The base directory must contain the standard subdirectories (ethora-backend, ethora-app-reactjs, ejabberd-docker)
- All specified paths must be absolute

## Troubleshooting

### "Required directory not found" Error

If you get this error, check:
1. The base path in your `deploy.yml` is correct
2. The base directory actually exists
3. The required subdirectories exist under the base:
   - `ethora-backend/`
   - `ethora-backend/services/api/`
   - `ethora-app-reactjs/`
   - `ejabberd-docker/`
4. You have read permissions to those directories

### Files Created in Wrong Location

If files are created in unexpected locations:
1. Check your `deploy.yml` for the `paths.source` and `paths.base` configuration
2. Verify both paths are absolute (start with `/`)
3. Confirm you edited the canonical config in the source checkout
4. Check the deployment log: `deploy/deploy.log`
5. Verify the calculated paths in the log output

### Example Log Output

When you run the deployment, you'll see:
```
[INFO] Using paths:
[INFO]   Source: /home/ubuntu/ethora-install-shared
[INFO]   Base: /home/ubuntu/ethora
[INFO]   Backend: /home/ubuntu/ethora/ethora-backend
[INFO]   Frontend: /home/ubuntu/ethora/ethora-app-reactjs
[INFO]   Ejabberd: /home/ubuntu/ethora/ejabberd-docker
```

This confirms the paths being used during deployment.
