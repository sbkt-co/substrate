#!/usr/bin/env bash
# secret.sh — SOPS + age secret distribution with NODE-HELD keys.
#
# The operator DX for substrate secrets: "a secret is one command; everything
# else is a commit." A value is encrypted (to the registered nodes' age PUBLIC
# keys) into secrets/<name>.sops.yaml and committed; nodes decrypt it with their
# own private key on the next reconcile. No workstation is ever required to
# converge the fleet — this script only PRODUCES ciphertext that git carries.
#
# Subcommands (see --help):
#   encrypt <name>                       encrypt a value (stdin) into a sops file
#   rotate <name>                        alias for encrypt, with rotation guidance
#   register-node <age1pubkey> --groups  add a node's public key to recipient groups
#   operator-init                        mint an OPTIONAL operator key for read-back
#
# The secret VALUE is always read from STDIN, never argv (argv leaks into shell
# history and `ps`). Encryption needs only PUBLIC keys — no node private key and
# no decryption happen here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOPS_CONFIG="$REPO_ROOT/.sops.yaml"
SECRETS_SRC_DIR="$REPO_ROOT/secrets"

# Name -> (sops src file, printf format, recipient group). MUST match the
# substrate_sops_secrets manifest in group_vars/all.yml and the canonical formats
# in docs/secrets.md (the formats are NOT interchangeable).
#   cloudflare-dns  -> secrets/cloudflare-dns.sops.yaml  CLOUDFLARE_API_TOKEN=<value>
#   acme            -> secrets/acme.sops.yaml            dns_cloudflare_api_token = <value>
#   tailnet-authkey -> secrets/tailnet-authkey.sops.yaml <value>
VALID_NAMES="cloudflare-dns acme tailnet-authkey"
VALID_GROUPS="dns_nodes acme_nodes tailnet_nodes"

