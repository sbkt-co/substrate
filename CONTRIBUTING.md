# Contributing

This repository is the **control plane**: whatever is committed to a tracked
branch is the specification that nodes converge themselves to. Treat changes
accordingly — a merge to `main` changes production.

## Environments are branches

- **`main`** = production. Most nodes track it.
- **`staging`** = pre-production. A small set of nodes track it for real-world
  soak before changes reach prod.

A node's environment is seeded once at bootstrap (`/etc/substrate/branch`), not
configured in `host_vars`. Deriving the branch from the repo would be circular,
and pinning it in `host_vars` would make that file differ between `main` and
`staging` — which breaks fast-forward promotion (see the `--ff-only` rule below).
So `host_vars/<hostname>.yml` stays identical across branches; move a node between
environments by rewriting its `/etc/substrate/branch` seed. [README.md](README.md)
covers the same model in public-facing terms.

## The rules

1. **PRs only.** Never commit directly to `main` or `staging`. Open a PR from a
   short-lived feature branch.
2. **CI must pass.** The `validate` job (lint + syntax + check-mode converge)
   runs on every PR and push and must be green. The `converge` job (real Incus
   convergence + idempotence) is expensive and therefore **gated** — it does
   *not* run on ordinary PRs. It runs automatically on pushes to `main`/`staging`
   that touch reconciler-relevant paths (`roles/`, `local.yml`, `ansible.cfg`,
   `group_vars/`, `host_vars/`, `bootstrap/`, `requirements.yml`, `tests/incus/`,
   `staging/`, the CI workflow), on manual `workflow_dispatch`, and on PRs carrying
   the `needs-converge` label. **If your PR touches any of those paths, add the
   `needs-converge` label** so real convergence is exercised before merge; a
   docs-only or unrelated PR can skip it. Configure branch protection to require
   `validate` (and `converge` where you rely on the label gate).
3. **Promote by fast-forward only.** Changes flow
   `feature → PR → staging → main`:

   ```sh
   # after a change has soaked on staging nodes
   git switch main
   git merge --ff-only staging
   git push origin main
   ```

   If `--ff-only` is refused, `main` has commits `staging` doesn't — rebase
   `staging` onto `main` and re-promote. **Never** force the merge.

   The `--ff-only` discipline is load-bearing: it guarantees `main` and
   `staging` never diverge (`staging` is only ever "`main` plus not-yet-promoted
   commits"), which is what keeps environments from drifting. Do **not** commit
   changes that exist on one branch but cannot fast-forward to the other —
   nothing should be environment-specific in the tree. Per-node differences
   (roles, reconcile cadence) belong in `host_vars`, which stays identical
   across branches.

## Before you open a PR

Run the fast suite locally (matches the CI `validate` job):

```sh
tests/run.sh
```

For changes touching the `reconciler` role, systemd units, or bootstrap, also
run the real convergence test (matches the CI `converge` job):

```sh
tests/incus/colima-up.sh   # macOS: Incus alongside Docker (first time only)
tests/incus/run.sh
```

## Adding a new service role

Roles are the differentiation layer — a node selects them via `node_roles`. To
add one:

1. **Scaffold** `roles/<name>/` with `tasks/main.yml`, `defaults/main.yml`, and
   `handlers/main.yml` as needed. Put every tunable in `defaults/` (role vars) so
   a node can override it in `host_vars`; never hard-code environment specifics.
2. **Wire it in** by adding `<name>` to `node_roles` in the relevant
   `host_vars/<hostname>.yml`. `local.yml` applies it on top of the base
   substrate automatically — nothing else selects roles.
3. **Guard systemd-dependent tasks** with `when: ansible_service_mgr ==
   'systemd'` so the unprivileged check-mode converge (CI `validate`) stays
   green in a plain container while still running normally on a real node.
4. **Keep secrets out of git.** Read secret material from a node-local file under
   `{{ substrate_secrets_dir }}`; if it is absent, skip the dependent tasks with
   a loud `debug` warning rather than failing the converge (see `cert_issuer` /
   `cert_client` for the pattern).
5. **Add a verify step.** Extend `tests/incus/converge.yml` / `verify.yml` (the
   real-convergence harness) to assert the role's units/files land and are
   active, mirroring how the reconciler is verified.
6. **Label the PR `needs-converge`** — adding a role touches `roles/`, so real
   convergence should run before merge.

## Conventions

- Keep changes idempotent and safe to apply repeatedly. Prefer modules with
  proper `state:` semantics over `command`/`shell`.
- Git messages: no references to tooling assistants and no emojis.
