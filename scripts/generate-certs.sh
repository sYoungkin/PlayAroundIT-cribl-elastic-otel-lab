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
generate_node_cert() {
  local NODE="$1"
  echo "[INFO] Generating certificate for ${NODE}..."

  openssl genrsa -out "$CERTS_DIR/${NODE}.key" 2048

  openssl req -new \
    -key "$CERTS_DIR/${NODE}.key" \
    -subj "//C=DE\ST=Hesse\L=Lab\O=PlayAroundIT\CN=${NODE}" \
    -out "$CERTS_DIR/${NODE}.csr"

  openssl x509 -req \
    -in "$CERTS_DIR/${NODE}.csr" \
    -CA "$CERTS_DIR/ca.crt" \
    -CAkey "$CERTS_DIR/ca.key" \
    -CAcreateserial \
    -out "$CERTS_DIR/${NODE}.crt" \
    -days $DAYS \
    -sha256

  rm "$CERTS_DIR/${NODE}.csr"
  echo "[INFO] ${NODE} certificate done."
}

generate_node_cert "elasticsearch"
generate_node_cert "kibana"
generate_node_cert "cribl"

# ─── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "[INFO] Certificates generated in: $CERTS_DIR"
ls -1 "$CERTS_DIR"