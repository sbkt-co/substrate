# CLAUDE.md

Guidance for Claude Code working in this repo. These instructions override defaults.

## Purpose & control plane

`substrate` bootstraps and configures a fleet of cloud servers: every node starts from a common base
and is **differentiated** into its role with no manual steps. **GitHub is the control plane** — the
tracked branch is the single source of truth; there is no authoritative state outside git. Reconciliation
is **pull-based**: each node runs `ansible-pull` on a systemd timer and converges itself idempotently,
repairing drift even when the branch is unchanged. There is **no local control plane** — no
operator-driven pushes, no laptop-held keys; the fleet must be fully operable with your laptop off.
Secrets ride git as SOPS ciphertext encrypted to **node-held** age keys (each node decrypts itself on
converge; see `docs/secrets.md`) — workstation-held SOPS/vault keys stay banned, and only revocable
material may be committed.

## Commands

| Task | Command |
| --- | --- |
| Validation gate (lint + syntax + check-mode converge, containerized) | `tests/run.sh` — exactly the CI `validate` job |
| Ad-hoc in toolchain image | `tests/run.sh ansible-lint roles/reconciler` |
| Real converge test (idempotence + drift repair, Incus + systemd) | `tests/incus/run.sh` — the gated CI `converge` job |
| Local converge (no fetch, current tree) | `sudo ansible-playbook -i inventory/hosts.yml local.yml` |
| Bring up the staging fleet | `staging/up.sh` |
| Promote staging→main (ff-only, dry-run by default) | `scripts/promote.sh` |
| Scaffold a new role layer | `scripts/new-role.sh <role>` |
| Register a node + print bootstrap snippet | `scripts/add-node.sh <hostname> [--branch staging\|main]` |
| Seed a node-local secret (value via stdin only) | `scripts/seed-secret.sh <target> <secret-name>` |

## Load-bearing constraints (violating these breaks CI or the fleet)

- **`when: ansible_service_mgr == 'systemd'` guards are load-bearing** — they let the unprivileged
  check-mode converge pass in a plain container. Do not remove to "simplify".
- **`ansible.cfg` stays dependency-free** (no `community.*` plugins/callbacks): it also governs
  `ansible-pull` on real nodes that have only `ansible-core`.
- **Never pin the tracked branch in `host_vars`** — it is seeded once at bootstrap
  (`SUBSTRATE_BRANCH` → `/etc/substrate/branch`). `host_vars` must stay identical across `main`/`staging`
  for ff-promotion. Roles and reconcile cadence legitimately differ there and are fine.
- **No secret values in git.** Secrets are node-local files under `/etc/substrate/secrets/` (root-only,
  seeded at bootstrap); consuming roles `stat` them and **skip loudly** when absent.
- **`staging`→`main` is ff-only, PRs only.** `--ff-only` keeps the branches from diverging; never
  commit env-specific differences that exist on one branch but not the other.
- **Commits: no AI/Claude references, no emojis.**
- Nodes and the test image are **Debian trixie** (Python 3.13) → **`ansible-core >= 2.18`** required;
  the **`uv`** toolchain installs it (`uv tool install ansible-core==2.18.6`), not pip/venv.
- Prefer modules with real `state:` semantics over `command`/`shell`; if unavoidable, guard with
  `creates:`/`changed_when`/`when`. Quote file modes in YAML; bash uses `set -euo pipefail`.

## Where to go deep (load on demand — do not inline this content)

| Reference | Answers |
| --- | --- |
| `docs/README.md` | Index of the docs below |
| `docs/architecture.md` | Layered network/TLS/topology, role layers, headscale tailnet + MagicDNS, wildcard cert (DNS-01) |
| `docs/secrets.md` | Node-local secret model, file names/formats, skip-loudly contract |
| `docs/runbook.md` | Operational workflows: add a node, rotate secrets, promote, recover |
| `CONTRIBUTING.md` | PR flow, CI job gating (`needs-converge` label), branch protection |
| `staging/README.md` | Staging fleet harness |
| `tests/README.md` | Test harness internals (validate vs converge, Incus/Colima) |

| Skill (`.claude/skills/`) | Does |
| --- | --- |
| `promote` | Drives `scripts/promote.sh`: dry-run → show delta → confirm → ff push |
| `new-role` | Scaffolds a role from templates with the load-bearing patterns baked in |
| `add-node` | Registers a `host_vars` entry + prints the cloud-init bootstrap snippet |
| `seed-secret` | Writes a node-local secret in the canonical file/format (stdin value, `0600`) |
