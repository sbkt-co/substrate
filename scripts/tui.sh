#!/usr/bin/env bash
#
# tui.sh — a thin, discoverable menu over the substrate Taskfile.
#
# This TUI is deliberately NOT a second source of truth. Taskfile.yml (go-task)
# is the single registry of operations; this menu only ever:
#   1. lists tasks via `task --list-all --json`,
#   2. groups them by their namespace prefix (check: ship: node: ...), and
#   3. executes `task <name>` (or previews with `task <name> --dry`).
# There is a structural 1:1 guarantee between what you see here and what `task`
# does — add a task to the Taskfile and it shows up here automatically. Every
# screen prints the "CLI equivalent: task <name>" so using the menu teaches the
# commands.
#
# gum (charmbracelet) is used for prettier menus when installed; otherwise a
# pure-bash numbered picker with identical behaviour is used. The only hard
# dependency beyond `task` is python3 (present on macOS and on the Debian nodes)
# for JSON parsing. Works on macOS bash 3.2 and Linux bash 5 — so NO associative
# arrays (case statements + parallel indexed arrays only).
#
# Var contract with the Taskfile (see task_prompt_spec below): tasks that need an
# identifier read a CLI var this TUI prompts for and passes as `task <name> VAR=..`:
#   node:*  and role:*  -> NAME   (a hostname / role name)
#   staging:logs|shell  -> NODE   (an instance name)
# Secret tasks are handed off interactively: their value is read from the
# underlying script's stdin and is never prompted for or echoed here.
#
# Non-interactive smoke mode for CI/verification:
#   scripts/tui.sh --smoke   # render main menu + every submenu, read no input, exit 0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Ctrl-C anywhere returns a clean exit rather than a stack of partial prompts.
trap 'printf "\n"; exit 130' INT

# --- capability detection -----------------------------------------------------
HAVE_GUM=0
if command -v gum >/dev/null 2>&1; then HAVE_GUM=1; fi

if ! command -v task >/dev/null 2>&1; then
  echo "tui.sh: 'task' (go-task) is not installed. Install from https://taskfile.dev" >&2
  echo "        The TUI is only a menu over the Taskfile; it needs the task binary." >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "tui.sh: python3 is required to parse 'task --list-all --json'." >&2
  exit 1
fi

# --- namespaces (parallel arrays; bash 3.2 has no associative arrays) ----------
# Order mirrors the Taskfile `default` cheat sheet so the menu and `task` agree.
NS_KEYS=(learn setup toolbox check ship node role secret cert staging docs)
NS_LABELS=(Learn Setup Toolbox Check Ship Node Role Secret Cert Staging Docs)
NS_BLURBS=(
  "Understand the system — short lessons"
  "Install the host toolchain (brew bundle) and audit it"
  "Build and enter the portable operator container"
  "Validate, converge-test and doctor the local setup"
  "Promote staging to production (ff-only) and open PRs"
  "Onboard fleet nodes and inspect their status"
  "Scaffold new differentiation role layers"
  "Set a secret in one command (secret:set) and check status"
  "Switch certs trusted/untrusted (real vs test) and check status"
  "Bring up and inspect the local staging fleet"
  "Open and list the reference docs"
)

# Namespaces that only work on the host (they reach the host's Docker/Incus).
# In toolbox mode (SUBSTRATE_TOOLBOX=1) these are flagged in the menu so you are
# not surprised when the wrapped task tells you to run it on the host. staging
# needs the host Incus; toolbox builds/enters images via the host Docker daemon,
# which the container itself cannot reach.
ns_host_only() {
  case "$1" in
    staging|toolbox) return 0 ;;
    *) return 1 ;;
  esac
}

# --- task registry cache ------------------------------------------------------
# Load the whole registry once. `task --list-all --json` already embeds each
# task's desc and summary, so no per-task calls are needed.
JSON_CACHE=""
load_registry() {
  JSON_CACHE="$( (cd "$REPO_ROOT" && task --list-all --json 2>/dev/null) || true )"
  if [ -z "$JSON_CACHE" ]; then
    JSON_CACHE='{"tasks":[]}'
  fi
}

# Emit "name<TAB>desc" for every task whose name starts with "<ns>:".
tasks_in_ns() {
  printf '%s' "$JSON_CACHE" | python3 -c '
import sys, json
ns = sys.argv[1] + ":"
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for t in data.get("tasks", []):
    name = t.get("name", "")
    if name.startswith(ns):
        desc = (t.get("desc") or "").replace("\t", " ").replace("\n", " ")
        print(name + "\t" + desc)
' "$1"
}

