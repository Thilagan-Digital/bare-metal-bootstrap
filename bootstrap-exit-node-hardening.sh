#!/usr/bin/env bash
#
# Exit-Node Hardening Bootstrap Script
# Layers additional security on top of an already-deployed Tailscale exit
# node (and optionally AdGuard Home) WITHOUT touching the existing installs.
#
# Idempotent: safe to run more than once — every step converges to the
# desired state. Nothing here modifies Tailscale's own firewall chains,
# tailscaled config, or AdGuardHome.yaml; everything this script installs
# lives in its own files and can be removed again (see the Rollback section
# in this repo's README).
#
# What it does (all layers optional, see flags below):
#   1. nftables scoping   — drops NEW inbound connections to sensitive ports
#                           (AdGuard admin/DNS, Netdata, ...) unless they
#                           arrive over tailscale0 or loopback. Lives in its
#                           own nftables table so Tailscale's rules, Docker,
#                           ufw, etc. are untouched. Also adds a FORWARD-hook
#                           rule (RFC1918 drop) for exit-node hosts: packets
#                           arriving over tailscale0 and destined for private
#                           ranges (10/8, 172.16/12, 192.168/16) are dropped,
#                           so a tailnet client using this exit node can never
#                           pivot into whatever LAN the exit node itself sits
#                           on. The tailnet's own CGNAT range (100.64.0.0/10)
#                           is deliberately excluded so normal tailnet traffic
#                           is unaffected.
#   2. CrowdSec           — community IP-reputation blocking (SSH, HTTP, ...)
#                           with the nftables bouncer. Tailnet + RFC1918
#                           sources are whitelisted so you can't ban yourself.
#   3. Suricata (opt-in)  — passive IDS on the WAN interface. Alert-only; no
#                           blocking until you tune it.
#   4. Netdata (opt-in)   — real-time system/network monitoring, reachable
#                           over the tailnet only (port 19999 is scoped).
#
# What it deliberately does NOT do:
#   - Tailscale ACLs      — set in the admin console; example policy provided
#                           in tailscale-acl.example.hujson (this repo).
#   - DNSSEC validation   — a checkbox in the AdGuard UI; this repo never
#                           writes to AdGuardHome.yaml.
#   - Raw WireGuard       — redundant next to Tailscale.
#   - fail2ban            — the exit-node bootstrap script already installs
#                           it; left as-is.
#
# Usage:
#   ./bootstrap-exit-node-hardening.sh
#
# One-liner (no clone needed — this repo is public):
#   curl -fsSL https://raw.githubusercontent.com/thilagan-digital/bare-metal-bootstrap/main/bootstrap-exit-node-hardening.sh \
#     | sudo bash
#
# Optional environment variables (defaults in brackets):
#   HARDEN_NFTABLES           [1] Install the tailnet-only nftables scoping.
#   HARDEN_CROWDSEC           [1] Install CrowdSec + nftables bouncer.
#   HARDEN_SURICATA           [0] Install Suricata in passive IDS mode.
#   HARDEN_NETDATA            [0] Install Netdata (tailnet-only via nftables).
#   HARDEN_TS_IFACE           [tailscale0] Tailscale interface name.
#   HARDEN_TAILNET_TCP_PORTS  [53,80,443,853,3000,19999] TCP ports reachable
#                             only via tailnet/loopback.
#   HARDEN_TAILNET_UDP_PORTS  [53,443,853] Same, for UDP.
#   HARDEN_ALLOW_CIDRS        [] Extra comma-separated source CIDRs allowed to
#                             reach the scoped ports (e.g. a home LAN:
#                             192.168.1.0/24). IPv4 and IPv6 both accepted.
#   HARDEN_SSH_TAILNET_ONLY   [0] DANGEROUS: also scope port 22 to the
#                             tailnet. Only set this once you have verified
#                             Tailscale SSH works from another device.
#   HARDEN_RFC1918_DROP       [1] On exit-node hosts, drop tunnel-ingress
#                             (tailscale0) traffic FORWARDed to RFC1918
#                             destinations (10/8, 172.16/12, 192.168/16), so
#                             the exit node can't be used to pivot into its
#                             own LAN. Never touches the tailnet's own CGNAT
#                             range (100.64.0.0/10). Harmless no-op on hosts
#                             that aren't forwarding (no forwarded packets to
#                             match).
#   CROWDSEC_ENROLL_KEY       [] Optional key to enroll this instance in the
#                             CrowdSec console (https://app.crowdsec.net).
#   HARDEN_DRY_RUN            [0] Generate + validate only: writes the
#                             nftables ruleset to a temp file, checks it with
#                             'nft -c', and makes no system changes (nothing
#                             loaded, no installs, no systemd units). Still
#                             needs root ('nft -c' talks to netlink) and the
#                             nftables package.

