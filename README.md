# substrate

Pull-based fleet configuration. GitHub is the control plane: whatever is committed to the branch a node tracks is its desired state. Nodes converge themselves — no operator action, no central push.

## How it works

1. **Bootstrap** — run `bootstrap/bootstrap.sh` as root on a fresh node. It installs git and ansible, seeds the node's environment into `/etc/substrate/branch`, and performs the first `ansible-pull` from this repo.
2. **Converge** — `local.yml` is the `ansible-pull` entry point. It loads the node's identity from `host_vars/<hostname>.yml`, applies the `common` base and the `reconciler` role unconditionally, then applies any additional role layers listed in `node_roles`.
3. **Drift repair** — the `reconciler` role installs a systemd timer (`substrate-reconcile.timer`) that re-runs `ansible-pull` every 15 minutes. `--only-if-changed` is intentionally absent: the node re-converges on every tick, repairing manual drift even when the repo has not changed.

```
local.yml                 # ansible-pull entry point
ansible.cfg               # roles_path, inventory, sudo-by-default
inventory/hosts.yml       # localhost only (ansible-pull targets the node itself)
group_vars/all.yml        # fleet-wide vars and control-plane pointers
host_vars/<hostname>.yml  # per-node identity: which role layers to apply (node_roles)
bootstrap/bootstrap.sh    # one-shot fresh-node bootstrap (cloud-init user-data)
roles/common/             # base substrate every node gets, always
roles/reconciler/         # systemd timer that keeps the node reconciling
roles/headscale/          # tailnet coordination server (one core node)
roles/tailnet/            # joins the node to the headscale tailnet (Tailscale client)
roles/cert_issuer/        # issues the wildcard cert (DNS-01) + serves it over the tailnet
roles/cert_client/        # fetches the wildcard cert from the issuer over the tailnet
roles/dns/                # reconciles the PUBLIC Cloudflare zone for sbkt.co from git
tests/                    # containerized validation suite + Incus converge harness
```

The base (`common` + `reconciler`) is applied to every node. The remaining roles
are differentiation layers, selected per-node via `node_roles` in
`host_vars/<hostname>.yml`; add new service roles under `roles/` the same way.

## Environments and promotion

Environments are branches — the branch a node tracks is its environment.

| Branch    | Environment     | Who tracks it                         |
|-----------|-----------------|---------------------------------------|
| `main`    | production      | most nodes                            |
| `staging` | pre-production  | staging fleet (Incus containers)      |

**Rules:**

1. **PRs only** into `main` or `staging` — never commit directly.
2. **CI must pass.** The `validate` job (lint + check-mode) runs on every PR and push. The expensive `converge` job (Incus real convergence) is *gated*: it runs automatically on pushes to `main`/`staging` that touch reconciler-relevant paths (`roles/`, `local.yml`, `ansible.cfg`, `group_vars/`, `host_vars/`, `bootstrap/`, `requirements.yml`, `tests/incus/`, `staging/`, the CI workflow), on manual dispatch, and on PRs labelled `needs-converge`. A PR that changes those paths should carry the `needs-converge` label so convergence is actually exercised before merge; doc-only PRs skip it by design.
3. **Fast-forward promotion only** — changes flow `feature → PR → staging → main`:

   ```sh
   git switch main
   git merge --ff-only staging
   git push origin main
   ```

   `--ff-only` is load-bearing: it guarantees `main` and `staging` never diverge (staging is always "`main` plus not-yet-promoted commits"), which prevents environment drift.

**Why the branch is not in `host_vars`:** the branch seed lives in `/etc/substrate/branch` (written at bootstrap, never in the repo) so `host_vars/<hostname>.yml` stays identical across `main` and `staging`, keeping fast-forward promotion clean. Move a node between environments by rewriting `/etc/substrate/branch` or re-bootstrapping.

