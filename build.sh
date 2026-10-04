#!/usr/bin/env bash
# Host-side entry point for the sm8850 (OnePlus Pad 4 / iceland) kernel build.
#
# Staged incremental pipeline inside a rootless podman container:
#
#   stage "image"       podman build of sm8850-kbuild:iceland-7.2
#   stage "kernel"      scripts/build-kernel.sh   (Image + dtbs + modules)
#   stage "headers"     scripts/pack-headers.sh   (linux-headers dev package)
#   stage "oot"         scripts/build-oot.sh      (out-of-tree module proof)
#   stage "initrd"      scripts/make-initrd.sh    (debug initrd)
#   stage "pack-images" scripts/pack-images.sh    (boot images + tars)
#   buildinfo.sh + verify.sh always run (host side, never skipped)
#
# Incrementality / caching (OUT doubles as the cache):
#   * every stage writes OUT/staging/stamps/<stage>.stamp holding a sha256
#     fingerprint of its inputs (script content, direct inputs, repo states
#     of metarepo/linux/firmware, the upstream stage fingerprint and, where
#     relevant, image digests).  A matching stamp plus present outputs means
#     the stage is SKIPped; otherwise it RUNs and refreshes the stamp.
#   * OUT/kbuild (the kernel O= dir) and OUT/staging are NEVER wiped by the
#     build itself, so a RUNning kernel stage still profits from make's
#     native incremental rebuild.
#   * the podman images (base ubuntu:26.04 and sm8850-kbuild) are archived
#     as OUT/podman-cache/*.tar.zst (`podman save | zstd`); when the local
#     podman store lacks an image, the archive is restored via `podman load`
#     before any pull/build is attempted.  After a pull/build the archive
#     is refreshed.  Both archives are hashed into OUT/SHA256SUMS and their
#     digests recorded in OUT/buildinfo.txt.
#
# Usage: ./build.sh [OUT_DIR] [--force] [--rebuild-image] [--clean]
#          OUT_DIR=/path ./build.sh [--force] [--rebuild-image] [--clean]
#
#   --force           re-run every stage regardless of stamps
#   --rebuild-image   force-rebuild the container image and refresh its cache
#   --clean           remove OUT/kbuild + OUT/staging (incl. stamps), keep
#                     podman-cache/, final artifacts and logs/, then exit
set -euo pipefail

META="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${OUT:-/home/wyb/Documents/mainline/build/kernel}"

IMAGE="sm8850-kbuild:iceland-7.2"
BASE="docker.io/library/ubuntu:26.04"
KVER="7.2.0-sm8850"
DTB_REL="arch/arm64/boot/dts/qcom/kaanapali-oneplus-iceland.dtb"
CACHE_DIR="${OUT}/podman-cache"
STAMPS="${OUT}/staging/stamps"
CACHE_BASE="${CACHE_DIR}/ubuntu-26.04.tar.zst"
CACHE_BUILD="${CACHE_DIR}/sm8850-kbuild-iceland-7.2.tar.zst"

FORCE=0
REBUILD_IMAGE=0
DO_CLEAN=0

log() { printf '[build.sh] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

usage() {
    sed -n '2,44p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
    case "$1" in
        --force)         FORCE=1 ;;
        --rebuild-image) REBUILD_IMAGE=1 ;;
        --clean)         DO_CLEAN=1 ;;
        -h|--help)       usage; exit 0 ;;
        --*)             die "unknown option: $1 (see --help)" ;;
        *)               OUT="$1" ;;
    esac
    shift
done

mkdir -p "${OUT}/logs" "${OUT}/staging"

if [ "${DO_CLEAN}" -eq 1 ]; then
    log "--clean: removing ${OUT}/kbuild and ${OUT}/staging (incl. stamps)"
    rm -rf "${OUT}/kbuild" "${OUT}/staging"
    log "--clean: kept podman-cache/, *.img, *.tar.gz, SHA256SUMS, buildinfo.txt, logs/"
    exit 0
