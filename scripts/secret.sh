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
#   set <name>                           THE one command: discover recipients from
#                                        host_vars, fetch+register their node keys,
#                                        read the value (hidden prompt or stdin),
#                                        encrypt, commit, push, open a PR.
#   status                               show every manifest secret's state at a glance
#   encrypt <name>                       (advanced) encrypt a value (stdin) into a sops file
#   rotate <name>                        alias for encrypt, with rotation guidance
#   register-node <age1pubkey> --groups  (advanced) add a node's public key to groups
#   operator-init                        mint an OPTIONAL operator key for read-back
#
# The secret VALUE is always read from STDIN or a HIDDEN prompt, never argv (argv
# leaks into shell history and `ps`). Encryption needs only PUBLIC keys — no node
# private key and no decryption happen here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOPS_CONFIG="$REPO_ROOT/.sops.yaml"
SECRETS_SRC_DIR="$REPO_ROOT/secrets"
HOST_VARS_DIR="$REPO_ROOT/host_vars"

# Incus targeting for fetching node age PUBLIC keys (override via env).
STAGING_PROJECT="${SUBSTRATE_STAGING_PROJECT:-substrate-staging}"
INCUS_REMOTE="${SUBSTRATE_INCUS_REMOTE:-}"   # empty = incus' current remote

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

THE ONE COMMAND:

  set <name> [--target h1[,h2]] [--key <age1...>] [--dry-run] [--yes]
      Publish (or rotate) a secret end to end. It discovers which nodes run the
      role that reads this secret (from host_vars node_roles), fetches each node's
      age PUBLIC key, registers them, reads the VALUE (hidden prompt, or stdin if
      piped), encrypts to secrets/<name>.sops.yaml, then commits, pushes, and opens
      a PR into staging. Merge it; the nodes pick the value up on next reconcile.
        --target  name recipient hosts explicitly (skip host_vars discovery)
        --key     supply an age pubkey for an unreachable host (repeatable)
        --dry-run show the full plan (recipients, keys, git+gh commands); no writes
        --yes     skip interactive confirmation (for automation)

  status
      One read-only table: for each manifest secret, whether it is published, its
      recipient hosts (from the role mapping), and best-effort whether each node
      already has the decrypted dest file. Never fails.

ADVANCED / MANUAL escape hatches (prefer `set`):

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

Normal path: `scripts/secret.sh set <name>` (or `task secret:set NAME=<name>`).
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
# Sets globals SRC_FILE, FMT, GROUP, ROLE, DEST_FILE for a valid name. ROLE is
# the differentiation role whose nodes are recipients (used to discover hosts
# from host_vars node_roles); DEST_FILE is the node-local file the role parses.
map_name() {
  case "$1" in
    cloudflare-dns)  SRC_FILE="cloudflare-dns.sops.yaml"; FMT='CLOUDFLARE_API_TOKEN=%s\n';    GROUP="dns_nodes";     ROLE="dns";         DEST_FILE="cloudflare-dns.ini" ;;
    acme)            SRC_FILE="acme.sops.yaml";           FMT='dns_cloudflare_api_token = %s\n'; GROUP="acme_nodes";  ROLE="cert_issuer"; DEST_FILE="cloudflare.ini" ;;
    tailnet-authkey) SRC_FILE="tailnet-authkey.sops.yaml"; FMT='%s\n';                          GROUP="tailnet_nodes"; ROLE="tailnet";   DEST_FILE="tailnet-authkey" ;;
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

