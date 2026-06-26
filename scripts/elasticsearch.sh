#!/usr/bin/env bash
set -euo pipefail

#### CONFIG ####
ELASTIC_VERSION="9.x"
ELASTIC_USER="elastic"
ELASTIC_PASSWORD="${ADMIN_PWD:-adminuser123!}"
TIMEZONE="Europe/Berlin"
CLUSTER_NAME="cribl-elastic-otel-lab"
CERT_SRC="/tmp"
CERT_DST="/etc/elasticsearch/certs"

#### FUNCTIONS ####
log()  { echo "[INFO] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

require_root() {
  [[ "$EUID" -eq 0 ]] || fail "Please run this script as root."
}

wait_for_elasticsearch() {
  log "Waiting for Elasticsearch to become available..."
  local retries=30
  until curl -sk -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
    https://localhost:9200 >/dev/null 2>&1; do
    retries=$((retries - 1))
    [[ $retries -gt 0 ]] || fail "Elasticsearch did not become available in time."
    log "Not ready yet, retrying in 10s... (${retries} attempts left)"
    sleep 10
  done
  log "Elasticsearch is up."
}

#### MAIN ####
require_root

log "Updating packages and installing dependencies..."
apt-get update -y
apt-get install -y wget curl apt-transport-https gnupg ca-certificates

log "Setting timezone to ${TIMEZONE}..."
timedatectl set-timezone "$TIMEZONE"

log "Adding Elastic GPG key..."
wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch \
  | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg

log "Adding Elastic ${ELASTIC_VERSION} APT repository..."
echo "deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/${ELASTIC_VERSION}/apt stable main" \
  > /etc/apt/sources.list.d/elastic-${ELASTIC_VERSION}.list

log "Updating package index..."
apt-get update -y

log "Installing Elasticsearch..."
apt-get install -y elasticsearch

log "Installing our lab certificates..."
mkdir -p "$CERT_DST"
cp "$CERT_SRC/ca.crt"                  "$CERT_DST/ca.crt"
cp "$CERT_SRC/elasticsearch-chain.crt" "$CERT_DST/elasticsearch-chain.crt"
cp "$CERT_SRC/elasticsearch.key"       "$CERT_DST/elasticsearch.key"
chown -R root:elasticsearch "$CERT_DST"
chmod 750 "$CERT_DST"
chmod 640 "$CERT_DST"/*
rm -f "$CERT_SRC/ca.crt" "$CERT_SRC/elasticsearch-chain.crt" "$CERT_SRC/elasticsearch.key"

log "Resetting Elasticsearch keystore (clearing auto-config secrets)..."
ES_KEYSTORE="/usr/share/elasticsearch/bin/elasticsearch-keystore"
rm -f /etc/elasticsearch/elasticsearch.keystore
$ES_KEYSTORE create
chown root:elasticsearch /etc/elasticsearch/elasticsearch.keystore
chmod 660 /etc/elasticsearch/elasticsearch.keystore

log "Setting elastic bootstrap password..."
echo "$ELASTIC_PASSWORD" | $ES_KEYSTORE add -f bootstrap.password

log "Writing elasticsearch.yml..."
cat > /etc/elasticsearch/elasticsearch.yml <<EOF
cluster.name: ${CLUSTER_NAME}
node.name: $(hostname)
network.host: 0.0.0.0
http.port: 9200
discovery.type: single-node

xpack.security.enabled: true

xpack.security.http.ssl:
  enabled: true
  key: certs/elasticsearch.key
  certificate: certs/elasticsearch-chain.crt
  certificate_authorities: certs/ca.crt
EOF

log "Ensuring Elasticsearch owns its runtime directories..."
mkdir -p /usr/share/elasticsearch/logs
chown -R elasticsearch:elasticsearch /usr/share/elasticsearch

log "Enabling and starting Elasticsearch..."
systemctl daemon-reload
systemctl enable elasticsearch.service
systemctl start elasticsearch.service

wait_for_elasticsearch

log "Setting kibana_system password via API..."
HTTP_CODE=$(curl -sk -o /dev/null -w "%{http_code}" \
  -X POST \
  -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
  -H "Content-Type: application/json" \
  https://localhost:9200/_security/user/kibana_system/_password \
  -d "{\"password\": \"${ELASTIC_PASSWORD}\"}")
[[ "$HTTP_CODE" == "200" ]] || fail "Failed to set kibana_system password (HTTP ${HTTP_CODE})"
log "kibana_system password set."

VM_IP=$(ip -4 addr show | grep -oP '192\.168\.65\.\d+' | head -1)
log "Elasticsearch installation complete."
log "Elasticsearch: https://${VM_IP}:9200"
log "Username:      ${ELASTIC_USER}"
log "Password:      ${ELASTIC_PASSWORD}"