set -euo pipefail

NC='\033[0m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'

log()  { echo -e "${GREEN}==> $*${NC}"; }
warn() { echo -e "${YELLOW}==> warning: $*${NC}" >&2; }
die()  { echo -e "${RED}==> error: $*${NC}" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (./bootstrap-exit-node-hardening.sh, or sudo ./bootstrap-exit-node-hardening.sh if not already root)"
command -v apt-get >/dev/null 2>&1 || die "this script targets Debian/Ubuntu (apt-get not found)"

echo -e "${GREEN}==> Initializing Exit-Node Hardening Bootstrap Sequence...${NC}"

HARDEN_NFTABLES="${HARDEN_NFTABLES:-1}"
HARDEN_CROWDSEC="${HARDEN_CROWDSEC:-1}"
HARDEN_SURICATA="${HARDEN_SURICATA:-0}"
HARDEN_NETDATA="${HARDEN_NETDATA:-0}"
HARDEN_TS_IFACE="${HARDEN_TS_IFACE:-tailscale0}"
HARDEN_TAILNET_TCP_PORTS="${HARDEN_TAILNET_TCP_PORTS:-53,80,443,853,3000,19999}"
HARDEN_TAILNET_UDP_PORTS="${HARDEN_TAILNET_UDP_PORTS:-53,443,853}"
HARDEN_ALLOW_CIDRS="${HARDEN_ALLOW_CIDRS:-}"
HARDEN_SSH_TAILNET_ONLY="${HARDEN_SSH_TAILNET_ONLY:-0}"
HARDEN_RFC1918_DROP="${HARDEN_RFC1918_DROP:-1}"
HARDEN_DRY_RUN="${HARDEN_DRY_RUN:-0}"

NFT_RULES_FILE="/etc/nftables.d/homelab-hardening.nft"
NFT_UNIT="homelab-hardening-nftables.service"
NFT_UNIT_FILE="/etc/systemd/system/$NFT_UNIT"
CROWDSEC_WHITELIST="/etc/crowdsec/parsers/s02-enrich/01-homelab-whitelist.yaml"

export DEBIAN_FRONTEND=noninteractive
apt_updated=0
apt_update_once() {
  if [ "$apt_updated" -eq 0 ]; then
    apt-get update -qq || warn "apt-get update failed; installs may use stale indexes"
    apt_updated=1
  fi
}

# ---------------------------------------------------------------------------
# 1. nftables: scope sensitive ports to the tailnet
# ---------------------------------------------------------------------------
if [ "$HARDEN_NFTABLES" = "1" ]; then
  if [ "$HARDEN_DRY_RUN" = "1" ]; then
    log "DRY RUN: generating + validating the nftables ruleset only (no system changes)"
    command -v nft >/dev/null 2>&1 || die "dry run needs the nftables package preinstalled (apt-get install nftables)"
    NFT_RULES_FILE="$(mktemp /tmp/homelab-hardening-dryrun.XXXXXX.nft)"
  else
    log "Configuring nftables tailnet-only scoping..."
    if ! command -v nft >/dev/null 2>&1; then
      apt_update_once
      apt-get install -y -qq nftables || die "could not install nftables"
    fi
  fi

  # We do NOT enable the distro nftables.service: on Debian its default
  # /etc/nftables.conf starts with 'flush ruleset', which would wipe
  # Tailscale's chains. Our rules live in their own table, loaded by a
  # dedicated oneshot unit, so everything else on the box is untouched.
  if systemctl is-active --quiet ufw 2>/dev/null; then
    warn "ufw is active; these nftables rules are independent of it (a drop in either wins). Review both if something is unreachable."
  fi

  if [ "$HARDEN_SSH_TAILNET_ONLY" = "1" ]; then
    if systemctl is-active --quiet tailscaled 2>/dev/null; then
      warn "HARDEN_SSH_TAILNET_ONLY=1: public SSH (port 22) will be DROPPED."
      warn "Make sure 'tailscale ssh' to this host works from another device BEFORE closing this session."
      HARDEN_TAILNET_TCP_PORTS="${HARDEN_TAILNET_TCP_PORTS},22"
    else
      warn "tailscaled is not running — refusing to scope SSH to the tailnet (you would be locked out). Skipping."
    fi
  fi

  # Build "{ 53, 80, ... }" nft sets from the comma-separated env lists.
  tcp_set="{ $(echo "$HARDEN_TAILNET_TCP_PORTS" | tr -s ',' ' ' | sed 's/ *$//; s/^ *//; s/ /, /g') }"
  udp_set="{ $(echo "$HARDEN_TAILNET_UDP_PORTS" | tr -s ',' ' ' | sed 's/ *$//; s/^ *//; s/ /, /g') }"

  allow_rules=""
  for cidr in $(echo "$HARDEN_ALLOW_CIDRS" | tr ',' ' '); do
    case "$cidr" in
      *:*) allow_rules="${allow_rules}    ip6 saddr $cidr accept
