# Contributing

This repository is the **control plane**: whatever is committed to a tracked
branch is the specification that nodes converge themselves to. Treat changes
accordingly — a merge to `main` changes production.

## Environments are branches

- **`main`** = production. Most nodes track it.
- **`staging`** = pre-production. A small set of nodes track it for real-world
  soak before changes reach prod.

A node's environment is seeded once at bootstrap (`/etc/substrate/branch`), not
configured in `host_vars`. See `CLAUDE.md` → *Branching & promotion* for why.

## The rules

1. **PRs only.** Never commit directly to `main` or `staging`. Open a PR from a
   short-lived feature branch.
2. **CI must pass.** Both the `validate` (lint + syntax + check-mode converge)
   and `converge` (real Incus convergence + idempotence) jobs must be green
   before merge. Configure branch protection to require them.
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

## Conventions

- Keep changes idempotent and safe to apply repeatedly. Prefer modules with
  proper `state:` semantics over `command`/`shell`.
- Git messages: no references to tooling assistants and no emojis.
