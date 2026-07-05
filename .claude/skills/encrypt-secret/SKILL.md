---
name: encrypt-secret
description: Encrypt or rotate a substrate secret into git with SOPS + node-held age keys (the PRIMARY secret mechanism). Use when publishing or rotating a Cloudflare DNS token, ACME token, or tailnet authkey so registered nodes decrypt it on reconcile.
---

# Encrypt / rotate a secret (SOPS, node-held keys)

This is the PRIMARY way substrate handles secrets: a value is encrypted to the
registered nodes' age PUBLIC keys, committed as `secrets/<name>.sops.yaml`, and
each node decrypts it with its OWN private key (`/etc/substrate/secrets/age.key`,
generated at bootstrap, never leaves the node) on the next reconcile. No
workstation is ever required to converge the fleet — the laptop only produces
ciphertext that git carries. See docs/secrets.md.

"A secret is one command; everything else is a commit."

Prereqs: `sops` and `age` on this machine (`brew install sops age`). At least one
node must already be REGISTERED for the secret's group — node keys are printed at
bootstrap; register them with the add-node flow / `register-node` (see below).

Steps:

1. Pick the secret name (maps to a canonical file/format — do not improvise):
   - `cloudflare-dns` -> `CLOUDFLARE_API_TOKEN=<value>`   (roles/dns)
   - `acme`           -> `dns_cloudflare_api_token = <value>` (roles/cert_issuer)
   - `tailnet-authkey`-> raw one-line preauth key         (roles/tailnet)

2. Encrypt — pipe the VALUE via stdin, NEVER on the command line:

   ```sh
   printf '%s' "$TOKEN" | scripts/secret.sh encrypt cloudflare-dns
   ```

   It wraps the value byte-for-byte as `{ content: | ... }`, encrypts to the
   group's registered recipients, and writes `secrets/cloudflare-dns.sops.yaml`.
   It REFUSES if no node is registered for that group (a ciphertext with no
   recipients is unreadable) and tells you to register one first.

3. Rotate is the same command with rotation guidance:

   ```sh
   printf '%s' "$NEW_TOKEN" | scripts/secret.sh rotate cloudflare-dns
   ```

   After rotating, REVOKE the old credential upstream (Cloudflare token /
   headscale preauth key) — re-encrypting does not invalidate the previous one.

4. Commit + PR the `secrets/*.sops.yaml` change via the runbook flow (branch off
   `staging` -> `tests/run.sh` -> PR). Nodes registered for the group pick it up
   on their next reconcile; a manually-seeded value for the same dest is replaced.

Registering a node key (once, from the bootstrap output):

```sh
scripts/secret.sh register-node <age1pubkey> --groups dns_nodes,acme_nodes
```

This edits `.sops.yaml` and re-keys existing secrets. If it reports a secret
"NOT re-keyed" (no current recipient key on this machine), just re-run `encrypt`
for that name from its source value — that republishes it to all recipients using
only public keys.

Only ever encrypt REVOCABLE material (scoped/rotatable tokens, single-use preauth
keys): public-repo ciphertext is forever. FALLBACK for not-yet-registered nodes or
emergencies is the seed-secret skill (node-local file, no git). SOPS with a
WORKSTATION-held key is BANNED — keys are node-held only (laptop-off invariant).
