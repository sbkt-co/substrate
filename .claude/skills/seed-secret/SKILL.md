---
name: seed-secret
description: FALLBACK — seed a node-local secret file directly (tailnet authkey, Cloudflare DNS token, ACME token) on a node not yet key-registered, or in an emergency. Primary path is the encrypt-secret skill (SOPS in git). Use when a node has no age key registered yet or you must place a value out-of-band.
---

# Seed / rotate a secret (FALLBACK path)

This is the FALLBACK mechanism. The PRIMARY path is the **encrypt-secret** skill
(`scripts/secret.sh encrypt/rotate`): a SOPS-encrypted value in git that every
registered node decrypts with its own node-held age key. Use seeding directly only
when a node is not yet key-registered, or in an emergency where committing is not
an option. Note: if a `secrets/<name>.sops.yaml` exists for the same dest, the next
reconcile REPLACES a hand-seeded value with the git one — git is the source of truth.

Secrets are root-only files under `/etc/substrate/secrets` on the node, never in
git. Seeding and rotation are the same operation — write the file, the next
reconcile applies it. The VALUE goes over stdin only (argv leaks into history and
`ps`); the script writes with umask 077 + chmod 0600 and never echoes the value.

Steps:

1. Ask the user which secret and which target:
   - secret: `tailnet-authkey` | `cloudflare-dns` | `acme`
   - target: `--incus <name>` (Incus instance, project `substrate-staging`) or
     `--local` (this host, root required).

2. Pipe the value via stdin — do NOT put it on the command line:

   ```sh
   printf '%s' "$VALUE" | scripts/seed-secret.sh --incus staging-core acme
   # or
   printf '%s' "$VALUE" | scripts/seed-secret.sh --local tailnet-authkey
   ```

   It maps the name to the canonical file/format (see docs/secrets.md):
   `tailnet-authkey` (raw), `cloudflare-dns` -> `cloudflare-dns.ini`
   (`CLOUDFLARE_API_TOKEN=...`), `acme` -> `cloudflare.ini` (`dns_cloudflare_api_token = ...`).

3. Suggest applying immediately instead of waiting for the timer:

   ```sh
   systemctl start substrate-reconcile.service
   ```

After rotating a Cloudflare token, remind the user to revoke the old one at
Cloudflare — the new file does not invalidate the previous credential.
