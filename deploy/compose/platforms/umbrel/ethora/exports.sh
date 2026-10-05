# Per-install secrets of the Ethora package, derived from the Umbrel seed so
# they are stable across restarts and updates (docker-compose.yml passes them
# to the config service, which renders every service's configuration).
export APP_ETHORA_JWT_SECRET="$(derive_entropy "${app_entropy_identifier}-jwt-secret")"
export APP_ETHORA_REFRESH_SECRET="$(derive_entropy "${app_entropy_identifier}-refresh-secret")"
export APP_ETHORA_XMPP_SECRET="$(derive_entropy "${app_entropy_identifier}-xmpp-secret")"
export APP_ETHORA_XMPP_JWT_SECRET="$(derive_entropy "${app_entropy_identifier}-xmpp-jwt-secret")"
export APP_ETHORA_XMPP_ADMIN_PASSWORD="$(derive_entropy "${app_entropy_identifier}-xmpp-admin-password")"
export APP_ETHORA_INTERNAL_REQUESTS_SECRET="$(derive_entropy "${app_entropy_identifier}-internal-requests-secret")"
export APP_ETHORA_MYSQL_ROOT_PASSWORD="$(derive_entropy "${app_entropy_identifier}-mysql-root-password")"
export APP_ETHORA_MINIO_ROOT_USER="ethora-$(derive_entropy "${app_entropy_identifier}-minio-root-user" | head -c 12)"
export APP_ETHORA_MINIO_ROOT_PASSWORD="$(derive_entropy "${app_entropy_identifier}-minio-root-password")"
export APP_ETHORA_CENTRIFUGO_API_KEY="$(derive_entropy "${app_entropy_identifier}-centrifugo-api-key")"
export APP_ETHORA_CENTRIFUGO_HMAC_SECRET="$(derive_entropy "${app_entropy_identifier}-centrifugo-hmac-secret")"
export APP_ETHORA_CENTRIFUGO_ADMIN_PASSWORD="$(derive_entropy "${app_entropy_identifier}-centrifugo-admin-password")"
export APP_ETHORA_CENTRIFUGO_ADMIN_SECRET="$(derive_entropy "${app_entropy_identifier}-centrifugo-admin-secret")"
# At-rest encryption: a passphrase for wallet keys, and "<64 hex>:<32 hex>" AES
# key and IV pairs (derive_entropy yields 64 hex characters).
export APP_ETHORA_CRYPTOPAIR_SECRET="$(derive_entropy "${app_entropy_identifier}-cryptopair-secret")"
export APP_ETHORA_SECRET_FOR_DB_ENCRYPTION="$(derive_entropy "${app_entropy_identifier}-db-encryption-key"):$(derive_entropy "${app_entropy_identifier}-db-encryption-iv" | head -c 32)"
export APP_ETHORA_SECRET_FOR_FILES_ENCRYPTION="$(derive_entropy "${app_entropy_identifier}-files-encryption-key"):$(derive_entropy "${app_entropy_identifier}-files-encryption-iv" | head -c 32)"
