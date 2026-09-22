#!/usr/bin/env bash
#
# Proxmox setup: join the VPS WireGuard tunnel as the lab site peer, create the
# internal lab bridge the LXC mock machines attach to, and route between them.
# Run as root on the Proxmox host:
#
#   SERVER_PUBKEY='...' ENDPOINT='lab.example.ch:51820' bash deploy/proxmox-setup.sh
#
# Prints this host's WireGuard public key at the end — feed it back to the VPS
# with deploy/vps-add-proxmox.sh.
set -euo pipefail

SERVER_PUBKEY="${SERVER_PUBKEY:?set SERVER_PUBKEY=... (from vps-setup.sh output)}"
ENDPOINT="${ENDPOINT:?set ENDPOINT=lab.example.ch:51820}"

WG_TUNNEL_CIDR="${WG_TUNNEL_CIDR:-10.66.0.0/24}"
PROXMOX_TUNNEL_IP="${PROXMOX_TUNNEL_IP:-10.66.0.2}"
LAB_CIDR="${LAB_CIDR:-10.66.10.0/24}"
LAB_GW="${LAB_GW:-10.66.10.1}"          # bridge address (containers' gateway)
LAB_BRIDGE="${LAB_BRIDGE:-vmbr1}"
WG_DIR=/etc/wireguard

UPLINK="$(ip route show default | awk '{print $5; exit}')"
[[ -n "$UPLINK" ]] || { echo "could not detect default uplink interface"; exit 1; }
echo "==> uplink interface for NAT: $UPLINK"

echo "==> [1/5] Installing WireGuard"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq wireguard wireguard-tools >/dev/null

echo "==> [2/5] IP forwarding"
echo 'net.ipv4.ip_forward = 1' >/etc/sysctl.d/99-lab-forward.conf
sysctl -q --system

echo "==> [3/5] Lab bridge $LAB_BRIDGE ($LAB_GW)"
if ! grep -q "auto $LAB_BRIDGE" /etc/network/interfaces; then
  cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%s)"
  cat >>/etc/network/interfaces <<EOF

# --- lab bridge (added by proxmox-setup.sh) ---
auto $LAB_BRIDGE
iface $LAB_BRIDGE inet static
    address $LAB_GW/${LAB_CIDR#*/}
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
  ifreload -a
  echo "    created $LAB_BRIDGE"
else
  echo "    $LAB_BRIDGE already present"
fi

echo "==> [4/5] WireGuard keys + tunnel"
umask 077
mkdir -p "$WG_DIR"
if [[ ! -f "$WG_DIR/proxmox.key" ]]; then
  wg genkey | tee "$WG_DIR/proxmox.key" | wg pubkey >"$WG_DIR/proxmox.pub"
fi
PROXMOX_PRIVKEY="$(cat "$WG_DIR/proxmox.key")"
PROXMOX_PUBKEY="$(cat "$WG_DIR/proxmox.pub")"
PREFIX="${WG_TUNNEL_CIDR#*/}"

cat >"$WG_DIR/wg0.conf" <<EOF
[Interface]
Address = $PROXMOX_TUNNEL_IP/$PREFIX
PrivateKey = $PROXMOX_PRIVKEY
# route + NAT for the lab subnet (tied to the tunnel lifecycle)
PostUp   = iptables -A FORWARD -i wg0 -o $LAB_BRIDGE -j ACCEPT
PostUp   = iptables -A FORWARD -i $LAB_BRIDGE -o wg0 -j ACCEPT
PostUp   = iptables -A FORWARD -i $LAB_BRIDGE -o $UPLINK -j ACCEPT
PostUp   = iptables -A FORWARD -i $UPLINK -o $LAB_BRIDGE -m state --state RELATED,ESTABLISHED -j ACCEPT
PostUp   = iptables -t nat -A POSTROUTING -s $LAB_CIDR -o $UPLINK -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -o $LAB_BRIDGE -j ACCEPT
PostDown = iptables -D FORWARD -i $LAB_BRIDGE -o wg0 -j ACCEPT
PostDown = iptables -D FORWARD -i $LAB_BRIDGE -o $UPLINK -j ACCEPT
PostDown = iptables -D FORWARD -i $UPLINK -o $LAB_BRIDGE -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s $LAB_CIDR -o $UPLINK -j MASQUERADE

[Peer]
# VPS hub
PublicKey = $SERVER_PUBKEY
Endpoint = $ENDPOINT
AllowedIPs = $WG_TUNNEL_CIDR
PersistentKeepalive = 25
EOF
chmod 600 "$WG_DIR/wg0.conf"
systemctl enable -q wg-quick@wg0
systemctl restart wg-quick@wg0

echo "==> [5/5] Done"
echo
echo "=========================================================="
echo " Proxmox site peer ready."
echo "   Lab bridge : $LAB_BRIDGE @ $LAB_GW  (subnet $LAB_CIDR)"
echo "   NAT uplink : $UPLINK"
echo
echo "   >>> Proxmox WireGuard public key (give this to the VPS): "
echo "   $PROXMOX_PUBKEY"
echo
echo " On the VPS run:  sudo bash deploy/vps-add-proxmox.sh '$PROXMOX_PUBKEY'"
echo " Then create mock machines: bash deploy/create-containers.sh"
echo "=========================================================="
