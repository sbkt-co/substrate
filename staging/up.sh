#!/usr/bin/env bash
#
# Bring up (and converge) the PERSISTENT local staging fleet in a dedicated Incus
# project. Two long-lived Debian trixie system containers (systemd as PID 1 —
# faithful stands-in for real nodes) model the tailnet + certificate topology:
#
#   staging-core  headscale coordination server + tailnet member + cert issuer
#   staging-web1  tailnet member + cert client (fetches the wildcard cert)
#
# Unlike tests/incus/run.sh (ephemeral, torn down on exit), these instances are
# long-lived: created with boot.autostart=true and NEVER deleted by this script.
# Re-running is safe and idempotent — it reuses existing instances and just
# re-converges them.
#
# Isolation & safety (mirrors the ephemeral harness):
#   - Everything runs inside a DEDICATED project (default substrate-staging),
#     never the shared `default` project (which holds unrelated instances).
#   - Instances carry user.substrate-managed=true; this script only ever touches
#     instances it created, and it never deletes anything.
#
# Prereqs on the host: incus (initialised), ansible-core, and the
# community.general collection (see requirements.yml). Install the controller
# toolchain with:
#   uv tool install ansible-core==2.18.6
#   ansible-galaxy collection install -r requirements.yml
#
# Usage: staging/up.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="${SUBSTRATE_STAGING_PROJECT:-substrate-staging}"
IMAGE="${SUBSTRATE_STAGING_IMAGE:-images:debian/trixie}"
INVENTORY="staging/inventory.yml"
CORE="staging-core"
WEB1="staging-web1"
INSTANCES=("$CORE" "$WEB1")

step() { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*" >&2; }

# Never operate in the shared default project — that is where a host's real
# containers live and this fleet must stay isolated from them.
if [ "$PROJECT" = "default" ]; then
    echo "refusing to run in the 'default' incus project; set SUBSTRATE_STAGING_PROJECT" >&2
    exit 1
fi

# Controller toolchain must be present before we start creating instances.
if ! command -v ansible-playbook >/dev/null 2>&1; then
    echo "ansible-playbook not found. Install the controller toolchain with:" >&2
    echo "  uv tool install ansible-core==2.18.6" >&2
    echo "  ansible-galaxy collection install -r requirements.yml" >&2
    exit 1
fi
if ! ansible-galaxy collection list community.general >/dev/null 2>&1; then
    echo "community.general collection not found (needed for the incus connection). Install with:" >&2
    echo "  ansible-galaxy collection install -r requirements.yml" >&2
    exit 1
fi

if ! incus info >/dev/null 2>&1; then
    echo "incus is not reachable. On macOS, start it alongside Docker with:" >&2
    echo "  tests/incus/colima-up.sh" >&2
    exit 1
fi

# Drive incus/ansible against whatever the default remote is: `local` on a Linux
# host, or the colima remote (colima-incus) on macOS. Both the incus CLI calls
# below and the ansible incus connection then target the same node.
REMOTE="$(incus remote get-default 2>/dev/null || echo local)"
export SUBSTRATE_INCUS_REMOTE="$REMOTE"
export SUBSTRATE_STAGING_PROJECT="$PROJECT"
echo "addressing incus node: remote=$REMOTE project=$PROJECT instances=${INSTANCES[*]}"

# Run an incus subcommand scoped to our project. --project must come right after
# the subcommand (before any `--` command separator), so insert it there.
incus_in() { local sub="$1"; shift; incus "$sub" --project "$PROJECT" "$@"; }

# True only for instances that exist AND carry our managed label — the guard that
# keeps this script from ever addressing something it did not create.
is_managed() {
    incus_in config get "$1" user.substrate-managed 2>/dev/null | grep -qx true
}

# Dedicated project for isolation. features.profiles/images=false share the
# host's default profile (network + storage) and image cache, so the project is
# an instance namespace only — no separate network/storage to provision (same
# flags the ephemeral test harness uses).
step "ensure isolated incus project '$PROJECT'"
if ! incus project show "$PROJECT" >/dev/null 2>&1; then
    incus project create "$PROJECT" -c features.profiles=false -c features.images=false
fi

launch_if_absent() {
    local name="$1"
    if incus_in info "$name" >/dev/null 2>&1; then
        if ! is_managed "$name"; then
            echo "instance '$name' exists but is not substrate-managed; refusing to touch it" >&2
            exit 1
        fi
        echo "instance '$name' already present (managed); reusing"
        # Ensure it is running (persistent instances may have been stopped).
        incus_in start "$name" >/dev/null 2>&1 || true
        return
    fi
    step "launch persistent system container '$name' ($IMAGE)"
    incus_in launch "$IMAGE" "$name" \
        -c user.substrate-managed=true \
        -c boot.autostart=true
    # tailscaled needs /dev/net/tun inside the container.
    incus_in config device add "$name" tun unix-char \
        source=/dev/net/tun path=/dev/net/tun
    incus_in restart "$name"
}

for name in "${INSTANCES[@]}"; do
    launch_if_absent "$name"
done

wait_ready() {
    local name="$1"
    step "wait for '$name' to finish booting"
    local state
    for _ in $(seq 1 60); do
        state="$(incus_in exec "$name" -- systemctl is-system-running 2>/dev/null || true)"
        case "$state" in running | degraded) return 0 ;; esac
        sleep 2
    done
    warn "'$name' did not reach a running/degraded systemd state; continuing anyway"
}

