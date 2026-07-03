# Staging fleet (local, persistent)

A two-node **persistent** Incus fleet that models the tailnet + certificate
topology for real, so changes can soak before promotion. Unlike the ephemeral
`tests/incus/` harness (torn down on exit), these instances are long-lived —
`staging/up.sh` creates them once with `boot.autostart=true` and never deletes
them; re-running just re-converges.

```
staging-core   headscale coordination server + tailnet member + cert issuer
staging-web1   tailnet member + cert client (fetches the wildcard cert)
```

Both are Debian **trixie** system containers (systemd as PID 1), addressed over
the `community.general.incus` connection (`incus exec` — no SSH, no IP, no
credentials). They live in a dedicated Incus project (`substrate-staging`),
never the shared `default` project.

## Bring the fleet up

Prereqs on the host: `incus` (initialised), `ansible-core`, and the
`community.general` collection.

```sh
uv tool install ansible-core==2.18.6
ansible-galaxy collection install -r requirements.yml
```

On macOS, start Incus in its own Colima profile alongside the default Docker
profile, then run the harness:

```sh
tests/incus/colima-up.sh                       # starts the `incus` colima profile
SUBSTRATE_INCUS_REMOTE=colima-incus staging/up.sh
```

`up.sh` auto-detects the default remote (`colima-incus` on macOS via Colima,
`local` on a Linux host), so on Linux you can just run `staging/up.sh`. Setting
`SUBSTRATE_INCUS_REMOTE` pins it explicitly.

What `up.sh` does, in order:

1. Ensures the isolated `substrate-staging` project and launches (or reuses) the
   two managed instances.
2. Seeds each node's `/etc/substrate/branch` (= `staging`) and secrets dir, the
   same way `bootstrap.sh` would on a real node.
3. Converges `staging-core` first to bring headscale up.
4. Ensures the `substrate` headscale user exists, then for **each** node mints a
   fresh **single-use** preauth key, pushes it to that node's
   `/etc/substrate/secrets/tailnet-authkey` (mode `0600`), and re-converges the
   node so its tailnet layer consumes the key on its one join. One key per node,
   never reusable, never echoed to stdout/logs.
5. Runs a final idempotence check.

## Seed the Cloudflare token on `staging-core`

Certificate issuance uses the certbot Cloudflare DNS-01 plugin, which needs a
Cloudflare API token. Secrets are **node-local files** under
`/etc/substrate/secrets` — no secret value ever lives in git. Until the token is
present the `cert_issuer` role SKIPS issuance with a loud warning (it never
fails the converge), so the fleet comes up cleanly and you enable certs by
seeding the file and re-running `up.sh`.

Write the certbot credentials file on `staging-core` in the certbot ini shape,
mode `0600` (replace the placeholder — do NOT commit a real token):

```sh
incus exec --project substrate-staging staging-core -- sh -c '
  umask 077
  cat > /etc/substrate/secrets/cloudflare.ini <<EOF
# Cloudflare API token with Zone:DNS:Edit on the sbkt.co zone
dns_cloudflare_api_token = REPLACE_WITH_REAL_TOKEN
EOF
  chmod 0600 /etc/substrate/secrets/cloudflare.ini
'
```

Then re-run `staging/up.sh` (or wait for the in-container reconciler) to issue
the certificate.

### `substrate_acme_staging` toggle

`group_vars/all.yml` sets `substrate_acme_staging: true`, which points certbot at
the **Let's Encrypt STAGING** ACME endpoint. Staging certs are issued off a
non-trusted root — expect a trust warning; this is intentional and keeps the
fleet clear of Let's Encrypt production rate limits during soak. Flip it to
`false` (via the orchestrator-owned fleet vars) to obtain trusted certificates
once the topology is proven.

## Verify

```sh
# tailnet is up and both nodes are enrolled
incus exec --project substrate-staging staging-core -- tailscale status
incus exec --project substrate-staging staging-web1 -- tailscale status

# MagicDNS resolves the coordination node from web1 over the tailnet
incus exec --project substrate-staging staging-web1 -- \
    getent hosts staging-core.net.sbkt.co

# the cert issuer serves the wildcard cert over the tailnet (bound to the
# tailscale IP); fetch it from web1
incus exec --project substrate-staging staging-web1 -- \
    curl -sk https://staging-core.net.sbkt.co:8444/fullchain.pem | head -c 64
```

(`net.sbkt.co` is `substrate_tailnet_domain`; the cert server listens on `:8444`
over the tailnet only.)

## Self-reconciliation

Each node's `/etc/substrate/branch` seed is `staging`, so the in-container
reconciler timer runs `ansible-pull` of the **`staging`** git branch. That means
self-reconciliation only goes live once this work has **landed on the `staging`
branch** — until then `up.sh` converges the current working tree by hand. After
the branch lands, the fleet reconciles itself from git and `up.sh` is only needed
to (re)create instances or re-seed secrets.

## Production secret seeding (pull model)

On real nodes the tailnet authkey and Cloudflare token must be delivered to
`/etc/substrate/secrets/` from a source **the node itself can reach** — a cloud
secret manager or instance identity/metadata — retrieved during/after
`bootstrap.sh`, NOT decrypted from or pushed by an operator's laptop. The repo
holds only the *spec* for where each secret goes; the values never enter git.
`up.sh` seeding these files over `incus file push` is the local-harness stand-in
for that node-reachable delivery.
