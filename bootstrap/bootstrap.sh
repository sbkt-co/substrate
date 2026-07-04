#!/usr/bin/env bash
#
# substrate bootstrap — run ONCE on a fresh node (e.g. from cloud-init
# user-data). Installs git + ansible and performs the first ansible-pull
# convergence. That first run applies the `reconciler` role, which installs a
# systemd timer that keeps the node converged from main thereafter. After
# bootstrap, this script is never needed again — the node maintains itself.
#
# No workstation is involved: the node pulls the spec directly from the control
# plane (this repo on GitHub) and applies it to itself.
#
# Override via environment if needed:
#   SUBSTRATE_REPO_URL        git URL of the control-plane repo
#   SUBSTRATE_BRANCH          branch to track (default: main)
#   SUBSTRATE_PLAYBOOK        playbook ansible-pull runs (default: local.yml)
#   SUBSTRATE_SECRETS_DIR     secrets directory (default: /etc/substrate/secrets)
#
# Optional secrets — pass via environment to seed credential files at bootstrap.
# If an env var is absent the corresponding file is NOT created; consuming roles
# detect the missing file and skip with a warning (graceful degradation).
# NOTE: cloud-init logs are world-readable — these values are NEVER logged.
#   SUBSTRATE_TAILNET_AUTHKEY   -> $SECRETS_DIR/tailnet-authkey
#                                  (Tailscale auth key, raw value)
#   SUBSTRATE_CLOUDFLARE_TOKEN  -> $SECRETS_DIR/cloudflare-dns.ini
#                                  (DNS-edit token; CLOUDFLARE_API_TOKEN=<value>)
#   SUBSTRATE_ACME_TOKEN        -> $SECRETS_DIR/cloudflare.ini
#                                  (ACME/certbot TXT-only token;
#                                   dns_cloudflare_api_token = <value>)
#   Two separate Cloudflare files/tokens is deliberate: DNS-edit scope vs
#   ACME TXT-only scope = smaller blast radius if either credential leaks.
#
set -euo pipefail

REPO_URL="${SUBSTRATE_REPO_URL:-https://github.com/sbkt-co/substrate.git}"
BRANCH="${SUBSTRATE_BRANCH:-main}"
PLAYBOOK="${SUBSTRATE_PLAYBOOK:-local.yml}"
WORKDIR="${SUBSTRATE_WORKDIR:-/var/lib/substrate/repo}"
SECRETS_DIR="${SUBSTRATE_SECRETS_DIR:-/etc/substrate/secrets}"

log() { printf '[substrate-bootstrap] %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
    log "must run as root" >&2
    exit 1
fi

# Install ansible-core (not the full `ansible` package): ansible.cfg is
# deliberately dependency-free, roles need only ansible-core, and role-required
# collections come from requirements.yml — pulling the full `ansible` bundle would
# drag in a large set of collections the repo never uses and may version-pin them
# differently. On Debian trixie `ansible-core` is packaged directly.
install_prereqs() {
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y --no-install-recommends git ansible-core ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y git ansible-core ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y git ansible-core ca-certificates
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache git ansible-core ca-certificates
    else
        log "no supported package manager found (apt/dnf/yum/apk)" >&2
        exit 1
    fi
}

log "installing prerequisites (git, ansible)"
install_prereqs

# Seed the environment this node belongs to. The reconciler reads this to keep
# the systemd timer tracking the SAME branch the node was bootstrapped onto, so
# environment membership is set once here and is not re-derived from the repo
# (which would be circular). Move a node between environments by rewriting this
# file (or re-bootstrapping); promotion of *config* is a branch merge, not this.
log "recording tracked branch (${BRANCH})"
install -d -m 0755 /etc/substrate
printf '%s\n' "$BRANCH" > /etc/substrate/branch

# Provision the secrets directory unconditionally (0700; root-only).
install -d -m 0700 "$SECRETS_DIR"

# Seed optional credential files from environment variables.  Each file is
# written with umask 077 so it is created 0600.  The variable VALUE is never
# logged — only the target filename — because cloud-init logs are world-readable.
(
    umask 077

    if [ -n "${SUBSTRATE_TAILNET_AUTHKEY:-}" ]; then
        log "seeding ${SECRETS_DIR}/tailnet-authkey"
        printf '%s\n' "$SUBSTRATE_TAILNET_AUTHKEY" > "${SECRETS_DIR}/tailnet-authkey"
        chmod 0600 "${SECRETS_DIR}/tailnet-authkey"
    fi

    if [ -n "${SUBSTRATE_CLOUDFLARE_TOKEN:-}" ]; then
        log "seeding ${SECRETS_DIR}/cloudflare-dns.ini"
        printf 'CLOUDFLARE_API_TOKEN=%s\n' "$SUBSTRATE_CLOUDFLARE_TOKEN" \
            > "${SECRETS_DIR}/cloudflare-dns.ini"
        chmod 0600 "${SECRETS_DIR}/cloudflare-dns.ini"
    fi

    if [ -n "${SUBSTRATE_ACME_TOKEN:-}" ]; then
        log "seeding ${SECRETS_DIR}/cloudflare.ini"
        printf 'dns_cloudflare_api_token = %s\n' "$SUBSTRATE_ACME_TOKEN" \
            > "${SECRETS_DIR}/cloudflare.ini"
        chmod 0600 "${SECRETS_DIR}/cloudflare.ini"
    fi
)

log "performing first convergence from ${REPO_URL}@${BRANCH}"
mkdir -p "$WORKDIR"
exec ansible-pull \
    --url "$REPO_URL" \
    --checkout "$BRANCH" \
    --directory "$WORKDIR" \
    --purge \
    --inventory "localhost," \
    "$PLAYBOOK"
