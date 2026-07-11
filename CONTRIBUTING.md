# Contributing

This repo is a set of small, standalone bash scripts that bootstrap bare
hardware (Proxmox nodes, a NAS, an Ansible controller) to a minimally-alive
state before a private automation repo's Ansible takes over. Each script is
fetched and run directly via `curl | bash` — see the README — so every
change has to preserve that single-file, no-dependencies usage.

## Ground rules

- **No secrets, ever.** No committed tokens, keys, credentials, or
  environment-specific hostnames/IPs. The only secret this repo touches is
  an optional `TS_AUTHKEY` read from the environment at run time — never
  written to a file, never logged, never hard-coded.
- **Idempotent.** Re-running a script should converge to the desired state,
  not fail because something already exists. Check before installing
  (`dpkg -s`, `command -v`), matching the existing scripts.
- **Self-contained.** Each `bootstrap-*.sh` must keep working as a single
  file piped straight from `raw.githubusercontent.com` — don't introduce a
  dependency on sourcing another file in this repo.
- **Public-safe.** Nothing fleet-specific (real hostnames, IPs, org
  internals) belongs here. If a step needs a secret or fleet-specific
  config, it belongs in your private automation repo's Ansible instead.

## Workflow

1. Branch off `main`. Name it after the change, e.g. `feat/...`, `fix/...`,
   `docs/...`.
2. Make the change.
3. Commit with [Conventional Commits](https://www.conventionalcommits.org/):
   `type(scope): description`, e.g. `fix(pve): handle missing ceph.sources`.
4. Open a PR against `main`. The `protect-main` ruleset requires a PR with
   resolved review threads before merging — see `.github/rulesets/`.
5. Squash-merge once reviewed.

## Shell style

- Every script starts with `set -euo pipefail`.
- Require root explicitly at the top (`[ "$(id -u)" -eq 0 ] || ...`), rather
  than failing partway through on a permission error.
- Print what the script is doing as it goes; fail loudly with a clear
  message rather than silently continuing.
- Keep the existing `GREEN`/`YELLOW`/`RED` log style consistent across
  scripts.

## Testing changes

There's no hardware-in-CI test harness — validate locally before opening a
PR:

```bash
# Lint every script
docker run --rm -v "$PWD:/mnt" koalaman/shellcheck:stable --severity=warning $(find . -name '*.sh' -not -path './.git/*')

# Syntax-check without executing
for f in *.sh; do bash -n "$f"; done
```

For anything that touches repo config, package sources, or networking
(`bootstrap-pve.sh`, `bootstrap-nas-base.sh`), test end-to-end on a
throwaway VM or spare hardware before merging — these scripts modify system
state and are hard to unwind from CI.

## Adding a new bootstrap script

- One script per device/role, named `bootstrap-<role>.sh`.
- Add a row to the table in `README.md` describing what it does and what it
  deliberately leaves for the private automation repo.
- Keep the same structure as the existing scripts: shebang, header comment
  (purpose, usage, one-liner), root check, then numbered steps with
  `log`-style echoes.