# Core encryption. Assumes map_name already ran (SRC_FILE/FMT/GROUP set) and the
# group has recipients. Reads the exact VALUE from $1 and writes the ciphertext
# to secrets/$SRC_FILE. Never echoes the value. Used by both `encrypt` and `set`.
encrypt_value() {
  local value="$1"
  [ -n "$value" ] || die "empty value; refusing to encrypt an empty secret."

  local plain enc; plain="$(mktemp)"; enc="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$plain' '$enc' '$plain.err'" RETURN
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
    err "sops encryption failed:"; cat "$plain.err" >&2; return 1
  fi
  mv "$enc" "$SECRETS_SRC_DIR/$SRC_FILE"
  chmod 0644 "$SECRETS_SRC_DIR/$SRC_FILE"   # ciphertext; safe to be world-readable in git
}

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

  encrypt_value "$value" || exit 1

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

# --- recipient discovery + incus key fetch (shared by set/status) ------------

# Print the hosts (one per line) whose host_vars/<host>.yml node_roles includes
# role $1. Skips *.example.yml (templates, not real nodes). host_vars is trusted
# repo YAML, so a tiny python parse is appropriate and robust.
hosts_for_role() {
  local role="$1"
  [ -d "$HOST_VARS_DIR" ] || return 0
  python3 - "$HOST_VARS_DIR" "$role" <<'PY'
import os, sys
try:
    import yaml
except Exception:
    yaml = None
hv_dir, role = sys.argv[1], sys.argv[2]
for fn in sorted(os.listdir(hv_dir)):
    if not fn.endswith(".yml") or fn.endswith(".example.yml"):
        continue
    host = fn[:-4]
    path = os.path.join(hv_dir, fn)
    roles = []
    if yaml is not None:
        with open(path) as fh:
            data = yaml.safe_load(fh) or {}
        roles = data.get("node_roles") or []
    else:
        # Minimal fallback: parse a `node_roles:` block of `  - name` lines.
        inblk = False
        with open(path) as fh:
            for line in fh:
                s = line.rstrip("\n")
                if s.strip().startswith("#"):
                    continue
                if inblk:
                    t = s.strip()
                    if t.startswith("- "):
                        roles.append(t[2:].strip())
                        continue
                    if s[:1] not in (" ", "\t") and t:
                        inblk = False
                if s.startswith("node_roles:"):
                    rest = s.split(":", 1)[1].strip()
                    if rest and rest not in ("[]", "|", ">"):
                        roles = [x.strip() for x in rest.strip("[]").split(",") if x.strip()]
                    else:
                        inblk = True
    if isinstance(roles, list) and role in roles:
        print(host)
PY
}

# Fetch a host's age PUBLIC key by running age-keygen -y against its node key
# over incus exec. Echoes the age1... key on success; empty on any failure.
# Never touches the private key — age-keygen -y derives the public key only.
fetch_host_pubkey() {
  local host="$1" remote_prefix="" pub
  [ -n "$INCUS_REMOTE" ] && remote_prefix="${INCUS_REMOTE}:"
  pub="$(incus exec "${remote_prefix}${host}" --project "$STAGING_PROJECT" -- \
           age-keygen -y /etc/substrate/secrets/age.key 2>/dev/null || true)"
  case "$pub" in age1*) printf '%s' "$pub" ;; *) : ;; esac
}

# Best-effort: does host $1 already have dest file $2 under the secrets dir?
# Echoes "yes"/"no"/"?" (? = host unreachable). Never fails.
host_has_dest() {
  local host="$1" dest="$2" remote_prefix=""
  [ -n "$INCUS_REMOTE" ] && remote_prefix="${INCUS_REMOTE}:"
  if incus exec "${remote_prefix}${host}" --project "$STAGING_PROJECT" -- \
       test -f "/etc/substrate/secrets/${dest}" >/dev/null 2>&1; then
    echo "yes"
  elif incus exec "${remote_prefix}${host}" --project "$STAGING_PROJECT" -- \
       true >/dev/null 2>&1; then
    echo "no"
  else
    echo "?"
  fi
}

# --- set ---------------------------------------------------------------------

