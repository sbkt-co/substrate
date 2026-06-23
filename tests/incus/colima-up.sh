#!/usr/bin/env bash
#
# Bring up an Incus runtime in its own Colima profile, ALONGSIDE the default
# Docker profile (which is left running and untouched). This is the macOS/Linux
# dev path so the real-converge test (tests/incus/run.sh) runs locally without a
# separate Linux box.
#
# Requires colima >= 0.7 and the incus client:  brew install colima incus
#
# The default Docker runtime stays on the `default` colima profile; Incus lives
# on its own profile, so `docker ...` and `incus ...` work side by side.
#
set -euo pipefail

PROFILE="${SUBSTRATE_COLIMA_PROFILE:-incus}"
CPU="${SUBSTRATE_COLIMA_CPU:-2}"
MEM="${SUBSTRATE_COLIMA_MEMORY:-4}"
DISK="${SUBSTRATE_COLIMA_DISK:-60}"

colima start "$PROFILE" --runtime incus --cpu "$CPU" --memory "$MEM" --disk "$DISK"

echo
echo "Incus runtime ready in colima profile '${PROFILE}'."
echo "Default incus remote: $(incus remote get-default 2>/dev/null || echo '?')"
echo "Default docker profile is unaffected:"
colima list
echo
echo "Run the real-converge test with:  tests/incus/run.sh"
echo "Stop the Incus runtime later with: colima stop ${PROFILE}"