fi

# --- sanity checks ---------------------------------------------------------
for f in "${META}/Containerfile" "${META}/config" "${META}/initrd-modules.txt"; do
    [ -f "$f" ] || { log "ERROR: missing ${f}"; exit 1; }
done
for s in build-kernel pack-headers build-oot make-initrd pack-images; do
    [ -f "${META}/scripts/${s}.sh" ] || { log "ERROR: missing ${META}/scripts/${s}.sh"; exit 1; }
done
command -v podman >/dev/null 2>&1 || { log "ERROR: podman not found"; exit 1; }
command -v zstd  >/dev/null 2>&1 || { log "ERROR: zstd not found (needed for image cache)"; exit 1; }

START_TS="$(date +%s)"

# --- helpers -----------------------------------------------------------------
hash_file() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# deterministic hash over all regular files below a directory
hash_tree() {
    local dir="$1"
    if [ ! -d "${dir}" ]; then printf 'missing'; return; fi
    ( cd "${dir}" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum ) \
        | sha256sum | cut -d' ' -f1
}

# repo identity: HEAD + porcelain (untracked included); mode "meta" also
# hashes the full `git diff` (tracked-content changes)
repo_state() {
    local path="$1" mode="$2"
    {
        printf 'head %s\n' "$(git -C "${path}" rev-parse HEAD 2>/dev/null || echo none)"
        git -C "${path}" --no-optional-locks status --porcelain 2>/dev/null | LC_ALL=C sort
        if [ "${mode}" = "meta" ]; then
            printf 'diff %s\n' "$(git -C "${path}" diff 2>/dev/null | sha256sum | cut -d' ' -f1)"
        fi
    } | sha256sum | cut -d' ' -f1
}

image_exists() { podman image exists "$1" >/dev/null 2>&1; }

image_digest() {
    local d
    d="$(podman image inspect "$1" --format '{{.Digest}}' 2>/dev/null || true)"
    if [ -z "${d}" ]; then
        d="$(podman image inspect "$1" --format '{{.Id}}' 2>/dev/null || echo unavailable)"
    fi
    printf '%s' "${d}"
}

save_image_cache() { # $1=image $2=archive path
    log "saving image $1 -> $2"
    mkdir -p "${CACHE_DIR}"
    podman save "$1" | zstd -q -T0 > "${2}.tmp"
    mv -f "${2}.tmp" "$2"
}

load_image_cache() { # $1=archive path
    log "loading image archive $1"
    podman load -i "$1" >/dev/null
}

# --- 0. base image (local -> cache archive -> pull) ---------------------------
ensure_base_image() {
    if image_exists "${BASE}"; then
        log "base image ${BASE} present locally"
    elif [ -f "${CACHE_BASE}" ]; then
        load_image_cache "${CACHE_BASE}"
        image_exists "${BASE}" || die "base image still missing after loading ${CACHE_BASE}"
    else
        log "pulling base image ${BASE}"
        podman pull "${BASE}"
        save_image_cache "${BASE}" "${CACHE_BASE}"
    fi
    BASE_DIGEST="$(image_digest "${BASE}")"
    log "base image digest: ${BASE_DIGEST}"
}

# make sure the build image is present locally, loading the cache archive if
# needed; returns non-zero when it is not available at all
ensure_build_image_available() {
    image_exists "${IMAGE}" && return 0
    if [ -f "${CACHE_BUILD}" ]; then
        load_image_cache "${CACHE_BUILD}"
    fi
    image_exists "${IMAGE}"
}

# --- stage machinery ----------------------------------------------------------
declare -A FP      # stage -> fingerprint of this run
declare -A STATE   # stage -> SKIP | RUN

STAGES=(image kernel headers oot initrd pack-images)

