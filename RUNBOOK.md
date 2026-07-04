# Runbook — how to actually use this

The one-sentence mental model: **you edit git; the machines watch git.**
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
what, scopes, and rotation — see [SECRETS.md](SECRETS.md). To place one
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
