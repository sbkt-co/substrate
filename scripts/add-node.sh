#!/usr/bin/env bash
# add-node.sh <hostname> [--branch staging|main] — onboard a new node.
#
# Two outputs:
#   1. Prints the exact cloud-init / run-once-as-root bootstrap snippet, with the
#      environment seed and the optional secret-seed env vars.
#   2. Creates host_vars/<hostname>.yml from host_vars/example.yml if it does not
#      already exist, so you can set node_roles and PR it via the runbook flow.
#
# The branch a node tracks is seeded ONCE at bootstrap (SUBSTRATE_BRANCH ->
# /etc/substrate/branch) and is deliberately NOT recorded in host_vars — that
# keeps host_vars identical across main and staging for ff-promotion.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
EXAMPLE="$REPO_ROOT/host_vars/example.yml"

BRANCH="staging"   # default: onboard to pre-prod first, promote later
HOSTNAME_ARG=""

usage() {
  cat <<'EOF'
Usage: scripts/add-node.sh <hostname> [--branch staging|main]

  <hostname>            the node's reported hostname (host_vars filename key).
  --branch staging|main environment seed for bootstrap (default: staging).

Prints the bootstrap snippet and creates host_vars/<hostname>.yml if absent.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --branch)
      shift; BRANCH="${1:-}"
      case "$BRANCH" in
        staging|main) ;;
        *) echo "add-node.sh: --branch must be 'staging' or 'main'." >&2; exit 2 ;;
      esac
      ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "add-node.sh: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -n "$HOSTNAME_ARG" ]; then
        echo "add-node.sh: unexpected extra argument: $1" >&2; exit 2
      fi
      HOSTNAME_ARG="$1"
      ;;
  esac
  shift
done

if [ -z "$HOSTNAME_ARG" ]; then
  echo "add-node.sh: <hostname> is required." >&2; usage >&2; exit 2
fi
if ! printf '%s' "$HOSTNAME_ARG" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; then
  echo "add-node.sh: invalid hostname '$HOSTNAME_ARG'." >&2
  echo "Use lowercase DNS-label form: [a-z0-9-], no leading/trailing dash." >&2
  exit 2
fi

RAW_BASE="https://raw.githubusercontent.com/sbkt-co/substrate/main/bootstrap/bootstrap.sh"

cat <<EOF
# ---------------------------------------------------------------------------
# Bootstrap snippet for '${HOSTNAME_ARG}' (tracks '${BRANCH}').
# Paste as cloud-init user-data, or run once as root on the fresh node.
# Secret seeds are OPTIONAL — omit any you will place out-of-band. Values in
# user-data can leak via provider metadata: use only single-use / scoped tokens
# (see docs/secrets.md 'What NOT to do').
# ---------------------------------------------------------------------------
export SUBSTRATE_BRANCH=${BRANCH}

# Optional secret seeds (leave unset to seed out-of-band later):
# export SUBSTRATE_TAILNET_AUTHKEY=...   # single-use headscale preauth key -> tailnet-authkey
# export SUBSTRATE_CLOUDFLARE_TOKEN=...  # Cloudflare DNS:Edit token        -> cloudflare-dns.ini  (roles/dns)
# export SUBSTRATE_ACME_TOKEN=...        # Cloudflare TXT-only token         -> cloudflare.ini      (roles/cert_issuer)

curl -fsSL ${RAW_BASE} | bash
# ---------------------------------------------------------------------------
EOF

DEST="$REPO_ROOT/host_vars/${HOSTNAME_ARG}.yml"
echo
if [ -e "$DEST" ]; then
  echo "host_vars/${HOSTNAME_ARG}.yml already exists — left untouched."
else
  if [ ! -f "$EXAMPLE" ]; then
    echo "add-node.sh: template host_vars/example.yml not found." >&2
    exit 1
  fi
  cp "$EXAMPLE" "$DEST"
  echo "Created host_vars/${HOSTNAME_ARG}.yml from host_vars/example.yml."
fi

cat <<EOF

Next:
  1. Edit host_vars/${HOSTNAME_ARG}.yml: set node_roles (and any required
     overrides, e.g. cert_client_issuer_host / substrate_headscale_url).
  2. PR it via the runbook flow (branch off staging -> tests/run.sh -> PR).
  See docs/runbook.md workflow 2 and docs/secrets.md for the secret-seeding caveats.
EOF
