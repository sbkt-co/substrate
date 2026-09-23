#!/usr/bin/env bash
#
# Real convergence test in an Incus system container (Debian trixie, systemd as
# PID 1 — i.e. a faithful stand-in for a real node). Proves what the unprivileged
# check-mode suite cannot: the playbook converges for real, is idempotent, and
# repairs drift, leaving the reconciler timer active.
#
# The node is given a REAL differentiation role set (see tests/incus/test-vars.yml):
# it is simultaneously the tailnet coordinator (headscale, loopback), a tailnet
# member (enrolled against its own headscale with a single-use preauth key this
# script mints), the public-DNS manager, the wildcard cert issuer, and a cert
# client. The secret-bearing roles (dns / cert_issuer / cert_client) find no
# operator secrets in CI and take their documented skip-loudly paths; verify.yml
# asserts both the roles that ran and the skips. This script also seeds a
# throwaway age identity + a test-only SOPS ciphertext so the node-held-key
# decrypt path (roles/common) runs for real instead of always skipping.
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
REPO_DIR="$PWD"

CONTAINER="${SUBSTRATE_TEST_CONTAINER:-substrate-test}"
PROJECT="${SUBSTRATE_INCUS_PROJECT:-substrate-test}"
IMAGE="${SUBSTRATE_TEST_IMAGE:-images:debian/trixie}"
INVENTORY="tests/incus/inventory.yml"

# Kept in lockstep with roles/common/defaults/main.yml. The harness seeds a
# throwaway age identity at this path and installs this exact sops release so it
# can build the test-only ciphertext BEFORE converge (the common role's own
# get_url then no-ops on the version match).
SOPS_VERSION="3.9.4"
AGE_KEY_FILE="/etc/substrate/secrets/age.key"
SOPS_BIN="/usr/local/bin/sops"
# The ciphertext must live at {{ playbook_dir }}/fixtures/... INSIDE the container,
# because sops_decrypt.yml stats/decrypts it on the target (incus makes the
# controller != target). Mirror the controller-side playbook dir path exactly.
FIXTURE_DIR_IN_CONTAINER="$REPO_DIR/tests/incus/fixtures"
FIXTURE_IN_CONTAINER="$FIXTURE_DIR_IN_CONTAINER/test-secret.sops.yaml"
SECRET_DEST="/etc/substrate/secrets/test-secret"
# Dummy plaintext the decrypt must reproduce byte-for-byte at $SECRET_DEST. This
# protects nothing — it exists only to prove the decrypt path writes real bytes.
SECRET_PLAINTEXT="substrate-sops-selftest-value"

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

# tailscaled needs /dev/net/tun to bring up its interface; add it before the
# container settles so the tailnet role can enrol this node (mirrors staging/up.sh).
step "attach /dev/net/tun for tailscaled"
incus_in config device add "$CONTAINER" tun unix-char \
    source=/dev/net/tun path=/dev/net/tun >/dev/null 2>&1 || true
incus_in restart "$CONTAINER"

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

# Seed node-local bootstrap state the way bootstrap.sh / staging/up.sh would:
#   - the tracked-branch seed, so converge.yml's branch-pinning pre_task actually
#     runs (rather than always no-oping) and node.yml records the seeded branch;
#   - the root-only secrets directory.
step "seed node-local bootstrap state (branch + secrets dir)"
incus_in exec "$CONTAINER" -- sh -c '
    set -e
    mkdir -p /etc/substrate/secrets
    chmod 0700 /etc/substrate /etc/substrate/secrets
    printf "staging" > /etc/substrate/branch
'

