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

## Backup and disaster recovery

### What state is irreplaceable

Git is the control plane. Everything defined there reconverges automatically on
a new or repaired node. The only irreplaceable runtime state is:

| Item | Location on node | Why it cannot be regenerated |
|------|-----------------|------------------------------|
| headscale `db.sqlite` | `/var/lib/headscale/db.sqlite` | Contains all enrolled peer node keys, ACLs, preauth keys, and user records. Losing it means peers must re-enrol. |
| headscale `noise_private.key` | `/var/lib/headscale/noise_private.key` | The Noise protocol keypair for the control channel. Replacing it disconnects every enrolled client until they reconnect to the new key. |
| each node's age private key | `/etc/substrate/age.key` | The node's secret-decryption root of trust for SOPS. Loss means the node can no longer decrypt any committed secret. |

Everything else (configuration files, TLS certs, installed packages, systemd
units) is in git and reconverges on the next `ansible-pull`. Seeded node-local
secrets under `/etc/substrate/secrets/` are lost with the node and must be
re-seeded (see *Node age-key loss* below).

### Automated local snapshots

`roles/headscale` installs a systemd timer (`headscale-backup.timer`, default:
daily) that runs `/usr/local/sbin/headscale-backup.sh`. Each run creates a
timestamped snapshot directory under `/var/lib/headscale/backups/` containing
`db.sqlite` and `noise_private.key` (both mode `0600`, directory mode `0700`).
The script retains the last `headscale_backup_retain` snapshots (default 7)
and removes older ones.

Check timer status and review recent runs:

```sh
# on the core node
systemctl status headscale-backup.timer
journalctl -u headscale-backup.service -n 20
ls -lt /var/lib/headscale/backups/
```

### Pulling backups off the core node

Snapshots live only on the node until you pull them. Do this regularly (at
minimum weekly; daily before any risky change). Pull over the tailnet with scp
or rsync — the tailnet address or MagicDNS name works from any enrolled peer:

```sh
# pull all snapshots to a local archive directory
rsync -avz --rsync-path='sudo rsync' \
  root@core.net.sbkt.co:/var/lib/headscale/backups/ \
  ~/substrate-backups/headscale/

# or pull a single snapshot by name
scp -r root@core.net.sbkt.co:/var/lib/headscale/backups/20260101T020000Z \
  ~/substrate-backups/headscale/
```

S3 push automation (to the versitygw bucket) is planned but not yet built. Until
then, operator-pulled copies are the off-node record. Keep at least one copy that
post-dates every enrolled peer (so the DB contains all active node keys).

### Core-node replacement procedure

Use this when the core node is lost or must be replaced with a fresh server.

1. **Bootstrap the new node** with `bootstrap.sh` as in workflow 2, giving it the
   `core` role in `host_vars`. Do NOT start headscale yet — the first converge
   will install and enable it, so stop it immediately after:

   ```sh
   # on the new node, after first ansible-pull completes
   systemctl stop headscale
   ```

2. **Restore `db.sqlite` and `noise_private.key`** from the most recent snapshot
   before headscale starts:

   ```sh
   # from the operator workstation, push the snapshot
   scp ~/substrate-backups/headscale/20260101T020000Z/db.sqlite \
     root@<new-node>:/var/lib/headscale/db.sqlite
   scp ~/substrate-backups/headscale/20260101T020000Z/noise_private.key \
     root@<new-node>:/var/lib/headscale/noise_private.key

   # fix ownership and permissions on the new node
   chown root:root /var/lib/headscale/db.sqlite /var/lib/headscale/noise_private.key
   chmod 0600 /var/lib/headscale/db.sqlite /var/lib/headscale/noise_private.key
   ```

3. **Start headscale** and verify it comes up cleanly:

   ```sh
   systemctl start headscale
   systemctl status headscale
   journalctl -u headscale -n 30
   ```

4. **Enrolled peers reconnect automatically** — their node keys are in the
   restored DB and the restored noise key is the same one they enrolled with, so
   clients re-establish the control channel without re-enrolment. Peers tracking
   `OnUnitInactiveSec` timers reconnect within their next poll interval (usually
   minutes).

5. **Re-register the new node's age key.** The new node generated a fresh age key
   at bootstrap (`/etc/substrate/age.key`). Register its public key so it can
   receive SOPS-encrypted secrets:

   ```sh
   # read the new node's public key (on the node, or via incus exec)
   cat /etc/substrate/age.key | grep -A1 'public key' || \
     age-keygen -y /etc/substrate/age.key

   # register it and re-encrypt all secrets it needs to receive
   scripts/secret.sh register-node <age1pubkey> --groups dns_nodes,tailnet_nodes,...
   # then re-encrypt each affected secret with the new recipient set:
   task secret:set NAME=<name>
   ```

   Until this step completes, the new core node cannot decrypt any committed
   SOPS secret; roles that need them will skip loudly (expected behaviour — not
   a fleet-stopping failure).

### Node age-key loss

**Consequence:** the node can no longer decrypt any SOPS secret it was a
recipient of. Roles that consume those secrets will skip loudly on every
converge until the secret is re-delivered. The node is otherwise healthy — git
reconverges everything else normally.

**Recovery:**

1. The node regenerates an age key at bootstrap, or you can generate one in
   place:

   ```sh
   age-keygen -o /etc/substrate/age.key
   chmod 0600 /etc/substrate/age.key
   ```

2. Register the new public key and re-encrypt all secrets the node needs:

   ```sh
   # on the operator workstation
   scripts/secret.sh register-node <age1pubkey> --groups <group1>[,<group2>]
   task secret:set NAME=<secret-name>   # repeat for each secret
   ```

   The full command reference and group names are in
   [secrets.md](secrets.md) (see *Under the hood*).

3. Force an immediate reconcile so the node picks up the re-encrypted values:

   ```sh
   systemctl start substrate-reconcile.service
   ```

4. Seeded node-local secrets under `/etc/substrate/secrets/` (bootstrap env vars
   or hand-seeded values that were never committed as SOPS ciphertext) are lost
   with the old key and must be re-seeded:

   ```sh
   task secret:seed -- <target> <secret-name>
   ```

### Break-glass: when the tailnet itself is down

If headscale is unreachable or the tailnet is fully down, enrolled peers lose
their overlay connectivity. Access is then limited to whatever the cloud
provider offers:

- **Provider console / serial console** — available even without network, use it
  to log in and diagnose headscale.
- **Provider SSH (public network)** — if the node has a public IP and SSH open
  on the host network, that path remains available independent of tailscale.
- **Local node reconcile** — `systemctl start substrate-reconcile.service` forces
  a converge from git without needing tailnet connectivity (ansible-pull uses
  HTTPS to GitHub).

Current limitation: there is no automated alerting when headscale goes down. The
timer at `headscale-backup.timer` will fail silently if headscale has not yet
started. Monitor via `systemctl status headscale` and journal logs. A monitoring
story is a known gap.

---

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