# Print the multi-line summary for a single task (empty if none).
summary_of() {
  printf '%s' "$JSON_CACHE" | python3 -c '
import sys, json
name = sys.argv[1]
try:
    data = json.load(sys.stdin)
except ValueError:
    sys.exit(0)
for t in data.get("tasks", []):
    if t.get("name") == name:
        s = (t.get("summary") or "").rstrip()
        if s:
            print(s)
        break
' "$1"
}

# --- per-task metadata the TUI adds on top of the registry --------------------
# A required-var prompt, if any. Echo "VAR|prompt text"; empty when none.
task_prompt_spec() {
  case "$1" in
    node:add)                echo "NAME|New node hostname (lowercase DNS label, e.g. web-3)" ;;
    node:status)             echo "NODE|Staging instance name (e.g. staging-core)" ;;
    role:new)                echo "NAME|New role name (lowercase, [a-z0-9_], e.g. metrics_agent)" ;;
    secret:set)              echo "NAME|Secret name (cloudflare-dns | acme | tailnet-authkey)" ;;
    cert:mode)               echo "MODE|Cert mode (trusted = real | untrusted = test)" ;;
    staging:logs)            echo "NODE|Staging instance name (e.g. staging-core)" ;;
    staging:shell)           echo "NODE|Staging instance name (e.g. staging-core)" ;;
    docs:open)               echo "FILE|Doc name to open (see docs:list, e.g. runbook)" ;;
    *) : ;;
  esac
}

# An advisory note shown on the task screen, if any.
task_note() {
  case "$1" in
    secret:set)
      echo "The one command: after NAME, the script asks for the VALUE with a HIDDEN prompt (or pipe it in), then opens a PR. The value is never echoed and never in argv." ;;
    secret:status)
      echo "Read-only: shows each secret's recipients and on-node state. Changes nothing." ;;
    secret:*)
      echo "Interactive: the secret VALUE is read from the underlying script's stdin and is never shown here." ;;
    ship:promote)
      echo "Safe by default: promote is a dry run unless the task/flags opt into the push." ;;
    *) : ;;
  esac
}

# One contextual teaching line printed after a task exits non-zero. We cannot
# capture the task's output (it streams straight to the TTY so interactive tasks
# work), so we map the common failure by task name and fall back to --summary.
failure_hint() {
  local name="$1"
  printf '\n' >&2
  case "$name" in
    ship:pr|ship:promote|ship:promote-dry)
      printf 'hint: dirty or diverged tree? commit or stash first — substrate never discards your work.\n' >&2 ;;
    check:*)
      printf 'hint: a tool may be missing — audit your setup with: task check:doctor\n' >&2 ;;
    node:add|role:new)
      printf 'hint: this task needs NAME= — usage: task %s NAME=<name>\n' "$name" >&2 ;;
    node:status|staging:logs|staging:shell)
      printf 'hint: this task needs NODE= — usage: task %s NODE=<instance>  (e.g. staging-core)\n' "$name" >&2 ;;
    staging:*)
      printf 'hint: staging needs Incus up — on macOS run tests/incus/colima-up.sh, then task staging:up.\n' >&2 ;;
    *)
      printf 'hint: see exactly what this task runs with: task %s --summary\n' "$name" >&2 ;;
  esac
}

# A one-time, gentle first-run notice (interactive path only). Prints at most one
# line and never nags again in the same run.
first_run_notice() {
  if [ "$HAVE_GUM" = 0 ]; then
    printf 'tip: gum is not installed — this menu works fine without it. For the nicer UI: task setup:host\n\n' >&2
  fi
}

# --- presentation helpers -----------------------------------------------------
header() {
  local title="$1"
  # A persistent badge so you always know you are inside the toolbox container
  # (where host-only tasks — Incus/Docker — will defer to the host).
  if [ "${SUBSTRATE_TOOLBOX:-0}" = "1" ]; then
    title="${title}   [toolbox mode]"
  fi
  if [ "$HAVE_GUM" = 1 ]; then
    gum style --border normal --margin "0 0" --padding "0 1" --bold "$title"
  else
    printf '\n== %s ==\n' "$title"
  fi
}

hint() { printf '   CLI equivalent: task %s\n' "$1"; }