See [RUNBOOK.md](RUNBOOK.md) for the day-to-day operator commands ("how do I actually use this")
and [CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow and conventions.

## Network and TLS architecture

This is the fleet's network design, implemented by the `headscale`, `tailnet`, `cert_issuer`, `cert_client`, and `dns` roles.

**Tailnet** — a headscale-coordinated Tailscale-compatible tailnet connects the fleet. MagicDNS names every node `<hostname>.net.sbkt.co`. Internal hosts never receive public DNS records, so the internal topology stays out of public DNS and Certificate Transparency logs.

**TLS** — a single wildcard certificate (`*.net.sbkt.co`) is issued via certbot DNS-01 (Cloudflare) on one designated issuer node; every other node fetches it from the issuer over the tailnet (served by the issuer, pulled by clients — the same pull principle as config). The fleet stays on the Let's Encrypt **staging** ACME endpoint until `substrate_acme_staging` is flipped to `false`.

**Secrets** — node-local secret material lives under `/etc/substrate/secrets`, seeded at bootstrap (or placed by an operator). Secret values are never committed to this repo; the repo holds only the paths roles read. Roles that need a missing secret skip with a loud warning rather than failing the whole converge.

**Staging fleet** — the staging environment runs as persistent Incus system containers on owned hardware, bootstrapped onto the `staging` branch. They run the same reconciler and join a real tailnet, at zero cloud cost.

For the full rationale and layered detail, see [ARCHITECTURE.md](ARCHITECTURE.md); for the secret-handling model (what lives where, how it is seeded, rotation), see [SECRETS.md](SECRETS.md).

## Fleet topology

The design holds at any fleet size; roles just concentrate or spread across nodes. The cloud provider is OVHCloud (VPS); production nodes have neither Docker nor Colima.

| Layer    | What it is                                                              | Where it lives                                                                 |
|----------|------------------------------------------------------------------------|--------------------------------------------------------------------------------|
| Physical | OVH VPS (production) or Incus system containers (staging/tests)         | one or more nodes                                                              |
| Network  | public IP per node; tailnet CGNAT `100.x.x.x` between nodes             | `tailnet` role on every node; `headscale` on one core node                     |
| Naming   | public `sbkt.co` records; internal `*.net.sbkt.co` via MagicDNS         | `dns` role (public zone) on one node; MagicDNS (headscale) for internal names  |
| TLS      | one wildcard `*.net.sbkt.co`, issued DNS-01, served over the tailnet    | `cert_issuer` on the core node; `cert_client` on every other node             |
| Control  | GitHub branches (`main`=prod, `staging`=preprod), pull-based reconcile  | this repo; each node's `/etc/substrate/branch` seed                            |

**Single-VPS.** All roles land on one node: `node_roles: [headscale, tailnet, cert_issuer, dns, <service...>]`. Headscale coordinates the node's own tailnet, the node issues and consumes its own wildcard cert, and `dns` reconciles the public zone from that same node. `substrate_headscale_url` and `cert_client_issuer_host` (if `cert_client` is used) point at that node.

**Multi-VPS.** One core node runs `headscale` + `cert_issuer` (and typically `dns`); every other node runs `tailnet` + `cert_client` and points `cert_client_issuer_host` at the core node's MagicDNS name and `substrate_headscale_url` at the core node. The `dns` role must be assigned to exactly one node (it owns the public zone). Growing from 1→N nodes is purely additive: add `host_vars/<hostname>.yml` files selecting the lighter role set; the core node is unchanged.

## Service deployment model

Prefer **systemd-native processes installed by roles** (as `headscale`, `tailnet`, and `cert_issuer` already do) — an Ansible role that installs a package/binary and manages a unit is the default for a new service. Containerize only when packaging or isolation genuinely demands it, and then use **podman with systemd (Quadlet) units**, not a long-running Docker daemon. Incus containers exist only to *model nodes* for staging and tests; they are never an application layer inside a production node. Docker on this project is confined to building the lint toolchain image in CI.

## Quickstart

**Bootstrap a node:**

```sh
# as root on the fresh node (e.g. from cloud-init user-data); tracks main by default
sudo SUBSTRATE_BRANCH=main bash bootstrap/bootstrap.sh

# or for staging:
sudo SUBSTRATE_BRANCH=staging bash bootstrap/bootstrap.sh
```

**Run the validation suite (lint + syntax + check-mode converge, containerized):**

```sh
tests/run.sh
```

This is exactly what the CI `validate` job runs. No privileges required.

**Run the real convergence test (Incus system container, systemd as PID 1):**

```sh
# macOS: start Incus alongside Docker (first time only)
tests/incus/colima-up.sh

tests/incus/run.sh
```

Asserts idempotence and drift repair. See [tests/README.md](tests/README.md) for full details. On a Linux host Incus runs natively (no Colima); Colima is macOS-only and is only ever a way to host the Incus daemon on a dev machine — it is never present on production nodes or CI runners.

**Inspect the reconciler on a live node:**

```sh
systemctl status substrate-reconcile.timer
journalctl -u substrate-reconcile.service
```
