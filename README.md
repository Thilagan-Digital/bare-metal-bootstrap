# bare-metal-bootstrap

Public, secret-free automation for turning bare-metal machines into a running
homelab — from a fresh OS install to a highly-available Proxmox cluster —
**before** any private, environment-specific configuration takes over.

Nothing in this repo is specific to one deployment or contains any secret.
Real host addresses, cluster names, storage topology, and passwords live in
your own **git-ignored** private inventory (see
[`inventory.example/`](inventory.example/)); the only secrets any script reads
are optional environment variables passed in at run time — `TS_AUTHKEY`
(Tailscale pre-auth key) and `CROWDSEC_ENROLL_KEY` — never committed, never
logged.

## Proxmox VE 9.x bare-metal → cluster automation

An Infrastructure-as-Code pipeline that takes raw Proxmox VE 9.x (Debian
Trixie) bare-metal installs and assembles them into a highly-available
Corosync cluster with Tailscale overlay networking, external QDevice quorum
arbitration, and automated shared-storage provisioning (NFS/SMB).

It separates one-time per-node OS prep from multi-node orchestration:

- **Phase 1 — Zero-touch node bootstrap** ([`bootstrap-node.sh`](bootstrap-node.sh)):
  run locally on each fresh install to fix the DEB822 repos, silence the
  subscription nag, install the core virtualization + Ansible dependencies,
  and join a Tailscale overlay network.
- **Phase 2 — Cluster orchestration** ([`site.yml`](site.yml) + [`playbooks/`](playbooks/)):
  an Ansible suite run from a management machine to assemble the Corosync
  ring, join worker nodes over SSH, bind an external QDevice for quorum, and
  mount cluster-wide shared storage.

```
+-------------------------------------------------------------------------+
|                  Tailscale Overlay Network (100.64.0.0/10)              |
+-------------------------------------------------------------------------+
       |                  |                  |                  |
+--------------+   +--------------+   +--------------+   +--------------+
| Control Node |   | Worker Node  |   | Worker Node  |   | Worker Node  |
| (pvecm init) |   | (pvecm join) |   | (pvecm join) |   | (pvecm join) |
+--------------+   +--------------+   +--------------+   +--------------+
       |                  |                  |                  |
+-------------------------------------------------------------------------+
|                      Local LAN Switch (e.g., 192.168.x.0/24)            |
+-------------------------------------------------------------------------+
                                     |
                             +---------------+
                             | External NAS  | <-- [QDevice Quorum Vote]
                             |  (NFS / SMB)  | <-- [Shared VM/Backup Storage]
                             +---------------+
```

### Repository structure

```
bare-metal-bootstrap/
├── bootstrap-node.sh        # Phase 1: bare-metal node preparation
├── ansible.cfg              # Default Ansible execution configuration
├── site.yml                 # Phase 2: master orchestration playbook
├── playbooks/
│   ├── 01-cluster-init.yml  # Initialize the Corosync cluster (control node)
│   ├── 02-join-workers.yml  # Join worker nodes to the control node
│   ├── 03-qdevice.yml       # Configure the external QDevice for quorum
│   ├── 04-storage.yml       # Provision cluster-wide NFS/SMB storage tiers
│   ├── 05-tls-cert.yml      # Trusted Tailscale TLS cert for the PVE API (pveproxy)
│   ├── 06-pve-firewall.yml  # Lock pveproxy (8006) to tailscale0 via pve-firewall; assert corosync stays on the LAN
│   ├── 07-pve-patch.yml     # Rolling patch-and-reboot + Debian-Security unattended-upgrades on PVE hosts
│   └── templates/
│       ├── host.fw.j2
│       ├── cluster.fw.j2
│       └── 50unattended-upgrades-pve.j2
├── inventory.example/       # Copy this into a git-ignored private-inventory/
│   ├── hosts.ini
│   └── group_vars/all.yml
├── requirements.yml         # Galaxy collections the playbooks depend on
└── bootstrap-*.sh           # Standalone single-purpose bootstrap scripts (below)
```

### Usage

**Phase 1 — on each fresh Proxmox node** (anonymous, no clone needed):

```bash
curl -fsSL https://raw.githubusercontent.com/thilagan-digital/bare-metal-bootstrap/main/bootstrap-node.sh \
  | sudo TS_AUTHKEY=tskey-auth-xxxx bash
```

**Phase 2 — from a management machine**, against your own private inventory:

