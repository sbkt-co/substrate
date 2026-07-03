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
tests/                    # containerized validation suite + Incus converge harness
```

Additional role layers (e.g. a webserver) are added under `roles/` and selected per-node via `node_roles` in `host_vars/<hostname>.yml`.

## Environments and promotion

Environments are branches — the branch a node tracks is its environment.

| Branch    | Environment     | Who tracks it                         |
|-----------|-----------------|---------------------------------------|
| `main`    | production      | most nodes                            |
| `staging` | pre-production  | staging fleet (Incus containers)      |

**Rules:**

1. **PRs only** into `main` or `staging` — never commit directly.
2. **CI must pass** — both the `validate` (lint + check-mode) and `converge` (Incus real convergence) jobs must be green.
3. **Fast-forward promotion only** — changes flow `feature → PR → staging → main`:

   ```sh
   git switch main
   git merge --ff-only staging
   git push origin main
   ```

   `--ff-only` is load-bearing: it guarantees `main` and `staging` never diverge (staging is always "`main` plus not-yet-promoted commits"), which prevents environment drift.

**Why the branch is not in `host_vars`:** the branch seed lives in `/etc/substrate/branch` (written at bootstrap, never in the repo) so `host_vars/<hostname>.yml` stays identical across `main` and `staging`, keeping fast-forward promotion clean. Move a node between environments by rewriting `/etc/substrate/branch` or re-bootstrapping.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow and conventions.

## Network and TLS architecture

This is the fleet's network design. The roles that implement it are being landed on in-flight feature branches; what follows is the architecture they converge on.

**Tailnet** — a headscale-coordinated Tailscale-compatible tailnet connects the fleet. MagicDNS names every node `<hostname>.net.sbkt.co`. Internal hosts never receive public DNS records, so the internal topology stays out of public DNS and Certificate Transparency logs.

**TLS** — a single wildcard certificate (`*.net.sbkt.co`) is issued via certbot DNS-01 (Cloudflare) on one designated issuer node; every other node fetches it from the issuer over the tailnet (served by the issuer, pulled by clients — the same pull principle as config). The fleet stays on the Let's Encrypt **staging** ACME endpoint until `substrate_acme_staging` is flipped to `false`.

**Secrets** — node-local secret material lives under `/etc/substrate/secrets`, seeded at bootstrap (or placed by an operator). Secret values are never committed to this repo; the repo holds only the paths roles read. Roles that need a missing secret skip with a loud warning rather than failing the whole converge.

**Staging fleet** — the staging environment runs as persistent Incus system containers on owned hardware, bootstrapped onto the `staging` branch. They run the same reconciler and join a real tailnet, at zero cloud cost.

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

Asserts idempotence and drift repair. See [tests/README.md](tests/README.md) for full details.

**Inspect the reconciler on a live node:**

```sh
systemctl status substrate-reconcile.timer
journalctl -u substrate-reconcile.service
```