err()  { printf 'secret.sh: %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage: scripts/secret.sh <subcommand> [args]

  encrypt <name>
      Read a secret VALUE from stdin and encrypt it into secrets/<name>.sops.yaml
      for the nodes registered in .sops.yaml. Refuses if no recipients exist.
      Example:
        printf '%s' "$TOKEN" | scripts/secret.sh encrypt cloudflare-dns

  rotate <name>
      Alias for `encrypt` with a reminder to revoke the old credential upstream.

  register-node <age1pubkey> --groups <g1[,g2,...]>
      Add a node's age PUBLIC key to the named recipient groups in .sops.yaml,
      then re-key every existing secrets/*.sops.yaml. Idempotent.
      Groups: dns_nodes | acme_nodes | tailnet_nodes | operator
      ('operator' is sugar for all three — an OPTIONAL read-back convenience.)

  operator-init
      Generate an OPTIONAL operator age key (~/.config/sops/age/keys.txt) so you
      can read/rotate values from this workstation. The fleet NEVER depends on it.

  <name> is one of: cloudflare-dns | acme | tailnet-authkey

Node keys are printed at bootstrap; register them, then `encrypt`, then commit.
EOF
}

# --- tool checks -------------------------------------------------------------

pkg_hint() {
  if [ "$(uname -s)" = "Darwin" ]; then echo "brew install sops age"; else echo "apt-get install -y age  # and install a sops release from github.com/getsops/sops"; fi
}
need_tool() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found. Install it: $(pkg_hint)"
}

# --- name mapping ------------------------------------------------------------

name_valid() {
  for n in $VALID_NAMES; do [ "$1" = "$n" ] && return 0; done
  return 1
}
# Sets globals SRC_FILE, FMT, GROUP for a valid name.
map_name() {
  case "$1" in
    cloudflare-dns)  SRC_FILE="cloudflare-dns.sops.yaml"; FMT='CLOUDFLARE_API_TOKEN=%s\n';    GROUP="dns_nodes" ;;
    acme)            SRC_FILE="acme.sops.yaml";           FMT='dns_cloudflare_api_token = %s\n'; GROUP="acme_nodes" ;;
    tailnet-authkey) SRC_FILE="tailnet-authkey.sops.yaml"; FMT='%s\n';                          GROUP="tailnet_nodes" ;;
    *) die "unknown secret name '$1'. Expected one of: $VALID_NAMES" ;;
  esac
}

# True if recipient group $1 in .sops.yaml has at least one age key.
group_has_recipients() {
  awk -v grp="$1" '
    $0 == "  " grp ": &" grp " []" { exit 1 }   # explicit empty
    $0 == "  " grp ": &" grp      { inblk=1; next }
    inblk==1 && $0 ~ /^    - age1/ { found=1 }
    inblk==1 && $0 !~ /^    - /    { inblk=0 }
    END { exit (found ? 0 : 1) }
  ' "$SOPS_CONFIG"
}

# --- encrypt / rotate --------------------------------------------------------

cmd_encrypt() {
  local name="${1:-}" rotate="${2:-}"
  [ -n "$name" ] || { err "encrypt: <name> required."; usage >&2; exit 2; }
  name_valid "$name" || die "unknown secret name '$name'. Expected: $VALID_NAMES"
  need_tool sops
  [ -f "$SOPS_CONFIG" ] || die ".sops.yaml not found at $SOPS_CONFIG"
  map_name "$name"

  if ! group_has_recipients "$GROUP"; then
    die "no recipients in group '$GROUP' of .sops.yaml. Register a node first:
  scripts/secret.sh register-node <age1pubkey> --groups $GROUP
(node keys are printed at bootstrap). A ciphertext with no recipients is unreadable."
  fi

  if [ -t 0 ]; then
    err "no stdin. Pipe the value in, e.g.:"
    err "  printf '%s' \"\$TOKEN\" | scripts/secret.sh encrypt $name"
    exit 2
  fi
  # $(cat) strips trailing newlines; the format re-adds the exact canonical one.
  local value; value="$(cat)"
  [ -n "$value" ] || die "empty value on stdin; refusing to encrypt an empty secret."

  local plain enc; plain="$(mktemp)"; enc="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$plain' '$enc'" EXIT
  chmod 0600 "$plain" "$enc"

  # Wrap as { content: | <exact bytes> }. The literal block scalar preserves the
  # value verbatim; clip chomping keeps exactly the single trailing newline the
  # printf format emits, so the decrypted dest is byte-identical to a seeded file.
  {
    printf 'content: |\n'
    # shellcheck disable=SC2059
    printf "$FMT" "$value" | sed 's/^/  /'
  } > "$plain"

  mkdir -p "$SECRETS_SRC_DIR"
  # --filename-override makes sops pick recipients by the FINAL path's regex while
  # reading the (differently named) temp plaintext.
  if ! sops --filename-override "secrets/$SRC_FILE" \
            --input-type yaml --output-type yaml \
            --encrypt "$plain" > "$enc" 2>"$plain.err"; then
    err "sops encryption failed:"; cat "$plain.err" >&2; rm -f "$plain.err"; exit 1
  fi
  rm -f "$plain.err"
  mv "$enc" "$SECRETS_SRC_DIR/$SRC_FILE"
  chmod 0644 "$SECRETS_SRC_DIR/$SRC_FILE"   # ciphertext; safe to be world-readable in git

  echo "Encrypted secrets/$SRC_FILE for group '$GROUP'."
  echo
  echo "Next: commit + PR. Nodes registered in '$GROUP' pick it up on their next reconcile."
  if [ "$rotate" = "rotate" ]; then
    echo
    echo "ROTATION: this only publishes the NEW value. REVOKE the OLD credential"
    echo "upstream now (Cloudflare token / headscale preauth key) — re-encrypting"
    echo "does not invalidate the previous secret."
  fi
}

# --- register-node -----------------------------------------------------------

# Add $KEY to group $1's anchored list in .sops.yaml (idempotent).
# Echoes "added" or "present"; exits non-zero only on real error.
add_key_to_group() {
  local grp="$1" key="$2" tmp rc
  tmp="$(mktemp)"
  set +e
  awk -v grp="$grp" -v key="$key" '
    inblk==1 {
      if ($0 ~ /^    - /) {
        k=$0; sub(/^    - /,"",k); gsub(/[ \t]+$/,"",k)
        if (k==key) present=1
        print; next
      } else {
        if (!present) { print "    - " key; changed=1 }
        inblk=0
      }
    }
    {
      if ($0 == "  " grp ": &" grp " []") { print "  " grp ": &" grp; print "    - " key; changed=1; next }
      if ($0 == "  " grp ": &" grp)       { print; inblk=1; present=0; next }
      print
    }
    END {
      if (inblk==1 && !present) { print "    - " key; changed=1 }
      exit (changed ? 0 : 10)
    }
  ' "$SOPS_CONFIG" > "$tmp"
  rc=$?
  set -e
  case "$rc" in
    0)  mv "$tmp" "$SOPS_CONFIG"; echo "added"; return 0 ;;
    10) rm -f "$tmp"; echo "present"; return 0 ;;
    *)  rm -f "$tmp"; return 1 ;;
  esac
}

cmd_register_node() {
  local pubkey="" groups=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --groups) shift; groups="${1:-}" ;;
      -*) die "register-node: unknown flag '$1'" ;;
      *)  if [ -z "$pubkey" ]; then pubkey="$1"; else die "register-node: unexpected argument '$1'"; fi ;;
    esac
    shift
  done
  [ -n "$pubkey" ] || { err "register-node: <age1pubkey> required."; usage >&2; exit 2; }
  [ -n "$groups" ] || { err "register-node: --groups <comma-list> required."; usage >&2; exit 2; }
  printf '%s' "$pubkey" | grep -Eq '^age1[0-9a-z]{50,}$' \
    || die "register-node: '$pubkey' is not a valid age public key (expected age1...)."
  need_tool sops
  [ -f "$SOPS_CONFIG" ] || die ".sops.yaml not found at $SOPS_CONFIG"

  # Expand groups; 'operator' is sugar for every purpose group.
  local requested="" want=""
  IFS=',' read -r -a _groups <<< "$groups"
  for g in "${_groups[@]}"; do
    [ -n "$g" ] || continue
    if [ "$g" = "operator" ]; then
      requested="$requested $VALID_GROUPS"
    else
      case " $VALID_GROUPS " in *" $g "*) requested="$requested $g" ;; *) die "register-node: unknown group '$g'. Valid: $VALID_GROUPS, operator" ;; esac
    fi
  done
  # De-duplicate.
  for g in $requested; do case " $want " in *" $g "*) ;; *) want="$want $g" ;; esac; done

  local changed=0 result
  for g in $want; do
    result="$(add_key_to_group "$g" "$pubkey")" || die "failed editing group '$g' in .sops.yaml"
    if [ "$result" = "added" ]; then echo "  + $g: added key"; changed=1; else echo "  = $g: already present"; fi
  done

  # Re-key every existing ciphertext so newly added recipients can decrypt it.
  # `sops updatekeys` must DECRYPT the current data key to re-encrypt it, so it
  # needs a CURRENT recipient's private key present locally (e.g. an operator key,
  # or run from a node). Where that is absent it fails — which is FINE: re-running
  # `encrypt <name>` republishes the ciphertext from the source value using only
  # public keys (laptop-off invariant intact). We report exactly which files need
  # that so the operator is never left with a silently un-decryptable node.
  local rekeyed=0 stale=""
  if [ -d "$SECRETS_SRC_DIR" ]; then
    for f in "$SECRETS_SRC_DIR"/*.sops.yaml; do
      [ -e "$f" ] || continue
      if sops updatekeys -y "$f" >/dev/null 2>&1; then
        echo "  updatekeys: $(basename "$f") re-keyed"
        rekeyed=$((rekeyed + 1))
      else
        echo "  updatekeys: $(basename "$f") NOT re-keyed (no readable data key here)"
        stale="$stale $(basename "$f")"
      fi
    done
  fi

  echo
  if [ "$changed" -eq 0 ]; then
    echo "No change — key already registered in:${want}."
  else
    echo "Registered node key into:${want}. Re-keyed ${rekeyed} existing secret file(s)."
  fi
  if [ -n "$stale" ]; then
    echo
    echo "NOTE: these existing secrets could NOT be re-keyed from this machine"
    echo "(no current recipient key present):${stale}"
    echo "The newly registered node cannot decrypt them until they are re-keyed."
    echo "Fix WITHOUT any private key — re-encrypt each from its source value:"
    for f in $stale; do
      case "$f" in
        cloudflare-dns.sops.yaml)  echo "  printf '%s' \"\$TOKEN\"   | scripts/secret.sh encrypt cloudflare-dns" ;;
        acme.sops.yaml)            echo "  printf '%s' \"\$TOKEN\"   | scripts/secret.sh encrypt acme" ;;
        tailnet-authkey.sops.yaml) echo "  printf '%s' \"\$AUTHKEY\" | scripts/secret.sh encrypt tailnet-authkey" ;;
      esac
    done
  fi
  echo
  echo "Next: commit + PR the updated .sops.yaml and secrets/*.sops.yaml."
}

# --- operator-init -----------------------------------------------------------

cmd_operator_init() {
  need_tool age-keygen
  local dir="${HOME}/.config/sops/age" file="${HOME}/.config/sops/age/keys.txt"
  if [ -f "$file" ]; then
    echo "Operator age key already exists at $file (left untouched)."
  else
    mkdir -p "$dir"; chmod 0700 "$dir"
    ( umask 077; age-keygen -o "$file" >/dev/null 2>&1 )
    chmod 0600 "$file"
    echo "Generated operator age key at $file."
  fi
  local pub; pub="$(age-keygen -y "$file" 2>/dev/null || true)"
  [ -n "$pub" ] || die "could not derive public key from $file"
  cat <<EOF

OPTIONAL operator public key:
  $pub

To read/rotate any secret from this workstation, register it into the purpose
groups you need (this is a convenience only — the fleet never depends on it):

  scripts/secret.sh register-node $pub --groups operator

then commit + PR the updated .sops.yaml and secrets/*.sops.yaml.
EOF
}

# --- dispatch ----------------------------------------------------------------

main() {
  local sub="${1:-}"
  case "$sub" in
    encrypt)        shift; cmd_encrypt "${1:-}" "" ;;
    rotate)         shift; cmd_encrypt "${1:-}" "rotate" ;;
    register-node)  shift; cmd_register_node "$@" ;;
    operator-init)  shift; cmd_operator_init ;;
    -h|--help|help|"") usage ;;
    *) err "unknown subcommand '$sub'"; usage >&2; exit 2 ;;
  esac
}

main "$@"
