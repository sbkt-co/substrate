# Secrets management

This document is the definitive direction for how secret material is stored,
distributed, seeded, consumed, and rotated in substrate. It reflects the
mechanism the code implements — it does not propose anything the roles do not
read today.

## Principle: the repo holds the spec, and only revocable ciphertext

The control plane is GitHub, and no workstation is authoritative (see
`CLAUDE.md` → *Architecture — GitHub as the control plane*). The same
constraint governs secrets:

- **The repo specifies where a secret lives and which role reads it.** Roles read
  plain files under `/etc/substrate/secrets`; grep the repo for a token and you
  find a *path*, never a plaintext credential.
- **Secret VALUES enter git only as SOPS ciphertext encrypted to NODE-held age
  keys.** Each node holds its own age private key (`/etc/substrate/secrets/age.key`,
  generated at bootstrap, never leaving the node). A committed
  `secrets/<name>.sops.yaml` is encrypted to the *public* keys of the nodes that
  are recipients; only those nodes can decrypt it, and they do so *themselves* on
  every converge. The laptop is never in the decrypt loop.
- **No workstation-held decryption key.** SOPS/`age`/`ansible-vault` decrypted by
  a key on an operator laptop is excluded by design — it would reintroduce a local
  control plane. Node-held keys are the sanctioned mechanism precisely because the
  fleet decrypts with the laptop turned off. (See *The SOPS carve-out* below.)
- **Skip-loudly contract.** A role (or the decrypt step) that needs a missing or
  undecryptable secret does not fail the converge. It emits a `WARNING` debug and
  skips, so one missing credential never wedges the fleet. Recipients are
  per-purpose, so "this node cannot decrypt that file" is an EXPECTED state.

## The one command: `task secret:set`

Day to day, secrets are **one command**. You do not need to know about age keys,
`.sops.yaml`, recipient groups, or `register-node` — `secret:set` does all of it.

```sh
task secret:set NAME=acme          # or: scripts/secret.sh set acme
```

That is the whole mental model: **run it, answer the hidden prompt, approve the
PR.** In order, `set`:

1. resolves the name to the role that reads it and finds which nodes run that
   role (from `host_vars` `node_roles`) — it prints the recipients it found;
2. fetches each node's age **public** key and registers it (idempotent — says
   "already registered" when nothing changes);
3. reads the VALUE from a **hidden** prompt (with a confirm re-entry), or from
   stdin if you pipe one in — never echoed, never in `argv`;
4. encrypts it to `secrets/<name>.sops.yaml`;
5. commits, pushes a `secret-set-<name>` branch, and opens a PR into `staging`.

Merge the PR; the recipient nodes decrypt the value on their next reconcile.
**Rotation is the same command** — run `secret:set` again with the new value,
then revoke the old credential upstream (re-encrypting does not invalidate it).

The three names and what reads them:

| NAME | Role | Recipient nodes come from | Node file the role reads |
|------|------|---------------------------|--------------------------|
| `cloudflare-dns` | `dns` | nodes with `dns` in `node_roles` | `cloudflare-dns.ini` |
| `acme` | `cert_issuer` | nodes with `cert_issuer` in `node_roles` | `cloudflare.ini` |
| `tailnet-authkey` | `tailnet` | nodes with `tailnet` in `node_roles` | `tailnet-authkey` |

Useful flags (pass after `--` from `task`, e.g. `task secret:set NAME=acme -- --dry-run`):

- `--dry-run` — print the full plan (resolved recipients, keys to register, the
  exact git + `gh` commands) and change nothing. Use it to preview.
- `--target <host>[,<host2>]` — name recipient hosts directly, skipping the
  `host_vars` discovery (useful before a node declares the role).
- `--key <age1...>` — supply a pubkey for a host you cannot reach over incus
  (e.g. a real cloud node — paste the pubkey it printed at bootstrap).
- `--yes` — skip the confirmation prompt (automation).

### See the state: `task secret:status`

```sh
task secret:status
```

Read-only. For each secret it shows whether the ciphertext is published, the
recipient hosts (from the role mapping), and — best effort — whether each node
already has the decrypted file. Run it before and after `set` to see what changed.

### When a node has no age key yet

`set` fetches keys over incus for staging nodes. A brand-new node (or a real
cloud node) may not be reachable that way. `set` tells you exactly what to do:
pass its bootstrap-printed pubkey with `--key <age1...>`, or seed the value
node-locally as a stopgap with `task secret:seed` (the FALLBACK — see below).

Everything past this point is **under the hood — you do not need it day to day.**

---

## Under the hood (you do not need this to use `secret:set`)

The remaining sections document the machinery `secret:set` orchestrates:
node-held age keys, the `.sops.yaml` recipient groups, the decrypt loop in
`roles/common`, the manifest, and the manual/fallback paths. Read them when you
are debugging, extending, or auditing the mechanism — not to publish a secret.

## Mechanism

Two cooperating layers. The **roles are unchanged** by any of this — they always
just read a file at a known path.

### 1. SOPS-encrypted secrets in git (PRIMARY)

The committed branch carries secret values as ciphertext, and each node decrypts
what it is a recipient of into the canonical dest files:

```
secrets/<name>.sops.yaml   (git, ciphertext)   -- encrypted to registered node age pubkeys
        |  roles/common, every converge: sops -d with the node's own age.key
        v
/etc/substrate/secrets/<file>   (node, 0600 plaintext)   -- what the role parses
```

- **The manifest** `substrate_sops_secrets` in `group_vars/all.yml` maps each
  ciphertext file to its dest + mode. `roles/common` loops it: for each entry, if
  the node has an age key and is a recipient, it `sops -d`s the file and writes the
  dest with `ansible.builtin.copy content=` (content-idempotent, `no_log: true`).
- **Encrypted file format** is YAML with a single `content: |` block holding the
  exact final file bytes. Decryption extracts `content` and writes it verbatim, so
  the dest is byte-identical to a hand-seeded file (trailing newline included).
- **`.sops.yaml`** at the repo root defines the recipient groups (anchored age
  lists) and a `creation_rule` per file. Manage it only via `scripts/secret.sh`.
- **git is the source of truth:** the decrypt task overwrites the dest. A value
  seeded by hand (or the env fallback) is REPLACED on the next converge *if* a
  sops file exists for it — that is the point.

The three committed secrets and their canonical dests (formats are **not**
interchangeable):

| sops file | Group | Dest file | Format | Consumed by |
|-----------|-------|-----------|--------|-------------|
| `secrets/cloudflare-dns.sops.yaml` | `dns_nodes` | `cloudflare-dns.ini` | `CLOUDFLARE_API_TOKEN=<value>` | `roles/dns` |
| `secrets/acme.sops.yaml` | `acme_nodes` | `cloudflare.ini` | `dns_cloudflare_api_token = <value>` | `roles/cert_issuer` |
| `secrets/tailnet-authkey.sops.yaml` | `tailnet_nodes` | `tailnet-authkey` | raw preauth key, one line | `roles/tailnet` |

`cloudflare-dns.ini` uses `KEY=VALUE` (no spaces; parsed with `.split('=', 1)[1]`);
`cloudflare.ini` uses the certbot ini form `key = value` (spaces) passed verbatim
to certbot. Every task touching secret content runs with `no_log: true`.

### 2. Node-local files (what the roles read; also the fallback surface)

Secrets are plain files on the node: directory `0700` (root only), every file
`0600`. This is the layer roles consume, whether a file arrived by SOPS decrypt,
env-seed at bootstrap, or a manual write.

## Seeding

### Primary: `task secret:set` (the one command above)

The normal path is `task secret:set NAME=<name>` (documented at the top of this
doc). It wraps everything below — registration, encryption, commit and PR — so
you rarely touch the raw steps. The raw steps exist for when you are scripting
the pieces yourself or debugging:

```sh
# What `set` does under the hood, by hand:
# 1. Register a node's PUBLIC age key into the groups matching its roles (once).
scripts/secret.sh register-node <age1pubkey> --groups dns_nodes,tailnet_nodes

# 2. Encrypt the value (stdin only) into secrets/<name>.sops.yaml, then commit+PR.
printf '%s' "$TOKEN" | scripts/secret.sh encrypt cloudflare-dns
```

`encrypt` needs only public keys (no decryption, no node/operator private key). It
refuses if the group has no recipients — a ciphertext with no recipients is
unreadable. The node picks the value up on its next reconcile.

If `register-node` reports an existing secret was "NOT re-keyed" (no current
recipient key on your machine to decrypt-and-re-encrypt it), just re-run
`encrypt <name>` from the source value — that republishes to all recipients using
only public keys, preserving the laptop-off invariant. (`secret:set` does exactly
this automatically — it re-encrypts from the value you supply.)

### Fallback: bootstrap env vars and out-of-band writes

For a node not yet key-registered, or an emergency, seed the node-local file
directly (no git). See the **seed-secret** skill.

1. **Bootstrap env vars (`bootstrap/bootstrap.sh`).** The `SUBSTRATE_*` variables
   seed the matching files under `umask 077`, logging only the filename, never the
   value (cloud-init logs are world-readable). An absent variable leaves the file
   uncreated (skip-loudly then applies). This path remains fully supported.

2. **By hand / `scripts/seed-secret.sh`.** Write the file directly on the node (or
   `incus exec` for staging) and the next reconcile picks it up. Staging's
   `up.sh` does exactly this for the single-use `tailnet-authkey`.

Because roles re-read the file every converge, seeding and rotation are the same
operation: change the source, wait for the next reconcile. Remember a committed
`*.sops.yaml` for the same dest OVERRIDES a hand-seeded value on the next converge.

## The SOPS carve-out (why this does not break the invariants)

`CLAUDE.md` bans "no local control plane." SOPS with **workstation-held keys**
remains **BANNED** — decrypting with a key on an operator laptop would make that
laptop necessary to converge the fleet. What is sanctioned here is different and
narrow:

- **Node-held keys only.** The private key lives on the node and nowhere else. The
  fleet decrypts itself with the laptop off; the workstation only ever *encrypts*
  (public-key operation) to produce ciphertext git carries. This preserves the
  pull model end-to-end.
