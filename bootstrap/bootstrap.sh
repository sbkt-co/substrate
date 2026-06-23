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
#   SUBSTRATE_REPO_URL   git URL of the control-plane repo
#   SUBSTRATE_BRANCH     branch to track (default: main)
#   SUBSTRATE_PLAYBOOK   playbook ansible-pull runs (default: local.yml)
#
set -euo pipefail

REPO_URL="${SUBSTRATE_REPO_URL:-https://github.com/sbkt-co/substrate.git}"
BRANCH="${SUBSTRATE_BRANCH:-main}"
PLAYBOOK="${SUBSTRATE_PLAYBOOK:-local.yml}"
WORKDIR="${SUBSTRATE_WORKDIR:-/var/lib/substrate/repo}"

log() { printf '[substrate-bootstrap] %s\n' "$*"; }

if [ "$(id -u)" -ne 0 ]; then
    log "must run as root" >&2
    exit 1
fi

install_prereqs() {
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y --no-install-recommends git ansible ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y git ansible-core ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y git ansible ca-certificates
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache git ansible ca-certificates
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

log "performing first convergence from ${REPO_URL}@${BRANCH}"
mkdir -p "$WORKDIR"
exec ansible-pull \
    --url "$REPO_URL" \
    --checkout "$BRANCH" \
    --directory "$WORKDIR" \
    --purge \
    --inventory "localhost," \
    "$PLAYBOOK"
