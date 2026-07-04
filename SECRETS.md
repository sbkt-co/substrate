# Secrets management

This document is the definitive direction for how secret material is stored,
seeded, consumed, rotated, and (eventually) sourced from a real secret manager
in substrate. It reflects the mechanism the code already implements — it does
not propose anything the roles do not read today.

## Principle: the repo holds the spec, never the values

The control plane is GitHub, and no workstation is authoritative (see
`CLAUDE.md` → *Architecture — GitHub as the control plane*). The same
constraint governs secrets:

- **The repo specifies where a secret lives and which role reads it — never the
  value.** `group_vars/all.yml` sets `substrate_secrets_dir:
  /etc/substrate/secrets`; each role points at a file under it. Grep the repo
  for a token and you will find a *path*, never a credential.
- **No SOPS, no `age`, no `ansible-vault` with a key on an operator laptop.**
  Any scheme that makes a specific workstation necessary to decrypt-and-converge
  is excluded by design — it would reintroduce a local control plane.
- **Skip-loudly contract.** A role that needs a missing secret does not fail the
  converge. It `stat`s the file, and if absent emits a `WARNING` debug and skips
  the credential-consuming tasks. A node with no Cloudflare token still
  converges everything else; only the DNS/cert work is deferred until the file
  appears. This keeps one missing credential from wedging the whole fleet.

## Mechanism: node-local files under `/etc/substrate/secrets`

Secrets are plain files on the node. The directory is `0700` (root only); every
secret file is `0600`. There are three today:

| File | Format | Seeded from env | Consumed by | Scope |
|------|--------|-----------------|-------------|-------|
| `tailnet-authkey` | raw preauth key, one line | `SUBSTRATE_TAILNET_AUTHKEY` | `roles/tailnet` | single-use headscale enrolment key |
| `cloudflare-dns.ini` | `CLOUDFLARE_API_TOKEN=<value>` | `SUBSTRATE_CLOUDFLARE_TOKEN` | `roles/dns` | Cloudflare **DNS:Edit** on the `sbkt.co` zone |
| `cloudflare.ini` | `dns_cloudflare_api_token = <value>` | `SUBSTRATE_ACME_TOKEN` | `roles/cert_issuer` (certbot) | Cloudflare **TXT-only** for ACME DNS-01 |

Notes on the formats — they are not interchangeable:

- `cloudflare-dns.ini` uses `KEY=VALUE` with no spaces; `roles/dns` parses it
  with `.split('=', 1)[1]`.
- `cloudflare.ini` uses the certbot ini form `key = value` (spaces around `=`)
  and is passed verbatim to `certbot --dns-cloudflare-credentials`.

Every consuming task that touches secret content runs with `no_log: true`.

## Seeding

Two supported paths, both keeping the value off disk-in-git and out of logs:

1. **Bootstrap env vars (`bootstrap/bootstrap.sh`).** On a fresh node the three
   `SUBSTRATE_*` variables above seed the matching files. The script writes
   under `umask 077`, `chmod 0600`, and **logs only the filename, never the
   value** — cloud-init logs are world-readable. An absent variable leaves the
   file uncreated (skip-loudly then applies).

2. **By hand / out-of-band.** Write the file directly on the node and the next
   reconcile picks it up. Staging does exactly this: `staging/up.sh` mints a
   single-use headscale preauth key and `incus file push`es it to
   `tailnet-authkey` (mode `0600`) — never via stdout or a logged command.

Because roles re-read the file on every converge, seeding and rotation are the
same operation: change the file, wait for the next reconcile.

## Scoping and blast radius

Least privilege is enforced by using narrow, per-purpose credentials:

- **Two Cloudflare tokens, deliberately.** The DNS-reconcile role gets a
  DNS:Edit token; certbot gets a TXT-only token. A leak of the ACME token cannot
  rewrite arbitrary records; a leak of the DNS token cannot be reused as a
  general Cloudflare credential. Do not collapse them into one token.
- **Single-use preauth keys.** A `tailnet-authkey` enrols the node once; after
  `tailscale up` the backend reports `Running` and `roles/tailnet` skips
  re-enrolment. Mint keys single-use and short-lived so a stolen key is a spent
  key.

