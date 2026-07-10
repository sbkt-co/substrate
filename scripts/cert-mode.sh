#!/usr/bin/env bash
#
# cert-mode.sh — switch the fleet's ACME certificates between trusted (real,
# from Let's Encrypt production) and untrusted (test, from LE staging).
#
# The underlying flag is `substrate_acme_staging` in group_vars/all.yml, whose
# boolean is deliberately confusing (true = the STAGING endpoint = UNTRUSTED
# test certs). This wrapper speaks in trusted/untrusted and hides the inversion:
#
#     trusted     -> substrate_acme_staging: false  (real, browser-valid certs)
#     untrusted   -> substrate_acme_staging: true   (LE staging TEST_CERT)
#
# Changing the mode edits group_vars/all.yml, then commits/pushes and opens a PR
# into staging (the normal promotion flow — nothing is applied to nodes until
# you merge and it reconciles). `status` just reports the current mode.
#
# Usage:
#   scripts/cert-mode.sh status
#   scripts/cert-mode.sh trusted   [--dry-run] [--yes]
#   scripts/cert-mode.sh untrusted [--dry-run] [--yes]
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VARS_FILE="$REPO_ROOT/group_vars/all.yml"
KEY="substrate_acme_staging"

err() { printf 'cert-mode: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }

usage() {
  sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
}

# Read the current boolean value of the flag from group_vars.
current_bool() {
  local v
  v="$(grep -E "^${KEY}:[[:space:]]" "$VARS_FILE" | head -1 | sed -E "s/^${KEY}:[[:space:]]*([a-zA-Z]+).*/\1/")"
  [ -n "$v" ] || die "could not find '${KEY}:' in $VARS_FILE"
  printf '%s' "$v"
}

# Map a boolean to the trusted/untrusted word.
bool_to_mode() { case "$1" in true) echo untrusted ;; false) echo trusted ;; *) echo "unknown($1)" ;; esac; }

print_status() {
  local b mode
  b="$(current_bool)"; mode="$(bool_to_mode "$b")"
  echo "ACME mode: ${mode}  (${KEY}: ${b})"
  if [ "$mode" = "untrusted" ]; then
    echo "  Endpoint: Let's Encrypt STAGING — issues TEST_CERT (untrusted by browsers)."
    echo "  Switch to real certs with: scripts/cert-mode.sh trusted"
  else
    echo "  Endpoint: Let's Encrypt PRODUCTION — real, browser-valid certs."
    echo "  Switch back to test certs with: scripts/cert-mode.sh untrusted"
  fi
}

set_mode() {
  local want="$1" dry="$2" yes="$3" target_bool cur_bool branch
  case "$want" in
    trusted)   target_bool=false ;;
    untrusted) target_bool=true ;;
    *) die "unknown mode '$want' (expected: trusted | untrusted | status)" ;;
  esac

  cur_bool="$(current_bool)"
  if [ "$cur_bool" = "$target_bool" ]; then
    echo "Already ${want} (${KEY}: ${cur_bool}). Nothing to do."
    return 0
  fi

  echo "Switching ACME mode: $(bool_to_mode "$cur_bool") -> ${want}  (${KEY}: ${cur_bool} -> ${target_bool})"
  if [ "$want" = "trusted" ]; then
    echo "NOTE: real Let's Encrypt has stricter rate limits than staging; issue deliberately."
  fi

  branch="cert-mode-${want}"
  if [ "$dry" = "1" ]; then
    echo
    echo "DRY RUN — no edit, commit, push, or PR. Would:"
    echo "  sed -i '' 's/^${KEY}: ${cur_bool}/${KEY}: ${target_bool}/' group_vars/all.yml"
    echo "  git switch -c ${branch}   # (or reset it to main)"
    echo "  git commit -am 'certs: switch fleet to ${want} ACME endpoint'"
    echo "  git push -u origin ${branch}"
    echo "  gh pr create --base staging"
    return 0
  fi

  command -v git >/dev/null 2>&1 || die "git not found."
  command -v gh  >/dev/null 2>&1 || die "gh not found (needed to open the PR)."
  [ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] || die "working tree is dirty; commit or stash first."

  if [ "$yes" != "1" ]; then
    printf 'Open a PR to switch the fleet to %s certs? [y/N] ' "$want"
    read -r reply
    case "$reply" in y|Y|yes|YES) ;; *) echo "aborted."; return 1 ;; esac
  fi

  git -C "$REPO_ROOT" fetch origin --quiet
  # Branch from the latest main so the PR is a clean single-line change.
  git -C "$REPO_ROOT" switch -C "$branch" origin/main --quiet
  # Portable in-place edit (GNU vs BSD sed).
  if sed --version >/dev/null 2>&1; then
    sed -i "s/^${KEY}: .*/${KEY}: ${target_bool}/" "$VARS_FILE"
  else
    sed -i '' "s/^${KEY}: .*/${KEY}: ${target_bool}/" "$VARS_FILE"
  fi
  git -C "$REPO_ROOT" commit -aqm "certs: switch fleet to ${want} ACME endpoint

Sets ${KEY}: ${target_bool}. On the next reconcile, cert_issuer reissues
the wildcard against the Let's Encrypt $( [ "$want" = trusted ] && echo PRODUCTION || echo STAGING ) endpoint."
  git -C "$REPO_ROOT" push -u origin "$branch" --quiet
  gh pr create --repo sbkt-co/substrate --base staging \
    --title "certs: switch fleet to ${want} ACME endpoint" \
    --body "Sets \`${KEY}: ${target_bool}\` — the fleet will issue **${want}** certificates ($( [ "$want" = trusted ] && echo 'real Let'\''s Encrypt production' || echo 'LE staging TEST_CERT' )) on the next reconcile after this lands and promotes to the tracked branch."
  echo
  echo "PR opened. Merge it, then promote (task ship:promote); cert_issuer reissues on the next reconcile."
}

main() {
  local sub="${1:-}"; shift || true
  local dry=0 yes=0
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      --yes) yes=1 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown argument '$a'" ;;
    esac
  done
  case "$sub" in
    status|"")        print_status ;;
    trusted|untrusted) set_mode "$sub" "$dry" "$yes" ;;
    -h|--help)        usage ;;
    *) usage >&2; die "unknown command '$sub' (expected: status | trusted | untrusted)" ;;
  esac
}

main "$@"
