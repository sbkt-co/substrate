#!/usr/bin/env bash
# promote.sh — fast-forward promote staging -> main (the control-plane deploy).
#
# Environments are branches: main = production, staging = pre-prod. Promotion is
# a strict fast-forward of main to staging's tip, so the two never diverge. This
# script refuses anything that is not ff-able and never force-pushes.
#
# Default is a DRY RUN: it prints the delta and the exact push command without
# touching origin. Pass --yes to actually push.
set -euo pipefail

REMOTE="origin"
SRC="staging"   # promote from
DST="main"      # promote to
DO_PUSH=0

usage() {
  cat <<'EOF'
Usage: scripts/promote.sh [--dry-run|--yes] [-h|--help]

  --dry-run   (default) show staging..main delta and the exact push command;
              do not push.
  --yes       execute the fast-forward push of origin/staging -> origin/main.

Fast-forward only. Aborts if the working tree is dirty or if main is not an
ancestor of staging (i.e. the promotion would not be a clean ff).
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DO_PUSH=0 ;;
    --yes)     DO_PUSH=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "promote.sh: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# 1. Refuse to operate on a dirty tree — promotion must be reproducible from git.
if [ -n "$(git status --porcelain)" ]; then
  echo "promote.sh: working tree is not clean; commit or stash first." >&2
  git status --short >&2
  exit 1
fi

# 2. Get authoritative refs.
echo "Fetching ${REMOTE}..." >&2
git fetch --quiet "$REMOTE" "$SRC" "$DST"

SRC_REF="${REMOTE}/${SRC}"
DST_REF="${REMOTE}/${DST}"

src_sha="$(git rev-parse "$SRC_REF")"
dst_sha="$(git rev-parse "$DST_REF")"

# 3. Already up to date?
if [ "$src_sha" = "$dst_sha" ]; then
  echo "Nothing to promote: ${DST_REF} already equals ${SRC_REF} (${src_sha:0:12})."
  exit 0
fi

# 4. Confirm ff: main must be an ancestor of staging.
if ! git merge-base --is-ancestor "$DST_REF" "$SRC_REF"; then
  echo "promote.sh: ${DST_REF} is NOT an ancestor of ${SRC_REF}." >&2
  echo "The branches have diverged; a fast-forward is impossible." >&2
  echo "Rebase ${SRC} onto ${DST} and re-run. Never force the merge." >&2
  exit 1
fi

# 5. Show what would ship.
echo
echo "Promoting ${SRC} -> ${DST} (fast-forward). Commits shipping to ${DST}:"
echo "-------------------------------------------------------------------"
git log --oneline "${DST_REF}..${SRC_REF}"
echo "-------------------------------------------------------------------"
count="$(git rev-list --count "${DST_REF}..${SRC_REF}")"
echo "${count} commit(s): ${dst_sha:0:12} -> ${src_sha:0:12}"
echo

PUSH_CMD="git push ${REMOTE} ${SRC_REF}:${DST}"

if [ "$DO_PUSH" -eq 0 ]; then
  echo "DRY RUN — nothing pushed. To promote, run:"
  echo "  ${PUSH_CMD}"
  echo "or re-run: scripts/promote.sh --yes"
  exit 0
fi

echo "Executing: ${PUSH_CMD}"
# origin/staging:main is inherently ff-only server-side unless forced; we never
# pass --force.
eval "$PUSH_CMD"
echo
echo "Promoted. ${DST} is now at ${src_sha:0:12}. Shipped ${count} commit(s)."