# Generic picker. Input: PICK_LABELS array + a header string.
# Output: PICK_RESULT = chosen 0-based index, or -1 for cancel/back/EOF.
PICK_RESULT=-1
pick() {
  local header_text="$1"
  local i choice l
  if [ "$HAVE_GUM" = 1 ]; then
    if ! choice="$(printf '%s\n' "${PICK_LABELS[@]}" | gum choose --header "$header_text")"; then
      PICK_RESULT=-1; return 0
    fi
    i=0
    for l in "${PICK_LABELS[@]}"; do
      if [ "$l" = "$choice" ]; then PICK_RESULT=$i; return 0; fi
      i=$((i + 1))
    done
    PICK_RESULT=-1
  else
    printf '%s\n' "$header_text" >&2
    i=1
    for l in "${PICK_LABELS[@]}"; do
      printf '  %2d) %s\n' "$i" "$l" >&2
      i=$((i + 1))
    done
    local ans
    printf 'Select a number> ' >&2
    if ! read -r ans; then PICK_RESULT=-1; return 0; fi
    case "$ans" in
      ''|*[!0-9]*) PICK_RESULT=-1; return 0 ;;
    esac
    if [ "$ans" -ge 1 ] && [ "$ans" -le "${#PICK_LABELS[@]}" ]; then
      PICK_RESULT=$((ans - 1))
    else
      PICK_RESULT=-1
    fi
  fi
}

# Confirm helper (gum confirm, else y/N read).
confirm() {
  local prompt="$1"
  if [ "$HAVE_GUM" = 1 ]; then
    gum confirm "$prompt" && return 0 || return 1
  fi
  local ans
  printf '%s [y/N] ' "$prompt" >&2
  read -r ans || return 1
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# --- running a task -----------------------------------------------------------
# Collect any prompted vars for a task into the RUN_VARS array (may be empty).
RUN_VARS=()
collect_vars() {
  RUN_VARS=()
  local spec var prompt val
  spec="$(task_prompt_spec "$1")"
  [ -n "$spec" ] || return 0
  var="${spec%%|*}"
  prompt="${spec#*|}"
  printf '%s\n' "$prompt" >&2
  printf '%s= ' "$var" >&2
  read -r val || return 0
  if [ -n "$val" ]; then
    RUN_VARS+=("${var}=${val}")
  fi
}

# Execute `task <name> [VARS...]`, foreground so stdin/tty pass through (this is
# what lets interactive tasks — e.g. secret seeding — read their value directly).
exec_task() {
  local name="$1"; shift
  local rc=0
  if [ "$#" -gt 0 ]; then
    ( cd "$REPO_ROOT" && task "$name" "$@" ) || rc=$?
  else
    ( cd "$REPO_ROOT" && task "$name" ) || rc=$?
  fi
  return "$rc"
}

# --- screens ------------------------------------------------------------------
task_screen() {
  local name="$1"
  local summary note
  while :; do
    header "Task: ${name}"
    summary="$(summary_of "$name")"
    if [ -n "$summary" ]; then
      printf '%s\n' "$summary"
    else
      printf '(no summary provided for this task)\n'
    fi
    note="$(task_note "$name")"
    [ -n "$note" ] && printf '\nNote: %s\n' "$note"
    printf '\n'
    hint "$name"
    printf '\n'

    PICK_LABELS=("Run this task" "Preview (task ${name} --dry)" "Back")
    pick "What now?"
    case "$PICK_RESULT" in
      0)  # run
        collect_vars "$name"
        printf '\n'
        local rc=0
        if [ "${#RUN_VARS[@]}" -gt 0 ]; then
          exec_task "$name" "${RUN_VARS[@]}" || rc=$?
        else
          exec_task "$name" || rc=$?
        fi
        printf '\n--- task %s exited with status %d ---\n' "$name" "$rc"
        [ "$rc" -ne 0 ] && failure_hint "$name"
        printf 'Press enter to return. '
        read -r _ || true
        ;;
      1)  # preview
        printf '\n'
        local rc=0
        exec_task "$name" --dry || rc=$?
        printf '\n--- preview exited with status %d ---\n' "$rc"
        printf 'Press enter to return. '
        read -r _ || true
        ;;
      *) return 0 ;;  # Back / cancel
    esac
  done
}

