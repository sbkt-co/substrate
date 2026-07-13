# Runbook — how to actually use this

## The launcher

Run **`./substrate`** for a menu of everything below, or **`task --list`** for
the flat list. Every workflow in this runbook is also a task name, so you never
have to remember a command — pick it from the menu, or run `task <name>`
(`task --summary <name>` explains any task before you run it):

| Runbook step | Task |
|---|---|
| validate before a PR | `task check:validate` |
| real converge test | `task check:converge` |
| open a PR into staging | `task ship:pr` |
| preview promotion staging→main | `task ship:promote-dry` |
| promote staging→main | `task ship:promote` |
| add a machine | `task node:add NAME=<hostname>` |
| check a node (status/timer) | `task node:status NODE=<name>` |
| sweep the whole fleet's status | `task fleet:status` |
| seed or rotate a secret | `task secret:seed -- <target> <name>` |
| bring up the staging fleet | `task staging:up` |
| staging fleet health | `task staging:status` |
| watch a node reconcile | `task staging:logs NODE=<name>` |
| shell into a staging node | `task staging:shell NODE=<name>` |
| scaffold a new role | `task role:new NAME=<role>` |
| audit local tooling | `task check:doctor` |

The launcher is a thin menu over the same registry (`Taskfile.yml`) — it only
ever runs `task <name>`, so the menu and the CLI can never drift apart.

New here? The **Learn** area (top of the menu) renders short, self-contained
lessons — no reading required first:

| Lesson | Task |
|---|---|
| you edit git; machines watch git (the pull loop) | `task learn:model` |
| a node's life: boot → bootstrap → converge → reconcile | `task learn:flow` |
| the layers: physical / tailnet / naming / TLS / control | `task learn:topology` |
| node-local secrets and the skip-loudly contract | `task learn:secrets` |
| the two staging containers as the integration test | `task learn:staging` |

Each ends with a pointer to the deeper doc (open it with `task docs:open FILE=<name>`).

## Reproducible setup

Two ways to get a working operator environment, both reproducible from this repo.

**Host-native (primary, macOS).** One command installs the whole toolchain from the
committed `Brewfile` and audits the result:

```sh
task setup:host        # macOS: brew bundle (go-task, gum, sops, age, uv, gh,
                       #        colima, incus, shellcheck), then check:doctor
```

This is the primary path on macOS because the `./substrate` TUI needs a real native
TTY and the staging fleet talks to the Colima-hosted Incus socket — a container
reaches neither cleanly. On Linux there is no Homebrew, so `setup:host` prints the
apt/equivalent install hints and then runs `check:doctor`.

**Toolbox container (portable fallback).** For a host without Homebrew, or CI-style
lint/PR work, build and enter the pinned operator image:

```sh
task toolbox:build     # docker build -f toolbox/Dockerfile -t substrate-toolbox .
task toolbox:shell     # mounts the tree at /substrate (+ gh/git config, read-only),
                       # lands in the ./substrate menu
```

