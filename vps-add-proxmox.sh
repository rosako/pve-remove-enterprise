#!/usr/bin/env bash
#
# Register (or update) the Proxmox site peer on the VPS once you know its
# public key. Run as root on the VPS:
#
#   sudo bash deploy/vps-add-proxmox.sh <PROXMOX_PUBKEY>
#
set -euo pipefail
PUBKEY="${1:?usage: vps-add-proxmox.sh <PROXMOX_PUBKEY>}"
ENV_FILE=/etc/lab-dashboard/dashboard.env
APP_DIR=/opt/lab-dashboard

sed -i "s|^WG_PROXMOX_PUBKEY=.*|WG_PROXMOX_PUBKEY=$PUBKEY|" "$ENV_FILE"
set -a; . "$ENV_FILE"; set +a
( cd "$APP_DIR" && "$APP_DIR/venv/bin/python" -c \
  "import db, wg; wg.regenerate(db.all_students(), apply=True)" )
systemctl restart lab-dashboard
echo "Proxmox peer registered and wg0 reloaded."
wg show wg0