stage_outputs_ok() {
    case "$1" in
        image)
            image_exists "${IMAGE}" ;;
        kernel)
            [ -f "${OUT}/kbuild/arch/arm64/boot/Image" ] \
                && [ -f "${OUT}/kbuild/${DTB_REL}" ] \
                && [ -f "${OUT}/staging/modroot/lib/modules/${KVER}/modules.dep" ] ;;
        headers)
            [ -f "${OUT}/headers.tar.gz" ] ;;
        oot)
            [ -f "${OUT}/staging/modroot/lib/modules/${KVER}/updates/charge_boost_lite.ko.zst" ] ;;
        initrd)
            [ -f "${OUT}/staging/initrd_debug.cpio.zst" ] ;;
        pack-images)
            [ -f "${OUT}/kernel.img" ] && [ -f "${OUT}/modules.tar.gz" ] \
                && [ -f "${OUT}/SHA256SUMS" ] ;;
        *)
            return 1 ;;
    esac
}

fingerprint() { # $1=stage; prints the sha256 fingerprint
    local stage="$1" script="" inputs="" upstream="-"
    case "${stage}" in
        image)
            script="containerfile=$(hash_file "${META}/Containerfile")"
            inputs="base-image=${BASE} base-digest=${BASE_DIGEST}"
            ;;
        kernel)
            script="script=$(hash_file "${META}/scripts/build-kernel.sh")"
            inputs="config=$(hash_file "${META}/config") image-digest=${IMAGE_DIGEST}"
            upstream="${FP[image]:-}"
            ;;
        headers)
            script="script=$(hash_file "${META}/scripts/pack-headers.sh")"
            upstream="${FP[kernel]:-}"
            ;;
        oot)
            script="script=$(hash_file "${META}/scripts/build-oot.sh")"
            inputs="oot-charge-boost=$(hash_tree "${META}/oot/charge_boost")"
            upstream="${FP[headers]:-}"
            ;;
        initrd)
            script="script=$(hash_file "${META}/scripts/make-initrd.sh")"
            inputs="initrd-modules=$(hash_file "${META}/initrd-modules.txt")"
            inputs="${inputs} initrd-debug-tree=$(hash_tree "${META}/initrd_debug")"
            inputs="${inputs} busybox=image:${IMAGE_DIGEST}"
            upstream="${FP[oot]:-}"
            ;;
        pack-images)
            script="script=$(hash_file "${META}/scripts/pack-images.sh")"
            upstream="${FP[initrd]:-}"
            ;;
    esac
    printf 'stage=%s\n%s\n%s\nupstream=%s\nmeta-state=%s\nlinux-state=%s\nfirmware-state=%s\n' \
        "${stage}" "${script}" "${inputs}" "${upstream}" \
        "${META_STATE}" "${LINUX_STATE}" "${FIRM_STATE}" \
        | sha256sum | cut -d' ' -f1
}

run_stage_command() {
    local stage="$1" script
    case "${stage}" in
        image)
            log "building container image ${IMAGE} (log: ${OUT}/logs/container-build.log)"
            podman build -t "${IMAGE}" -f "${META}/Containerfile" "${META}" 2>&1 \
                | tee "${OUT}/logs/container-build.log"
            image_exists "${IMAGE}" || die "podman build did not produce ${IMAGE}"
            save_image_cache "${IMAGE}" "${CACHE_BUILD}"
            IMAGE_DIGEST="$(image_digest "${IMAGE}")"
            log "build image digest: ${IMAGE_DIGEST}"
            ;;
        *)
            script="$(stage_script_name "${stage}")"
            log "running ${script}.sh (log: ${OUT}/logs/${script}.log)"
            podman run --rm \
                -v "${META}:/work/src:ro" \
                -v "${OUT}:/work/out" \
                "${IMAGE}" \
                bash "/work/src/scripts/${script}.sh" 2>&1 \
                | tee "${OUT}/logs/${script}.log"
            ;;
    esac
}

stage_script_name() {
    case "$1" in
        kernel)      echo build-kernel ;;
        headers)     echo pack-headers ;;
        oot)         echo build-oot ;;
        initrd)      echo make-initrd ;;
        pack-images) echo pack-images ;;
        *)           die "no script for stage $1" ;;
    esac
}

