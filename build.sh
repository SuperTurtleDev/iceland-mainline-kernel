#!/usr/bin/env bash
# Host-side entry point for the sm8850 (OnePlus Pad 4 / iceland) kernel build.
#
# Every build stage runs inside the provisioned container through
# ../podman_container/runin.sh; buildinfo + verify run on the host (git /
# file-level work only).
#
# Stages (in order, always executed):
#   scripts/build-kernel.sh        Image + dtbs + modules_install + depmod
#   scripts/pack-headers.sh        headers.tar.gz (OOT dev package)
#   scripts/build-oot.sh           charge_boost against headers.tar.gz + depmod
#   scripts/build-debs.sh          4 debian packages (image/modules/headers/fw)
#   scripts/make-initrd.sh         debug initrd (bare .ko subset, modules.order)
#   scripts/make-charge-initrd.sh  charge initrd = debug base + charge_boost_lite
#                                  (9V/2A fixed PDO + console telemetry)
#   scripts/build-deployd.sh         static ARM64 streaming deploy server
#   scripts/make-deploy-initrd.sh  deploy initrds + initrd-partition containers
#   scripts/build-deploy-tools.sh     host makeblob/deployclient + ramdeploy file set
#   scripts/make-deploy-net-initrd.sh  TINY net-deploy initrds (TestBootApp RAM boot;
#                                  rootfs+debs stream over NCM to deployd)
#                                  ([size]initrd[size]deb..., debs loaded off
#                                  the partition at runtime to save BL memory)
#   scripts/pack-images.sh         .img/.tar.gz/SHA256SUMS artifacts
#
# Incrementality -- by design, no extra fingerprint machinery:
#   * container data: runin.sh reprovisions OUT/podman-data only when the
#     podman_container repo state changed (CONTAINER_DATA/commit mismatch)
#   * kernel: make's native incremental build in OUT/kbuild, which is never
#     cleaned -- unchanged sources/config mean a near no-op make
#   * staging/ and the images/archives are regenerated on every run (fast
#     and deterministic thanks to SOURCE_DATE_EPOCH)
#
# Usage: ./build.sh [OUT_DIR]      (or OUT_DIR=... ./build.sh)
set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META="${SCRIPTDIR}"
OUT="${OUT:-${SCRIPTDIR}/../../build/kernel}"
# podman (SecureJoin) rejects paths that still contain '..' components
mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"
RUNIN="${META}/../podman_container/runin.sh"
DATA="${OUT}/podman-data"

STAGES=(build-kernel pack-headers build-oot build-debs build-deployd make-initrd make-charge-initrd make-deploy-initrd make-deploy-net-initrd build-deploy-tools pack-images)

log() { printf '[build.sh] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) OUT="$1" ;;
    esac
    shift
done

[ -x "${RUNIN}" ] || die "runin.sh not found at ${RUNIN}"
command -v podman >/dev/null 2>&1 || die "podman not found"
for s in "${STAGES[@]}"; do
    [ -f "${META}/scripts/${s}.sh" ] || die "missing ${META}/scripts/${s}.sh"
done
[ -f "${META}/config" ] || die "missing ${META}/config"

mkdir -p "${OUT}/logs" "${OUT}/staging"
START="$(date +%s)"
printf 'start-utc %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "${OUT}/staging/last-run.txt"

for stage in "${STAGES[@]}"; do
    t0="$(date +%s)"
    log "[${stage}] RUN (log: ${OUT}/logs/${stage}.log)"
    CONTAINER_DATA="${DATA}" \
    EXTRA_MOUNTS="-v ${META}:/work/src:ro -v ${OUT}:/work/out" \
        bash "${RUNIN}" bash "/work/src/scripts/${stage}.sh" 2>&1 | tee "${OUT}/logs/${stage}.log"
    printf '%s %ss\n' "${stage}" "$(( $(date +%s) - t0 ))" >> "${OUT}/staging/last-run.txt"
done

t0="$(date +%s)"
log "generating buildinfo (log: ${OUT}/logs/buildinfo.log)"
OUT="${OUT}" bash "${META}/scripts/buildinfo.sh" > "${OUT}/logs/buildinfo.log" 2>&1
printf 'buildinfo %ss\n' "$(( $(date +%s) - t0 ))" >> "${OUT}/staging/last-run.txt"

log "verifying artifacts (log: ${OUT}/logs/verify.log)"
OUT="${OUT}" bash "${META}/scripts/verify.sh" 2>&1 | tee "${OUT}/logs/verify.log"

log "total wall time: $(( $(date +%s) - START )) s"

log "done. artifacts in ${OUT}:"
ls -l "${OUT}"/*.img "${OUT}"/*.tar.gz "${OUT}"/SHA256SUMS "${OUT}"/buildinfo.txt >&2 || true
