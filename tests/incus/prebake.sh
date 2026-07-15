#!/usr/bin/env bash
#
# Produce a local Incus image `substrate-base` = the base node image plus python3
# and sudo, so the converge test needs no in-container apt (faster, and removes
# the container's network dependency at test time). Intended for CI, where the
# resulting tarball is cached across runs.
#
# Freshness: the baked image carries a content FINGERPRINT (a hash of the pinned
# base image id + the prereq package list below) and its build date as image
# properties. A persistent (self-hosted) runner reuses the baked image only while
# the stored fingerprint matches the computed one AND the image is younger than
# SUBSTRATE_IMAGE_MAX_AGE_DAYS — otherwise it rebuilds automatically, so a bumped
# base image, an edited prereq list, or plain base-image security drift all
# propagate without a manual cache-key bump or alias deletion.
#
# Safety: on ANY failure this falls back to the public base image, so it can
# never break the build — at worst the test does its own apt install as before.
# It writes the chosen image to $GITHUB_ENV as SUBSTRATE_TEST_IMAGE.
#
set -euo pipefail

CACHE_DIR="${SUBSTRATE_IMAGE_CACHE_DIR:-/tmp/incus-image}"
ALIAS="${SUBSTRATE_BASE_ALIAS:-substrate-base}"
BASE="${SUBSTRATE_BASE_IMAGE:-images:debian/trixie}"
# Rebake a persistent image once it is older than this many days, so base-image
# security updates propagate even when nothing in this script changed.
MAX_AGE_DAYS="${SUBSTRATE_IMAGE_MAX_AGE_DAYS:-14}"
# The prereq package list baked into the image. This is the single source of
# truth: it is both installed at bake time AND folded into the fingerprint, so
# editing it forces a rebuild.
PREREQ_PACKAGES="python3 sudo ca-certificates"
# Build the transient bake container in a DEDICATED project, never the shared
# `default` project (same isolation principle as run.sh / staging/up.sh): a
# collision with an unrelated instance named `bake` in `default` would otherwise
# be force-deleted. features.images=false shares the host image store, so the
# published `substrate-base` alias still lands where run.sh reads it.
BAKE_PROJECT="${SUBSTRATE_PREBAKE_PROJECT:-substrate-prebake}"
mkdir -p "$CACHE_DIR"

# Content fingerprint of everything that determines the image's contents: the
# pinned base image identifier plus the prereq package list. A change to either
# yields a different hash, which invalidates both the CI cache key (ci.yml embeds
# the same computed value) and the reuse check below.
FINGERPRINT="$(printf '%s\n%s\n' "$BASE" "$PREREQ_PACKAGES" | sha256sum | cut -c1-16)"

# If asked only for the fingerprint (ci.yml computes the cache-key suffix this
# way, from the same package list, so the two never drift), print it and stop.
if [ "${1:-}" = "--print-fingerprint" ]; then
    echo "$FINGERPRINT"
    exit 0
fi

incus_in() { local sub="$1"; shift; incus "$sub" --project "$BAKE_PROJECT" "$@"; }

emit() {
    [ -n "${GITHUB_ENV:-}" ] && echo "SUBSTRATE_TEST_IMAGE=$1" >>"$GITHUB_ENV"
    echo "node image for converge: $1"
}

# Read a user.* property off the baked image ("" if absent / image missing).
image_prop() { incus image get-property "$ALIAS" "$1" 2>/dev/null || true; }

# Is the persistent baked image still usable? Reusable iff it exists, its stored
# fingerprint matches the computed one, and it is younger than MAX_AGE_DAYS.
image_is_fresh() {
    incus image info "$ALIAS" >/dev/null 2>&1 || return 1

    local stored built now age_days
    stored="$(image_prop user.substrate.fingerprint)"
    if [ "$stored" != "$FINGERPRINT" ]; then
        echo "prebaked image fingerprint '$stored' != computed '$FINGERPRINT'; rebuilding" >&2
        return 1
    fi

    built="$(image_prop user.substrate.built_epoch)"
    if [ -z "$built" ]; then
        echo "prebaked image has no build stamp; rebuilding" >&2
        return 1
    fi
    now="$(date +%s)"
    age_days=$(( (now - built) / 86400 ))
    if [ "$age_days" -ge "$MAX_AGE_DAYS" ]; then
        echo "prebaked image is ${age_days}d old (>= ${MAX_AGE_DAYS}d); rebuilding for base updates" >&2
        return 1
    fi
    return 0
}

# Fast path for a persistent (self-hosted) runner: reuse the already-baked image
# when it is still fresh; otherwise fall through and rebuild.
if image_is_fresh; then
    emit "$ALIAS"
    exit 0
fi

# A stale-but-present persistent image must go before we rebuild, else the
# publish below would collide with the existing alias.
if incus image info "$ALIAS" >/dev/null 2>&1; then
    incus image delete "$ALIAS" >/dev/null 2>&1 || true
fi

# Cache hit: import the prebaked tarball and use it — but only if the imported
# image is itself fresh (the tarball carries the same properties). A stale
# tarball is discarded so we rebuild rather than resurrect an outdated image.
tarball="$(ls "$CACHE_DIR"/*.tar.gz 2>/dev/null | head -1 || true)"
if [ -n "$tarball" ]; then
    if incus image import "$tarball" --alias "$ALIAS" >/dev/null 2>&1; then
        if image_is_fresh; then
            emit "$ALIAS"
            exit 0
        fi
        echo "cached tarball is stale; discarding and rebuilding" >&2
        incus image delete "$ALIAS" >/dev/null 2>&1 || true
    else
        echo "import of cached image failed; rebuilding" >&2
    fi
fi

# Cache miss / stale: build the prebaked image. Any failure -> fall back to the
# public base. Wrapped in a subshell so its local `set -e` cannot leak, and so a
# mid-build failure returns non-zero to the fallback branch without aborting the
# whole (set -e) script.
build() (
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
    incus_in exec bake -- sh -c "apt-get update -qq && apt-get install -y -qq $PREREQ_PACKAGES"
    incus_in stop bake
    # Stamp the freshness metadata onto the published image so future runs can
    # decide whether to reuse it. Properties survive export/import in the tarball.
    incus_in publish bake --alias "$ALIAS" \
        "user.substrate.fingerprint=$FINGERPRINT" \
        "user.substrate.built_epoch=$(date +%s)" >/dev/null
    incus_in delete --force bake >/dev/null
    rm -f "$CACHE_DIR"/*.tar.gz
    incus image export "$ALIAS" "$CACHE_DIR/$ALIAS" >/dev/null
)

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