# --- run the pipeline ----------------------------------------------------------
ensure_base_image

META_STATE="$(repo_state "${META}" meta)"
LINUX_STATE="$(repo_state "${META}/linux" submodule)"
FIRM_STATE="$(repo_state "${META}/firmware" submodule)"
log "meta-state=${META_STATE}"
log "linux-state=${LINUX_STATE}"
log "firmware-state=${FIRM_STATE}"

IMAGE_DIGEST=""
for stage in "${STAGES[@]}"; do
    if [ "${stage}" = "kernel" ] && [ -z "${IMAGE_DIGEST}" ]; then
        # image stage SKIPped: pick up the digest of the existing image
        ensure_build_image_available || die "build image ${IMAGE} unavailable"
        IMAGE_DIGEST="$(image_digest "${IMAGE}")"
    fi
    fp="$(fingerprint "${stage}")"
    FP[${stage}]="${fp}"
    stamp="${STAMPS}/${stage}.stamp"
    old=""
    [ -f "${stamp}" ] && old="$(cat "${stamp}" 2>/dev/null || true)"

    skip=0
    if [ "${FORCE}" -eq 0 ]; then
        if [ "${stage}" != "image" ] || [ "${REBUILD_IMAGE}" -eq 0 ]; then
            if [ "${old}" = "${fp}" ] && stage_outputs_ok "${stage}"; then
                skip=1
            fi
        fi
    fi

    if [ "${skip}" -eq 1 ]; then
        log "[${stage}] SKIP (hash ${fp})"
        STATE[${stage}]=SKIP
    else
        log "[${stage}] RUN (hash ${fp})"
        run_stage_command "${stage}"
        mkdir -p "${STAMPS}"
        printf '%s\n' "${fp}" > "${stamp}"
        STATE[${stage}]=RUN
    fi

    if [ "${stage}" = "image" ] && [ -z "${IMAGE_DIGEST}" ]; then
        # image stage SKIPped
        ensure_build_image_available || die "build image ${IMAGE} unavailable"
        IMAGE_DIGEST="$(image_digest "${IMAGE}")"
    fi
done

# record the stage decisions of this run (consumed by buildinfo.sh)
{
    printf 'finished-utc %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    for stage in "${STAGES[@]}"; do
        printf '%s %s %s\n' "${stage}" "${STATE[${stage}]}" "${FP[${stage}]}"
    done
} > "${STAMPS}/last-run.txt"

# --- refresh the podman-cache lines in SHA256SUMS (always) ----------------------
if [ -f "${OUT}/SHA256SUMS" ]; then
    (
        cd "${OUT}"
        grep -v ' podman-cache/' SHA256SUMS > SHA256SUMS.tmp || true
        find podman-cache -maxdepth 1 -type f -name '*.tar.zst' | LC_ALL=C sort \
            | xargs -r sha256sum >> SHA256SUMS.tmp
        mv -f SHA256SUMS.tmp SHA256SUMS
    ) || die "failed to refresh SHA256SUMS with podman-cache entries"
    log "SHA256SUMS refreshed with podman-cache entries"
fi

# --- host-side bookkeeping and verification (never skipped) ----------------------
log "generating buildinfo (log: ${OUT}/logs/buildinfo.log)"
OUT="${OUT}" bash "${META}/scripts/buildinfo.sh" 2>&1 | tee "${OUT}/logs/buildinfo.log"

log "verifying artifacts (log: ${OUT}/logs/verify.log)"
OUT="${OUT}" bash "${META}/scripts/verify.sh" 2>&1 | tee "${OUT}/logs/verify.log"

END_TS="$(date +%s)"
log "total wall time: $((END_TS - START_TS)) s"

log "done. artifacts in ${OUT}:"
ls -l "${OUT}"/*.img "${OUT}"/*.tar.gz "${OUT}"/SHA256SUMS "${OUT}"/buildinfo.txt >&2 || true
