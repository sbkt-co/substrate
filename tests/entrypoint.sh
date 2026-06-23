#!/usr/bin/env bash
#
# Validation suite for the substrate control plane. Runs identically on a
# developer laptop (via tests/run.sh) and in CI (.github/workflows/ci.yml).
#
# Pass a command to bypass the suite and run it in the toolchain, e.g.:
#   docker run --rm substrate-ci ansible-lint roles/reconciler
#
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$#" -gt 0 ]; then
    exec "$@"
fi

run() {
    printf '\n\033[1m== %s ==\033[0m\n' "$1"
    shift
    "$@"
}

run "yamllint"          yamllint .
run "ansible-lint"      ansible-lint
run "syntax-check"      ansible-playbook --syntax-check local.yml
run "check-mode converge (localhost)" \
    ansible-playbook -i inventory/hosts.yml --connection=local --check local.yml

printf '\n\033[1;32mAll validation checks passed.\033[0m\n'
