# Test/validation image for the substrate control plane.
#
# Build (from repo root):  docker build -f tests/Dockerfile -t substrate-ci .
# Run full suite:          docker run --rm substrate-ci
# Run ad-hoc command:      docker run --rm -v "$PWD":/substrate substrate-ci ansible-playbook --syntax-check local.yml
#
# The default entrypoint runs lint + syntax-check + a check-mode converge of
# local.yml against the container itself (localhost). It needs no privileges,
# so it drops straight into a GitHub Actions runner. A full systemd converge
# (actually starting the reconciler timer) is out of scope here — see
# tests/README.md for the Incus harness (`tests/incus/run.sh`).
FROM debian:trixie-slim

# uv is the Python installer/resolver (pinned, reproducible).
COPY --from=ghcr.io/astral-sh/uv:0.8.22 /uv /uvx /usr/local/bin/

ENV DEBIAN_FRONTEND=noninteractive \
    UV_NO_CACHE=1 \
    ANSIBLE_FORCE_COLOR=1

# The check-mode converge gathers facts and predicts apt/file/template/systemd
# changes, so the image carries the same base tooling a real node would have.
# python3-apt is required for the apt module to run in --check mode (a normal
# converge on a real node auto-installs it).
# Apt lists are kept (not pruned) so the apt module can resolve not-yet-installed
# packages like `ansible` during the check-mode converge.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      python3 python3-apt \
      git sudo ca-certificates

COPY tests/requirements.txt /tmp/requirements.txt
RUN uv pip install --system --break-system-packages -r /tmp/requirements.txt

WORKDIR /substrate
COPY . /substrate

ENTRYPOINT ["tests/entrypoint.sh"]
