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
# Build the transient bake container in a DEDICATED project, never the shared
# `default` project (same isolation principle as run.sh / staging/up.sh): a
# collision with an unrelated instance named `bake` in `default` would otherwise
# be force-deleted. features.images=false shares the host image store, so the
# published `substrate-base` alias still lands where run.sh reads it.
BAKE_PROJECT="${SUBSTRATE_PREBAKE_PROJECT:-substrate-prebake}"
mkdir -p "$CACHE_DIR"

incus_in() { local sub="$1"; shift; incus "$sub" --project "$BAKE_PROJECT" "$@"; }

emit() {
    [ -n "${GITHUB_ENV:-}" ] && echo "SUBSTRATE_TEST_IMAGE=$1" >>"$GITHUB_ENV"
    echo "node image for converge: $1"
}

# Fast path for a persistent (self-hosted) runner: the prebaked image is already
# in the local Incus store from a previous run, so just reuse it.
if incus image info "$ALIAS" >/dev/null 2>&1; then
    emit "$ALIAS"
    exit 0
fi

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
    incus project show "$BAKE_PROJECT" >/dev/null 2>&1 \
        || incus project create "$BAKE_PROJECT" -c features.profiles=false -c features.images=false >/dev/null
    incus_in delete --force bake >/dev/null 2>&1 || true
    incus_in launch "$BASE" bake
    for _ in $(seq 1 60); do
        s="$(incus_in exec bake -- systemctl is-system-running 2>/dev/null || true)"
        case "$s" in running | degraded) break ;; esac
        sleep 2
    done
    incus_in exec bake -- sh -c 'apt-get update -qq && apt-get install -y -qq python3 sudo ca-certificates'
    incus_in stop bake
    incus_in publish bake --alias "$ALIAS" >/dev/null
    incus_in delete --force bake >/dev/null
    rm -f "$CACHE_DIR"/*.tar.gz
    incus image export "$ALIAS" "$CACHE_DIR/$ALIAS" >/dev/null
}

if build; then
    emit "$ALIAS"
else
    echo "prebake failed; falling back to $BASE (test will apt-install in-container)" >&2
    incus_in delete --force bake >/dev/null 2>&1 || true
    emit "$BASE"
fi
# Drop the dedicated bake project if we left it empty (never force-remove one
# someone else populated).
incus project delete "$BAKE_PROJECT" >/dev/null 2>&1 || true
exit 0
