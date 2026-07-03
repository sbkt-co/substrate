#!/usr/bin/env bash
#
# Real convergence test in an Incus system container (Debian trixie, systemd as
# PID 1 — i.e. a faithful stand-in for a real node). Proves what the unprivileged
# check-mode suite cannot: the playbook converges for real, is idempotent, and
# repairs drift, leaving the reconciler timer active.
#
# Isolation: everything runs inside a DEDICATED Incus project (default
# `substrate-test`), never the `default` project. Combined with a
# `user.substrate-managed=true` label on the instance, this guarantees the
# harness only ever addresses and deletes containers it created — no collision
# with related or unrelated instances on a busy host. The instance is addressed
# fully as <remote>:<instance> within <project>.
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
PROJECT="${SUBSTRATE_INCUS_PROJECT:-substrate-test}"
IMAGE="${SUBSTRATE_TEST_IMAGE:-images:debian/trixie}"
INVENTORY="tests/incus/inventory.yml"

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }

# Never operate in the shared default project — that is where a user's real
# containers live, and a stray --force delete there would be destructive.
if [ "$PROJECT" = "default" ]; then
    echo "refusing to run in the 'default' incus project; set SUBSTRATE_INCUS_PROJECT" >&2
    exit 1
fi

# Run an incus subcommand scoped to our project. --project must come right after
# the subcommand (before any `--` command separator), so insert it there rather
# than appending. Address the instance and only delete it if it carries our
# managed label, so we can never remove something we did not create.
incus_in() { local sub="$1"; shift; incus "$sub" --project "$PROJECT" "$@"; }
delete_if_managed() {
    if incus_in config get "$CONTAINER" user.substrate-managed 2>/dev/null | grep -qx true; then
        incus_in delete --force "$CONTAINER" >/dev/null 2>&1 || true
    fi
}
cleanup() {
    delete_if_managed
    # Drop the project only if we left it empty (never force-remove a project
    # that someone else has put instances into).
    incus project delete "$PROJECT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! incus info >/dev/null 2>&1; then
    echo "incus is not reachable. On macOS, start it alongside Docker with:" >&2
    echo "  tests/incus/colima-up.sh" >&2
    exit 1
fi

# Drive incus/ansible against whatever the default remote is: `local` on a Linux
# host (incus admin init), or the colima remote (colima-incus) on macOS. Both the
# incus CLI calls below and the ansible incus connection then target the same node.
REMOTE="$(incus remote get-default 2>/dev/null || echo local)"
export SUBSTRATE_INCUS_REMOTE="$REMOTE"
export SUBSTRATE_INCUS_PROJECT="$PROJECT"
echo "addressing incus node: remote=$REMOTE project=$PROJECT instance=$CONTAINER"

# Dedicated project for isolation. features.profiles/images=false share the
# host's default profile (network + storage) and image cache, so the project is
# an instance namespace only — no separate network/storage to provision.
step "ensure isolated incus project '$PROJECT'"
if ! incus project show "$PROJECT" >/dev/null 2>&1; then
    incus project create "$PROJECT" -c features.profiles=false -c features.images=false
fi
delete_if_managed   # clear any leftover managed instance from a prior failed run

step "launch system container ($IMAGE)"
incus_in launch "$IMAGE" "$CONTAINER" -c user.substrate-managed=true

step "wait for the container to finish booting"
for _ in $(seq 1 60); do
    state="$(incus_in exec "$CONTAINER" -- systemctl is-system-running 2>/dev/null || true)"
    case "$state" in running | degraded) break ;; esac
    sleep 2
done

# Ansible needs python3 on the target; become needs sudo. Skip the apt install
# (and its network dependency) when the image already carries them — e.g. a
# prebaked/cached image in CI.
step "ensure prerequisites (python3 for Ansible, sudo for become)"
if ! incus_in exec "$CONTAINER" -- sh -c 'command -v python3 >/dev/null 2>&1' 2>/dev/null; then
    incus_in exec "$CONTAINER" -- sh -c 'apt-get update -qq && apt-get install -y -qq python3 sudo ca-certificates'
fi

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
incus_in exec "$CONTAINER" -- rm -f \
    /etc/systemd/system/substrate-reconcile.timer \
    /etc/substrate/node.yml
converge
incus_in exec "$CONTAINER" -- test -f /etc/systemd/system/substrate-reconcile.timer
incus_in exec "$CONTAINER" -- test -f /etc/substrate/node.yml

step "verify reconciler is live"
ansible-playbook -i "$INVENTORY" tests/incus/verify.yml

printf '\n\033[1;32mAll Incus converge checks passed.\033[0m\n'
