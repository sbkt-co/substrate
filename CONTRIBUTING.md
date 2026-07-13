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
   convergence + idempotence) is expensive and therefore **gated**, but on PRs it
   is now **auto-triggered by the diff**: a cheap `changes` job runs a path
   filter, and if your PR touches any reconciler-relevant path (`roles/`,
   `local.yml`, `ansible.cfg`, `group_vars/`, `host_vars/`, `bootstrap/`,
   `requirements.yml`, `tests/incus/`, `staging/`, the CI workflow) the `converge`
   job **is required to run** — you no longer need a label for it. A docs-only or
   otherwise unrelated PR skips converge automatically.

   The `needs-converge` label is now only a **manual override**: use it to force
   converge on a PR the path filter would not catch. `converge` also runs on
   pushes to `main`/`staging` that touch those paths and on manual
   `workflow_dispatch`. See "Branch protection (required settings)" below for the
   status checks to require.

   > **Self-hosted runner trust.** The `converge` job runs on a **self-hosted**
   > Incus runner and executes the PR's checked-out code as part of the test.
   > Because the path filter now auto-triggers converge, a PR touching reconciler
   > paths runs on that host **by default, without a label**. That is safe for
   > trusted contributors but is a live risk for fork / outside-collaborator PRs.
   > The repository **must** be configured to *"Require approval for all outside
   > collaborators"* (Settings → Actions → General → Fork pull request workflows)
   > so untrusted PRs cannot run self-hosted jobs without a maintainer clicking
   > approve. This is a **maintainer responsibility** — it cannot be enforced by
   > the workflow file alone.
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
6. **Converge runs automatically** — adding a role touches `roles/`, so the path
   filter triggers the `converge` job on your PR (no label needed). Only reach for
   the `needs-converge` label if you need to force it on a PR the filter misses.

## Branch protection (required settings)

Both `main` and `staging` must be protected. These settings could not be applied
automatically (the CI/contributor token lacks repo-admin), so a **maintainer with
admin** must apply them. Run the following once per branch (they are idempotent):

```sh
for b in main staging; do
  gh api -X PUT "repos/sbkt-co/substrate/branches/$b/protection" --input - <<'JSON'
{
  "required_status_checks": {
    "strict": true,
    "checks": [
      { "context": "validate" },
      { "context": "changes" }
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "require_code_owner_reviews": true,
    "required_approving_review_count": 1
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_linear_history": true
}
JSON
done
```

Notes:

- **Required checks are `validate` and `changes` only, not `converge`.** The
  `converge` job is *conditionally skipped* on docs-only PRs (the path filter
  produces no reason to run it). A skipped job never reports the context, so
  requiring `converge` as a status check would **deadlock every docs-only PR**
  (it would wait forever for a check that never runs). Requiring `changes`
  instead guarantees the path filter itself always executes; when the filter
  says converge is needed, `converge` runs and — being a `needs: changes`
  dependant that GitHub surfaces as a required-by-dependency check on the merge —
  must pass. `required_linear_history` enforces the `--ff-only` promotion rule.
- **`require_code_owner_reviews` pairs with [`.github/CODEOWNERS`](CODEOWNERS)**
  (`* @sbkt-co`), so every PR needs owner approval — appropriate given a merge is
  unattended root on the whole fleet.
- Also enable, in **Settings → Actions → General → Fork pull request workflows**,
  *"Require approval for all outside collaborators"* — see the self-hosted runner
  trust note above. This is not expressible via the branch-protection API.

## Conventions

- Keep changes idempotent and safe to apply repeatedly. Prefer modules with
  proper `state:` semantics over `command`/`shell`.
- Git messages: no references to tooling assistants and no emojis.