```bash
git clone https://github.com/thilagan-digital/bare-metal-bootstrap.git
cd bare-metal-bootstrap

# Copy the examples into a git-ignored private inventory and adapt them:
mkdir -p private-inventory/group_vars
cp inventory.example/hosts.ini          private-inventory/hosts.ini
cp inventory.example/group_vars/all.yml private-inventory/group_vars/all.yml

# Store your passwords in an encrypted vault (never plaintext):
ansible-vault create private-inventory/group_vars/vault.yml

# Requires: ansible-core + the pexpect python module (pip install pexpect),
# plus the Galaxy collections in requirements.yml (used by 06-pve-firewall.yml's
# corosync-address assertion):
ansible-galaxy collection install -r requirements.yml

ansible-playbook -i private-inventory/hosts.ini site.yml --ask-vault-pass
```

`06-pve-firewall.yml` runs `serial: 1` and pauses for an operator confirmation
before each node — have physical/iDRAC/IPMI console access to that node ready
before confirming. See the playbook's header comment for the recovery path
if a node ends up unreachable mid-rollout.

`07-pve-patch.yml` is the rolling patch-and-reboot playbook — also `serial: 1`
with an operator pause per node. Each node is drained (guests live-migrated
or HA-drained), fully upgraded (`apt full-upgrade`), rebooted only if the
kernel or `pve-manager` version changed, then verified for quorum and
`pveproxy` health before proceeding. It also configures `unattended-upgrades`
scoped to the **Debian-Security origin only** — PVE packages are never
auto-dist-upgraded. Run it standalone for maintenance windows:

```bash
ansible-playbook -i private-inventory/hosts.ini playbooks/07-pve-patch.yml \
  --ask-vault-pass
```

The playbooks are idempotent and each is independently re-runnable — a
partial or repeated run reconverges rather than erroring on what already
exists.

## Standalone bootstrap scripts

Single-purpose, secret-free installers for individual homelab roles — each is
self-contained and runs with a single anonymous `curl | bash`:

| Script | What it does | What it leaves for your private automation |
|---|---|---|
| [`bootstrap-node.sh`](bootstrap-node.sh) | Prepares a bare Proxmox VE 9.x node (repos, nag, core deps, Tailscale) — Phase 1 above | Cluster formation, storage, VM/LXC provisioning (the Ansible pipeline / your IaC) |
| [`bootstrap-ansible-controller.sh`](bootstrap-ansible-controller.sh) | Installs `ansible-core`, `python3`, `openssh-client`, `python3-pexpect`, `git`, the Doppler CLI, joins Tailscale, generates this host's SSH keypair, and (given `ANSIBLE_TARGETS`) pushes that key to each managed host | Galaxy collections, inventory, playbooks, secrets |
| [`bootstrap-nas-base.sh`](bootstrap-nas-base.sh) | Installs core apt/TLS packages + Docker, and joins Tailscale | Samba/NFS/Cockpit configuration, add-on containers |
| [`bootstrap-tailscale-exit-node.sh`](bootstrap-tailscale-exit-node.sh) | Installs Tailscale, enables IP forwarding, advertises the host as an exit node, tunes UDP GRO throughput, installs fail2ban + unattended-upgrades | Tailscale ACLs, DNS filtering config, monitoring |
| [`bootstrap-adguard-home.sh`](bootstrap-adguard-home.sh) | Installs AdGuard Home (DNS ad/tracker blocker) and starts it as a systemd service | All AdGuard config (upstream DNS, blocklists, admin password) — set through its own web wizard |
| [`bootstrap-exit-node-hardening.sh`](bootstrap-exit-node-hardening.sh) | Layers nftables tailnet-only port scoping + RFC1918 tunnel-ingress drop + CrowdSec (+ optional Suricata/Netdata) on an existing exit-node/AdGuard host | Tailscale ACLs (see [`tailscale-acl.example.hujson`](tailscale-acl.example.hujson)), fleet-specific port/CIDR tuning |

```bash
curl -fsSL https://raw.githubusercontent.com/thilagan-digital/bare-metal-bootstrap/main/<script>.sh \
  | sudo TS_AUTHKEY=tskey-auth-xxxx bash
```

Omit `TS_AUTHKEY` for an interactive Tailscale login instead of a
non-interactive one. `bootstrap-exit-node-hardening.sh` takes its own set of
`HARDEN_*` flags — see its header comment.

## Why this repo is public

Every step here is generic and secret-free, so it can be fetched and run with
a single anonymous `curl | bash` — no GitHub PAT or deploy key. Anything that
needs a secret or is specific to one deployment (real inventory, vault, storage
topology) stays in your own private repo or git-ignored `private-inventory/`.

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for branch/commit conventions,
shell style, how to test changes locally, and the ground rules (no secrets,
no build-specific values, idempotent).

## License

[MIT](LICENSE)
