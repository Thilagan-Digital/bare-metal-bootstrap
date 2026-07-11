#!/usr/bin/env bash
#
# AdGuard Home Bootstrap Script
# Installs AdGuard Home (network-wide DNS ad/tracker blocker) via the
# official installer and registers it as a systemd service. Frees port 53
# from systemd-resolved's stub listener first, if present, so AdGuard can
# bind it.
#
# Idempotent: safe to run more than once. Leaves an existing installation in
# place unless ADGUARD_REINSTALL=1 is set. This script never touches
# AdGuardHome.yaml — all first-run config (admin credentials, listen ports,
# upstream DNS) happens through the web setup wizard, so nothing secret is
# ever read or written by this script.
#
# Usage:
#   ./bootstrap-adguard-home.sh
#
# Optional environment variables:
#   ADGUARD_REINSTALL   Set to "1" to force a reinstall over an existing one.
#
# One-liner (no clone needed — this repo is public):
#   curl -fsSL https://raw.githubusercontent.com/thilagan-digital/bare-metal-bootstrap/main/bootstrap-adguard-home.sh \
#     | sudo bash

set -euo pipefail

NC='\033[0m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'

log()  { echo -e "${GREEN}==> $*${NC}"; }
warn() { echo -e "${YELLOW}==> warning: $*${NC}" >&2; }
die()  { echo -e "${RED}==> error: $*${NC}" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (./bootstrap-adguard-home.sh, or sudo ./bootstrap-adguard-home.sh if not already root)"

INSTALL_DIR="/opt/AdGuardHome"
WEB_PORT=3000

echo -e "${GREEN}==> Initializing AdGuard Home Bootstrap Sequence...${NC}"

# 0. Free port 53 from systemd-resolved's stub listener, if present. The stub
# binds 127.0.0.53/127.0.0.54:53, which is enough to make a wildcard
# 0.0.0.0:53 bind fail with "address already in use" even though `ss` shows
# no listener on 0.0.0.0:53. Disabling it and repointing /etc/resolv.conf at
# systemd-resolved's non-stub file keeps host DNS resolution working via the
# same upstreams, just without the stub port.
RESOLVED_CONF="/etc/systemd/resolved.conf"
if systemctl is-active --quiet systemd-resolved 2>/dev/null \
  && ! grep -Eq '^\s*DNSStubListener\s*=\s*no' "$RESOLVED_CONF" 2>/dev/null; then
  log "Disabling systemd-resolved's DNS stub listener (frees :53 for AdGuard Home)..."
  [ -f "$RESOLVED_CONF.orig" ] || cp "$RESOLVED_CONF" "$RESOLVED_CONF.orig"
  if grep -q '^\[Resolve\]' "$RESOLVED_CONF"; then
    sed -i 's/^\[Resolve\]/[Resolve]\nDNSStubListener=no/' "$RESOLVED_CONF"
  else
    printf '\n[Resolve]\nDNSStubListener=no\n' >> "$RESOLVED_CONF"
  fi
  systemctl restart systemd-resolved
  ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
fi

if [ -x "$INSTALL_DIR/AdGuardHome" ] && [ "${ADGUARD_REINSTALL:-0}" != "1" ]; then
  log "AdGuard Home already installed at $INSTALL_DIR"
else
  log "Installing AdGuard Home..."
  reinstall_flag=()
  [ "${ADGUARD_REINSTALL:-0}" = "1" ] && reinstall_flag=(-r)
  curl -fsSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh \
    | sh -s -- "${reinstall_flag[@]}"
fi

log "Enabling and starting the AdGuardHome service..."
systemctl enable --now AdGuardHome \
  || die "could not enable/start AdGuardHome — check 'systemctl status AdGuardHome'"

HOST_IP="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"

echo -e "${GREEN}==> Setup Complete!${NC}"
echo ""
echo "AdGuard Home is running but not yet configured. Finish setup in a browser:"
echo "  http://${HOST_IP:-<this-host>}:${WEB_PORT}/"
echo ""
echo "Configure upstream DNS, blocklists, and the admin account in the setup"
echo "wizard — nothing here writes to AdGuardHome.yaml on your behalf."