# Seed a THROWAWAY age identity and a TEST-ONLY SOPS ciphertext so roles/common's
# node-held-key decrypt path runs for real (it is otherwise dead in CI: the node
# is a recipient of nothing). The private key is generated inside the container
# and never leaves it or gets printed; the plaintext is a dummy self-test value.
# We install the pinned sops release here so we can encrypt BEFORE converge; the
# common role's own get_url then no-ops on the version match.
step "seed throwaway age identity + test-only SOPS ciphertext"
incus_in exec "$CONTAINER" -- sh -c '
    set -eu
    export DEBIAN_FRONTEND=noninteractive
    if ! command -v age-keygen >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        apt-get update -qq
        apt-get install -y -qq age curl ca-certificates
    fi
    if ! sops --version 2>/dev/null | grep -q "'"$SOPS_VERSION"'"; then
        arch="$(dpkg --print-architecture)"
        curl -fsSL -o "'"$SOPS_BIN"'" \
            "https://github.com/getsops/sops/releases/download/v'"$SOPS_VERSION"'/sops-v'"$SOPS_VERSION"'.linux.${arch}"
        chmod 0755 "'"$SOPS_BIN"'"
    fi
    # Generate the node age identity exactly where roles/common expects it, so the
    # common role finds it present (its age-keygen creates: guard then no-ops).
    if [ ! -f "'"$AGE_KEY_FILE"'" ]; then
        age-keygen -o "'"$AGE_KEY_FILE"'" >/dev/null 2>&1
    fi
    chmod 0600 "'"$AGE_KEY_FILE"'"
    pub="$(age-keygen -y "'"$AGE_KEY_FILE"'")"
    mkdir -p "'"$FIXTURE_DIR_IN_CONTAINER"'"
    # Encrypt a dummy {content: <value>} mapping to the throwaway public key. The
    # decrypt task reads .content from --output-type json, so the plaintext must
    # be a mapping under the key `content` and the store type must be YAML.
    # BOTH store types are pinned explicitly: sops otherwise infers the input
    # type from the file extension, and an extensionless mktemp file silently
    # becomes a BINARY store — the plaintext then round-trips under a `data` key
    # and the role fails on the missing `content` (censored by no_log). Exactly
    # that bit CI once; do not "simplify" the explicit types away.
    plain="$(mktemp --suffix=.yaml)"
    printf "content: %s\n" "'"$SECRET_PLAINTEXT"'" > "$plain"
    sops --encrypt --input-type yaml --output-type yaml --age "$pub" "$plain" \
        > "'"$FIXTURE_IN_CONTAINER"'"
    rm -f "$plain"
    # Self-check BEFORE converge: decrypt the fixture exactly the way
    # roles/common will (same binary, same key file, same output type) and
    # assert the `content` key round-trips. A store-type or recipient mistake
    # fails HERE with a readable error instead of inside a no_log-censored task.
    SOPS_AGE_KEY_FILE="'"$AGE_KEY_FILE"'" \
        sops --decrypt --output-type json "'"$FIXTURE_IN_CONTAINER"'" \
        | python3 -c "
