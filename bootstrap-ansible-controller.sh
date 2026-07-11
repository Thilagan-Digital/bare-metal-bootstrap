#!/usr/bin/env bash
#
# Ansible Controller Bootstrap Script
# Installs the prerequisites for running `ansible-playbook` against a fleet
# from this host (ansible-core, python3, openssh-client, python3-pexpect,
# Doppler CLI), optionally joins the host to a Tailscale network so the
# controller can reach fleet hosts by MagicDNS name, ensures the controller
# has its own SSH keypair, and — if you pass a target list — pushes that
# public key out to each managed host so Ansible can reach them without a
# password.
#
# This script deliberately stops short of running any playbook — it only
# gets a bare host to the point where a private automation repo's Ansible
# can take over. No secrets are read or written by this script beyond
# optional environment variables (TS_AUTHKEY, ANSIBLE_TARGET_PASSWORD) —
# never written to a file, never logged.
#
# Usage:
#   Run as root — most minimal images (a fresh Proxmox VE install included)
#   don't have `sudo` installed at all, so prefix with `sudo` only if you're
#   not already root.
#
#   Export what you need first (all optional):
#     export TS_AUTHKEY="tskey-auth-..."             # zero-touch Tailscale join
#     export ANSIBLE_TARGETS="root@10.0.0.11 root@10.0.0.12"   # space-separated user@host list
#     export ANSIBLE_TARGET_PASSWORD="..."           # only if every target above shares ONE password
#   Then run:
#     ./bootstrap-ansible-controller.sh
#
# One-liner (no clone needed — this repo is public):
#   curl -fsSL https://raw.githubusercontent.com/thilagan-digital/bare-metal-bootstrap/main/bootstrap-ansible-controller.sh \
#     | TS_AUTHKEY=tskey-auth-xxxx ANSIBLE_TARGETS="root@10.0.0.11 root@10.0.0.12" bash
#
# Omit ANSIBLE_TARGETS entirely to skip SSH provisioning (e.g. if it's
# already set up, or you'd rather run ssh-copy-id by hand). Omit
# ANSIBLE_TARGET_PASSWORD — the recommended default, especially across a
# fleet of hosts that don't all share one root/user password — to be
# prompted interactively per host instead of supplying one non-interactively
# via sshpass; a single shared value is applied to EVERY target, so it will
# silently fail (permission denied) on any host with a different password.

set -euo pipefail

NC='\033[0m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'

[ "$(id -u)" -eq 0 ] || { echo -e "${RED}==> Run as root (./bootstrap-ansible-controller.sh, or sudo ./bootstrap-ansible-controller.sh if not already root)${NC}" >&2; exit 1; }

echo -e "${GREEN}==> Initializing Ansible Controller Bootstrap Sequence...${NC}"

# 1. Ansible-core, python3, openssh-client, pexpect (drives pvecm's
#    interactive prompts via ansible.builtin.expect), and gnupg/gpgv — a
#    minimal image (e.g. a fresh Proxmox VE install) often lacks gpgv, which
#    the Doppler CLI installer in step 2 requires for signature verification
#    even though gnupg itself may already be present.
PACKAGES=(ansible-core python3 openssh-client python3-pexpect gnupg gpgv)
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

# 4. This controller's own SSH keypair — Ansible connects to managed hosts
#    over SSH, so it needs one. Generated once, reused on every run.
SSH_KEY="${SSH_KEY_PATH:-$HOME/.ssh/id_ed25519}"
if [ -f "${SSH_KEY}" ]; then
    echo -e "${GREEN}==> SSH keypair already present (${SSH_KEY})${NC}"
else
    echo -e "${YELLOW}==> Generating SSH keypair (${SSH_KEY})...${NC}"
    mkdir -p "$(dirname "${SSH_KEY}")"
    ssh-keygen -t ed25519 -N "" -f "${SSH_KEY}" -C "ansible-controller@$(hostname)"
fi

# 5. Optional: push this controller's public key to each managed host, so
#    Ansible can reach them without a password. Skipped entirely if
#    ANSIBLE_TARGETS isn't set — real hostnames/IPs are fleet-specific and
#    never hard-coded here.
if [ -n "${ANSIBLE_TARGETS:-}" ]; then
    echo -e "${YELLOW}==> Provisioning SSH access to: ${ANSIBLE_TARGETS}${NC}"
    if ! command -v ssh-copy-id >/dev/null 2>&1; then
        apt-get install -y -qq openssh-client
    fi
    if [ -n "${ANSIBLE_TARGET_PASSWORD:-}" ] && ! command -v sshpass >/dev/null 2>&1; then
        apt-get install -y -qq sshpass
    fi
    for target in ${ANSIBLE_TARGETS}; do
        echo -e "${YELLOW}    -> ${target}${NC}"
        if [ -n "${ANSIBLE_TARGET_PASSWORD:-}" ]; then
            sshpass -p "${ANSIBLE_TARGET_PASSWORD}" ssh-copy-id -o StrictHostKeyChecking=accept-new -i "${SSH_KEY}.pub" "${target}"
        else
            ssh-copy-id -o StrictHostKeyChecking=accept-new -i "${SSH_KEY}.pub" "${target}"
        fi
    done
    echo -e "${GREEN}==> SSH access provisioned for all listed targets${NC}"
else
    echo -e "${YELLOW}==> ANSIBLE_TARGETS not set — skipping SSH key provisioning${NC}"
fi

echo -e "${GREEN}==> Setup Complete!${NC}"
echo ""
echo "Next steps: clone your private automation repo and run its Ansible"
echo "playbooks (Galaxy collections, inventory, and secrets live there, not"
echo "here) — e.g.:"
echo "  git clone <your-private-infra-repo>"
echo "  cd <repo>/ansible && doppler run -- ansible-playbook playbooks/site.yml"
