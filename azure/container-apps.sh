#!/bin/bash

# Resource & Location
RESOURCE_GROUP="ohc-rg"
LOCATION="centralindia"

# Application & Services
APP_NAME="ohc-backend"
WORKER_APP_NAME="ohc-celery-worker"
BEAT_APP_NAME="ohc-celery-beat"
DOCKER_IMAGE="ghcr.io/ohcnetwork/care:production-latest"

# Database & Caching
POSTGRES_SERVER_NAME="ohc-postgres"
POSTGRES_DB="ohcdb"
POSTGRES_USER="ohcadmin"
POSTGRES_PASSWORD="Test@123456"
POSTGRES_PORT="5432"
REDIS_NAME="ohc-redis"

# Storage
STORAGE_ACCOUNT_NAME="ohcteststorage"
STORAGE_CONTAINER_NAME="ohctestfiles"

# Flexify Configuration (S3 Compatible)
FLEXIFY_ENDPOINT="https://s3.flexify.io"
FLEXIFY_ACCESS_KEY="FlIONbXW06aRCq4ZY3w7hxL2"
FLEXIFY_SECRET_KEY="uMTaYqQSUn0K3kkvJN5FIIiqA3MizT5HpSZDyY"

# Sentry Configuration
SENTRY_DSN=https://0ef536cb49d03d3c2247fb0eac7f95ab@o4509054753964032.ingest.de.sentry.io/4509054759796816
SENTRY_ENV="care-azure"

# Create resource group
echo "Creating resource group..."
az group create --name $RESOURCE_GROUP --location $LOCATION

# Create PostgreSQL server
echo "Creating PostgreSQL server..."
az postgres flexible-server create \
  --name $POSTGRES_SERVER_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --admin-user $POSTGRES_USER \
  --admin-password $POSTGRES_PASSWORD \
  --database-name $POSTGRES_DB \
  --sku-name Standard_D4ds_v5 \
  --storage-size 32 \
  --version 16 \
  --tier GeneralPurpose \
  --public-access 0.0.0.0 \
  --yes

# Configure PostgreSQL firewall (allow all Azure services)
echo "Configuring PostgreSQL firewall..."
az postgres flexible-server firewall-rule create \
  --name $POSTGRES_SERVER_NAME \
  --resource-group $RESOURCE_GROUP \
  --rule-name AllowAzureServices \
  --start-ip-address 0.0.0.0 \
  --end-ip-address 0.0.0.0

# Create Redis Cache
echo "Creating Redis Cache..."
az redis create \
  --name $REDIS_NAME \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku Basic \
  --vm-size C1 \
  --redis-version 6

# Create WAF-enabled Application Gateway
echo "Creating Application Gateway with WAF..."
az network application-gateway create \
  --name ohc-app-gateway \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION \
  --sku WAF_v2 \
  --capacity 2 \
  --gateway-ip-configurations "name=appGatewayIpConfig subnet=/subscriptions/{subscription-id}/resourceGroups/{resource-group}/providers/Microsoft.Network/virtualNetworks/{vnet-name}/subnets/{subnet-name}" \
  --frontend-ports "name=appGatewayFrontendPort port=80" \
  --http-settings "name=appGatewayHttpSettings port=80 cookie-based-affinity Disabled" \
  --backend-pool "name=appGatewayBackendPool backend-addresses=[\"${APP_NAME}.${LOCATION}.azurecontainerapps.io\"]" \
  --waf-configuration "enabled=true firewall-mode=Prevention"

# Get connection details for PostgreSQL & Redis
echo "Getting connection details..."
# PostgreSQL configuration
POSTGRES_HOST="${POSTGRES_SERVER_NAME}.postgres.database.azure.com"
DATABASE_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_HOST}:${POSTGRES_PORT}/${POSTGRES_DB}?sslmode=require"

# Redis configuration
REDIS_HOST="$REDIS_NAME.redis.cache.windows.net"
REDIS_PORT="6380"
REDIS_KEY=$(az redis list-keys --name $REDIS_NAME --resource-group $RESOURCE_GROUP --query primaryKey -o tsv)
REDIS_URL="rediss://:${REDIS_KEY}@${REDIS_HOST}:${REDIS_PORT}/0"
CELERY_BROKER_URL=$REDIS_URL

