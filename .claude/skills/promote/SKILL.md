---
name: promote
description: Promote staging to production (main) by fast-forward. Use when the user wants to ship, deploy, promote, or release staging to prod.
---

# Promote staging -> main

Promotion is a strict fast-forward of `main` to the tip of `staging` (see
CONTRIBUTING.md). Never merge-commit, never force. `scripts/promote.sh` enforces
the ff-only semantics and refuses a dirty tree or a diverged branch.

Steps:

1. Run the dry run and show the user the delta:

   ```sh
   scripts/promote.sh --dry-run
   ```

   This fetches origin, prints the `main..staging` commit log and the exact push
   command, and pushes nothing.

2. Show the user what would ship (the commit list) and ask them to confirm.

3. Only on their explicit confirmation, execute:

   ```sh
   scripts/promote.sh --yes
   ```

   It performs `git push origin origin/staging:main` (ff-only) and prints what
   shipped.

Do not run `--yes` without showing the delta first. If the script reports the
branches diverged, do NOT force — surface it; staging needs a rebase onto main.
