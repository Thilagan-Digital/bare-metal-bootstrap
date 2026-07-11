#!/usr/bin/env bash
#
# Generic Proxmox VE 9.x (Trixie) Bare-Metal Node Bootstrap Script
#
# Phase 1 of the bare-metal -> cluster pipeline: run this locally on each
# fresh Proxmox VE 9.x install to fix the DEB822 repositories, silence the
# subscription nag, install the core utilities the cluster automation needs
# (python3 for Ansible, qemu-guest-agent, ifupdown2, jq), and join a
# Tailscale overlay network. After every node has run this, drive the
# Ansible pipeline (site.yml) from a management machine to form the cluster.
#
# Idempotent: safe to run more than once.
#
# Usage:
#   Export your key first (optional for zero-touch headless Tailscale join):
#     export TS_AUTHKEY="tskey-auth-..."
#   Then run:
#     sudo ./bootstrap-node.sh
#
# One-liner (no clone needed — this repo is public):
#   curl -fsSL https://raw.githubusercontent.com/thilagan-digital/bare-metal-bootstrap/main/bootstrap-node.sh \
#     | sudo TS_AUTHKEY=tskey-auth-xxxx bash

set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "error: run as root (sudo ./bootstrap-node.sh)" >&2; exit 1; }

echo "==> 1. Disabling default enterprise repositories..."
for f in pve-enterprise ceph; do
    if [ -f "/etc/apt/sources.list.d/${f}.sources" ]; then
        mv "/etc/apt/sources.list.d/${f}.sources" "/etc/apt/sources.list.d/${f}.sources.bak"
        echo "    disabled ${f}.sources"
    fi
done

echo "==> 2. Configuring community no-subscription repository..."
cat <<EOF > /etc/apt/sources.list.d/pve-no-subscription.sources
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Architectures: amd64
Comment: Proxmox VE community no-subscription repository
EOF

echo "==> 3. Updating system & installing core dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get dist-upgrade -y
apt-get install -y curl jq qemu-guest-agent ifupdown2 python3 python3-pip

echo "==> 4. Silencing the GUI 'No valid subscription' warning..."
# Cosmetic only — no functional effect. pve-manager upgrades silently revert
# this patch, so re-run this script after an upgrade to reapply it.
sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" \
    /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js || true
systemctl restart pveproxy.service || true

echo "==> 5. Bootstrapping the Tailscale client..."
curl -fsSL https://tailscale.com/install.sh | sh
if [ -n "${TS_AUTHKEY:-}" ]; then
    echo "    auth key detected — registering non-interactively"
    tailscale up --authkey="${TS_AUTHKEY}"
else
    echo "    no auth key provided — starting interactive login"
    tailscale up
fi

echo "==> Node bootstrap complete! Ready for Ansible management."
