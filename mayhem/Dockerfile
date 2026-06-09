# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base): debian + clang/llvm + libFuzzer/afl++ + identities + build ENV.
# This only adds elfutils' extra build deps and the per-commit build.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t mytag .

FROM ghcr.io/mayhemheroes/base:2026-06

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never an ENV — an empty value breaks clang.
ARG SOURCE_DATE_EPOCH
# Sanitizer override: undefaulted ARG lets the base ENV (ASan+UBSan) flow through unless --build-arg'd.
ARG SANITIZER_FLAGS
# Build parallelism (optional). build.sh falls back to nproc when unset: --build-arg MAYHEM_JOBS=8
ARG MAYHEM_JOBS=

# Extra build deps elfutils needs beyond the base (gawk for its build scripts; the dev libs libelf
# links). debuginfod and bzlib/lzma/zstd are disabled in build.sh so their -dev pkgs aren't needed.
# `zstd` is the RUNTIME CLI tool a handful of tests/run-*.sh invoke to decompress zstd test data; with
# it absent those tests just SKIP — installing it lets them actually run (bz2/xz CLIs are in the base).
# Install as root, re-pinning apt to SOURCE_DATE_EPOCH when set (reproducible; script ships in base).
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
      gawk zlib1g-dev libarchive-dev zstd \
 && rm -rf /var/lib/apt/lists/*
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history) is
# copied to /mayhem as `mayhem`; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run the project's functional tests at build time IF the repo ships mayhem/test.sh. elfutils ships
# mayhem/test.sh, which RUNS automake's `make check` suite in the NORMAL-flags test tree that build.sh
# built (the heavy lib+tools build is already done; `make check` only builds the small per-test programs
# at run time). A failing suite (CTRF failed>0) fails the build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