" ;;
      *)   allow_rules="${allow_rules}    ip saddr $cidr accept
" ;;
    esac
  done

  drop_rules=""
  [ "$HARDEN_TAILNET_TCP_PORTS" != "" ] && drop_rules="${drop_rules}    tcp dport $tcp_set counter drop comment \"tailnet-only TCP\"
"
  [ "$HARDEN_TAILNET_UDP_PORTS" != "" ] && drop_rules="${drop_rules}    udp dport $udp_set counter drop comment \"tailnet-only UDP\"
"

  forward_chain=""
  if [ "$HARDEN_RFC1918_DROP" = "1" ]; then
    forward_chain="
  chain forward {
    type filter hook forward priority filter; policy accept;
    # Tunnel-ingress traffic (from a tailnet peer, via this exit node) bound
    # for private address space is dropped. This is what keeps a phone using
    # this exit node from also pivoting into whatever LAN the exit node sits
    # on. The tailnet's own range (100.64.0.0/10) is intentionally NOT in
    # this list — that's normal tailnet-to-tailnet traffic.
    iifname \"$HARDEN_TS_IFACE\" ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 } counter drop comment \"rfc1918 tunnel-ingress drop\"
  }"
  fi

  mkdir -p "$(dirname "$NFT_RULES_FILE")"
  cat > "$NFT_RULES_FILE" <<EOF
#!/usr/sbin/nft -f
# Managed by bare-metal-bootstrap bootstrap-exit-node-hardening.sh — do not
# edit by hand (rerun the script with different env vars instead).
#
# Independent table: declaring + deleting it first makes reloads idempotent
# without ever flushing Tailscale's / anyone else's ruleset. The 'input'
# chain scopes sensitive ports to the tailnet; policy is 'accept' there, so
# nothing is blocked except NEW connections to the listed ports arriving from
# outside the tailnet — a bad rule here cannot lock you out of SSH (unless
# you opted into HARDEN_SSH_TAILNET_ONLY). The 'forward' chain (only present
# when HARDEN_RFC1918_DROP=1) drops tunnel-ingress traffic bound for private
# address space; it never touches Tailscale's own FORWARD rules or non-tailnet
# forwarded traffic.

table inet homelab_hardening
delete table inet homelab_hardening

table inet homelab_hardening {
  chain input {
    type filter hook input priority filter; policy accept;
    iifname "lo" accept
    iifname "$HARDEN_TS_IFACE" accept
    ct state established,related accept
$allow_rules$drop_rules  }
$forward_chain
}
EOF

  nft -c -f "$NFT_RULES_FILE" || die "generated nftables ruleset failed validation: $NFT_RULES_FILE"
  if [ "$HARDEN_DRY_RUN" = "1" ]; then
    log "DRY RUN: ruleset validates (TCP $tcp_set, UDP $udp_set -> tailnet only); left at $NFT_RULES_FILE, nothing loaded"
  else
    nft -f "$NFT_RULES_FILE"
    log "nftables table 'inet homelab_hardening' loaded (TCP $tcp_set, UDP $udp_set -> tailnet only)"
    if [ "$HARDEN_RFC1918_DROP" = "1" ]; then
      log "RFC1918 tunnel-ingress drop active: $HARDEN_TS_IFACE -> {10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16} FORWARDed traffic is dropped"
    fi

    # Persist across reboots with a dedicated oneshot unit. Ordered after the
    # distro nftables.service in case it is ever enabled (its 'flush ruleset'
    # would otherwise wipe this table at boot).
    cat > "$NFT_UNIT_FILE" <<EOF
[Unit]
Description=Homelab hardening nftables rules (tailnet-only service ports)
Documentation=https://github.com/Thilagan-Digital/bare-metal-bootstrap
Wants=network-pre.target
After=nftables.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f $NFT_RULES_FILE
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --quiet "$NFT_UNIT"
    log "Enabled $NFT_UNIT (rules persist across reboots)"
  fi
else
  log "Skipping nftables scoping (HARDEN_NFTABLES=$HARDEN_NFTABLES)"
fi

