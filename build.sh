#!/usr/bin/env bash
# Host-side entry point for the sm8850 (OnePlus Pad 4 / iceland) kernel build.
#
# Every build stage runs inside a provisioned container through
# ../podman_container/runin.sh -- the x86_64 one by default, the arm64 one
# (qemu-user binfmt, OUT/podman-data-arm64) for stages prefixed "arm64:" in
# STAGES; buildinfo + verify run on the host (git / file-level work only).
#
# Stages (in order, always executed):
#   scripts/build-kernel.sh        Image + dtbs + modules_install + depmod
#   scripts/build-hdr-tools.sh     [arm64] kbuild_hdr: aarch64 kernel host
#                                  tools (for linux-headers) + perf (for
#                                  linux-tools) + their ${shlibs:Depends}
#   scripts/pack-headers.sh        headers.tar.gz (OOT dev package)
#   scripts/build-oot.sh           [arm64] charge_boost against headers.tar.gz
#                                  + depmod (native aarch64: validates the
#                                  shipped host tools exactly as the device
#                                  will run them)
#   scripts/build-debs.sh          5 debian packages (image/modules/headers/
#                                  tools/fw)
#   scripts/make-initrd.sh         debug initrd (bare .ko subset, modules.order)
#   scripts/make-charge-initrd.sh  charge initrd = debug base + charge_boost_lite
#                                  (9V/2A fixed PDO + console telemetry)
#   scripts/build-deployd.sh         static ARM64 streaming deploy server
#   scripts/build-deploy-tools.sh     host makeblob/deployclient + ramdeploy and
#                                  charge (charge/*_charge.bin) file sets
#   scripts/make-deploy-net-initrd.sh  TINY net-deploy initrds (TestBootApp RAM boot;
#                                  rootfs+debs stream over NCM to deployd)
#                                  ([size]initrd[size]deb..., debs loaded off
#   scripts/pack-images.sh         .img/.tar.gz/SHA256SUMS artifacts
#
# Incrementality -- by design, no extra fingerprint machinery:
#   * container data: runin.sh reprovisions OUT/podman-data{,-arm64} only
#     when the podman_container repo state changed (CONTAINER_DATA/commit
#     mismatch)
#   * kernel: make's native incremental build in OUT/kbuild (and the host
#     tool / perf tree OUT/kbuild_hdr), which are never cleaned -- unchanged
#     sources/config mean a near no-op make
#   * staging/ and the images/archives are regenerated on every run (fast
#     and deterministic thanks to SOURCE_DATE_EPOCH)
#
# Usage: ./build.sh [--debs] [--from STAGE] [OUT_DIR] (or OUT=... ./build.sh)
set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META="${SCRIPTDIR}"
OUT="${OUT:-${SCRIPTDIR}/../../build/kernel}"
FROM_STAGE=
DEBS_ONLY=0
STAGES=(build-kernel arm64:build-hdr-tools pack-headers arm64:build-oot build-debs build-deployd make-initrd make-charge-initrd make-deploy-net-initrd build-deploy-tools pack-images)

# stage_arch / stage_name: "arm64:<name>" runs in the arm64 container
stage_arch() { case "$1" in arm64:*) echo arm64 ;; *) echo amd64 ;; esac; }
stage_name() { echo "${1#arm64:}"; }

log() { printf '[build.sh] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --from) [ $# -ge 2 ] || die "--from needs a stage name"; FROM_STAGE="$2"; shift ;;
        --debs) DEBS_ONLY=1 ;;
        -h|--help) sed -n '2,42p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) OUT="$1" ;;
    esac
    shift
done

# Select a contiguous suffix of the declared dependency order.
selected=()
started=0
[ -z "$FROM_STAGE" ] && started=1
for s in "${STAGES[@]}"; do
    [ "$(stage_name "$s")" != "$FROM_STAGE" ] || started=1
    [ "$started" = 0 ] || selected+=("$s")
    if [ "$DEBS_ONLY" = 1 ] && [ "$s" = build-debs ]; then break; fi
done
[ "${#selected[@]}" -gt 0 ] || die "unknown or out-of-scope start stage: $FROM_STAGE"
STAGES=("${selected[@]}")

# podman (SecureJoin) rejects paths that still contain '..' components
mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"
RUNIN="${META}/../podman_container/runin.sh"
DATA="${OUT}/podman-data"


[ -x "${RUNIN}" ] || die "runin.sh not found at ${RUNIN}"
command -v podman >/dev/null 2>&1 || die "podman not found"
for s in "${STAGES[@]}"; do
    [ -f "${META}/scripts/$(stage_name "$s").sh" ] || die "missing ${META}/scripts/$(stage_name "$s").sh"
done
[ -f "${META}/config" ] || die "missing ${META}/config"

mkdir -p "${OUT}/logs" "${OUT}/staging"
START="$(date +%s)"
printf 'start-utc %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "${OUT}/staging/last-run.txt"

# stage the bootloader build's esp.img (Android-sparse FAT32) for the
# netdeploy initrd's factory-first-boot ESP install, when present
if [ -f "${OUT}/../bootloader/esp.img" ]; then
    cp -f "${OUT}/../bootloader/esp.img" "${OUT}/staging/firsttime-esp.img"
    log "staged ../bootloader/esp.img for the netdeploy initrd"
fi

for s in "${STAGES[@]}"; do
    stage="$(stage_name "$s")"
    arch="$(stage_arch "$s")"
    data="${DATA}"
    [ "${arch}" = amd64 ] || data="${DATA}-${arch}"
    t0="$(date +%s)"
    log "[${stage}] RUN (${arch}; log: ${OUT}/logs/${stage}.log)"
    CONTAINER_DATA="${data}" CONTAINER_ARCH="${arch}" \
    EXTRA_MOUNTS="-v ${META}:/work/src:ro -v ${OUT}:/work/out" \
        bash "${RUNIN}" bash "/work/src/scripts/${stage}.sh" 2>&1 | tee "${OUT}/logs/${stage}.log"
    printf '%s %ss\n' "${stage}" "$(( $(date +%s) - t0 ))" >> "${OUT}/staging/last-run.txt"
done

t0="$(date +%s)"
log "generating buildinfo (log: ${OUT}/logs/buildinfo.log)"
OUT="${OUT}" bash "${META}/scripts/buildinfo.sh" > "${OUT}/logs/buildinfo.log" 2>&1
printf 'buildinfo %ss\n' "$(( $(date +%s) - t0 ))" >> "${OUT}/staging/last-run.txt"

if [ "$DEBS_ONLY" = 1 ]; then
    python3 "${META}/scripts/verify-debs.py" "${OUT}" 2>&1 | tee "${OUT}/logs/verify-debs.log"
    log "done. Debian packages in ${OUT}/debs"
    exit 0
fi

log "verifying artifacts (log: ${OUT}/logs/verify.log)"
OUT="${OUT}" bash "${META}/scripts/verify.sh" 2>&1 | tee "${OUT}/logs/verify.log"

log "total wall time: $(( $(date +%s) - START )) s"

log "done. artifacts in ${OUT}:"
ls -l "${OUT}"/*.img "${OUT}"/*.tar.gz "${OUT}"/SHA256SUMS "${OUT}"/buildinfo.txt >&2 || true
