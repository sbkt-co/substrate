#!/usr/bin/env bash
#
# Produce a local Incus image `substrate-base` = the base node image plus python3
# and sudo, so the converge test needs no in-container apt (faster, and removes
# the container's network dependency at test time). Intended for CI, where the
# resulting tarball is cached across runs.
#
# Safety: on ANY failure this falls back to the public base image, so it can
# never break the build — at worst the test does its own apt install as before.
# It writes the chosen image to $GITHUB_ENV as SUBSTRATE_TEST_IMAGE.
#
set -uo pipefail

CACHE_DIR="${SUBSTRATE_IMAGE_CACHE_DIR:-/tmp/incus-image}"
ALIAS="${SUBSTRATE_BASE_ALIAS:-substrate-base}"
BASE="${SUBSTRATE_BASE_IMAGE:-images:debian/trixie}"
mkdir -p "$CACHE_DIR"

emit() {
    [ -n "${GITHUB_ENV:-}" ] && echo "SUBSTRATE_TEST_IMAGE=$1" >>"$GITHUB_ENV"
    echo "node image for converge: $1"
}

# Cache hit: import the prebaked tarball and use it.
tarball="$(ls "$CACHE_DIR"/*.tar.gz 2>/dev/null | head -1 || true)"
if [ -n "$tarball" ]; then
    if incus image import "$tarball" --alias "$ALIAS" >/dev/null 2>&1; then
        emit "$ALIAS"
        exit 0
    fi
    echo "import of cached image failed; rebuilding" >&2
fi

# Cache miss: build the prebaked image. Any failure -> fall back to the public base.
build() {
    set -e
    incus delete --force bake >/dev/null 2>&1 || true
    incus launch "$BASE" bake
    for _ in $(seq 1 60); do
        s="$(incus exec bake -- systemctl is-system-running 2>/dev/null || true)"
        case "$s" in running | degraded) break ;; esac
        sleep 2
    done
    incus exec bake -- sh -c 'apt-get update -qq && apt-get install -y -qq python3 sudo ca-certificates'
    incus stop bake
    incus publish bake --alias "$ALIAS" >/dev/null
    incus delete --force bake >/dev/null
    rm -f "$CACHE_DIR"/*.tar.gz
    incus image export "$ALIAS" "$CACHE_DIR/$ALIAS" >/dev/null
}

if build; then
    emit "$ALIAS"
else
    echo "prebake failed; falling back to $BASE (test will apt-install in-container)" >&2
    incus delete --force bake >/dev/null 2>&1 || true
    emit "$BASE"
fi
exit 0
