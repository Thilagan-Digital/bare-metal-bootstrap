# bare-metal-bootstrap

Public, secret-free bootstrap scripts for getting bare hardware (Proxmox
nodes, a NAS, a Tailscale exit node, an Ansible controller) to a
minimally-alive state — on the network, on the tailnet, with the right base
packages installed — **before** a private automation repo's Ansible takes
over for the rest of the convergence (service configuration, secrets,
compose stacks).

Nothing in this repo reads or writes a secret except a couple of optional
environment variables passed in at run time — `TS_AUTHKEY` (Tailscale
pre-auth key) and `CROWDSEC_ENROLL_KEY` — never committed, never logged.
See each script's header for details.

## Scripts

| Script | What it does | What it deliberately leaves for your private repo |
|---|---|---|
| [`bootstrap-pve.sh`](bootstrap-pve.sh) | Converts a Proxmox VE enterprise install to the no-subscription repo, installs Tailscale, and suppresses the "No valid subscription" nag popup | Clustering (`pvecm add`), storage pools, Terraform-managed VM/LXC provisioning |
| [`bootstrap-ansible-controller.sh`](bootstrap-ansible-controller.sh) | Installs `ansible-core`, `python3`, `openssh-client`, the Doppler CLI, and joins Tailscale | Galaxy collections (`ansible/requirements.yml`), inventory, playbooks, secrets |
| [`bootstrap-nas-base.sh`](bootstrap-nas-base.sh) | Installs core apt/TLS packages + Docker, and joins Tailscale | Samba/NFS/Cockpit configuration, add-on containers |
| [`bootstrap-tailscale-exit-node.sh`](bootstrap-tailscale-exit-node.sh) | Installs Tailscale, enables IP forwarding, advertises the host as an exit node, tunes UDP GRO throughput, installs fail2ban + unattended-upgrades | Tailscale ACLs, DNS filtering config, monitoring |
| [`bootstrap-adguard-home.sh`](bootstrap-adguard-home.sh) | Installs AdGuard Home (DNS ad/tracker blocker) and starts it as a systemd service | All AdGuard config (upstream DNS, blocklists, admin password) — set through its own web wizard, never touched by this script |
| [`bootstrap-exit-node-hardening.sh`](bootstrap-exit-node-hardening.sh) | Layers nftables tailnet-only port scoping + CrowdSec (+ optional Suricata/Netdata) on an existing exit-node/AdGuard host | Tailscale ACLs (see [`tailscale-acl.example.hujson`](tailscale-acl.example.hujson)), fleet-specific port/CIDR tuning |

## Usage

Each script is self-contained — no clone required, since this repo is
public:

```bash
curl -fsSL https://raw.githubusercontent.com/thilagan-digital/bare-metal-bootstrap/main/<script>.sh \
  | sudo TS_AUTHKEY=tskey-auth-xxxx bash
```

Omit `TS_AUTHKEY` for an interactive Tailscale login instead of a
non-interactive one. `bootstrap-exit-node-hardening.sh` takes its own set of
`HARDEN_*` flags — see its header comment.

## Why a separate repo

These steps used to be reachable only through a private automation repo,
which meant fetching them required a GitHub PAT or deploy key even though
none of the steps themselves touch a secret. Splitting them out here means
a brand-new device can be bootstrapped with a single anonymous `curl | bash`
one-liner, and the private repo's Ansible only has to handle the parts that
actually need secrets or fleet-specific configuration.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for branch/commit conventions,
shell style, how to test changes locally, and the ground rules (no secrets,
idempotent, self-contained single-file scripts).

## License

[MIT](LICENSE)
