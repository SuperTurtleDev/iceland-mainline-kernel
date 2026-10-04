#!/usr/bin/env bash
# Host-side entry point for the sm8850 (OnePlus Pad 4 / iceland) kernel build.
#
# Runs the whole pipeline inside a rootless podman container:
#
#   1. build the container image from ./Containerfile
#   2. run scripts/build-kernel.sh  (kernel Image + dtbs + modules)
#   3. run scripts/pack-headers.sh   (linux-headers style dev package)
#   4. run scripts/build-oot.sh      (out-of-tree module, validates headers pkg)
#   5. run scripts/make-initrd.sh    (debug initrd)
#   6. run scripts/pack-images.sh    (boot-partition payload images + tars)
#   7. host side: scripts/buildinfo.sh + scripts/verify.sh
#
# Usage:   ./build.sh [OUT_DIR]
#          OUT_DIR=/path ./build.sh
#
# Idempotent: every step re-runs (rebuild); kbuild itself is incremental.
# The metarepo is mounted read-only into the container; all artifacts are
# written to OUT_DIR (default: /home/wyb/Documents/mainline/build/kernel).
set -euo pipefail

META="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-${OUT:-/home/wyb/Documents/mainline/build/kernel}}"

IMAGE="sm8850-kbuild:iceland-7.2"

mkdir -p "${OUT}/logs" "${OUT}/staging"

log() { printf '[build.sh] %s\n' "$*" >&2; }

# --- sanity checks ---------------------------------------------------------
for f in "${META}/Containerfile" "${META}/config" "${META}/initrd-modules.txt"; do
    [ -f "$f" ] || { log "ERROR: missing ${f}"; exit 1; }
done
for s in build-kernel pack-headers build-oot make-initrd pack-images; do
    [ -f "${META}/scripts/${s}.sh" ] || { log "ERROR: missing ${META}/scripts/${s}.sh"; exit 1; }
done
command -v podman >/dev/null 2>&1 || { log "ERROR: podman not found"; exit 1; }

# --- 1. container image ------------------------------------------------------
log "building container image ${IMAGE} (log: ${OUT}/logs/container-build.log)"
podman build -t "${IMAGE}" -f "${META}/Containerfile" "${META}" 2>&1 \
    | tee "${OUT}/logs/container-build.log"

# --- 2..6. in-container pipeline steps ---------------------------------------
run_step() {
    local step="$1"
    log "running ${step}.sh (log: ${OUT}/logs/${step}.log)"
    podman run --rm \
        -v "${META}:/work/src:ro" \
        -v "${OUT}:/work/out" \
        "${IMAGE}" \
        bash "/work/src/scripts/${step}.sh" 2>&1 \
        | tee "${OUT}/logs/${step}.log"
}

for step in build-kernel pack-headers build-oot make-initrd pack-images; do
    run_step "$step"
done

# --- 7. host-side bookkeeping and verification --------------------------------
log "generating buildinfo (log: ${OUT}/logs/buildinfo.log)"
OUT="${OUT}" bash "${META}/scripts/buildinfo.sh" 2>&1 | tee "${OUT}/logs/buildinfo.log"

log "verifying artifacts (log: ${OUT}/logs/verify.log)"
OUT="${OUT}" bash "${META}/scripts/verify.sh" 2>&1 | tee "${OUT}/logs/verify.log"

log "done. artifacts in ${OUT}:"
ls -l "${OUT}"/*.img "${OUT}"/*.tar.gz "${OUT}"/SHA256SUMS "${OUT}"/buildinfo.txt >&2 || true
