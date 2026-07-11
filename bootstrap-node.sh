#!/usr/bin/env bash
#
# Generic Proxmox VE 9.x (Trixie) Bare-Metal Node Bootstrap Script
#
# Phase 1 of the bare-metal -> cluster pipeline: run this locally on each
# fresh Proxmox VE 9.x install to fix the apt repositories (DEB822 and any
# legacy .list leftovers from an in-place upgrade), silence the
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

[ "$(id -u)" -eq 0 ] || { echo "error: run as root (./bootstrap-node.sh, or sudo ./bootstrap-node.sh if not already root — a fresh Proxmox VE install's root shell won't have sudo installed at all)" >&2; exit 1; }

echo "==> 1. Detecting Debian OS codename..."
VERSION_CODENAME="$(grep "VERSION_CODENAME=" /etc/os-release | cut -d= -f2)"
echo "    detected: ${VERSION_CODENAME}"

echo "==> 2. Disabling default enterprise repositories..."
for f in pve-enterprise ceph; do
    # Legacy one-line format (PVE 7/8 upgrades that never migrated)
    if [ -f "/etc/apt/sources.list.d/${f}.list" ]; then
        sed -i 's/^deb/#deb/g' "/etc/apt/sources.list.d/${f}.list"
        echo "    disabled ${f}.list"
    fi
    # Modern DEB822 format (PVE 8+/Trixie default). "Enabled:" is frequently
    # omitted entirely (it defaults to yes), so sed-patching it is unreliable
    # — take the file out of sources.list.d/ instead so apt never reads it.
    if [ -f "/etc/apt/sources.list.d/${f}.sources" ]; then
        mv "/etc/apt/sources.list.d/${f}.sources" "/etc/apt/sources.list.d/${f}.sources.disabled"
        echo "    disabled ${f}.sources"
    fi
done

echo "==> 3. Cleaning up stale repository files..."
# Remove a legacy no-subscription .list this script (or an older run of it)
# may have created previously, so it doesn't shadow/duplicate the DEB822 file.
if [ -f /etc/apt/sources.list.d/pve-no-subscription.list ]; then
    rm -f /etc/apt/sources.list.d/pve-no-subscription.list
    echo "    removed stale pve-no-subscription.list"
fi

echo "==> 4. Configuring community no-subscription repository..."
cat <<EOF > /etc/apt/sources.list.d/pve-no-subscription.sources
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${VERSION_CODENAME}
Components: pve-no-subscription
Architectures: amd64
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Comment: Proxmox VE community no-subscription repository
EOF

echo "==> 5. Updating system & installing core dependencies..."
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get dist-upgrade -y
apt-get install -y curl jq qemu-guest-agent ifupdown2 python3 python3-pip

echo "==> 6. Silencing the GUI 'No valid subscription' warning..."
# Cosmetic only — no functional effect. pve-manager upgrades silently revert
# this patch, so re-run this script after an upgrade to reapply it.
sed -Ezi.bak "s/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void\(\{ \/\/\1/g" \
    /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js || true
systemctl restart pveproxy.service || true

echo "==> 7. Bootstrapping the Tailscale client..."
curl -fsSL https://tailscale.com/install.sh | sh
if [ -n "${TS_AUTHKEY:-}" ]; then
    echo "    auth key detected — registering non-interactively"
    tailscale up --authkey="${TS_AUTHKEY}"
else
    echo "    no auth key provided — starting interactive login"
    tailscale up
fi

echo "==> Node bootstrap complete! Ready for Ansible management."
