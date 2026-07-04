#!/usr/bin/env bash
# new-role.sh <role_name> — scaffold a new differentiation role from templates.
#
# Creates roles/<name>/{defaults,tasks,handlers}/main.yml from the templates in
# scripts/templates/role/, substituting the role name into the load-bearing
# patterns (FQCN modules, the systemd guard, the skip-loudly secret stat with
# no_log, quoted file modes, a guarded restart handler). Refuses to overwrite an
# existing role. After scaffolding, edit the TODOs and follow the checklist in
# docs/architecture.md section 5.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/templates/role"

usage() {
  cat <<'EOF'
Usage: scripts/new-role.sh <role_name>

  <role_name>   lowercase, starts with a letter, [a-z0-9_] only
                (e.g. metrics_agent, webserver).

Scaffolds roles/<role_name>/{defaults,tasks,handlers}/main.yml from
scripts/templates/role/. Refuses to overwrite an existing role.
EOF
}

case "${1:-}" in
  -h|--help|"") usage; [ "${1:-}" = "" ] && exit 2 || exit 0 ;;
esac

ROLE="$1"; shift || true
if [ "$#" -gt 0 ]; then
  echo "new-role.sh: unexpected extra arguments: $*" >&2; usage >&2; exit 2
fi

if ! printf '%s' "$ROLE" | grep -Eq '^[a-z][a-z0-9_]*$'; then
  echo "new-role.sh: invalid role name '$ROLE'." >&2
  echo "Use lowercase, start with a letter, only [a-z0-9_]." >&2
  exit 2
fi

ROLE_PATH="$REPO_ROOT/roles/$ROLE"
if [ -e "$ROLE_PATH" ]; then
  echo "new-role.sh: roles/$ROLE already exists; refusing to overwrite." >&2
  exit 1
fi

if [ ! -d "$TEMPLATE_DIR" ]; then
  echo "new-role.sh: template dir not found: $TEMPLATE_DIR" >&2
  exit 1
fi

for sub in defaults tasks handlers; do
  src="$TEMPLATE_DIR/$sub/main.yml"
  dst="$ROLE_PATH/$sub/main.yml"
  if [ ! -f "$src" ]; then
    echo "new-role.sh: missing template: $src" >&2
    exit 1
  fi
  mkdir -p "$ROLE_PATH/$sub"
  # __ROLE__ is the only placeholder; substitute it for the real role name.
  sed "s/__ROLE__/${ROLE}/g" "$src" > "$dst"
done

echo "Scaffolded roles/$ROLE:"
find "$ROLE_PATH" -type f | sort | sed "s#^$REPO_ROOT/#  #"
cat <<EOF

Next:
  1. Edit the TODOs in roles/$ROLE/tasks/main.yml and defaults/main.yml.
  2. Run tests/run.sh (lint + syntax + check-mode).
  3. Wire it in: add '$ROLE' to node_roles in host_vars/<hostname>.yml.
  See docs/architecture.md section 5 for the full checklist.
EOF