What a compromised node yields, honestly:

- Its own tailnet identity and whatever the tailnet ACLs let that node reach.
- If it holds `cloudflare-dns.ini` / `cloudflare.ini`: the ability to edit the
  public `sbkt.co` zone / mint ACME challenges until the token is revoked.
- **The wildcard tradeoff.** TLS is one wildcard cert `*.net.sbkt.co` issued on
  the cert-issuer node and distributed over the tailnet to every `cert_client`
  node (`/etc/substrate/certs/privkey.pem`). That means **every cert_client node
  holds the wildcard private key.** Compromise of any one node exposes the key
  for the whole internal domain. This is an accepted simplicity tradeoff for a
  single-digit fleet on a private tailnet (the cert is never public-facing and
  `net.sbkt.co` is not in public DNS or CT logs). If node count or trust
  boundaries grow, move to per-node certs (issue a `<host>.net.sbkt.co` cert per
  node) so no node holds a domain-wide key.

## Rotation

Rotation is "overwrite the file; next reconcile applies it." Concrete commands
(run as root on the node, or via `incus exec` for staging containers):

```sh
# Cloudflare DNS-edit token (roles/dns)
umask 077
printf 'CLOUDFLARE_API_TOKEN=%s\n' "$NEW_TOKEN" > /etc/substrate/secrets/cloudflare-dns.ini
chmod 0600 /etc/substrate/secrets/cloudflare-dns.ini

# Cloudflare ACME TXT token (roles/cert_issuer / certbot)
umask 077
printf 'dns_cloudflare_api_token = %s\n' "$NEW_TOKEN" > /etc/substrate/secrets/cloudflare.ini
chmod 0600 /etc/substrate/secrets/cloudflare.ini

# Tailnet preauth key — only meaningful for a node NOT yet enrolled.
# An already-Running node ignores a new key; to re-enrol, `tailscale logout`
# (or remove the node in headscale) first, then seed a fresh single-use key.
umask 077
printf '%s\n' "$NEW_AUTHKEY" > /etc/substrate/secrets/tailnet-authkey
chmod 0600 /etc/substrate/secrets/tailnet-authkey
```

After rewriting a token, **revoke the old one at Cloudflare** — writing the new
file does not invalidate the previous credential. Force an immediate converge
instead of waiting for the timer with:

```sh
systemctl start substrate-reconcile.service
```

There is no fleet-wide rotation primitive yet; rotate node-by-node.

## What NOT to do

- **Never commit a secret value** to any branch, in any file — not
  `host_vars`, not `group_vars`, not a role default. The repo holds paths only.
- **Do not share one token across purposes.** Keep DNS:Edit and ACME TXT-only
  separate; that separation is the blast-radius control.
- **Do not reuse preauth keys** or mint long-lived/reusable ones. Single-use,
  short-TTL only.
- **Do not put secrets in cloud-init user-data casually.** Provider metadata and
  the serial console can expose user-data; it is acceptable only for
  single-use / narrowly-scoped material (a one-shot preauth key, a scoped
  token you will rotate), never for long-lived broad credentials.
- **Do not introduce SOPS/`age`/`ansible-vault`** decrypted by a workstation
  key, or any operator-laptop `ansible-playbook` push that delivers secrets.
  That breaks the no-local-control-plane invariant.

## Graduation path

The roles' contract is "read a file at a known path." Only the **seeding** step
changes as the fleet or team grows — no role edits required.

- **Today:** env-var seeding at bootstrap + occasional manual/`incus file push`
  rotation. Adequate for a single-digit fleet with one operator.
- **Next:** a node-reachable secret manager the node itself queries at bootstrap
  and on rotation. OVHCloud (the current provider) has no first-class secret
  manager, so the realistic options are (a) a self-hosted **OpenBao/Vault** on
  the tailnet with node identity auth, or (b) an external secret manager reached
  over the network. Either way the delivery mechanism writes the same files
  under `/etc/substrate/secrets` and the roles are unchanged.
- **Whatever the source, the invariant holds:** the node fetches its own
  secrets from something it can reach with the laptop turned off. No commit-time
  decryption, no workstation key, no push from an operator machine.
