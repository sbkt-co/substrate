#!/usr/bin/env bash
#
# Build the test image and run the validation suite against the current working
# tree (mounted, so edits are picked up without rebuilding the image).
#
# Usage:
#   tests/run.sh                       # full suite
#   tests/run.sh ansible-lint roles/   # ad-hoc command in the toolchain
#
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${SUBSTRATE_CI_IMAGE:-substrate-ci}"

docker build -f tests/Dockerfile -t "$IMAGE" .
exec docker run --rm -v "$PWD":/substrate "$IMAGE" "$@"