import json, sys
got = json.load(sys.stdin).get(\"content\")
want = \"'"$SECRET_PLAINTEXT"'\"
assert got == want, f\"fixture round-trip mismatch: {got!r} != {want!r}\"
"
    echo "SOPS fixture self-check passed (content key round-trips)."
'

converge() { ansible-playbook -i "$INVENTORY" tests/incus/converge.yml "$@"; }

assert_converge_idempotent() {
    local label="$1"
    shift
    local output rc
    if output="$(converge "$@" 2>&1)"; then
        printf '%s\n' "$output" >&2
    else
        rc=$?
        printf '%s\n' "$output" >&2
        echo "$label convergence failed with exit $rc" >&2
        exit "$rc"
    fi
    if ! grep -qE 'changed=0[[:space:]].*failed=0' <<<"$output"; then
        echo "$label convergence was not idempotent" >&2
        exit 1
    fi
}

# First converge: brings up headscale, installs tailscale + tailscaled, applies
# the skip-loudly secret roles, and decrypts the test-only SOPS secret. The
# tailnet role SKIPS enrolment here — the preauth key is not seeded yet — which
# is expected and not a failure.
step "converge (first run)"
converge

step "assert first converge has no resolver route"
incus_in exec "$CONTAINER" -- test ! -e /var/lib/substrate/resolver-address
if incus_in exec "$CONTAINER" -- grep -Eq '^[[:space:]]+svc\.sbkt\.co:' /etc/headscale/config.yaml; then
    echo "first converge unexpectedly rendered the svc.sbkt.co split route" >&2
    exit 1
fi
if incus_in exec "$CONTAINER" -- systemctl is-active --quiet coredns; then
    echo "first converge unexpectedly started CoreDNS without a tailnet address" >&2
    exit 1
fi


# Enrol this single node into its own tailnet: ensure the fleet headscale user
# exists, mint a SINGLE-USE preauth key, seed it (mode 0600), and re-converge so
# the tailnet role consumes it exactly once. The key is captured and streamed over
# stdin — never printed to stdout/logs (mirrors staging/up.sh).
step "mint single-use preauth key and enrol the node into its own tailnet"
incus_in exec "$CONTAINER" -- headscale users create substrate >/dev/null 2>&1 || true
key="$(incus_in exec "$CONTAINER" -- sh -c '
    set -e
    uid="$(headscale users list --output json \
        | python3 -c "import sys,json; print(next(u[\"id\"] for u in json.load(sys.stdin) if u[\"name\"]==\"substrate\"))")"
    headscale preauthkeys create --user "$uid" --expiration 24h --output json \
        | python3 -c "import sys,json; print(json.load(sys.stdin)[\"key\"])"
' 2>/dev/null | tr -d '[:space:]')"
if [ -z "$key" ]; then
    echo "failed to obtain a headscale preauth key for enrolment" >&2
    exit 1
fi
printf '%s' "$key" | \
    incus_in file push - "$CONTAINER/etc/substrate/secrets/tailnet-authkey" --mode 0600
unset key

step "converge again so the tailnet role enrols with the seeded key"
converge

step "assert enrollment starts CoreDNS before resolver discovery"
if ! incus_in exec "$CONTAINER" -- systemctl is-active --quiet coredns; then
    echo "enrollment converge did not start CoreDNS" >&2
    incus_in exec "$CONTAINER" -- systemctl status coredns --no-pager >&2 || true
    incus_in exec "$CONTAINER" -- journalctl -u coredns --no-pager -n 40 >&2 || true
    exit 1
fi
if incus_in exec "$CONTAINER" -- test -e /var/lib/substrate/resolver-address; then
    echo "enrollment converge unexpectedly created the resolver cache:" >&2
    incus_in exec "$CONTAINER" -- cat /var/lib/substrate/resolver-address >&2 || true
    incus_in exec "$CONTAINER" -- headscale nodes list --output json >&2 || true
    exit 1
fi
if incus_in exec "$CONTAINER" -- grep -Eq '^[[:space:]]+svc\.sbkt\.co:' /etc/headscale/config.yaml; then
    echo "enrollment converge unexpectedly rendered the svc.sbkt.co split route" >&2
    incus_in exec "$CONTAINER" -- sed -n '/^dns:/,/^unix_socket:/p' /etc/headscale/config.yaml >&2 || true
    exit 1
fi
headscale_before_wiring="$(incus_in exec "$CONTAINER" -- systemctl show headscale -p InvocationID --value | tr -d '[:space:]')"

step "converge once more so headscale wires split DNS"
converge
resolver_address="$(incus_in exec "$CONTAINER" -- tailscale ip -4 | tr -d '[:space:]')"
cached_address="$(incus_in exec "$CONTAINER" -- cat /var/lib/substrate/resolver-address | tr -d '[:space:]')"
[ "$cached_address" = "$resolver_address" ] || {
    echo "resolver cache $cached_address does not match tailnet address $resolver_address" >&2
    exit 1
}
incus_in exec "$CONTAINER" -- grep -Eq '^[[:space:]]+svc\.sbkt\.co:' /etc/headscale/config.yaml
incus_in exec "$CONTAINER" -- grep -Eq "^[[:space:]]+- $resolver_address$" /etc/headscale/config.yaml
headscale_after_wiring="$(incus_in exec "$CONTAINER" -- systemctl show headscale -p InvocationID --value | tr -d '[:space:]')"
[ -n "$headscale_before_wiring" ] && [ "$headscale_before_wiring" != "$headscale_after_wiring" ] || {
    echo "headscale did not restart when split DNS was first wired" >&2
    exit 1
}

step "assert idempotence does not restart headscale"
assert_converge_idempotent "full re-converge"
echo "idempotent."
headscale_after_idempotence="$(incus_in exec "$CONTAINER" -- systemctl show headscale -p InvocationID --value | tr -d '[:space:]')"
[ "$headscale_after_idempotence" = "$headscale_after_wiring" ] || {
    echo "headscale restarted during an idempotent convergence" >&2
    exit 1
}


step "reload CoreDNS for a records-only service-zone change"
coredns_before_zone_reload="$(incus_in exec "$CONTAINER" -- systemctl show coredns -p InvocationID --value | tr -d '[:space:]')"
# Do not query reload-probe before updating the zone: that would prime an NXDOMAIN
# in the Tailscale/MagicDNS path and could hide a successful CoreDNS file reload.
# Each harness run starts from a fresh container whose initial fixture has only
# the control record, so the post-update lookup still proves the new record loaded.
converge --extra-vars '{"resolver_service_records":[{"name":"control","type":"CNAME","value":"substrate-test.net.sbkt.co."},{"name":"reload-probe","type":"CNAME","value":"substrate-test.net.sbkt.co."}]}'
zone_reload_ready=false
for _ in $(seq 1 10); do
    if incus_in exec "$CONTAINER" -- getent ahostsv4 reload-probe.svc.sbkt.co 2>/dev/null | grep -q "$resolver_address"; then
        zone_reload_ready=true
        break
    fi
    sleep 1
done
[ "$zone_reload_ready" = true ] || {
    echo "CoreDNS did not serve the records-only zone update after convergence" >&2
    exit 1
}
coredns_after_zone_reload="$(incus_in exec "$CONTAINER" -- systemctl show coredns -p InvocationID --value | tr -d '[:space:]')"
[ "$coredns_after_zone_reload" = "$coredns_before_zone_reload" ] || {
    echo "records-only zone update restarted CoreDNS instead of reloading it" >&2
    exit 1
}
converge

assert_lkg_unchanged() {
    local label="$1"
    shift
    local cache_before config_before invocation_before cache_after config_after invocation_after
    cache_before="$(incus_in exec "$CONTAINER" -- sha256sum /var/lib/substrate/resolver-address | awk '{print $1}')"
    config_before="$(incus_in exec "$CONTAINER" -- sha256sum /etc/headscale/config.yaml | awk '{print $1}')"
    invocation_before="$(incus_in exec "$CONTAINER" -- systemctl show headscale -p InvocationID --value | tr -d '[:space:]')"
    assert_converge_idempotent "$label discovery rejection" "$@"
    cache_after="$(incus_in exec "$CONTAINER" -- sha256sum /var/lib/substrate/resolver-address | awk '{print $1}')"
    config_after="$(incus_in exec "$CONTAINER" -- sha256sum /etc/headscale/config.yaml | awk '{print $1}')"
    invocation_after="$(incus_in exec "$CONTAINER" -- systemctl show headscale -p InvocationID --value | tr -d '[:space:]')"
    [ "$cache_after" = "$cache_before" ] && [ "$config_after" = "$config_before" ] && [ "$invocation_after" = "$invocation_before" ] || {
        echo "$label discovery rejection changed cache, config, or Headscale invocation" >&2
        exit 1
    }
}

step "accept a changed valid resolver address"
changed_resolver_address=100.127.255.254
printf '%s' '[{"given_name":"substrate-test","ip_addresses":["100.127.255.254"]}]' | \
    incus_in exec "$CONTAINER" -- sh -c 'cat > /tmp/substrate-resolver-nodes.json && chmod 0644 /tmp/substrate-resolver-nodes.json'
invocation_before_changed_address="$(incus_in exec "$CONTAINER" -- systemctl show headscale -p InvocationID --value | tr -d '[:space:]')"
converge --extra-vars '{"headscale_nodes_list_argv":["/bin/cat","/tmp/substrate-resolver-nodes.json"]}'
[ "$(incus_in exec "$CONTAINER" -- cat /var/lib/substrate/resolver-address | tr -d '[:space:]')" = "$changed_resolver_address" ]
incus_in exec "$CONTAINER" -- grep -Eq "^[[:space:]]+- $changed_resolver_address$" /etc/headscale/config.yaml
invocation_after_changed_address="$(incus_in exec "$CONTAINER" -- systemctl show headscale -p InvocationID --value | tr -d '[:space:]')"
[ "$invocation_after_changed_address" != "$invocation_before_changed_address" ] || {
    echo "headscale did not restart for a changed valid resolver address" >&2
    exit 1
}

step "restore the actual discovered resolver address"
converge
[ "$(incus_in exec "$CONTAINER" -- cat /var/lib/substrate/resolver-address | tr -d '[:space:]')" = "$resolver_address" ]
incus_in exec "$CONTAINER" -- grep -Eq "^[[:space:]]+- $resolver_address$" /etc/headscale/config.yaml

step "reject failed resolver discovery without replacing LKG"
assert_lkg_unchanged command-failure \
    --extra-vars '{"headscale_nodes_list_argv":["/bin/false"]}'

step "reject malformed resolver discovery without replacing LKG"
malformed_fixture_count=0
while IFS='|' read -r fixture payload <&3; do
    [ -n "$fixture" ] || continue
    malformed_fixture_count=$((malformed_fixture_count + 1))
    printf '%s' "$payload" | \
        incus_in exec "$CONTAINER" -- sh -c 'cat > /tmp/substrate-resolver-nodes.json && chmod 0644 /tmp/substrate-resolver-nodes.json'
    assert_lkg_unchanged "$fixture" \
        --extra-vars '{"headscale_nodes_list_argv":["/bin/cat","/tmp/substrate-resolver-nodes.json"]}'
done 3<<'EOF'
malformed-json|not-json
zero-match|[{"given_name":"other","ip_addresses":["100.64.0.9"]}]
duplicate-match|[{"given_name":"substrate-test","ip_addresses":["100.64.0.9"]},{"given_name":"substrate-test","ip_addresses":["100.64.0.10"]}]
malformed-address|[{"given_name":"substrate-test","ip_addresses":["not-an-address"]}]
non-cgnat-address|[{"given_name":"substrate-test","ip_addresses":["192.0.2.53"]}]
EOF
[ "$malformed_fixture_count" -eq 5 ] || {
    echo "expected five malformed resolver fixtures, ran $malformed_fixture_count" >&2
    exit 1
}

step "withdraw split DNS when the resolver role is removed"
headscale_before_withdrawal="$(incus_in exec "$CONTAINER" -- systemctl show headscale -p InvocationID --value | tr -d '[:space:]')"
converge --extra-vars '{"node_roles":["headscale","tailnet","dns","cert_issuer","cert_client"]}'
incus_in exec "$CONTAINER" -- test ! -e /var/lib/substrate/resolver-address
if incus_in exec "$CONTAINER" -- grep -Eq '^[[:space:]]+svc\.sbkt\.co:' /etc/headscale/config.yaml; then
    echo "Headscale retained the svc.sbkt.co split route after resolver-role removal" >&2
    exit 1
fi
headscale_after_withdrawal="$(incus_in exec "$CONTAINER" -- systemctl show headscale -p InvocationID --value | tr -d '[:space:]')"
[ "$headscale_after_withdrawal" != "$headscale_before_withdrawal" ] || {
    echo "Headscale did not restart when the resolver split route was withdrawn" >&2
    exit 1
}

step "restore the resolver role and split DNS route"
converge
[ "$(incus_in exec "$CONTAINER" -- cat /var/lib/substrate/resolver-address | tr -d '[:space:]')" = "$resolver_address" ]
incus_in exec "$CONTAINER" -- grep -Eq '^[[:space:]]+svc\.sbkt\.co:' /etc/headscale/config.yaml
incus_in exec "$CONTAINER" -- grep -Eq "^[[:space:]]+- $resolver_address$" /etc/headscale/config.yaml

# Drift repair: exercise BOTH a DELETED managed file and a MODIFIED one. A pull
# reconciler must restore deletions AND overwrite hand edits back to the committed
# state. node.yml is a templated copy (content-managed) so a corrupting edit must
# be repaired; the reconciler timer unit is deleted outright.
step "drift repair (delete a managed unit, corrupt a managed file; re-converge restores both)"
incus_in exec "$CONTAINER" -- rm -f /etc/systemd/system/substrate-reconcile.timer
incus_in exec "$CONTAINER" -- sh -c 'printf "%s\n" "roles: DRIFTED-BY-HAND" > /etc/substrate/node.yml'
converge
incus_in exec "$CONTAINER" -- test -f /etc/systemd/system/substrate-reconcile.timer
incus_in exec "$CONTAINER" -- test -f /etc/substrate/node.yml
# The corrupted node.yml must have been rewritten back to managed content.
if incus_in exec "$CONTAINER" -- grep -q 'DRIFTED-BY-HAND' /etc/substrate/node.yml; then
    echo "DRIFT NOT REPAIRED — node.yml still holds the hand edit" >&2
    exit 1
fi
echo "drift repaired: deleted unit restored and modified file rewritten."

step "verify the fully differentiated node"
ansible-playbook -i "$INVENTORY" tests/incus/verify.yml

printf '\n\033[1;32mAll Incus converge checks passed.\033[0m\n'
