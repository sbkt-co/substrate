---
name: encrypt-secret
description: Publish or rotate a substrate secret with the one command `task secret:set` (SOPS + node-held age keys, the PRIMARY mechanism). Use when publishing or rotating a Cloudflare DNS token, ACME token, or tailnet authkey so recipient nodes decrypt it on reconcile.
---

# Set a secret (the one command)

Publishing or rotating a substrate secret is **one command**. It hides all the
SOPS/age machinery: it discovers which nodes read the secret, registers their age
PUBLIC keys, asks you for the value at a HIDDEN prompt, encrypts to
`secrets/<name>.sops.yaml`, and opens a PR. Each node decrypts with its OWN
private key (`/etc/substrate/secrets/age.key`, generated at bootstrap, never
leaves the node) on the next reconcile. No workstation is ever in the decrypt
loop. See docs/secrets.md.

"Run one command, answer the hidden prompt, approve the PR."

Prereq: `sops`, `age`, and `gh` on this machine (`brew install sops age gh`).

## Primary path

1. Pick the name (each maps to a role + canonical node file — do not improvise):
   - `cloudflare-dns` -> `roles/dns` -> `cloudflare-dns.ini`
   - `acme`           -> `roles/cert_issuer` -> `cloudflare.ini`
   - `tailnet-authkey`-> `roles/tailnet` -> `tailnet-authkey`

2. Run the one command and answer the hidden prompt:

   ```sh
   task secret:set NAME=acme
   # or directly: scripts/secret.sh set acme
   ```

   It prints the recipients it found, registers their keys, reads the VALUE at a
   hidden prompt (with a confirm re-entry — never echoed, never in argv), encrypts,
   commits, pushes a `secret-set-<name>` branch, and opens a PR into `staging`.

3. Approve/merge the PR. Recipient nodes pick the value up on their next reconcile.

**Rotation is the same command** — run `task secret:set NAME=<name>` again with the
new value, then REVOKE the old credential upstream (Cloudflare token / headscale
preauth key); re-encrypting does not invalidate the previous one.

## Flags (pass after `--` from task)

- `--dry-run` — show the full plan (recipients, keys, git+gh commands), change
  nothing. Preview with `task secret:set NAME=acme -- --dry-run`.
- `--target <host>[,<host2>]` — name recipients directly (before a node declares
  the role in host_vars).
- `--key <age1...>` — supply a pubkey for a host not reachable over incus (a real
  cloud node — paste the pubkey it printed at bootstrap).
- `--yes` — skip the confirmation prompt (automation; or pipe the value on stdin).

## See state

```sh
task secret:status
```

Read-only: per secret, whether it is published, its recipient hosts, and whether
each node already has the decrypted file.

## Notes

- If no node declares the secret's role yet, `set` explains that and tells you to
  add the role to a host_vars file (PR) or pass `--target`. It never fails
  cryptically.
- Only ever set REVOCABLE material (scoped/rotatable tokens, single-use preauth
  keys): public-repo ciphertext is forever.
- FALLBACK for a not-yet-registered node or an emergency is the **seed-secret**
  skill (node-local file, no git). SOPS with a WORKSTATION-held key is BANNED —
  keys are node-held only (laptop-off invariant).

## Advanced / manual (only if you are scripting the pieces)

`task secret:set` wraps these; reach for them only when debugging:

```sh
scripts/secret.sh register-node <age1pubkey> --groups dns_nodes,acme_nodes
printf '%s' "$TOKEN" | scripts/secret.sh encrypt cloudflare-dns   # then commit + PR
```
