#!/usr/bin/env bash
#
# Ansible Controller Bootstrap Script
# Installs the prerequisites for running `ansible-playbook` against a fleet
# from this host (ansible-core, python3, openssh-client, Doppler CLI), and
# optionally joins the host to a Tailscale network so the controller can
# reach fleet hosts by MagicDNS name.
#
# This script deliberately stops short of running any playbook — it only
# gets a bare host to the point where a private automation repo's Ansible
# can take over. No secrets are read or written by this script beyond an
# optional TS_AUTHKEY passed in the environment.
#
# Usage:
#   Export your key first (optional for zero-touch headless setup):
#     export TS_AUTHKEY="tskey-auth-..."
#   Then run:
#     ./bootstrap-ansible-controller.sh
#
# One-liner (no clone needed — this repo is public):
#   curl -fsSL https://raw.githubusercontent.com/thilagan-digital/bare-metal-bootstrap/main/bootstrap-ansible-controller.sh \
#     | sudo TS_AUTHKEY=tskey-auth-xxxx bash

set -euo pipefail

NC='\033[0m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}==> Run as root (sudo ./bootstrap-ansible-controller.sh)${NC}" >&2; exit 1; }

echo -e "${GREEN}==> Initializing Ansible Controller Bootstrap Sequence...${NC}"

# 1. Ansible-core, python3, openssh-client
PACKAGES=(ansible-core python3 openssh-client)
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

# 2. Doppler CLI (official installer; already a no-op if current)
if command -v doppler >/dev/null 2>&1; then
    echo -e "${GREEN}==> Doppler CLI already installed ($(doppler --version))${NC}"
else
    echo -e "${YELLOW}==> Installing Doppler CLI...${NC}"
    curl -fsSL https://cli.doppler.com/install.sh | sh
fi

# 3. Tailscale — join the tailnet so this host can reach fleet hosts by
#    MagicDNS name once Ansible takes over.
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
    tailscale up --authkey="${TS_AUTHKEY}"
else
    echo -e "${YELLOW}==> No auth key provided. Initializing standard interactive link...${NC}"
    tailscale up
fi

echo -e "${GREEN}==> Setup Complete!${NC}"
echo ""
echo "Next steps: clone your private automation repo and run its Ansible"
echo "playbooks (Galaxy collections, inventory, and secrets live there, not"
echo "here) — e.g.:"
echo "  git clone <your-private-infra-repo>"
echo "  cd <repo>/ansible && doppler run -- ansible-playbook playbooks/site.yml"