# ---------------------------------------------------------------------------
# 2. CrowdSec: community IP-reputation blocking + nftables bouncer
# ---------------------------------------------------------------------------
if [ "$HARDEN_CROWDSEC" = "1" ] && [ "$HARDEN_DRY_RUN" = "1" ]; then
  log "DRY RUN: would install CrowdSec + the nftables bouncer, whitelist tailnet/RFC1918/loopback sources"
elif [ "$HARDEN_CROWDSEC" = "1" ]; then
  if command -v cscli >/dev/null 2>&1; then
    log "CrowdSec already installed ($(cscli version 2>/dev/null | head -n1 || echo 'version unknown'))"
  else
    log "Installing CrowdSec..."
    # Official repo-setup script (same pattern as the Tailscale/AdGuard
    # installers used elsewhere in this repo).
    curl -fsSL https://install.crowdsec.net | sh || die "could not set up the CrowdSec package repository"
    apt_updated=0 # the repo script added a new source; force a re-update
    apt_update_once
    apt-get install -y -qq crowdsec || die "could not install crowdsec"
  fi
  systemctl enable --now --quiet crowdsec || warn "could not enable/start crowdsec"

  # The nftables bouncer turns CrowdSec decisions into actual drops. It
  # manages its own 'crowdsec'/'crowdsec6' tables — independent of both
  # Tailscale's rules and our homelab_hardening table. The Debian package
  # auto-registers itself with the local CrowdSec API on install.
  if dpkg -s crowdsec-firewall-bouncer-nftables >/dev/null 2>&1; then
    log "CrowdSec nftables bouncer already installed"
  else
    log "Installing CrowdSec nftables bouncer..."
    apt_update_once
    apt-get install -y -qq crowdsec-firewall-bouncer-nftables \
      || warn "could not install crowdsec-firewall-bouncer-nftables"
  fi
  systemctl enable --now --quiet crowdsec-firewall-bouncer 2>/dev/null \
    || warn "could not enable/start crowdsec-firewall-bouncer"

  # Never ban ourselves: whitelist tailnet (CGNAT range Tailscale uses),
  # RFC1918, and loopback sources at the parser stage.
  if [ ! -f "$CROWDSEC_WHITELIST" ]; then
    log "Whitelisting tailnet + private ranges in CrowdSec..."
    mkdir -p "$(dirname "$CROWDSEC_WHITELIST")"
    cat > "$CROWDSEC_WHITELIST" <<'EOF'
# Managed by bare-metal-bootstrap bootstrap-exit-node-hardening.sh.
# Sources that must never be banned: the tailnet (Tailscale's CGNAT range),
# private LANs, and loopback.
name: homelab/tailnet-whitelist
description: "Whitelist tailnet, RFC1918, and loopback sources"
whitelist:
  reason: "tailnet / private / loopback source"
  cidr:
    - "100.64.0.0/10"
    - "10.0.0.0/8"
    - "172.16.0.0/12"
    - "192.168.0.0/16"
    - "127.0.0.0/8"
    - "fd7a:115c:a1e0::/48"
EOF
    systemctl reload crowdsec 2>/dev/null || systemctl restart crowdsec \
      || warn "could not reload crowdsec to pick up the whitelist"
  else
    log "CrowdSec whitelist already present at $CROWDSEC_WHITELIST"
  fi

  if [ -n "${CROWDSEC_ENROLL_KEY:-}" ]; then
    log "Enrolling in the CrowdSec console..."
    cscli console enroll "$CROWDSEC_ENROLL_KEY" 2>/dev/null \
      || warn "console enroll failed (already enrolled, or bad key) — check 'cscli console status'"
  fi
else
  log "Skipping CrowdSec (HARDEN_CROWDSEC=$HARDEN_CROWDSEC)"
fi

# ---------------------------------------------------------------------------
# 3. Suricata (opt-in): passive IDS on the WAN interface
# ---------------------------------------------------------------------------
if [ "$HARDEN_SURICATA" = "1" ] && [ "$HARDEN_DRY_RUN" = "1" ]; then
  log "DRY RUN: would install Suricata in passive IDS mode on the default (WAN) interface"
