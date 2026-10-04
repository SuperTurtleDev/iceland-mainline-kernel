#!/usr/bin/env bash
# Host-side step: generate OUT/buildinfo.txt describing the exact inputs and
# outputs of a build: revision state of the four repositories (metarepo,
# linux, firmware, podman_container), the provisioned container data
# (identity + package versions), the reproducibility epoch, config drift and
# per-artifact hashes.  Host-side work only (git + file reads).
set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
META="$(cd "${SCRIPTDIR}/.." && pwd)"
OUT="${OUT:-${SCRIPTDIR}/../../build/kernel}"
mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"
PCONT="$(cd "${META}/.." && pwd)/podman_container"
DATA="${OUT}/podman-data"
KVER="7.2.0-sm8850"

log() { printf '[buildinfo] %s\n' "$*" >&2; }
line() { printf '%s: %s\n' "$1" "$2"; }

# repo_state <path> <label> <diff-file>
# Prints commit/branch/dirty; writes a text diff file when dirty.
repo_state() {
    local path="$1" label="$2" difffile="$3"
    local commit branch dirty
    commit="$(git -C "${path}" rev-parse HEAD 2>/dev/null || echo unknown)"
    branch="$(git -C "${path}" branch --show-current 2>/dev/null || true)"
    [ -n "${branch}" ] || branch="(detached)"
    if [ -n "$(git -C "${path}" status --porcelain 2>/dev/null)" ]; then
        dirty=yes
    else
        dirty=no
    fi
    line "${label}-commit" "${commit}"
    line "${label}-branch" "${branch}"
    line "${label}-dirty"  "${dirty}"
    if [ "${dirty}" = yes ]; then
        git -C "${path}" diff > "${OUT}/${difffile}" 2>/dev/null \
            || echo "(git diff failed)" > "${OUT}/${difffile}"
        line "${label}-diff-file" "${difffile}"
    fi
}

{
    line "build-time-utc" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    if [ -f "${OUT}/kbuild/include/config/kernel.release" ]; then
        line "kernel-version" "$(cat "${OUT}/kbuild/include/config/kernel.release")"
    else
        line "kernel-version" "${KVER} (expected; kbuild release file not found)"
    fi

    if [ -f "${OUT}/staging/source-date-epoch" ]; then
        line "source-date-epoch" "$(cat "${OUT}/staging/source-date-epoch")"
    else
        line "source-date-epoch" "(missing)"
    fi

    echo
    echo "# repository state"
    repo_state "${META}"   "metarepo"         "buildinfo-meta.diff"
    repo_state "${META}/linux" "linux"        "buildinfo-linux.diff"
    # firmware carries uncommitted binary blobs: stat-only diff
    fw_commit="$(git -C "${META}/firmware" rev-parse HEAD 2>/dev/null || echo unknown)"
    fw_branch="$(git -C "${META}/firmware" branch --show-current 2>/dev/null || true)"
    [ -n "${fw_branch}" ] || fw_branch="(detached)"
    line "firmware-commit" "${fw_commit}"
    line "firmware-branch" "${fw_branch}"
    if [ -n "$(git -C "${META}/firmware" status --porcelain 2>/dev/null)" ]; then
        {
            echo "# NOTE: firmware diff contains binary content, stat only."
            git -C "${META}/firmware" diff --stat
        } > "${OUT}/buildinfo-firmware.diff" 2>/dev/null || true
        line "firmware-dirty" "yes"
        line "firmware-diff-file" "buildinfo-firmware.diff (binary, stat only)"
    else
        line "firmware-dirty" "no"
    fi
    # podman_container: an independent repository (like firmware), not a gitlink
    repo_state "${PCONT}" "podman_container" "buildinfo-podman_container.diff"

    echo
    echo "# container data (provisioned by src/podman_container)"
    line "container-data" "${DATA}"
    if [ -f "${DATA}/commit" ]; then
        line "container-data-commit" "$(cat "${DATA}/commit")"
    else
        line "container-data-commit" "(missing)"
    fi

    echo
    echo "# CONTAINER_DATA/build-env.txt (package versions of the provisioned container)"
    if [ -f "${DATA}/build-env.txt" ]; then
        sed 's/^/build-env: /' "${DATA}/build-env.txt"
    else
        echo "build-env: (missing)"
    fi

    echo
    echo "# stage timings of the last run (see also staging/last-run.txt)"
    if [ -f "${OUT}/staging/last-run.txt" ]; then
        sed 's/^/last-run: /' "${OUT}/staging/last-run.txt"
    else
        echo "(staging/last-run.txt not found)"
    fi

    echo
    echo "# config drift introduced by olddefconfig (expected empty)"
    if [ -f "${OUT}/staging/config-drift.diff" ]; then
        if [ -s "${OUT}/staging/config-drift.diff" ]; then
            cat "${OUT}/staging/config-drift.diff"
        else
            echo "(empty)"
        fi
    else
        echo "(config-drift.diff not found)"
    fi

    echo
    echo "# initrd module/firmware subset stats"
    if [ -f "${OUT}/staging/initrd-missing.txt" ]; then
        line "initrd-missing-entries" "$(grep -c . "${OUT}/staging/initrd-missing.txt" || true)"
    fi
    if [ -f "${OUT}/staging/initrd-root/etc/modules.order" ]; then
        line "initrd-modules-order-entries" \
            "$(grep -c -v '^[[:space:]]*$' "${OUT}/staging/initrd-root/etc/modules.order" || true)"
    fi

    echo
    echo "# artifacts"
    for f in \
        kernel.img dtb.img initrd_debug.img bootcfg_debug.img \
        bootcfg/kernel.img bootcfg_debug/kernel_debug.img \
        headers.tar.gz modules.tar.gz \
        initrd_deploy_release.img initrd_deploy_debug.img SHA256SUMS; do
        if [ -f "${OUT}/${f}" ]; then
            line "artifact-sha256-${f}" "$(sha256sum "${OUT}/${f}" | cut -d' ' -f1)"
            line "artifact-size-${f}" "$(stat -c %s "${OUT}/${f}")"
        else
            line "artifact-sha256-${f}" "(missing)"
        fi
    done
    for f in "${OUT}"/debs/*.deb; do
        [ -f "$f" ] || continue
        line "artifact-sha256-debs/$(basename "$f")" "$(sha256sum "$f" | cut -d' ' -f1)"
        line "artifact-size-debs/$(basename "$f")" "$(stat -c %s "$f")"
    done
} > "${OUT}/buildinfo.txt"

log "wrote ${OUT}/buildinfo.txt"
