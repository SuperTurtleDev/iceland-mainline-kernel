#!/usr/bin/env bash
# In-container stage: cross-compile the static ARM64 deploy server.
set -euo pipefail

SRC=/work/src
OUT=/work/out

log() { printf '[build-deployd] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 \
    || die "aarch64-linux-gnu-gcc missing (add gcc-aarch64-linux-gnu + libc6-dev-arm64-cross to packages.list)"
[ -f "${SRC}/deploy/deployd.c" ] || die "deploy/deployd.c missing"

aarch64-linux-gnu-gcc -static -O2 -Wall -Wextra \
    -o "${OUT}/staging/deployd" "${SRC}/deploy/deployd.c"
file "${OUT}/staging/deployd" | grep -q "ARM aarch64" || die "not an aarch64 binary"
file "${OUT}/staging/deployd" | grep -q "statically linked" || die "not statically linked"
log "deployd: $(du -h "${OUT}/staging/deployd" | cut -f1) (static aarch64)"
log "done"
