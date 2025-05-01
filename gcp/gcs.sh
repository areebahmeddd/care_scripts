#!/bin/bash

BUCKET_NAME="ohc-bucket-01"
LOCATION="asia-south1"
BACKEND_BUCKET_NAME="ohc-backend-bucket"
URL_MAP_NAME="ohc-url-map"
HTTP_PROXY_NAME="ohc-http-proxy"
HTTPS_PROXY_NAME="ohc-https-proxy"
IP_ADDRESS_NAME="ohc-ip-address"
HTTP_FORWARDING_RULE="ohc-http-forwarding-rule"
HTTPS_FORWARDING_RULE="ohc-https-forwarding-rule"
SSL_CERT_NAME="ohc-cert"
DOMAIN="care.areeb.dev"

echo "Creating bucket..."
gsutil mb -l $LOCATION gs://$BUCKET_NAME

echo "Setting bucket permissions..."
gsutil iam ch allUsers:objectViewer gs://$BUCKET_NAME

echo "Uploading build files to bucket..."
gsutil -m cp -r build/* gs://$BUCKET_NAME/

echo "Setting website configuration..."
gsutil web set -m index.html gs://$BUCKET_NAME

echo "Setting cache control headers..."
gsutil -m setmeta -h "Cache-Control:no-cache, no-store, must-revalidate" \
  gs://$BUCKET_NAME/service-worker.js \
  gs://$BUCKET_NAME/*.js.map

gsutil -m setmeta -h "Cache-Control:public, max-age=3600" \
  gs://$BUCKET_NAME/index.html \
  gs://$BUCKET_NAME/robots.txt

gsutil -m setmeta -h "Cache-Control:public, max-age=86400" \
  gs://$BUCKET_NAME/manifest.webmanifest \
  gs://$BUCKET_NAME/manifest.json \
  gs://$BUCKET_NAME/favicon.ico

gsutil -m setmeta -h "Cache-Control:public, max-age=31536000" \
  gs://$BUCKET_NAME/static/* \
  gs://$BUCKET_NAME/assets/* \
  gs://$BUCKET_NAME/*.js \
  gs://$BUCKET_NAME/*.css \
  gs://$BUCKET_NAME/*.png \
  gs://$BUCKET_NAME/*.svg \
  gs://$BUCKET_NAME/*.jpg

echo "Creating backend bucket..."
gcloud compute backend-buckets create $BACKEND_BUCKET_NAME \
  --gcs-bucket-name=$BUCKET_NAME \
  --enable-cdn

echo "Creating URL map..."
gcloud compute url-maps create $URL_MAP_NAME \
  --default-backend-bucket=$BACKEND_BUCKET_NAME

echo "Creating HTTP proxy..."
gcloud compute target-http-proxies create $HTTP_PROXY_NAME \
  --url-map=$URL_MAP_NAME

echo "Creating global static IP address..."
gcloud compute addresses create $IP_ADDRESS_NAME --global

IP_ADDRESS=$(gcloud compute addresses describe $IP_ADDRESS_NAME --global --format="get(address)")
echo "Using IP address: $IP_ADDRESS"

echo "Creating HTTP forwarding rule..."
gcloud compute forwarding-rules create $HTTP_FORWARDING_RULE \
  --load-balancing-scheme=EXTERNAL \
  --global \
  --address=$IP_ADDRESS \
  --target-http-proxy=$HTTP_PROXY_NAME \
  --ports=80

echo "Creating SSL certificate..."
gcloud compute ssl-certificates create $SSL_CERT_NAME \
  --domains=$DOMAIN

echo "Creating HTTPS proxy..."
gcloud compute target-https-proxies create $HTTPS_PROXY_NAME \
  --url-map=$URL_MAP_NAME \
  --ssl-certificates=$SSL_CERT_NAME

echo "Creating HTTPS forwarding rule..."
gcloud compute forwarding-rules create $HTTPS_FORWARDING_RULE \
  --load-balancing-scheme=EXTERNAL \
  --global \
  --address=$IP_ADDRESS \
  --target-https-proxy=$HTTPS_PROXY_NAME \
  --ports=443


echo "Deployment complete. The app is now live at https://$DOMAIN"
echo "IP Address: $IP_ADDRESS"
echo "SSL Certificate Status: $(gcloud compute ssl-certificates describe $SSL_CERT_NAME --format='get(managed.status)')"
