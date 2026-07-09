# toolbox/Dockerfile — a portable "operator shell" for substrate.
#
# This is the FALLBACK path for hosts without Homebrew (or a stock Linux box / CI):
# it packages the same operational surface as the macOS Brewfile into one image so
# you can lint, run tasks, browse the ./substrate menu, encrypt secrets, and open
# PRs anywhere Docker runs. On macOS the host-native Brewfile stays primary (the TUI
# needs a real TTY and staging needs the Colima Incus socket — see toolbox:shell).
#
# Build (from repo root):   docker build -f toolbox/Dockerfile -t substrate-toolbox .
#                           (or `task toolbox:build`)
# Enter the menu:           docker run -it --rm -v "$PWD":/substrate substrate-toolbox
#                           (or `task toolbox:shell`)
# Drop to a shell instead:  docker run -it --rm -v "$PWD":/substrate substrate-toolbox bash
#
# WHAT WORKS inside: ansible-lint / yamllint / ansible-playbook --syntax-check via the
#   pinned toolchain, `task <name>` and the ./substrate TUI, sops+age encryption,
#   `gh` PRs and git. WHAT DOES NOT: check:validate (needs the host Docker daemon),
#   check:converge and staging:* (need the host's Incus). Those tasks detect this
#   image via SUBSTRATE_TOOLBOX=1 and tell you to run them on the host.
#
# Multi-arch: buildable on an arm64 Mac and amd64 CI. TARGETARCH is supplied by
# BuildKit/buildx (amd64|arm64); it is defaulted for plain `docker build` too.
FROM debian:trixie-slim

# Provided by buildx; default to the build host's arch for a plain `docker build`.
ARG TARGETARCH

# Pinned tool versions — bump deliberately, like tests/requirements.txt. roles/common
# pins no sops/age versions, so these track current upstream stable (2026) and are
# documented here as the single place to bump.
ARG TASK_VERSION=v3.52.0
ARG SOPS_VERSION=v3.13.2
ARG AGE_VERSION=v1.3.1

ENV DEBIAN_FRONTEND=noninteractive \
    UV_NO_CACHE=1 \
    ANSIBLE_FORCE_COLOR=1 \
    SUBSTRATE_TOOLBOX=1

# uv is the Python installer/resolver (pinned, reproducible) — same as tests/Dockerfile.
COPY --from=ghcr.io/astral-sh/uv:0.8.22 /uv /uvx /usr/local/bin/

# Base OS tooling: git/python3/less for the TUI + git workflows, gnupg+curl to add
# the Charm (gum) and GitHub (gh) apt repos, ca-certificates for TLS fetches.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg \
      git python3 python3-apt less sudo \
 && rm -rf /var/lib/apt/lists/*

# gum from the Charm apt repo; gh from GitHub's official apt repo. Both are multi-arch.
RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://repo.charm.sh/apt/gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/charm.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" \
      > /etc/apt/sources.list.d/charm.list \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gum gh \
 && rm -rf /var/lib/apt/lists/*

# go-task — pinned release tarball, arch-aware. Ships the `task` binary; the TUI and
# every operation route through it.
RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
 && curl -fsSL "https://github.com/go-task/task/releases/download/${TASK_VERSION}/task_linux_${arch}.tar.gz" \
      -o /tmp/task.tar.gz \
 && tar -xzf /tmp/task.tar.gz -C /usr/local/bin task \
 && rm /tmp/task.tar.gz \
 && task --version

# sops — pinned single binary, arch-aware (secret encryption for secret:encrypt/rotate).
RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
 && curl -fsSL "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${arch}" \
      -o /usr/local/bin/sops \
 && chmod 0755 /usr/local/bin/sops \
 && sops --version

# age + age-keygen — pinned tarball, arch-aware (encryption backend paired with sops).
RUN arch="${TARGETARCH:-$(dpkg --print-architecture)}" \
 && curl -fsSL "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-${arch}.tar.gz" \
      -o /tmp/age.tar.gz \
 && tar -xzf /tmp/age.tar.gz -C /tmp \
 && install -m 0755 /tmp/age/age /tmp/age/age-keygen /usr/local/bin/ \
 && rm -rf /tmp/age.tar.gz /tmp/age \
 && age --version

# Pinned Ansible lint/converge toolchain — the exact versions the CI validate job and
# tests/Dockerfile use, so `ansible-lint`/`yamllint`/`--syntax-check` match here.
COPY tests/requirements.txt /tmp/requirements.txt
RUN uv pip install --system --break-system-packages -r /tmp/requirements.txt \
 && rm /tmp/requirements.txt

# The repo is mounted here at run time (-v "$PWD":/substrate); ./substrate is the TUI.
WORKDIR /substrate

# Land straight in the menu; override with `docker run ... substrate-toolbox bash`
# for a plain shell (or any other command, e.g. `... task check:doctor`).
ENTRYPOINT ["./substrate"]
CMD []
