#!/usr/bin/env bash
#
# Tailscale Exit Node Bootstrap Script
# Turns this host (a Raspberry Pi, a cloud VM, any Debian/Ubuntu box) into a
# Tailscale exit node: installs Tailscale, enables IP forwarding, brings the
# node up advertising --advertise-exit-node, tunes UDP GRO forwarding for
# throughput, and installs fail2ban + unattended-upgrades.
#
# Idempotent: safe to run more than once.
#
# Usage:
#   Export your key first (optional for zero-touch headless setup):
#     export TS_AUTHKEY="tskey-auth-..."
#   Optionally override the tailnet hostname (defaults to this host's own):
#     export TS_HOSTNAME="pi-exitnode"
#   Then run:
#     ./bootstrap-tailscale-exit-node.sh
#
# One-liner (no clone needed — this repo is public):
#   curl -fsSL https://raw.githubusercontent.com/thilagan-digital/bare-metal-bootstrap/main/bootstrap-tailscale-exit-node.sh \
#     | sudo TS_AUTHKEY=tskey-auth-xxxx bash
#
# After running: approve the exit node in the Tailscale admin console
# (https://login.tailscale.com/admin/machines -> this node -> Edit route
# settings -> Use as exit node), and disable key expiry for it — Tailscale
# fail-closes an exit node's route once its key expires.

set -euo pipefail

NC='\033[0m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'

log()  { echo -e "${GREEN}==> $*${NC}"; }
warn() { echo -e "${YELLOW}==> warning: $*${NC}" >&2; }
die()  { echo -e "${RED}==> error: $*${NC}" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (./bootstrap-tailscale-exit-node.sh, or sudo ./bootstrap-tailscale-exit-node.sh if not already root)"

SYSCTL_FILE="/etc/sysctl.d/99-tailscale.conf"

echo -e "${GREEN}==> Initializing Tailscale Exit Node Bootstrap Sequence...${NC}"

# Default the tailnet name to the machine's own (short) hostname rather than
# hardcoding one, so the same script deploys anywhere unchanged. Override
# with TS_HOSTNAME when the tailnet name should differ from the OS hostname.
TS_HOSTNAME="${TS_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
[ -n "$TS_HOSTNAME" ] || die "could not determine this host's hostname; set TS_HOSTNAME explicitly"

# 1. Install Tailscale (official install script is idempotent).
if command -v tailscale >/dev/null 2>&1; then
  log "Tailscale already installed ($(tailscale version | head -n1))"
else
  log "Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | sh
fi

# 2. Enable IPv4 + IPv6 forwarding (required for exit-node routing).
log "Enabling IP forwarding..."
cat > "$SYSCTL_FILE" <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p "$SYSCTL_FILE" >/dev/null

# 3. Bring the node up as an exit node.
log "Bringing up Tailscale as an exit node (hostname: $TS_HOSTNAME)..."
up_args=(
  --advertise-exit-node
  --hostname="$TS_HOSTNAME"
  --ssh
)
if [ -n "${TS_AUTHKEY:-}" ]; then
  up_args+=(--authkey="$TS_AUTHKEY")
fi
tailscale up "${up_args[@]}"

# 4. Tune UDP GRO forwarding for exit-node throughput (best-effort).
# See https://tailscale.com/s/ethtool-config-udp-gro — without this, Tailscale
# warns that UDP forwarding (used by the WireGuard data path) runs below
# capacity on the primary interface. Applied now, and reapplied by a
# networkd-dispatcher hook so it survives reboots/interface renegotiation.
if command -v ethtool >/dev/null 2>&1; then
  log "Tuning UDP GRO forwarding for exit-node throughput..."
  DISPATCH_DIR="/etc/networkd-dispatcher/routable.d"
  HOOK="$DISPATCH_DIR/50-tailscale-udp-gro"
  IFACE="$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')"
  if [ -n "$IFACE" ]; then
    ethtool -K "$IFACE" rx-udp-gro-forwarding on rx-gro-list off \
      || warn "could not tune UDP GRO forwarding on $IFACE"
  else
    warn "could not determine default interface; skipping UDP GRO tuning"
  fi
  if [ -d "$DISPATCH_DIR" ]; then
    cat > "$HOOK" <<'HOOKEOF'
#!/usr/bin/env bash
# Apply Tailscale's recommended UDP GRO forwarding tweak whenever the
# interface comes up. See https://tailscale.com/s/ethtool-config-udp-gro
set -eu
[ -n "${IFACE:-}" ] || exit 0
command -v ethtool >/dev/null 2>&1 || exit 0
ethtool -K "$IFACE" rx-udp-gro-forwarding on rx-gro-list off 2>/dev/null || true
HOOKEOF
    chmod +x "$HOOK"
  else
    warn "networkd-dispatcher not present; UDP GRO tuning won't survive reboot"
  fi
else
  warn "ethtool not installed; skipping UDP GRO tuning"
fi

# 5. Best-effort hardening (non-fatal if the packages aren't available).
if command -v apt-get >/dev/null 2>&1; then
  log "Installing hardening packages (fail2ban, unattended-upgrades)..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || warn "apt-get update failed; skipping hardening packages"
  apt-get install -y -qq fail2ban unattended-upgrades \
    || warn "could not install hardening packages"
fi

echo -e "${GREEN}==> Setup Complete!${NC}"
echo ""
echo "Next steps:"
echo "  1. Approve the exit node in the Tailscale admin console:"
echo "     https://login.tailscale.com/admin/machines"
echo "     (open '$TS_HOSTNAME' -> Edit route settings -> Use as exit node)"
echo "  2. From another tailnet device:"
echo "       sudo tailscale set --exit-node=$TS_HOSTNAME"
echo "       curl -s https://api.ipify.org ; echo   # should show your home IP"
echo "  3. Disable key expiry for this node in the admin console:"
echo "     https://login.tailscale.com/admin/machines"
echo "     (open '$TS_HOSTNAME' -> ... -> Disable key expiry)"
echo "     Tailscale enforces a fail-close policy on key expiry: once the"
echo "     node key expires, its advertised exit-node route goes dark for"
echo "     every device using it. There's no CLI flag for this -- it's a"
echo "     per-device admin console setting -- so it has to be done by hand."