# Other configuration
JWKS_BASE64="eyJrZXlzIjogW3sibiI6ICJ4X21fNGNKQ3NHTHN4WkFIa2VCbFZQa2ZqNFNSckdHN3UySERFM3VLX3dFNERhTWhHQ2lxTXFsaTFDM2pxSE5JTVhuWV9ab1M5R3pHbnJpdGg1UUZGVDlLMGtBdF9YaXBJNnV1djcwOWtOV2FFNXZrYks4VlFRcFd2UFp4NUJSeTBGay0wU2lxZG1xOTNJRXdUTnNTLUpETnRXQm5VX0F1cjU0UXptQmI3SmhfOGttRDAtaHhROVZVejRpSUU3QTlySU5vQXNHSHhfdGtuNXd6YmpPR3F2Q3JqRi1RWXo0OGJXVkZzVVliNkFqUlFrZER2RWVwQlpNSHZsNVUxQlZxOVdRTTJGTmRUR0tJb3ZYeDRuTDFybUVONHpxbEpqWmc2bEZiODVuOUhkc01VblFiSXhkUjVlVl8wWmNVaHBrQWc0NldrejRZWkxMNm5NaGR0RmFTMXciLCAiZSI6ICJBUUFCIiwgImQiOiAiRXo4T3dDZ2xxZnREWlhwSXVEbjhGck1KWGhNNHZfb0NDdlZNUko1QjBPd3BuR3BrWDRKZWF4VFJYYkZ5OVQzdkowX2VXZjRQcl9XZUloMk5HZnpkaGw5NmtJUzd5R2JxQkhSY0U3a2ZhVWFkbHlDTVdnZDV5TEk1aWVOQUw5N2w4X1o2N0w5NHRIX3VlUF80Q1pXV0hGVTNieXJ4bHVzSld6NmZ5SFVPczlVSDFxV284V1RNOVp0RndqV0cxOWpkUXZ1RkQ0Z0x4UEJYZEk5ZV9zdTNwbmZHR0ZkN0xfMDFwcEFkQ2Y5eHhNTWFEel8wZ0xXM0NENFhnWU1rS2d3eDdKWlVlN0VaWFhyU0lETzFZN202MmF4NEpZRU5pSDFiaVlwQk15dmVfM3FzdnRQOWR4eVg2VkFROGZFNVdnOTBCcThsd1F0NzROWmgzMHhDY0dDNHFRIiwgInAiOiAiOXhXeXNjbVExT1FRcEptWmkzZDR5Tk5qT29Ja3lQVDRyZVRBNlJJdW5PSjVDUVFiVE1BVlpzUmsxa05rQ2R1cGVQU1ZnNWVXNktpOXZIV1M3b2NnclVEYzJTRkw0RWtNY21UR2lHRnh1YVIzNHRMTXpUQlJEVVFxZnR6WGxraGRJWmdKenJCT2h4NEEyZ1FQTnRrNkNVSEJWRGRncng0RmR3c21SaElSOU9rIiwgInEiOiAienpEb2FvclpqZ2ZPeDVHckFJZ3R3SGVhM29vQTlqbkFSeDdvM1V2bHprY3p1eC1DY1JORGppS3duaGxzVEROWFFWRTBXUlpWa0ZTQ0JVU3JSS1dLd0JGcnFVQzhlMkxwQVpBb0ZTQ0dqdllIMi1hdGUxeEhxc0NGY09OVlVYM1JXcFd4OFQ4RGhSNGpfaTRKN3g0d2VHc1hkRHRpelY2eHlZMmNHSjltY2I4IiwgImRwIjogInpUV3FLZHA4ZlRQRlZzOXpKTV9lOHZ3TnA2UTdKT1BBUGJ5Rk00MjBSUHdiQmdfeEZIZGJ6dlJCdzJwSkJaNzRTOHJtLWxuR0xna25QQVJ5T2NUa3NMXzBMQ2xwT1NleVBMZlI0NmI2cXZJYjE3aTMtNXFyVmxkTTZfeEMyVF9VaVhnYWZSMFV1MGVCOFlfNWl0WXpTMGpmWmpCd0RrRGl6UkhuZ2I2MFJ6RSIsICJkcSI6ICJYZHdoSGNyaV9ZV3A5aHlXWV9wTkI2am5Qck16OWxkNU5IN2JMUTBxQVFXZWVNR3dmUHNtR21pNnJCU0dUQXJpRjFQckxBU0RKSXcwRHFEcUdZSUkxalBPR3ZHWnNTZkF1SldPb3V1R0taTnBRZ1JCU09Zb0RVR0Q4Zno2ZEoxVHp2NkxpdWRwOTg4TXJTUThHZGdLU3pMd2dCWTdEeUE3MkR2UG9CUHQtODgiLCAicWkiOiAiSlF0UUJERXdnQVVMcWJFRWoybmdyXy02aV9pUmdRWmJTQ0hXNGdpZG5fdHlwdUJWS2R0ZW1jT3J6M3NnTnk0ekZrZElTbUZfbmdnbFlJb080TjNza1NNUXdGY1B0S1kzWUVlT2ZGNzMzRDZaTVJtSTFTby12QU54YVBDUkREbnUwTWk1TnUzbS02SkhGSFF5RDU2ZTFsQUlwUS1lakpuTWR6MXQ0aUplbEFzIiwgImt0eSI6ICJSU0EiLCAia2lkIjogIlhjckcyVS0tR3B4SVhORXpKOWNWREdRaEUzeXlIamREMDN1aDZmYXpRX2siLCAiYWxnIjogIlJTMjU2In1dfQ=="

