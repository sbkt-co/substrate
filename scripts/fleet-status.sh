#!/usr/bin/env bash
# fleet-status.sh — one glance at every fleet node's reconcile health.
#
# The fleet is pull-based and tailnet-reachable by hostname (MagicDNS), so this
# is pure observability: for each node it opens a plain `ssh <host>` and prints
# the node's /etc/substrate/status.yml (the last converge result the reconciler
# recorded) and its substrate-reconcile.timer state. Nothing is changed on any
# node — it only reads.
#
# Node discovery: the tracked inventory (inventory/hosts.yml) is deliberately
# just `localhost` (ansible-pull converges each node against itself), so the
# fleet roster lives in host_vars/<hostname>.yml — one file per real node. We
# enumerate those, skipping the *.example.yml templates.
#
# Transport degrades per-node: an unreachable node prints a clear "unreachable"
# line and the loop continues — one dead node never aborts the sweep.
#
# Dependency-free: bash + ssh + awk/sed only.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_VARS_DIR="$REPO_ROOT/host_vars"

# ssh tuning: never hang on a dead node, never prompt interactively. Overridable
# via SSH_OPTS for e.g. a jump host or an alternate user.
SSH_OPTS="${SSH_OPTS:--o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new}"

if [ ! -d "$HOST_VARS_DIR" ]; then
  echo "fleet-status.sh: no host_vars/ directory at $HOST_VARS_DIR" >&2
  exit 1
fi

# Roster: every host_vars/<name>.yml except the *.example.yml templates. The
# hostname is the file's basename with the .yml suffix stripped.
hosts=()
for f in "$HOST_VARS_DIR"/*.yml; do
  [ -e "$f" ] || continue
  case "$f" in
    *.example.yml) continue ;;
  esac
  base="$(basename "$f" .yml)"
  hosts+=("$base")
done

if [ "${#hosts[@]}" -eq 0 ]; then
  echo "fleet-status.sh: no nodes found in $HOST_VARS_DIR (only *.example.yml templates?)."
  exit 0
fi

echo "substrate fleet status — ${#hosts[@]} node(s) from host_vars/ (transport: ssh)"
echo

for host in "${hosts[@]}"; do
  echo "=== $host ==="
  # One round trip per node: read status.yml and the timer state together. The
  # remote script tolerates a missing status file and a non-systemd host so the
  # output is uniform. Local failures (ssh itself) are caught below.
  # SSH_OPTS is intentionally a word-split list of ssh flags, not one argument.
  # shellcheck disable=SC2086
  if out="$(ssh $SSH_OPTS "$host" '
      echo "-- /etc/substrate/status.yml --"
      if [ -r /etc/substrate/status.yml ]; then
        cat /etc/substrate/status.yml
      else
        echo "(absent — node has not recorded a converge yet)"
      fi
      echo "-- substrate-reconcile.timer --"
      if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active substrate-reconcile.timer 2>/dev/null || echo "inactive"
        systemctl list-timers substrate-reconcile.timer --no-pager 2>/dev/null \
          | sed -n "2p" || true
      else
        echo "(systemd not present)"
      fi
    ' 2>/dev/null)"; then
    printf '%s\n' "$out"
  else
    echo "unreachable — ssh $host failed (down, not in the tailnet, or no access)"
  fi
  echo
done