elif [ "$HARDEN_SURICATA" = "1" ]; then
  WAN_IFACE="$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')"
  if [ -z "$WAN_IFACE" ]; then
    warn "could not determine the default (WAN) interface; skipping Suricata"
  else
    if command -v suricata >/dev/null 2>&1; then
      log "Suricata already installed"
    else
      log "Installing Suricata (passive IDS mode, interface: $WAN_IFACE)..."
      apt_update_once
      apt-get install -y -qq suricata || warn "could not install suricata"
    fi
    if [ -f /etc/suricata/suricata.yaml ]; then
      # Point the first af-packet capture interface at the WAN NIC. The Debian
      # default is eth0; this is a no-op when already set. Best-effort — if
      # the config layout changes, fix the interface by hand.
      sed -i "0,/^\(\s*- interface:\).*/s//\1 $WAN_IFACE/" /etc/suricata/suricata.yaml \
        || warn "could not set the Suricata capture interface; edit /etc/suricata/suricata.yaml"
      if command -v suricata-update >/dev/null 2>&1; then
        log "Updating Suricata rulesets (best-effort)..."
        suricata-update >/dev/null 2>&1 || warn "suricata-update failed; run it manually later"
      fi
      systemctl enable --now --quiet suricata || warn "could not enable/start suricata"
      log "Suricata running in IDS (alert-only) mode — alerts land in /var/log/suricata/fast.log"
    fi
  fi
else
  log "Skipping Suricata (HARDEN_SURICATA=$HARDEN_SURICATA; set to 1 to opt in)"
fi

# ---------------------------------------------------------------------------
# 4. Netdata (opt-in): real-time monitoring, tailnet-only
# ---------------------------------------------------------------------------
if [ "$HARDEN_NETDATA" = "1" ] && [ "$HARDEN_DRY_RUN" = "1" ]; then
  log "DRY RUN: would install Netdata bound to all interfaces (port 19999 tailnet-only via nftables)"
elif [ "$HARDEN_NETDATA" = "1" ]; then
  if command -v netdata >/dev/null 2>&1 || [ -x /usr/sbin/netdata ]; then
    log "Netdata already installed"
  else
    log "Installing Netdata..."
    apt_update_once
    apt-get install -y -qq netdata || warn "could not install netdata"
  fi
  # The Debian package binds Netdata to 127.0.0.1 only. Bind to all
  # interfaces and rely on the nftables scoping above (19999 is in the
  # default tailnet-only port list) so it is reachable over the tailnet but
  # not from the internet.
  if [ -f /etc/netdata/netdata.conf ] && grep -qE '^\s*bind (socket )?to( IP)?\s*=\s*127\.0\.0\.1' /etc/netdata/netdata.conf; then
    if [ "$HARDEN_NFTABLES" = "1" ]; then
      log "Binding Netdata to all interfaces (port 19999 stays tailnet-only via nftables)..."
      sed -i -E 's/^(\s*bind (socket )?to( IP)?\s*=\s*)127\.0\.0\.1.*/\1*/' /etc/netdata/netdata.conf
      systemctl restart netdata || warn "could not restart netdata"
    else
      warn "nftables scoping is disabled; leaving Netdata bound to 127.0.0.1 (would otherwise be exposed publicly)"
    fi
  fi
else
  log "Skipping Netdata (HARDEN_NETDATA=$HARDEN_NETDATA; set to 1 to opt in)"
fi

# ---------------------------------------------------------------------------
# Done — the remaining (highest-leverage) steps are manual.
# ---------------------------------------------------------------------------
if [ "$HARDEN_DRY_RUN" = "1" ]; then
  log "DRY RUN complete — no system changes were made."
  exit 0
fi

echo -e "${GREEN}==> Setup Complete!${NC}"
echo ""
echo "Manual next steps (highest leverage first):"
echo "  1. Tailscale ACLs — restrict which devices can reach which ports:"
echo "       https://login.tailscale.com/admin/acls"
echo "     A commented starting policy is in this repo:"
echo "       tailscale-acl.example.hujson"
echo "  2. Enable DNSSEC in AdGuard Home (this repo never edits AdGuardHome.yaml):"
echo "       AdGuard UI -> Settings -> DNS settings -> 'Enable DNSSEC'"
echo "  3. Verify the port scoping from OUTSIDE the tailnet (should time out):"
echo "       nc -vz -w3 <public-ip> 3000"
echo "     ...and from a tailnet device (should connect):"
echo "       nc -vz -w3 <tailscale-ip> 3000"
if [ "$HARDEN_CROWDSEC" = "1" ]; then
  echo "  4. Check CrowdSec is watching and blocking:"
  echo "       sudo cscli metrics ; sudo cscli decisions list"
fi
if [ "$HARDEN_RFC1918_DROP" = "1" ]; then
  echo "  5. Verify the RFC1918 tunnel-ingress drop from a client using this exit node:"
  echo "       curl -m3 http://192.168.1.1/   # any RFC1918 IP the exit node's LAN sits on -> should time out"
  echo "       sudo nft list table inet homelab_hardening   # check 'forward' chain drop counter"
fi
