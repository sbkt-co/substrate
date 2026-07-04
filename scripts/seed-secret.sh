#!/usr/bin/env bash
# seed-secret.sh <target> <secret-name> — place a node-local secret file.
#
# The VALUE is read from STDIN, never from argv (argv leaks into shell history
# and `ps`). The value is never echoed and is written under umask 077 + chmod
# 0600. Seeding and rotation are the same operation: roles re-read the file on
# every converge.
#
#   target       --incus <name>   write inside an Incus instance in project
#                                  substrate-staging (incus exec)
#                --local          write on this host (needs root for /etc/substrate)
#   secret-name  tailnet-authkey | cloudflare-dns | acme
#
# Mapping (canonical file names/formats — see docs/secrets.md):
#   tailnet-authkey -> tailnet-authkey     raw one-line preauth key
#   cloudflare-dns  -> cloudflare-dns.ini  CLOUDFLARE_API_TOKEN=<value>      (roles/dns)
#   acme            -> cloudflare.ini       dns_cloudflare_api_token = <value> (roles/cert_issuer)
set -euo pipefail

SECRETS_DIR="/etc/substrate/secrets"
INCUS_PROJECT="substrate-staging"

usage() {
  cat <<'EOF'
Usage: printf '%s' "$VALUE" | scripts/seed-secret.sh <target> <secret-name>

  target:
    --incus <name>   write inside Incus instance <name> (project substrate-staging)
    --local          write on this host (root required for /etc/substrate/secrets)
  secret-name:
    tailnet-authkey | cloudflare-dns | acme

The secret VALUE is read from stdin only. Example:
  printf '%s' "$TOKEN" | scripts/seed-secret.sh --incus staging-core acme
EOF
}

TARGET_KIND=""
INCUS_NAME=""
SECRET_NAME=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --incus)
      TARGET_KIND="incus"; shift
      INCUS_NAME="${1:-}"
      [ -n "$INCUS_NAME" ] || { echo "seed-secret.sh: --incus needs an instance name." >&2; exit 2; }
      ;;
    --local) TARGET_KIND="local" ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "seed-secret.sh: unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [ -z "$SECRET_NAME" ]; then SECRET_NAME="$1"
      else echo "seed-secret.sh: unexpected extra argument: $1" >&2; exit 2; fi
      ;;
  esac
  shift
done

if [ -z "$TARGET_KIND" ]; then
  echo "seed-secret.sh: a target (--incus <name> | --local) is required." >&2
  usage >&2; exit 2
fi
if [ -z "$SECRET_NAME" ]; then
  echo "seed-secret.sh: a secret-name is required." >&2; usage >&2; exit 2
fi

# Map secret-name -> file + formatter. The formatter turns the raw value into the
# exact file content (formats are NOT interchangeable; see docs/secrets.md).
case "$SECRET_NAME" in
  tailnet-authkey) FILE="tailnet-authkey"; FMT='%s\n' ;;
  cloudflare-dns)  FILE="cloudflare-dns.ini"; FMT='CLOUDFLARE_API_TOKEN=%s\n' ;;
  acme)            FILE="cloudflare.ini"; FMT='dns_cloudflare_api_token = %s\n' ;;
  *)
    echo "seed-secret.sh: unknown secret-name '$SECRET_NAME'." >&2
    echo "Expected one of: tailnet-authkey | cloudflare-dns | acme" >&2
    exit 2
    ;;
esac

# Read the value from stdin only. $(cat) strips trailing newlines.
if [ -t 0 ]; then
  echo "seed-secret.sh: no stdin. Pipe the value in, e.g.:" >&2
  echo "  printf '%s' \"\$TOKEN\" | scripts/seed-secret.sh $* " >&2
  exit 2
fi
VALUE="$(cat)"
if [ -z "$VALUE" ]; then
  echo "seed-secret.sh: empty value on stdin; refusing to write an empty secret." >&2
  exit 2
fi

DEST="${SECRETS_DIR}/${FILE}"

# Emit the canonical file content (with its trailing newline) to stdout. The
# value only ever passes through this function's stdin/format — never argv of a
# child process. FMT is a controlled format string, not user data.
emit_content() {
  # shellcheck disable=SC2059
  printf "$FMT" "$VALUE"
}

if [ "$TARGET_KIND" = "local" ]; then
  install -d -m 0700 "$SECRETS_DIR"
  ( umask 077; emit_content > "$DEST" )
  chmod 0600 "$DEST"
  echo "Wrote ${DEST} (0600) on this host."
else
  # Pipe the content via stdin to incus exec; the path (not the value) is argv.
  # The single-quoted script runs in the remote shell — expansion there is intended.
  # shellcheck disable=SC2016
  emit_content | incus exec "$INCUS_NAME" --project "$INCUS_PROJECT" -- \
    sh -c 'umask 077; install -d -m 0700 "$(dirname "$1")"; cat > "$1"; chmod 0600 "$1"' _ "$DEST"
  echo "Wrote ${DEST} (0600) in incus:${INCUS_NAME} (project ${INCUS_PROJECT})."
fi

echo "Apply now with:  systemctl start substrate-reconcile.service"
