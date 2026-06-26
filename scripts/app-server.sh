#!/usr/bin/env bash
set -euo pipefail

#### CONFIG ####
TIMEZONE="Europe/Berlin"

#### FUNCTIONS ####
log()  { echo "[INFO] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
require_root() { [[ "$EUID" -eq 0 ]] || fail "Please run this script as root."; }

#### MAIN ####
require_root

log "Updating and upgrading packages..."
apt-get update -y
#apt-get upgrade -y

log "Setting timezone to ${TIMEZONE}..."
timedatectl set-timezone "$TIMEZONE"

log "Installing common tools..."
apt-get install -y \
  curl \
  wget \
  vim \
  htop \
  net-tools \
  ca-certificates \
  gnupg \
  jq \
  unzip

log "Cleaning up apt cache..."
apt-get autoremove -y
apt-get clean

log "Staging lab CA certificate..."
mkdir -p /etc/lab-certs
cp /tmp/ca.crt /etc/lab-certs/ca.crt
chmod 644 /etc/lab-certs/ca.crt
rm -f /tmp/ca.crt

VM_IP=$(ip -4 addr show | grep -oP '192\.168\.65\.\d+' | head -1)
log "App server base configuration complete."
log "Hostname: $(hostname)"
log "IP:       ${VM_IP}"