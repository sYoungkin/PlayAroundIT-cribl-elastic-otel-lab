#!/usr/bin/env bash
set -euo pipefail

#### CONFIG ####
ELASTIC_VERSION="9.x"
ELASTIC_PASSWORD="${ADMIN_PWD:-adminuser123!}"
TIMEZONE="Europe/Berlin"
CERT_SRC="/tmp"
CERT_DST="/etc/kibana/certs"

#### FUNCTIONS ####
log()  { echo "[INFO] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

require_root() { [[ "$EUID" -eq 0 ]] || fail "Please run this script as root."; }

#### MAIN ####
require_root

log "Updating packages and installing dependencies..."
apt-get update -y
apt-get install -y wget curl apt-transport-https gnupg ca-certificates openssl

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

log "Installing Kibana..."
apt-get install -y kibana

log "Installing our lab certificates..."
mkdir -p "$CERT_DST"
cp "$CERT_SRC/ca.crt"           "$CERT_DST/ca.crt"
cp "$CERT_SRC/kibana-chain.crt" "$CERT_DST/kibana-chain.crt"
cp "$CERT_SRC/kibana.key"       "$CERT_DST/kibana.key"
chown -R root:kibana "$CERT_DST"
chmod 750 "$CERT_DST"
chmod 640 "$CERT_DST"/*
rm -f "$CERT_SRC/ca.crt" "$CERT_SRC/kibana-chain.crt" "$CERT_SRC/kibana.key"

log "Writing kibana.yml..."
KIBANA_CONF="/etc/kibana/kibana.yml"
cat > "$KIBANA_CONF" <<EOF
server.host: "0.0.0.0"
server.port: 5601

# Kibana UI HTTPS (browser -> Kibana)
server.ssl.enabled: true
server.ssl.certificate: ${CERT_DST}/kibana-chain.crt
server.ssl.key: ${CERT_DST}/kibana.key

# ─── Elasticsearch connection — MANUAL BOOTSTRAP STEP ───────────────
# Replace ELASTIC_HOST with elastic-1's IP, then: systemctl restart kibana
elasticsearch.hosts: ["https://elastic-1:9200"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "${ELASTIC_PASSWORD}"
elasticsearch.ssl.certificateAuthorities: ["${CERT_DST}/ca.crt"]
elasticsearch.ssl.verificationMode: full
EOF

log "Generating Kibana encryption keys..."
ENC_KEYS=$(/usr/share/kibana/bin/kibana-encryption-keys generate -q 2>/dev/null \
  | grep -E '^xpack' || true)
if [[ -n "$ENC_KEYS" ]]; then
  echo "" >> "$KIBANA_CONF"
  echo "# Encryption keys" >> "$KIBANA_CONF"
  echo "$ENC_KEYS" >> "$KIBANA_CONF"
else
  log "WARN: encryption key generation produced no output; adding saved-objects key only."
  echo "" >> "$KIBANA_CONF"
  echo "xpack.encryptedSavedObjects.encryptionKey: \"$(openssl rand -hex 32)\"" >> "$KIBANA_CONF"
fi

log "Enabling and starting Kibana..."
systemctl daemon-reload
systemctl enable kibana.service
systemctl start kibana.service

VM_IP=$(ip -4 addr show | grep -oP '192\.168\.65\.\d+' | head -1)
log "Kibana installation complete."
log "Kibana UI:  https://${VM_IP}:5601"
log "Connected to Elasticsearch at https://elastic-1:9200 (full TLS verification)."