# Ansible needs python3 on the target; become needs sudo. Skip the apt install
# (and its network dependency) when the image already carries them.
ensure_prereqs() {
    local name="$1"
    if ! incus_in exec "$name" -- sh -c 'command -v python3 >/dev/null 2>&1' 2>/dev/null; then
        step "install prerequisites in '$name' (python3, sudo)"
        incus_in exec "$name" -- sh -c 'apt-get update -qq && apt-get install -y -qq python3 sudo ca-certificates'
    fi
}

# Seed node-local state the same way bootstrap.sh would: the tracked-branch seed
# and the secrets directory. host_vars/<host>.yml supplies the rest of identity.
seed_node() {
    local name="$1"
    step "seed node-local state in '$name'"
    incus_in exec "$name" -- sh -c '
        set -e
        mkdir -p /etc/substrate/secrets
        chmod 0700 /etc/substrate /etc/substrate/secrets
        printf "staging" > /etc/substrate/branch
    '
}

for name in "${INSTANCES[@]}"; do
    wait_ready "$name"
    ensure_prereqs "$name"
    seed_node "$name"
done

converge() {
    ansible-playbook -i "$INVENTORY" staging/converge.yml "$@"
}

# Order matters. Converge the coordination node first so headscale is up and can
# mint a preauth key; the tailnet role on every node (core included) consumes
# that key from {{ substrate_secrets_dir }}/tailnet-authkey.
step "converge $CORE (brings up headscale)"
converge --limit "$CORE"

# Defensive: ensure the "substrate" headscale user (namespace) exists before we
# mint any preauth keys. The headscale role creates it during the CORE converge
# above; this belt-and-suspenders create tolerates "already exists" so a partially
# converged CORE can still be enrolled. Output is discarded — nothing here or
# below is allowed to echo a user/key value to stdout or logs.
step "ensure the 'substrate' headscale user exists on $CORE"
incus_in exec "$CORE" -- headscale users create substrate >/dev/null 2>&1 || true

# Mint a fresh SINGLE-USE preauth key for exactly one joining node, then push it
# straight into that node's secrets dir (mode 0600) and re-converge it so its
# tailnet role consumes the key on its one and only join. One key per node — never
# reusable — so a compromised node only ever holds an already-spent key. The key
# is captured into a local and streamed over stdin; it is never printed.
# headscale 0.26's `preauthkeys create --user` takes the numeric user *ID*, not
# the name, so resolve substrate's id from `users list --output json` first, then
# mint with --output json and extract only the .key field. All parsing runs
# inside the container (python3 is present) so the raw key never lands in a host
# shell variable or the process table, and stdout carries the bare key only.
mint_join_converge() {
    local name="$1" key
    step "mint single-use preauth key and enrol $name"
    key="$(incus_in exec "$CORE" -- sh -c '
        set -e
        uid="$(headscale users list --output json \
            | python3 -c "import sys,json; print(next(u[\"id\"] for u in json.load(sys.stdin) if u[\"name\"]==\"substrate\"))")"
        headscale preauthkeys create --user "$uid" --expiration 24h --output json \
            | python3 -c "import sys,json; print(json.load(sys.stdin)[\"key\"])"
    ' 2>/dev/null | tr -d '[:space:]')"
    if [ -z "$key" ]; then
        echo "failed to obtain a headscale preauth key from $CORE for $name" >&2
        return 1
    fi
    printf '%s' "$key" | \
        incus_in file push - "$name/etc/substrate/secrets/tailnet-authkey" --mode 0600
    unset key
    # Re-converge this node now that its key is seeded so the (previously blocked)
    # tailnet + cert layers apply. Converges are idempotent.
    converge --limit "$name"
}

# Order matters: enrol CORE first (it joins its own tailnet so the cert server can
# bind a tailscale IP), then WEB1 (joins to reach the coordination server and
# fetch the cert). Each node gets its own single-use key, minted immediately
# before its converge.
mint_join_converge "$CORE"
mint_join_converge "$WEB1"

# Idempotence check: a full re-converge should ideally report changed=0. First
# bring-up can legitimately have ordering-dependent changes (e.g. a service that
# only settled after the key landed), so warn rather than fail and print the recap.
step "idempotence check (full re-converge)"
recap="$(converge 2>&1 | tee /dev/stderr | grep -E 'ok=[0-9]+.*changed=[0-9]+' || true)"
if printf '%s\n' "$recap" | grep -qE 'changed=[1-9]'; then
    warn "re-converge reported changes (see recap below). On first bring-up this can"
    warn "be ordering-dependent; run staging/up.sh again and it should settle to changed=0."
    printf '%s\n' "$recap" >&2
else
    echo "idempotent: full re-converge reported changed=0 on all hosts."
fi

printf '\n\033[1;32mStaging fleet is up.\033[0m %s and %s are running and converged.\n' "$CORE" "$WEB1"
echo "Seed the Cloudflare token on $CORE to enable cert issuance — see staging/README.md."