- **Public-repo ciphertext is forever.** Anything committed, even encrypted, is
  permanently exfiltratable by anyone who ever had read access. Therefore encrypt
  **only revocable material** — scoped/rotatable API tokens and single-use,
  short-TTL preauth keys — never long-lived or irrevocable secrets. The
  wildcard TLS private key is never committed (it is issued on the node and moves
  only over the tailnet).
- **The operator key is OPTIONAL.** `scripts/secret.sh operator-init` mints an
  age key so an operator can read/rotate values from a workstation for
  convenience. The fleet never depends on it; it is not a control-plane key.

## Scoping and blast radius

Least privilege via narrow, per-purpose credentials AND per-purpose recipient
groups — a node is a recipient of only the secrets its roles need.

- **Two Cloudflare tokens, deliberately.** DNS-reconcile gets a DNS:Edit token
  (`dns_nodes`); certbot gets a TXT-only token (`acme_nodes`). Do not collapse
  them into one token or one group.
- **Single-use preauth keys.** A `tailnet-authkey` enrols the node once; mint
  keys single-use and short-lived so a stolen key is a spent key.
- **Recipient scoping.** Because each sops file is encrypted only to its group,
  compromising a node that runs `tailnet` does not expose the Cloudflare tokens —
  it was never a recipient of them.

What a compromised node yields, honestly:

- Its own tailnet identity and whatever the tailnet ACLs let it reach.
- Any secret it is a recipient of, until that credential is revoked upstream.
- **The wildcard tradeoff.** TLS is one wildcard cert `*.net.sbkt.co` distributed
  over the tailnet to every `cert_client` node (`/etc/substrate/certs/privkey.pem`),
  so **every cert_client node holds the wildcard private key.** Compromise of any
  one exposes the key for the whole internal domain. This is an accepted simplicity
  tradeoff for a single-digit fleet on a private tailnet (the cert is never
  public-facing and `net.sbkt.co` is not in public DNS or CT logs). If node count
  or trust boundaries grow, move to per-node certs.

## Rotation

Primary: **run `task secret:set NAME=<name>` again** with the fresh value (it is
the same command for publish and rotate), then **revoke the old credential
upstream** — re-encrypting does not invalidate the previous one. The raw
equivalent is `scripts/secret.sh rotate <name>` (encrypt a fresh value, commit+PR).
Force an immediate converge instead of waiting for the timer:

```sh
systemctl start substrate-reconcile.service
```

Fallback (node-local, no git) — overwrite the file directly; next reconcile
applies it (unless a sops file for the same dest exists, which would override):

```sh
umask 077
printf 'CLOUDFLARE_API_TOKEN=%s\n' "$NEW_TOKEN" > /etc/substrate/secrets/cloudflare-dns.ini
chmod 0600 /etc/substrate/secrets/cloudflare-dns.ini
# certbot ACME token:  dns_cloudflare_api_token = <value>  -> cloudflare.ini
# tailnet preauth key: raw one line                        -> tailnet-authkey
```

To rotate a NODE age key (rare — key compromise): re-bootstrap or regenerate
`age.key` on the node, register the new public key, `encrypt`/re-key the secrets it
needs, and remove the old key from `.sops.yaml`. For the full step-by-step
procedure including consequences and re-seeding node-local secrets, see
[runbook.md — Node age-key loss](runbook.md#node-age-key-loss).

There is no fleet-wide rotation primitive yet; rotate node-by-node.

## What NOT to do

- **Never commit a plaintext secret value** to any branch or file. Ciphertext in
  `secrets/*.sops.yaml` is the ONLY form a value may take in git.
- **Never encrypt irrevocable/long-lived material** into git (public-repo
  ciphertext is forever). Scoped, rotatable, single-use only.
- **Do not introduce a workstation-held SOPS/age/vault key** as the decrypt path,
  or any operator-laptop `ansible-playbook` push that delivers secrets. Node-held
  keys only — the laptop-off invariant is non-negotiable.
- **Do not share one token across purposes** or put a node in a recipient group it
  does not need. Keep DNS:Edit and ACME TXT-only separate.
- **Do not reuse preauth keys** or mint long-lived/reusable ones.
- **Do not put long-lived broad credentials in cloud-init user-data.** Provider
  metadata and the serial console can expose user-data; only single-use / narrowly
  scoped material is acceptable there.

## Graduation path

The roles' contract is "read a file at a known path." Only the **delivery** step
changes as the fleet or team grows — no role edits required.

- **Today:** SOPS-in-git with node-held age keys (primary) + bootstrap-env /
  manual seeding (fallback). Adequate for a single-digit fleet.
- **Next:** a node-reachable secret manager the node itself queries — a
  self-hosted OpenBao/Vault on the tailnet with node identity auth, or an external
  secret manager reached over the network. Either way the delivery writes the same
  files under `/etc/substrate/secrets` and the roles are unchanged.
- **Whatever the source, the invariant holds:** the node fetches/decrypts its own
  secrets from something it can reach with the laptop turned off. No commit-time
  decryption by a workstation key, no push from an operator machine.