cmd_set() {
  local name="" targets="" dry=0 assume_yes=0
  local -a extra_keys=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target) shift; targets="${1:-}"; [ -n "$targets" ] || die "set: --target needs a host list" ;;
      --key)    shift; [ -n "${1:-}" ] || die "set: --key needs an age1... key"
                printf '%s' "$1" | grep -Eq '^age1[0-9a-z]{50,}$' || die "set: --key '$1' is not a valid age public key"
                extra_keys+=("$1") ;;
      --dry-run) dry=1 ;;
      --yes|-y)  assume_yes=1 ;;
      -*) die "set: unknown flag '$1'" ;;
      *)  if [ -z "$name" ]; then name="$1"; else die "set: unexpected argument '$1'"; fi ;;
    esac
    shift
  done
  [ -n "$name" ] || { err "set: <name> required."; usage >&2; exit 2; }
  name_valid "$name" || die "unknown secret name '$name'. Expected one of: $VALID_NAMES"
  need_tool sops
  [ -f "$SOPS_CONFIG" ] || die ".sops.yaml not found at $SOPS_CONFIG"
  map_name "$name"

  echo "Secret '$name' -> role '$ROLE' -> group '$GROUP' -> dest '$DEST_FILE'."

  # --- discover recipient hosts --------------------------------------------
  local -a hosts=()
  if [ -n "$targets" ]; then
    IFS=',' read -r -a hosts <<< "$targets"
    echo "Recipients (explicit --target): ${hosts[*]}"
  else
    local discovered; discovered="$(hosts_for_role "$ROLE")"
    if [ -n "$discovered" ]; then
      while IFS= read -r h; do [ -n "$h" ] && hosts+=("$h"); done <<< "$discovered"
    fi
    if [ "${#hosts[@]}" -eq 0 ] && [ "${#extra_keys[@]}" -eq 0 ]; then
      err "no node declares role '$ROLE' in host_vars/*.yml, so '$name' has zero recipients."
      err "Either:"
      err "  - add '$ROLE' to a node's node_roles in host_vars/<host>.yml (PR it), then re-run; or"
      err "  - name recipients directly:   scripts/secret.sh set $name --target <host>[,<host2>]"
      exit 1
    fi
    echo "Recipients for $name (host_vars node_roles has '$ROLE'): ${hosts[*]:-(none — using --key only)}"
  fi

  # --- fetch + collect age pubkeys -----------------------------------------
  # Parallel arrays: key_hosts[i] label, key_vals[i] age pubkey.
  local -a key_hosts=() key_vals=()
  local h pub
  for h in ${hosts[@]+"${hosts[@]}"}; do
    printf 'Fetching %s age key... ' "$h"
    pub="$(fetch_host_pubkey "$h")"
    if [ -n "$pub" ]; then
      echo "ok"
      key_hosts+=("$h"); key_vals+=("$pub")
    else
      echo "unreachable"
      err "  could not fetch ${h}'s age key over incus (project \"$STAGING_PROJECT\"${INCUS_REMOTE:+, remote \"$INCUS_REMOTE\"})."
      err "  If $h is a real node (not incus), grab its bootstrap-printed pubkey and pass it:"
      err "    scripts/secret.sh set $name --target $h --key <age1...>"
      err "  or register it manually:  scripts/secret.sh register-node <age1...> --groups $GROUP"
    fi
  done
  local i=0
  if [ "${#extra_keys[@]}" -gt 0 ]; then
    for pub in "${extra_keys[@]}"; do
      i=$((i + 1)); key_hosts+=("--key#$i"); key_vals+=("$pub"); echo "Using supplied --key $pub"
    done
  fi

  if [ "${#key_vals[@]}" -eq 0 ]; then
    die "no age keys collected for any recipient — nothing to encrypt to. See the guidance above."
  fi

  # --- register keys into the group ----------------------------------------
  if [ "$dry" -eq 1 ]; then
    echo
    echo "DRY RUN — no files, .sops.yaml, commits, pushes, or PRs will change."
    echo "Would register these keys into group '$GROUP':"
    i=0
    while [ "$i" -lt "${#key_vals[@]}" ]; do
      echo "  ${key_hosts[$i]} -> ${key_vals[$i]}"
      i=$((i + 1))
    done
    local branch="secret-set-$name"
    echo
    echo "Would then run:"
    echo "  # encrypt the value (read hidden / from stdin) into secrets/$SRC_FILE"
    echo "  git switch -c $branch   # (or reset it to staging if it exists)"
    echo "  git add secrets/$SRC_FILE .sops.yaml"
    echo "  git commit -m 'secret: set $name'"
    echo "  git push -u origin $branch"
    echo "  gh pr create --base staging --title 'secret: set $name' --body <recipients + reconcile note>"
    echo
    echo "Recipients that would decrypt $name: ${key_hosts[*]}"
    return 0
  fi

  i=0
  while [ "$i" -lt "${#key_vals[@]}" ]; do
    local res
    res="$(add_key_to_group "$GROUP" "${key_vals[$i]}")" || die "failed editing group '$GROUP' in .sops.yaml"
    if [ "$res" = "added" ]; then
      echo "Registering ${key_hosts[$i]} key... ok"
    else
      echo "Registering ${key_hosts[$i]} key... already registered"
    fi
    i=$((i + 1))
  done

  # --- read the VALUE (hidden prompt, or stdin if piped) -------------------
  local value=""
  if [ ! -t 0 ]; then
    value="$(cat)"                       # pipeable / automatable
    [ -n "$value" ] || die "empty value on stdin; refusing to encrypt an empty secret."
    echo "Value (from stdin): ********"
  else
    local v1="" v2=""
    printf 'Value for %s (hidden): ' "$name" >&2
    read -r -s v1 || die "no value read."
    printf '\n' >&2
    printf 'Re-enter to confirm: ' >&2
    read -r -s v2 || die "no value read."
    printf '\n' >&2
    [ -n "$v1" ] || die "empty value; refusing to encrypt an empty secret."
    [ "$v1" = "$v2" ] || die "values did not match; aborting (nothing was written or committed)."
    value="$v1"
    echo "Value (hidden): ********"
  fi

  # --- encrypt --------------------------------------------------------------
  encrypt_value "$value" || die "encryption failed."
  value=""                               # drop the plaintext from memory promptly
  echo "Encrypted secrets/$SRC_FILE"

  # --- git branch + commit + push + PR -------------------------------------
  # Confirm before we mutate git / push / open a PR (skip with --yes or no tty).
  if [ "$assume_yes" -eq 0 ] && [ -t 0 ] && [ -t 1 ]; then
    printf 'Commit + push + open a PR into staging now? [Y/n] ' >&2
    local ans; read -r ans || ans=""
    case "$ans" in n|N|no|NO) die "aborted before any git/push/PR (secrets/$SRC_FILE and .sops.yaml were written locally; revert with git restore if unwanted)." ;; esac
  fi

  local branch="secret-set-$name"
  # Prefer origin/staging as the branch base; fall back to local staging, then
  # the current HEAD if neither is fetched. Reuse an existing branch by resetting
  # it to base cleanly (--keep preserves our just-written working-tree changes;
  # it never clobbers unrelated branches).
  local base=""
  if git -C "$REPO_ROOT" rev-parse --verify --quiet "origin/staging" >/dev/null 2>&1; then
    base="origin/staging"
  elif git -C "$REPO_ROOT" rev-parse --verify --quiet "staging" >/dev/null 2>&1; then
    base="staging"
  fi
  if git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$REPO_ROOT" switch "$branch" >/dev/null 2>&1
    [ -n "$base" ] && git -C "$REPO_ROOT" reset --keep "$base" >/dev/null 2>&1 || true
  elif [ -n "$base" ]; then
    git -C "$REPO_ROOT" switch -c "$branch" "$base" >/dev/null 2>&1 || git -C "$REPO_ROOT" switch "$branch" >/dev/null 2>&1
  else
    git -C "$REPO_ROOT" switch -c "$branch" >/dev/null 2>&1 || git -C "$REPO_ROOT" switch "$branch" >/dev/null 2>&1
  fi

  git -C "$REPO_ROOT" add "secrets/$SRC_FILE" .sops.yaml
  if git -C "$REPO_ROOT" diff --cached --quiet; then
    echo "No changes to commit (value + recipients already published). Nothing to PR."
    return 0
  fi
  git -C "$REPO_ROOT" commit -q -m "secret: set $name

