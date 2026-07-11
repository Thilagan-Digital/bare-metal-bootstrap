#!/usr/bin/env bash
#
# Proxmox VE 9.x (Trixie) Bootstrap Script
# Disables enterprise repos, enables the community no-subscription repo,
# installs Tailscale, and suppresses the "No valid subscription" nag popup.
#
# Usage:
#   Export your key first (optional for zero-touch headless setup):
#     export TS_AUTHKEY="tskey-auth-..."
#   Then run:
#     ./bootstrap-pve.sh
#
# One-liner (no clone needed — this repo is public):
#   curl -fsSL https://raw.githubusercontent.com/thilagan-digital/bare-metal-bootstrap/main/bootstrap-pve.sh \
#     | sudo TS_AUTHKEY=tskey-auth-xxxx bash

set -euo pipefail

NC='\033[0m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}==> Run as root (sudo ./bootstrap-pve.sh)${NC}" >&2; exit 1; }

echo -e "${GREEN}==> Initializing Proxmox VE Bootstrap Sequence...${NC}"

# 1. Disable default enterprise repositories safely by renaming them
echo -e "${YELLOW}==> Disabling PVE Enterprise repositories...${NC}"
if [ -f /etc/apt/sources.list.d/pve-enterprise.sources ]; then
    mv /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/pve-enterprise.sources.bak
    echo "Disabled pve-enterprise.sources"
fi

if [ -f /etc/apt/sources.list.d/ceph.sources ]; then
    mv /etc/apt/sources.list.d/ceph.sources /etc/apt/sources.list.d/ceph.sources.bak
    echo "Disabled ceph.sources"
fi

# 2. Deploy the clean, generic No-Subscription configuration file
echo -e "${YELLOW}==> Configuring PVE Community No-Subscription repository...${NC}"
cat <<EOF > /etc/apt/sources.list.d/pve-no-subscription.sources
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Architectures: amd64
Comment: Proxmox VE community no-subscription repository
EOF

# 3. Update the package manager database with new target repos
echo -e "${YELLOW}==> Refreshing package index...${NC}"
apt-get update

# 4. Pull down and execute the official Tailscale engine setup
echo -e "${YELLOW}==> Downloading and installing Tailscale...${NC}"
curl -fsSL https://tailscale.com/install.sh | sh

# 5. Initialize the node configuration into the network layer
echo -e "${GREEN}==> Bootstrapping Tailscale client connection...${NC}"
if [ -n "${TS_AUTHKEY:-}" ]; then
    echo -e "${GREEN}==> Auth key detected. Registering non-interactively...${NC}"
    tailscale up --authkey="${TS_AUTHKEY}"
else
    echo -e "${YELLOW}==> No auth key provided. Initializing standard interactive link...${NC}"
    tailscale up
fi

# 6. Suppress the "No valid subscription" nag popup in the web UI.
#    Cosmetic only — has no effect on functionality. pve-manager upgrades
#    silently revert this patch, so it needs to be reapplied after updates
#    (safe to just re-run this script).
echo -e "${YELLOW}==> Patching subscription-nag popup...${NC}"
sed -i.bak "s/Ext\.Msg\.show\(\{\s*title: gettext\('No valid sub/void(\/\/&/" \
  /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js
systemctl restart pveproxy

echo -e "${GREEN}==> Setup Complete!${NC}"