Inside the toolbox you **can**: lint (`ansible-lint`/`yamllint`/`--syntax-check`),
run `task <name>` and the TUI, encrypt with `sops`+`age`, open PRs with `gh`, and use
git. You **cannot** run `check:validate` (needs the host Docker daemon) or
`check:converge`/`staging:*` (need the host's Incus) — those tasks detect the
container via the `SUBSTRATE_TOOLBOX=1` marker and tell you to run them on the host.
Override the menu with a plain shell: `docker run -it --rm -v "$PWD":/substrate substrate-toolbox bash`.

## The one-sentence mental model

**You edit git; the machines watch git.**
If a "how do I configure X" question has an answer that is not "commit a
file", something is wrong.

There are only three workflows.

## 1. Change anything (config, roles, schedules — 95% of usage)

```sh
git switch -c my-change staging   # branch from staging, not main
# edit files
tests/run.sh                      # same checks CI runs; must exit 0
git commit -am "..." && git push
gh pr create --base staging       # merge when CI is green
```

Then do nothing. Every node tracking `staging` pulls and applies the
change within its reconcile interval (staging nodes: 5 min). Watch it
land:

```sh
incus exec staging-core --project substrate-staging -- \
  journalctl -u substrate-reconcile.service -n 30
```

When staging has soaked long enough, promote everything to production
with one fast-forward (never a merge commit — see CONTRIBUTING.md):

```sh
git fetch origin && git push origin origin/staging:main
```

You never SSH in to deploy. Merging is deploying. To undo a bad change,
`git revert` it on `staging` via PR — nodes converge back automatically.

## 2. Add a machine

Rent the server, then paste this as cloud-init user-data (or run once
as root):

```sh
export SUBSTRATE_BRANCH=staging          # or main for production
export SUBSTRATE_TAILNET_AUTHKEY=...     # mint: incus exec staging-core --project substrate-staging -- headscale preauthkeys create --user substrate --expiration 1h
curl -fsSL https://raw.githubusercontent.com/sbkt-co/substrate/main/bootstrap/bootstrap.sh | bash
```

Then tell git what the machine is: add `host_vars/<its-hostname>.yml`
with a `node_roles:` list (copy `host_vars/example.yml`) and PR it via
workflow 1. The node picks its roles up on the next pull.

Local staging fleet (already exists; only needed after wiping it):

```sh
tests/incus/colima-up.sh                          # macOS only, once
SUBSTRATE_INCUS_REMOTE=colima-incus staging/up.sh
```

## 3. Seed or rotate a secret

Secrets are root-only files on the node, never in git. The three files
live in `/etc/substrate/secrets/`. On a real node they're seeded by env
vars at bootstrap (workflow 2). For the full model — which file holds
what, scopes, and rotation — see [secrets.md](secrets.md). To place one
by hand, e.g. the ACME token on staging-core:

```sh
incus exec staging-core --project substrate-staging -- sh -c \
  'umask 077; printf "dns_cloudflare_api_token = YOUR_TOKEN\n" \
   > /etc/substrate/secrets/cloudflare.ini'
```

The next reconcile picks it up (cert issuance runs against the Let's
Encrypt STAGING endpoint until `substrate_acme_staging: false` in
`group_vars/all.yml` — flip it via workflow 1 once certs look right).

## Alerting and fleet status

Two observability surfaces answer "is the fleet healthy?" without you SSHing in
to watch journals: a **push alert** when a node's converge fails, and a
**pull sweep** you run on demand.

### Failure alerts (push)

Every reconcile that fails triggers `substrate-reconcile-failure.service` (wired
via `OnFailure=` on the reconciler). It runs `substrate-reconcile-alert`, which
POSTs a short report — hostname, timestamp, the tail of the
`substrate-reconcile.service` journal, and the node's `status.yml` — to a
node-local webhook.

The webhook URL is a node-local secret at `/etc/substrate/secrets/alert-webhook`
(a single line: the URL — e.g. an ntfy.sh topic URL, or any generic webhook).
It follows the standard secret convention (root-only, `0600`, never in git) and
is seeded out of band like any other node-local secret:

```sh
# On a real node (drop the incus prefix; write the file directly, umask 077):
printf '%s' 'https://ntfy.sh/my-substrate-alerts' \
  > /etc/substrate/secrets/alert-webhook && chmod 0600 /etc/substrate/secrets/alert-webhook

# On a staging Incus node, via the seed-secret path (value via stdin only):
printf '%s' 'https://ntfy.sh/my-substrate-alerts' | \
  incus exec staging-core --project substrate-staging -- sh -c \
    'umask 077; cat > /etc/substrate/secrets/alert-webhook'
```

**Skip-loudly, never-fail:** if the webhook file is absent (or empty), the alert
script logs a clear line to the journal and exits 0 — a node that opts out of
alerting is a valid state, not an error. If the webhook is configured but the
POST fails (endpoint down), it logs a WARNING and still exits 0: an alerting
failure must never cascade back into the node. Opting out is simply not seeding
the file.

### Fleet status (pull)

```sh
task fleet:status        # scripts/fleet-status.sh
```

Sweeps **every** node in the roster (`host_vars/<hostname>.yml`, one file per
node — `*.example.yml` templates are skipped) over a plain `ssh <host>`; the
fleet is tailnet-reachable by hostname via MagicDNS, so no address inventory is
needed. For each node it prints `/etc/substrate/status.yml` and the
`substrate-reconcile.timer` state. It only reads — it changes nothing. An
unreachable node prints a clear `unreachable` line and the sweep continues; one
dead node never aborts the loop. Tune ssh via `SSH_OPTS`, e.g.
`SSH_OPTS='-o ConnectTimeout=2 -l root' task fleet:status`.

**A healthy node** shows a recent `status.yml` with `result: success`, a matching
`last_run`/`exit_status: 0`, and its timer `active`:

```
=== web-1 ===
-- /etc/substrate/status.yml --
last_run: 2026-07-13T09:12:04Z
result: success
exit_status: 0
-- substrate-reconcile.timer --
active
```

**A failing node** shows a non-`success` result (or a stale `last_run`), and —
if you seeded a webhook — you already got a push alert for it. `unreachable`
means ssh could not connect (node down, not on the tailnet, or no access), which
is itself a signal worth chasing. Drill into the offender with
`task node:status NODE=<name>` (staging) or `ssh <node> journalctl -u substrate-reconcile.service -n 50`.

## When something seems wrong

```sh
# Is the node reconciling? When did it last succeed?
incus exec staging-core --project substrate-staging -- cat /etc/substrate/status.yml
incus exec staging-core --project substrate-staging -- systemctl status substrate-reconcile.timer

# What happened on the last run?
incus exec staging-core --project substrate-staging -- journalctl -u substrate-reconcile.service -n 50

# Is the tailnet up? Does MagicDNS resolve?
incus exec staging-web1 --project substrate-staging -- tailscale status
incus exec staging-web1 --project substrate-staging -- getent hosts staging-core.net.sbkt.co
```

(On a real node, drop the `incus exec ... --` prefix and run the same
commands over SSH.)

## Cheat sheet

| I want to… | Do |
|---|---|
| change anything | branch off `staging` → PR → merge → wait 5 min |
| ship staging to prod | `git push origin origin/staging:main` (ff-only) |
| add a server | bootstrap.sh with `SUBSTRATE_BRANCH` + authkey, PR its `host_vars` file |
| undo a change | `git revert` on `staging` via PR |
| check a node | `cat /etc/substrate/status.yml` on the node |
| validate before PR | `tests/run.sh` |
| real converge test | `tests/incus/run.sh` |