Publishes secrets/$SRC_FILE (ciphertext) for group '$GROUP'.
Recipients: ${key_hosts[*]}." || die "git commit failed."

  git -C "$REPO_ROOT" push -u origin "$branch" >/dev/null 2>&1 || die "git push failed (check your remote / auth)."

  local pr_body
  pr_body="Publishes the '$name' secret (ciphertext only — no value here) for role '$ROLE'.

Recipients (nodes that can decrypt it): ${key_hosts[*]}

These nodes pick the value up on their next reconcile once this merges to staging."
  need_tool gh
  local pr_url
  if pr_url="$(cd "$REPO_ROOT" && gh pr create --base staging \
                 --title "secret: set $name" --body "$pr_body" 2>/dev/null)"; then
    local pr_num; pr_num="$(printf '%s' "$pr_url" | grep -oE '[0-9]+$' || true)"
    echo "Opened PR #${pr_num:-?} -> staging"
    echo "Merge it; ${key_hosts[*]} picks it up on next reconcile."
    echo "$pr_url"
  else
    err "gh pr create failed (a PR may already exist for '$branch')."
    err "Open it manually:  gh pr create --base staging --head $branch"
    exit 1
  fi
}

# --- status ------------------------------------------------------------------

cmd_status() {
  echo "substrate secrets — status"
  echo
  local name
  for name in $VALID_NAMES; do
    map_name "$name"
    local published="no"
    [ -f "$SECRETS_SRC_DIR/$SRC_FILE" ] && published="yes"
    local recips=""; recips="$(hosts_for_role "$ROLE" | tr '\n' ' ')"
    recips="${recips% }"
    local count=0
    [ -n "$recips" ] && count="$(printf '%s\n' "$recips" | wc -w | tr -d ' ')"
    printf '%s\n' "$name"
    printf '  role/group : %s / %s\n' "$ROLE" "$GROUP"
    printf '  ciphertext : secrets/%s (%s)\n' "$SRC_FILE" "$published"
    printf '  recipients : %s (%s)\n' "$count" "${recips:-none declared in host_vars}"
    if [ -n "$recips" ] && command -v incus >/dev/null 2>&1; then
      local h have
      for h in $recips; do
        have="$(host_has_dest "$h" "$DEST_FILE")"
        case "$have" in
          yes) printf '    - %-14s dest %s present\n' "$h" "$DEST_FILE" ;;
          no)  printf '    - %-14s dest %s absent (not decrypted yet)\n' "$h" "$DEST_FILE" ;;
          *)   printf '    - %-14s unreachable (cannot check dest)\n' "$h" ;;
        esac
      done
    fi
    echo
  done
  echo "Publish or rotate any of these with:  scripts/secret.sh set <name>"
}

# --- dispatch ----------------------------------------------------------------

main() {
  local sub="${1:-}"
  case "$sub" in
    set)            shift; cmd_set "$@" ;;
    status)         shift; cmd_status ;;
    encrypt)        shift; cmd_encrypt "${1:-}" "" ;;
    rotate)         shift; cmd_encrypt "${1:-}" "rotate" ;;
    register-node)  shift; cmd_register_node "$@" ;;
    operator-init)  shift; cmd_operator_init ;;
    -h|--help|help|"") usage ;;
    *) err "unknown subcommand '$sub'"; usage >&2; exit 2 ;;
  esac
}

main "$@"
