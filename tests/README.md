# Testing the substrate control plane

The validation suite is containerized so a laptop and a CI runner execute the
exact same checks against the exact same toolchain (pinned in
`tests/requirements.txt`).

## Run it

```sh
tests/run.sh                       # build image + run full suite on the working tree
tests/run.sh ansible-lint roles/   # ad-hoc command inside the toolchain
```

In CI the same image and entrypoint run via `.github/workflows/ci.yml`.

## What the default suite covers

1. **yamllint** — YAML hygiene across the repo.
2. **ansible-lint** (moderate profile) — FQCN modules, task naming, idempotent
   patterns, safe file modes.
3. **`--syntax-check`** of `local.yml`.
4. **Check-mode converge** of `local.yml` against the container itself
   (`--connection=local --check`) — exercises fact gathering, var resolution,
   role wiring, and predicts every change without mutating anything.

This needs no privileges, which is why it runs cleanly on a stock GitHub
Actions runner.

The check-mode converge stops at the `systemd` boundary: the reconciler's
`systemctl`-dependent tasks are guarded with `when: ansible_service_mgr ==
'systemd'`, so in a plain container they skip. To prove they actually work, use
the Incus harness below.

## Real convergence — Incus system container

`tests/incus/` runs the playbook for real against a **Debian trixie Incus
system container** (systemd as PID 1 — a faithful stand-in for a node).
Ansible reaches it over the `community.general.incus` connection (`incus exec`,
no SSH).

```sh
tests/incus/run.sh
```

It launches the container, converges, then asserts:

1. **Idempotence** — a second converge reports `changed=0`.
2. **Drift repair** — it deletes the timer unit and `/etc/substrate/node.yml`,
   re-converges, and confirms both are restored (the reconciler's whole reason
   to exist).
3. **Liveness** — `tests/incus/verify.yml` asserts the unit files exist and the
   timer is `active`.

### Addressing the right container on a busy host

A host may run many unrelated Incus instances, so the harness never relies on a
bare instance name. It is isolated and addressed three ways:

- **Dedicated project.** Everything runs in its own Incus project
  (`SUBSTRATE_INCUS_PROJECT`, default `substrate-test`), never the shared
  `default` project. The script refuses to run if pointed at `default`.
- **Full address.** Both the CLI calls and the Ansible connection target
  `<remote>:<instance>` *within* that project (`ansible_incus_remote` +
  `ansible_incus_project` + `ansible_incus_host`), so the node is unambiguous
  regardless of same-named instances elsewhere.
- **Managed label.** The instance is created with `user.substrate-managed=true`
  and the harness only ever `--force` deletes an instance carrying that label —
  it cannot remove something it did not create, even inside its own project. The
  project is dropped on exit only if empty.

(In production this problem does not arise: each node converges only *itself*
over a local connection — there is no central selection of "which node".)

### macOS (Colima) — Incus alongside Docker

On macOS, run Incus in its own Colima profile next to the default Docker
profile (they coexist; `docker` and `incus` both work):

```sh
brew install colima incus uv
tests/incus/colima-up.sh          # starts the `incus` colima profile (--runtime incus)
```

`run.sh` auto-detects the active incus remote (`colima-incus` on macOS, `local`
on a Linux host), so the same script works on both. Stop it later with
`colima stop incus` — the Docker profile is unaffected.

Colima only hosts the Incus daemon on macOS dev machines; Linux hosts (including
the self-hosted CI runner) run Incus natively; production nodes have neither
Colima nor Docker.

### Controller prerequisites

`ansible-core` + the `community.general` collection (for the incus connection):

```sh
uv tool install ansible-core==2.18.6
ansible-galaxy collection install -r requirements.yml
```

In CI this is the `converge` job in `.github/workflows/ci.yml`, which installs
Incus on the runner, sets up the toolchain with `uv`, and runs the same script.

`converge.yml` mirrors `local.yml`'s bootstrap→differentiate shape but targets
the container over the incus connection (`local.yml` is pinned to
localhost/local for the real `ansible-pull` path).
