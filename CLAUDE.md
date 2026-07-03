# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Layout

```
local.yml                      # ansible-pull entry point: bootstrap base + apply role layers
ansible.cfg                    # roles_path, inventory, sudo-by-default
inventory/hosts.yml            # localhost only (ansible-pull converges the local node)
group_vars/all.yml             # control-plane pointers + reconcile schedule (canonical vars)
host_vars/<hostname>.yml       # per-node identity: which role layers a node selects (node_roles)
bootstrap/bootstrap.sh         # one-shot fresh-node bootstrap (e.g. cloud-init user-data)
roles/common/                  # base substrate every node gets (always applied)
roles/reconciler/              # installs the systemd timer that runs ansible-pull from main
/etc/substrate/secrets/        # root-only (0700) credential files seeded at bootstrap:
  tailnet-authkey              #   Tailscale auth key (SUBSTRATE_TAILNET_AUTHKEY)
  cloudflare-dns.ini           #   DNS-edit API token (SUBSTRATE_CLOUDFLARE_TOKEN)
  cloudflare.ini               #   ACME/certbot TXT-only token (SUBSTRATE_ACME_TOKEN)
```

Role differentiation layers (e.g. `roles/webserver/`) are added under `roles/` and selected per-node via `node_roles` in `host_vars/<hostname>.yml`.

## Commands

- **Fast validation suite (lint + syntax + check-mode converge), containerized:** `tests/run.sh`. Unprivileged, exactly what the CI `validate` job runs. The image is Debian **trixie** + a pinned toolchain (`tests/requirements.txt`).
- **Real convergence test (idempotence + drift repair) in an Incus system container:** `tests/incus/run.sh`. Boots Debian trixie with systemd as PID 1 and converges over the `community.general.incus` connection; this is the CI `converge` job. Docker is used only for the lint toolchain image — **node/deployment modeling is Incus**. On macOS, `tests/incus/colima-up.sh` runs Incus in its own Colima profile alongside the default Docker profile; `run.sh` auto-detects the remote (`colima-incus` vs `local`). See `tests/README.md`.
- **Python toolchain is `uv`** (not pip/venv): the test image installs via `uv pip install --system`, and CI/local controllers use `uv tool install ansible-core==2.18.6`.
- **Ad-hoc command in the toolchain image:** `tests/run.sh ansible-lint roles/reconciler`
- **Individual checks (if Ansible is installed on the host):** `ansible-playbook --syntax-check local.yml`, `ansible-lint`, `yamllint .`
- **Local converge (no git fetch, current working tree):** `sudo ansible-playbook -i inventory/hosts.yml local.yml`
- **Bootstrap a fresh node:** run `bootstrap/bootstrap.sh` as root (installs git+ansible, does the first `ansible-pull`; the `reconciler` role then takes over scheduling). Pass `SUBSTRATE_TAILNET_AUTHKEY`, `SUBSTRATE_CLOUDFLARE_TOKEN`, and/or `SUBSTRATE_ACME_TOKEN` as env vars to seed credential files under `/etc/substrate/secrets/` at bootstrap time; absent vars leave the file uncreated and consuming roles skip gracefully.
- **Inspect the reconciler on a node:** `systemctl status substrate-reconcile.timer` / `journalctl -u substrate-reconcile.service`

## Target platform & gotchas

- Nodes (and the test image) are Debian **trixie** (13, Python 3.13). The toolchain pin requires `ansible-core >= 2.18` for controller Python 3.13 — older pins fail to run.
- `ansible.cfg` is deliberately **dependency-free** (no `community.*` callbacks/plugins) because it also governs `ansible-pull` runs on real nodes that have only `ansible-core`.
- The `reconciler` role's `systemctl`-dependent tasks are guarded with `when: ansible_service_mgr == 'systemd'`. This is what lets the unprivileged check-mode converge pass in a plain container; on real nodes systemd is the init, so the timer is installed and started normally. Do not remove the guard to "simplify" — it is load-bearing for CI.

## How a node converges

1. `bootstrap.sh` runs once → installs git+ansible → `ansible-pull` of `main` → runs `local.yml`.
2. `local.yml` loads `host_vars/<hostname>.yml` to resolve the node's `node_roles`, applies `common` + `reconciler`, then each role layer.
3. The `reconciler` role installs `substrate-reconcile.timer`, which re-runs `ansible-pull` every `substrate_reconcile_interval`. Each run re-converges the node, repairing manual drift even when `main` is unchanged (`--only-if-changed` is intentionally NOT used).

