#!/usr/bin/env bash
#
# Real convergence test in an Incus system container (Debian trixie, systemd as
# PID 1 — i.e. a faithful stand-in for a real node). Proves what the unprivileged
# check-mode suite cannot: the playbook converges for real, is idempotent, and
# repairs drift, leaving the reconciler timer active.
#
# Prereqs on the host: incus (initialised), ansible-core, and the
# community.general collection (see requirements.yml). The current user must be
# able to drive incus (incus-admin group or root).
#
# Usage: tests/incus/run.sh
#
set -euo pipefail
cd "$(dirname "$0")/../.."

CONTAINER="${SUBSTRATE_TEST_CONTAINER:-substrate-test}"
IMAGE="${SUBSTRATE_TEST_IMAGE:-images:debian/trixie}"
INVENTORY="tests/incus/inventory.yml"

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

cleanup() { incus delete --force "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if ! incus info >/dev/null 2>&1; then
    echo "incus is not reachable. On macOS, start it alongside Docker with:" >&2
    echo "  tests/incus/colima-up.sh" >&2
    exit 1
fi

# Drive incus/ansible against whatever the default remote is: `local` on a Linux
# host (incus admin init), or the colima remote (colima-incus) on macOS. Both
# incus CLI calls below and the ansible incus connection then target the same node.
REMOTE="$(incus remote get-default 2>/dev/null || echo local)"
export SUBSTRATE_INCUS_REMOTE="$REMOTE"
echo "using incus remote: $REMOTE"

step "launch system container ($IMAGE)"
incus launch "$IMAGE" "$CONTAINER"

step "wait for systemd to finish booting"
incus exec "$CONTAINER" -- systemctl is-system-running --wait || true

step "install minimal prerequisites (python3 for Ansible, sudo for become)"
incus exec "$CONTAINER" -- bash -c 'apt-get update -qq && apt-get install -y -qq python3 sudo ca-certificates'

converge() { ansible-playbook -i "$INVENTORY" tests/incus/converge.yml "$@"; }

step "converge (first run)"
converge

step "idempotence (second run must report changed=0)"
if converge | tee /dev/stderr | grep -qE 'changed=0[[:space:]].*failed=0'; then
    echo "idempotent."
else
    echo "NOT IDEMPOTENT — second converge reported changes" >&2
    exit 1
fi

step "drift repair (delete managed unit + state, re-converge restores them)"
incus exec "$CONTAINER" -- rm -f \
    /etc/systemd/system/substrate-reconcile.timer \
    /etc/substrate/node.yml
converge
incus exec "$CONTAINER" -- test -f /etc/systemd/system/substrate-reconcile.timer
incus exec "$CONTAINER" -- test -f /etc/substrate/node.yml

step "verify reconciler is live"
ansible-playbook -i "$INVENTORY" tests/incus/verify.yml

printf '\n\033[1;32mAll Incus converge checks passed.\033[0m\n'
