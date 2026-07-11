#!/usr/bin/env bash
#
# NAS Baseline Bootstrap Script
# Installs the generic OS prerequisites a headless storage appliance needs
# before a private automation repo's Ansible run converges it (Samba, NFS,
# Cockpit, unattended-upgrades, add-on containers, etc.) — apt/TLS basics
# and Docker, plus an optional Tailscale join.
#
# This script does not configure Samba/NFS/Cockpit itself — those are
# service-specific convergence steps that belong in your private repo's
# Ansible role, not in a public bootstrap script.
#
# Usage:
#   Export your key first (optional for zero-touch headless setup):
#     export TS_AUTHKEY="tskey-auth-..."
#   Then run:
#     ./bootstrap-nas-base.sh
#
# One-liner (no clone needed — this repo is public):
#   curl -fsSL https://raw.githubusercontent.com/thilagan-digital/bare-metal-bootstrap/main/bootstrap-nas-base.sh \
#     | sudo TS_AUTHKEY=tskey-auth-xxxx bash

set -euo pipefail

NC='\033[0m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}==> Run as root (./bootstrap-nas-base.sh, or sudo ./bootstrap-nas-base.sh if not already root)${NC}" >&2; exit 1; }

echo -e "${GREEN}==> Initializing NAS Baseline Bootstrap Sequence...${NC}"

# 1. Core apt/TLS prerequisites
PACKAGES=(curl ca-certificates apt-transport-https software-properties-common)
missing_packages=()
for pkg in "${PACKAGES[@]}"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing_packages+=("$pkg")
done
if [ "${#missing_packages[@]}" -eq 0 ]; then
    echo -e "${GREEN}==> Already installed: ${PACKAGES[*]}${NC}"
else
    echo -e "${YELLOW}==> Installing: ${missing_packages[*]}...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq "${missing_packages[@]}"
fi

# 2. Docker + Compose plugin — for add-on containers (drive-health dashboards,
#    reverse proxies, media tools) layered on by Ansible later.
if dpkg -s docker.io >/dev/null 2>&1 && dpkg -s docker-compose-v2 >/dev/null 2>&1; then
    echo -e "${GREEN}==> Docker already installed${NC}"
else
    echo -e "${YELLOW}==> Installing docker.io + docker-compose-v2...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq docker.io docker-compose-v2
    systemctl enable --now docker
fi

# 3. Tailscale — join the tailnet. Bare-metal hosts with no cloud-init hook
#    have no way to auto-join, so this is normally a manual step; this
#    script just makes it a single non-interactive command.
echo -e "${YELLOW}==> Installing Tailscale...${NC}"
if command -v tailscale >/dev/null 2>&1; then
    echo -e "${GREEN}==> Tailscale already installed${NC}"
else
    curl -fsSL https://tailscale.com/install.sh | sh
fi

echo -e "${GREEN}==> Bootstrapping Tailscale client connection...${NC}"
if tailscale status >/dev/null 2>&1; then
    echo -e "${GREEN}==> Already authenticated ($(tailscale ip -4 2>/dev/null))${NC}"
elif [ -n "${TS_AUTHKEY:-}" ]; then
    echo -e "${GREEN}==> Auth key detected. Registering non-interactively...${NC}"
    tailscale up --ssh --authkey="${TS_AUTHKEY}"
else
    echo -e "${YELLOW}==> No auth key provided. Initializing standard interactive link...${NC}"
    tailscale up --ssh
fi

echo -e "${GREEN}==> Setup Complete!${NC}"
echo ""
echo "Next steps: run your private automation repo's Ansible playbook"
echo "against this host to converge Samba/NFS/Cockpit and any add-on"
echo "containers, e.g.:"
echo "  doppler run -- ansible-playbook playbooks/site.yml --limit <this-host>"