## Branching & promotion (environments)

Environments are **branches**, because in a pull model the branch is the unit a node subscribes to. Two long-lived branches:

- **`main` = production.** What most nodes track.
- **`staging` = pre-production.** A small set of nodes track it for real-world soak before changes reach prod.

Rules:

1. **PRs only** into `main`/`staging` — never commit directly. Branch protection should require the CI `validate` + `converge` jobs to pass before anything lands on a branch nodes pull from.
2. **Flow:** feature branch → PR → CI → merge to `staging` → soak on staging nodes → **promote to `main` by fast-forward** (`git switch main && git merge --ff-only staging`, via PR).
3. **`--ff-only` is mandatory.** It guarantees `main` and `staging` never diverge — staging is only ever "`main` plus not-yet-promoted commits." This is what prevents environment drift, so **everything must be ff-mergeable**: don't commit env-specific differences that exist on one branch but not the other.

How a node picks its environment (and why it is NOT in `host_vars`):

- The tracked branch is **seeded once at bootstrap** (`SUBSTRATE_BRANCH` → `/etc/substrate/branch`). `local.yml` reads that seed and pins `substrate_branch`, so the `reconciler` timer keeps `ansible-pull`-ing the *same* branch the node was bootstrapped onto. Deriving the branch from the repo would be circular.
- Therefore **do not pin the branch in `host_vars`** — that file must stay identical across `main`/`staging` for ff-promotion. Per-node settings that legitimately differ (roles, reconcile cadence) do belong in `host_vars` (see `host_vars/staging-canary.example.yml`).
- Move a node between environments by rewriting `/etc/substrate/branch` (or re-bootstrapping); the node's recorded environment is visible in `/etc/substrate/node.yml` (`tracked_branch`).

## Purpose

`substrate` is the bootstrap and configuration framework for a fleet of cloud servers. Every server starts from a common, fully-prepared base ("substrate") and is then **differentiated** into its individual role. The goal is that a freshly provisioned machine can be brought to its complete, role-specific desired state with no manual steps.

## Architecture — GitHub as the control plane

This is the central design decision and it constrains everything else:

- **The committed branch is the specification.** Whatever is committed to the branch a node tracks (`main` for production, `staging` for pre-prod — see *Branching & promotion*) is the single source of truth for that node's desired state. There is no authoritative state outside git. `staging` is kept a strict fast-forward ancestor of itself relative to `main` so the two never diverge.
- **The reconciler runs on the servers, not on a workstation.** A server pulls the spec from this repo and applies it to itself idempotently to resolve drift. Reconciliation is something the fleet does *to itself* from git — it is not something an operator pushes from a laptop.
- **No local control plane.** Do **not** introduce SOPS, `age` keys held on workstations, `ansible-playbook` runs driven from an operator's machine as the system of record, or any design that makes a specific local computer necessary to converge the fleet. A laptop may be used for development and ad-hoc runs, but the system must be fully operable with the laptop turned off.
- **Idempotent + drift-resolving.** Applying the spec repeatedly must be safe and must converge the machine to the committed desired state regardless of its current state. Prefer Ansible (or a comparably simple, robust, declarative-by-convention tool) over bespoke imperative scripts.

### Implications when designing changes

- Reconciliation should be **pull-based**: a server (via cron/systemd timer/`ansible-pull` or equivalent) fetches `main` and converges itself. Favor this over push-based orchestration.
- **Bootstrap → differentiate** is a two-stage shape. Keep the common base (the part every node runs) cleanly separated from role-specific layers so a node's identity is the only thing that selects which roles apply. A node should be able to discover its own role (e.g. from instance metadata, hostname, or a small committed mapping) rather than being told by an external orchestrator.
- **Secrets**: because no workstation may be the control plane and SOPS is excluded, secret material must be retrievable by a node from a source the node itself can reach (cloud secret manager / instance identity), not decrypted by a local key on commit. Keep secret *values* out of the repo; the repo holds the *spec* for how a node obtains and places them.
- **Everything is reproducible from the tracked branch.** If a step can only be done by hand or only from one person's machine, redesign it.

## Conventions

- Keep the framework **simple and robust** over clever. The reconciler should be auditable end-to-end by reading the repo.
- Make every change safe to apply N times. When writing Ansible, lean on modules with proper `state:` semantics rather than `command`/`shell`; if `command`/`shell` is unavoidable, guard it with `creates:`/`changed_when`/`when`.
- Git messages: no references to Claude and no emojis.
