---
name: add-node
description: Onboard a new fleet node — print its bootstrap snippet and create its host_vars file. Use when adding a server/machine/node to substrate.
---

# Add a node

A new node needs two things: a bootstrap seed (environment + optional secrets)
and a `host_vars/<hostname>.yml` that declares its `node_roles`. The script
produces both. The tracked branch is seeded at bootstrap, never in host_vars.

Steps:

1. Run the script (default branch is `staging`; pass `--branch main` for prod):

   ```sh
   scripts/add-node.sh <hostname> [--branch staging|main]
   ```

   It prints the exact cloud-init / run-once-as-root bootstrap snippet (with the
   `SUBSTRATE_BRANCH` seed and the optional `SUBSTRATE_*` secret-seed env vars),
   and creates `host_vars/<hostname>.yml` from `host_vars/example.yml` if absent.

2. Review the generated `host_vars/<hostname>.yml` and set `node_roles` (plus any
   required overrides such as `cert_client_issuer_host` or
   `substrate_headscale_url`).

3. PR it via the runbook flow (branch off `staging` -> `tests/run.sh` -> PR).

Give the user the bootstrap snippet to paste on the fresh node. See
docs/runbook.md workflow 2, and docs/secrets.md for the seeding caveats (only single-use /
scoped tokens belong in cloud-init user-data).
