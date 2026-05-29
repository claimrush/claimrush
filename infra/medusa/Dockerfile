# Custom Medusa runner image: official medusa + foundry binaries.
#
# Why we need this:
#   The official `ghcr.io/crytic/medusa:v1.5.1` image does NOT include the
#   `forge` binary, and the bundled `crytic-compile` 0.3.11 expects to
#   shell out to `forge config` and `forge build` when compiling a Foundry
#   project. Without forge, every harness errors out with:
#       FileNotFoundError: [Errno 2] No such file or directory: 'forge'
#   The CI workflow `.github/workflows/medusa.yml` swallows this with
#   `continue-on-error: true`, but the run is effectively a no-op. This
#   image fixes that.
#
# Pinning rationale:
#   - Medusa pin must match `scripts/run_medusa.sh` and
#     `.github/workflows/medusa.yml` (currently v1.5.1).
#   - Foundry pin must match `.github/workflows/medusa.yml`'s
#     `foundry-toolchain` action input (currently v1.5.1) so the artifact
#     formats produced inside this container are bytecode-equivalent to CI.
#
# Build:
#   docker build -t claimrush-medusa:v1.5.1 -f infra/medusa/Dockerfile infra/medusa/
#
# Or let scripts/run_medusa.sh build it lazily on first run (the script
# checks for the local tag and builds if missing).
FROM ghcr.io/crytic/medusa:v1.5.1

ARG FOUNDRY_VERSION=v1.5.1

USER root

# curl + ca-certificates so we can pull the foundry release archive.
# tar/gzip are already in the base image (Ubuntu 24.04).
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Download pinned foundry binaries (forge, cast, anvil, chisel) from the
# official GitHub release tarball and install into /usr/local/bin so
# crytic-compile finds them on PATH.
RUN set -eux; \
    arch="$(uname -m)"; \
    case "${arch}" in \
        x86_64)  fdy_arch=amd64 ;; \
        aarch64) fdy_arch=arm64 ;; \
        *) echo "unsupported arch: ${arch}" >&2 ; exit 1 ;; \
    esac; \
    url="https://github.com/foundry-rs/foundry/releases/download/${FOUNDRY_VERSION}/foundry_${FOUNDRY_VERSION}_linux_${fdy_arch}.tar.gz"; \
    echo "Downloading foundry from: ${url}"; \
    curl -fsSL "${url}" -o /tmp/foundry.tar.gz; \
    tar -xzf /tmp/foundry.tar.gz -C /usr/local/bin/ forge cast anvil chisel; \
    chmod +x /usr/local/bin/forge /usr/local/bin/cast /usr/local/bin/anvil /usr/local/bin/chisel; \
    rm -f /tmp/foundry.tar.gz; \
    forge --version

# Restore the medusa entrypoint exactly as the upstream image had it.
# (The base image's ENTRYPOINT is medusa; nothing to change.)
#
# Switch off root so the image satisfies the semgrep
# `dockerfile.security.last-user-is-root.last-user-is-root` rule that runs
# in the public-CI security-minimum baseline. Runtime invocations from
# scripts/run_medusa.sh and .github/workflows/medusa.yml override
# this with `--user "$(id -u):$(id -g)"` so the host UID owns corpora and
# logs anyway; the directive here is purely for the static-analysis check.
USER 1000
