#!/bin/bash

# ============================================
#  PlayAroundIT Observability Lab - Status
# ============================================

VAGRANT_DIR="$(cd "$(dirname "$0")/../vagrant" && pwd)"

if [ ! -f "$VAGRANT_DIR/Vagrantfile" ]; then
  echo "ERROR: Vagrantfile not found at $VAGRANT_DIR"
  exit 1
fi

cd "$VAGRANT_DIR"

echo ""
echo "============================================"
echo "  Observability Lab - VM Status"
echo "============================================"
printf "  %-14s %-18s %-10s\n" "HOSTNAME" "IP ADDRESS" "STATUS"
echo "  ------------------------------------------"

# Dynamically discover all VMs from Vagrant
VMS=$(vagrant status --machine-readable 2>/dev/null \
  | grep ",state," \
  | awk -F',' '{print $2}')

for VM in $VMS; do
  STATUS=$(vagrant status --machine-readable "$VM" 2>/dev/null \
    | grep ",state," \
    | awk -F',' '{print $4}')

  if [ "$STATUS" = "running" ]; then
    IP=$(vagrant ssh "$VM" -c "hostname -I | awk '{print \$1}'" 2>/dev/null | tr -d '\r')
    printf "  %-14s %-18s %-10s\n" "$VM" "$IP" "running"
  else
    printf "  %-14s %-18s %-10s\n" "$VM" "---" "${STATUS:-unknown}"
  fi
done

echo "  ------------------------------------------"
echo ""