submenu() {
  local ns="$1" label="$2" blurb="$3"
  local names labels n d
  while :; do
    names=(); labels=()
    while IFS="$(printf '\t')" read -r n d; do
      [ -n "$n" ] || continue
      names+=("$n")
      if [ -n "$d" ]; then
        labels+=("${n}  —  ${d}")
      else
        labels+=("${n}")
      fi
    done < <(tasks_in_ns "$ns")

    header "${label} — ${blurb}"
    if [ "${#names[@]}" -eq 0 ]; then
      printf 'No tasks defined in the %s: namespace yet.\n' "$ns"
      printf 'Press enter to go back. '
      read -r _ || true
      return 0
    fi

    PICK_LABELS=("${labels[@]}" "Back")
    pick "Select a ${ns}: task"
    if [ "$PICK_RESULT" -lt 0 ] || [ "$PICK_RESULT" -ge "${#names[@]}" ]; then
      return 0  # Back / cancel
    fi
    task_screen "${names[$PICK_RESULT]}"
  done
}

main_menu() {
  local i labels
  while :; do
    header "substrate — operations menu"
    printf 'One menu over the Taskfile. Everything here maps 1:1 to a "task <name>" command.\n'

    labels=()
    i=0
    while [ "$i" -lt "${#NS_KEYS[@]}" ]; do
      local row="${NS_LABELS[$i]}  —  ${NS_BLURBS[$i]}"
      if [ "${SUBSTRATE_TOOLBOX:-0}" = "1" ] && ns_host_only "${NS_KEYS[$i]}"; then
        row="${row}  (host-only)"
      fi
      labels+=("$row")
      i=$((i + 1))
    done
    PICK_LABELS=("${labels[@]}" "Quit")

    pick "Choose an area"
    if [ "$PICK_RESULT" -lt 0 ] || [ "$PICK_RESULT" -ge "${#NS_KEYS[@]}" ]; then
      printf 'Bye.\n'
      return 0  # Quit / cancel
    fi
    submenu "${NS_KEYS[$PICK_RESULT]}" "${NS_LABELS[$PICK_RESULT]}" "${NS_BLURBS[$PICK_RESULT]}"
  done
}

# --- smoke mode ---------------------------------------------------------------
# Render the main menu and every submenu to stdout, read no input, exit 0.
# Used by CI to prove the whole menu tree builds from the registry.
smoke() {
  local i n d ns label title
  title="substrate — operations menu"
  # Mirror the interactive header's toolbox badge so a --smoke run inside the
  # container visibly proves it is in toolbox mode.
  if [ "${SUBSTRATE_TOOLBOX:-0}" = "1" ]; then
    title="${title}   [toolbox mode]"
  fi
  printf '== %s ==\n' "$title"
  i=0
  while [ "$i" -lt "${#NS_KEYS[@]}" ]; do
    printf '  %d) %s  —  %s\n' "$((i + 1))" "${NS_LABELS[$i]}" "${NS_BLURBS[$i]}"
    i=$((i + 1))
  done
  printf '  %d) Quit\n' "$(( ${#NS_KEYS[@]} + 1 ))"

  i=0
  while [ "$i" -lt "${#NS_KEYS[@]}" ]; do
    ns="${NS_KEYS[$i]}"
    label="${NS_LABELS[$i]}"
    printf '\n== %s — %s ==\n' "$label" "${NS_BLURBS[$i]}"
    local any=0
    while IFS="$(printf '\t')" read -r n d; do
      [ -n "$n" ] || continue
      any=1
      if [ -n "$d" ]; then
        printf '  - %s  —  %s\n' "$n" "$d"
      else
        printf '  - %s\n' "$n"
      fi
      printf '      CLI equivalent: task %s\n' "$n"
    done < <(tasks_in_ns "$ns")
    [ "$any" -eq 1 ] || printf '  (no tasks defined in %s: yet)\n' "$ns"
    i=$((i + 1))
  done
  return 0
}

# --- entrypoint ---------------------------------------------------------------
main() {
  load_registry
  case "${1:-}" in
    --smoke) smoke; exit 0 ;;
    -h|--help)
      cat <<'EOF'
Usage: scripts/tui.sh [--smoke]

  (no args)  launch the interactive menu over the Taskfile.
  --smoke    render the whole menu tree to stdout without reading input; exit 0.

The menu only ever runs `task <name>` / `task <name> --dry`. Taskfile.yml is the
single source of truth; run `task --list-all` to see the same tasks on the CLI.
EOF
      exit 0 ;;
    "") : ;;
    *) echo "tui.sh: unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  first_run_notice
  main_menu
}

main "$@"
