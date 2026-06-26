#!/usr/bin/env bash
set -euo pipefail

#### CONFIG ####
TIMEZONE="Europe/Berlin"
CRIBL_HOME="/opt/cribl"
CRIBL_USER="cribl"
PKG_SRC="/tmp/cribl.tgz"
CERT_SRC="/tmp"
CERT_DST="${CRIBL_HOME}/lab-certs"   # park certs here for manual ES-destination setup later

#### FUNCTIONS ####
log()  { echo "[INFO] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
require_root() { [[ "$EUID" -eq 0 ]] || fail "Please run this script as root."; }

#### MAIN ####
require_root

log "Updating packages and installing dependencies..."
apt-get update -y
apt-get install -y ca-certificates

log "Setting timezone to ${TIMEZONE}..."
timedatectl set-timezone "$TIMEZONE"

log "Creating dedicated '${CRIBL_USER}' user..."
if ! id "$CRIBL_USER" &>/dev/null; then
  useradd --system --create-home --shell /bin/bash "$CRIBL_USER"
fi

log "Extracting Cribl package to /opt..."
[[ -f "$PKG_SRC" ]] || fail "Cribl package not found at ${PKG_SRC}"
tar zxf "$PKG_SRC" -C /opt/
rm -f "$PKG_SRC"

log "Parking lab certificates for later config..."
mkdir -p "$CERT_DST"
cp "$CERT_SRC/ca.crt"          "$CERT_DST/ca.crt"
cp "$CERT_SRC/cribl-chain.crt" "$CERT_DST/cribl-chain.crt"
cp "$CERT_SRC/cribl.key"       "$CERT_DST/cribl.key"
rm -f "$CERT_SRC/ca.crt" "$CERT_SRC/cribl-chain.crt" "$CERT_SRC/cribl.key"

log "Setting ownership of ${CRIBL_HOME} to ${CRIBL_USER} (install+run as same user)..."
chown -R "${CRIBL_USER}:${CRIBL_USER}" "$CRIBL_HOME"

log "Enabling Cribl boot-start as systemd service (user=${CRIBL_USER})..."
"${CRIBL_HOME}/bin/cribl" boot-start enable -m systemd -u "$CRIBL_USER"

log "Configuring trusted CA for Cribl (NODE_EXTRA_CA_CERTS)..."
mkdir -p /etc/systemd/system/cribl.service.d
cat > /etc/systemd/system/cribl.service.d/ca-trust.conf <<EOF
[Service]
Environment="NODE_EXTRA_CA_CERTS=${CERT_DST}/ca.crt"
EOF
systemctl daemon-reload

log "Starting Cribl..."
systemctl daemon-reload
systemctl start cribl

VM_IP=$(ip -4 addr show | grep -oP '192\.168\.65\.\d+' | head -1)
log "Cribl Stream installation complete."
log "Cribl UI: http://${VM_IP}:9000"
log "Login:    admin / admin  (CHANGE THIS after first login)"
log ""
log "Lab certs parked at: ${CERT_DST}"
log "  (use ca.crt when configuring the Elasticsearch destination)"