# Create Container App Environment
echo "Creating Container App Environment..."
az containerapp env create \
  --name ohc-env \
  --resource-group $RESOURCE_GROUP \
  --location $LOCATION

# Common environment variables for all apps
COMMON_ENV_VARS=(
  "DJANGO_SETTINGS_MODULE=config.settings.production"
  "DATABASE_URL=$DATABASE_URL"
  "REDIS_URL=$REDIS_URL"
  "CORS_ALLOWED_ORIGINS=[\"https://care.areeb.dev\", \"https://s3.flexify.io\"]"
  "CELERY_BROKER_URL=$CELERY_BROKER_URL"
  "BUCKET_PROVIDER=aws"
  "BUCKET_REGION=$LOCATION"
  "BUCKET_KEY=$FLEXIFY_ACCESS_KEY"
  "BUCKET_SECRET=$FLEXIFY_SECRET_KEY"
  "BUCKET_ENDPOINT=$FLEXIFY_ENDPOINT"
  "BUCKET_HAS_FINE_ACL=True"
  "FILE_UPLOAD_BUCKET=$STORAGE_CONTAINER_NAME"
  "FILE_UPLOAD_BUCKET_ENDPOINT=$FLEXIFY_ENDPOINT"
  "FACILITY_S3_BUCKET=$STORAGE_CONTAINER_NAME"
  "FACILITY_S3_BUCKET_ENDPOINT=$FLEXIFY_ENDPOINT"
  "POSTGRES_USER=$POSTGRES_USER"
  "POSTGRES_PASSWORD=$POSTGRES_PASSWORD"
  "POSTGRES_HOST=$POSTGRES_HOST"
  "POSTGRES_PORT=$POSTGRES_PORT"
  "POSTGRES_DB=$POSTGRES_DB"
  "REDIS_AUTH_TOKEN=$REDIS_KEY"
  "REDIS_HOST=$REDIS_HOST"
  "REDIS_PORT=$REDIS_PORT"
  "REDIS_DATABASE=0"
  "JWKS_BASE64=$JWKS_BASE64"
  "DISABLE_COLLECTSTATIC=1"
  "SENTRY_DSN=$SENTRY_DSN"
  "SENTRY_ENVIRONMENT=$SENTRY_ENV"
)

# Deploy main app
echo "Deploying main app: $APP_NAME..."
az containerapp create \
  --name $APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --environment ohc-env \
  --image $DOCKER_IMAGE \
  --env-vars "${COMMON_ENV_VARS[@]}" \
  --target-port 9000 \
  --ingress external \
  --min-replicas 1 \
  --max-replicas 3 \
  --command "./app/start.sh"

# Deploy worker app
echo "Deploying worker app: $WORKER_APP_NAME..."
az containerapp create \
  --name $WORKER_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --environment ohc-env \
  --image $DOCKER_IMAGE \
  --env-vars "${COMMON_ENV_VARS[@]}" \
  --min-replicas 1 \
  --max-replicas 3 \
  --command "./app/celery_worker.sh"

# Deploy beat app
echo "Deploying beat app: $BEAT_APP_NAME..."
az containerapp create \
  --name $BEAT_APP_NAME \
  --resource-group $RESOURCE_GROUP \
  --environment ohc-env \
  --image $DOCKER_IMAGE \
  --env-vars "${COMMON_ENV_VARS[@]}" \
  --min-replicas 1 \
  --max-replicas 3 \
  --command "./app/celery_beat.sh"

echo "Deployment complete. Web App URL: https://${APP_NAME}.${LOCATION}.azurecontainerapps.io"
