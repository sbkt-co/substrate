# Brewfile — the macOS host toolchain for operating substrate.
#
# This is the PRIMARY, host-native path on macOS. Install it with:
#   brew bundle              # (or `task setup:host`, which wraps this + doctor)
#
# Why host-native and not a container on macOS: the `./substrate` TUI needs a real
# native TTY (gum menus + interactive task prompts), and the staging fleet talks to
# the Colima-hosted Incus socket on this Mac. A Linux container cannot reach the
# host's TTY or that Incus socket cleanly, so the day-to-day driver lives on the host.
# The toolbox/ image is the fallback for lint/PR work on machines without Homebrew.
#
# Each line notes WHY the tool is here. Cross-check the same set with `task check:doctor`.

brew "go-task"    # the `task` runner — single source of truth for every operation (Taskfile.yml)
brew "gum"        # Charm gum: pretty `./substrate` menus + prompts (optional; pure-bash fallback exists)
brew "sops"       # secret encryption for the (pending) sops-based secret:encrypt/rotate distribution
brew "age"        # modern encryption backend paired with sops (keys, recipients)
brew "uv"         # the Python toolchain — installs pinned ansible-core (uv tool install ansible-core==2.18.6)
brew "gh"         # GitHub CLI — opens PRs (ship:pr) against the GitHub control plane
brew "colima"     # hosts the Linux VM that runs Incus on macOS, in its own profile (tests/incus/colima-up.sh)
brew "incus"      # models fleet nodes as system containers for staging:* and check:converge
brew "shellcheck" # lints the bash under scripts/ (tui.sh, promote.sh, ...) — keep the launcher clean
