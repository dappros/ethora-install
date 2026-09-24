# Testing the Deployment Automation

This guide explains how to test the deployment automation system locally without SSL certificates or domain names.

## Quick Start for Local Testing

### 1. Prepare Configuration

```bash
cd deploy
cp config/deploy-local.yml.template config/deploy.yml
```

The local template is pre-configured for localhost testing with:
- All domains set to `localhost`
- SSL disabled
- Simple passwords for testing
- Development mode enabled
- AI and docs services disabled (for basic testing)

### 2. Run the Installer

```bash
sudo ./scripts/install.sh
```

**Note**: The installer will:
- Skip SSL certificate setup
- Skip Nginx configuration
- Skip DNS validation
- Use HTTP instead of HTTPS
- Access services directly on their ports

### 3. Access Services

After deployment, services will be accessible on:

- **Backend API**: `http://localhost:8080`
  - Health check: `curl http://localhost:8080/v1/ping`
  - API docs: `http://localhost:8080/api-docs/`
- **Frontend**: Build directory at `ethora-app-reactjs/dist/` (serve manually or via simple HTTP server)
- **Ejabberd**: 
  - HTTP: `http://localhost:5280`
  - HTTPS: `https://localhost:5443` (uses self-signed cert, browser will warn)
  - Admin: `https://localhost:5443/admin` (admin@localhost / admin)
- **MinIO**: 
  - API: `http://localhost:9000`
  - Console: `http://localhost:9001` (minioroot123 / minioroot123)
- **MongoDB**: `localhost:27017`
- **MySQL**: `localhost:3306` (root / root)
- **Redis**: `localhost:6379`

### 4. Test Basic Functionality

```bash
# Test backend API
curl http://localhost:8080/v1/ping

# Test Ejabberd
docker-compose -f deploy/docker-compose.enterprise.yml exec xmpp /home/ejabberd/bin/ejabberdctl status

# Check all services
./scripts/health-check.sh
```

## Testing in a Separate Directory

If you want to test without affecting your main development environment, you can test in the same directory - the deployment uses Docker containers and won't interfere with your existing setup if ports are available.

However, if you want complete isolation:

### Option 1: Use Different Ports

Modify `deploy.yml` to use different ports to avoid conflicts:

```yaml
services:
  backend:
    port: 8081  # Instead of 8080
databases:
  mongo:
    port: 27018  # Instead of 27017
  mysql:
    port: 3307   # Instead of 3306
  redis:
    port: 6380   # Instead of 6379
```

**Note**: You'll also need to update the Docker Compose file environment variables or modify port mappings.

### Option 2: Stop Existing Services First

If you have services running on the default ports, stop them first:

```bash
# Stop existing Docker services
cd ethora-backend
docker-compose down

cd ../ejabberd-docker
docker-compose -f docker-compose-local.yml down

# Stop PM2 processes
pm2 stop all
```

## What Gets Tested

### Basic Deployment Flow

1. ✅ Prerequisites check (Docker, Node.js, etc.)
2. ✅ Configuration parsing
3. ✅ Environment file generation
4. ✅ Docker services startup
5. ✅ Database initialization
6. ✅ Service initialization (MongoDB replica set, Ejabberd admin)
7. ✅ Backend app initialization
8. ✅ Node.js services build and start
9. ✅ Health checks

### Services Tested

- ✅ MongoDB (with replica set)
- ✅ Redis
- ✅ MinIO
- ✅ Centrifugo
- ✅ MySQL (for Ejabberd)
- ✅ Ejabberd XMPP server
- ✅ Backend API (Node.js)
- ✅ Frontend build

## Debugging

### Check Logs

```bash
# Deployment log
cat deploy/deploy.log

# Docker services
docker-compose -f deploy/docker-compose.enterprise.yml logs

# PM2 processes
pm2 logs

# Specific service
pm2 logs backend
```

### Manual Service Checks

```bash
# Check Docker containers
docker-compose -f deploy/docker-compose.enterprise.yml ps

# Check PM2 processes
pm2 list

# Test API endpoint
curl http://localhost:8080/v1/ping

# Test Ejabberd
docker-compose -f deploy/docker-compose.enterprise.yml exec xmpp /home/ejabberd/bin/ejabberdctl status
```

### Common Issues

#### Port Conflicts

If ports are already in use:

```bash
# Find what's using a port
sudo lsof -i :8080
sudo lsof -i :27017

# Stop conflicting services or change ports in deploy.yml
```

#### Docker Services Not Starting

```bash
# Check Docker logs
docker-compose -f deploy/docker-compose.enterprise.yml logs mongo
docker-compose -f deploy/docker-compose.enterprise.yml logs xmpp

# Restart services
docker-compose -f deploy/docker-compose.enterprise.yml restart
```

#### Backend Not Starting

```bash
# Check PM2 logs
pm2 logs backend --lines 50

# Check environment variables
pm2 env backend

# Restart backend
pm2 restart backend
```

#### Frontend Build Fails

```bash
cd ethora-app-reactjs
npm install
npm run build
```

## Testing Checklist

- [ ] All Docker containers start successfully
- [ ] MongoDB replica set initializes
- [ ] Ejabberd admin user is created
- [ ] Backend API responds to `/v1/ping`
- [ ] Frontend builds successfully
- [ ] Health checks pass
- [ ] Can access MinIO console
- [ ] Can connect to Ejabberd

## Cleanup After Testing

To remove the test deployment:

```bash
# Stop all services
docker-compose -f deploy/docker-compose.enterprise.yml down
pm2 delete all

# Remove data volumes (optional - removes all data)
docker-compose -f deploy/docker-compose.enterprise.yml down -v

# Remove generated files
rm -f deploy/config/deploy.yml
rm -f deploy/.deploy.env
rm -f deploy/deploy.log
rm -f ethora-backend/backend/.env
rm -f ethora-app-reactjs/.env
```

## Next Steps

Once local testing is successful:

1. Test with real domains (update `deploy.yml` with your domains)
2. Test SSL certificate generation
3. Test Nginx configuration
4. Test in a staging environment
5. Prepare for production deployment

