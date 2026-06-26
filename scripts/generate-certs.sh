#!/usr/bin/env bash
set -euo pipefail

CERTS_DIR="$(cd "$(dirname "$0")/.." && pwd)/certs"
mkdir -p "$CERTS_DIR"

DAYS=825

# ─── Certificate Authority ──────────────────────────────────────────────────
echo "[INFO] Generating CA key and certificate..."
openssl genrsa -out "$CERTS_DIR/ca.key" 4096
openssl req -x509 -new -nodes \
  -key "$CERTS_DIR/ca.key" \
  -sha256 -days $DAYS \
  -subj "//C=DE\ST=Hesse\L=Lab\O=PlayAroundIT\CN=PlayAroundIT-Lab-CA" \
  -out "$CERTS_DIR/ca.crt"
echo "[INFO] CA done."

# ─── Node certificates ──────────────────────────────────────────────────────
# Args:
#   $1 = tier name (also the canonical CN, e.g. "elasticsearch")
#   $2 = SAN list (comma-separated openssl SAN entries, e.g. "DNS:elasticsearch,IP:192.168.65.11,...")
generate_node_cert() {
  local NODE="$1"
  local SANS="$2"
  echo "[INFO] Generating certificate for ${NODE}..."

  openssl genrsa -out "$CERTS_DIR/${NODE}.key" 2048

  openssl req -new \
    -key "$CERTS_DIR/${NODE}.key" \
    -subj "//C=DE\ST=Hesse\L=Lab\O=PlayAroundIT\CN=${NODE}" \
    -out "$CERTS_DIR/${NODE}.csr"

  # SANs must be supplied via an extfile; -subj cannot carry them.
  cat > "$CERTS_DIR/${NODE}.ext" <<EOF
subjectAltName = ${SANS}
EOF

  openssl x509 -req \
    -in "$CERTS_DIR/${NODE}.csr" \
    -CA "$CERTS_DIR/ca.crt" \
    -CAkey "$CERTS_DIR/ca.key" \
    -CAcreateserial \
    -extfile "$CERTS_DIR/${NODE}.ext" \
    -out "$CERTS_DIR/${NODE}.crt" \
    -days $DAYS \
    -sha256

  # Emit the full chain (leaf + CA) for servers that must present it.
  cat "$CERTS_DIR/${NODE}.crt" "$CERTS_DIR/ca.crt" > "$CERTS_DIR/${NODE}-chain.crt"

  rm "$CERTS_DIR/${NODE}.csr" "$CERTS_DIR/${NODE}.ext"
  echo "[INFO] ${NODE} certificate + chain done."
}

# ─── Per-tier certs (service name canonical CN; node names + IPs in SANs) ────
generate_node_cert "elasticsearch" \
  "DNS:elasticsearch,DNS:elastic-1,DNS:elastic-2,DNS:elastic-3,DNS:localhost,IP:192.168.65.11,IP:192.168.65.12,IP:192.168.65.13,IP:127.0.0.1"

generate_node_cert "kibana" \
  "DNS:kibana,DNS:kibana-1,DNS:kibana-2,DNS:localhost,IP:192.168.65.21,IP:192.168.65.22,IP:127.0.0.1"

generate_node_cert "cribl" \
  "DNS:cribl,DNS:cribl-1,DNS:cribl-2,DNS:cribl-3,DNS:localhost,IP:192.168.65.31,IP:192.168.65.32,IP:192.168.65.33,IP:127.0.0.1"

generate_node_cert "app" \
  "DNS:app,DNS:app-1,DNS:app-2,DNS:app-3,DNS:localhost,IP:192.168.65.41,IP:192.168.65.42,IP:192.168.65.43,IP:127.0.0.1"

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "[INFO] Certificates generated in: $CERTS_DIR"
ls -1 "$CERTS_DIR"