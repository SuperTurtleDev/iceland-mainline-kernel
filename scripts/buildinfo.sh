#!/usr/bin/env bash
# Host-side step: generate OUT/buildinfo.txt describing the exact inputs and
# outputs of a build (revision state of all three repositories, container
# image details, toolchain versions from inside the image, config drift and
# per-artifact hashes).
set -euo pipefail

META="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-/home/wyb/Documents/mainline/build/kernel}"
IMAGE="sm8850-kbuild:iceland-7.2"
KVER="7.2.0-sm8850"

log() { printf '[buildinfo] %s\n' "$*" >&2; }

line() { printf '%s: %s\n' "$1" "$2"; }

# repo_state <path> <label> <diff-file>
# Prints commit/branch/dirty; writes a diff file when dirty.
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
    line "${label}-commit"  "${commit}"
    line "${label}-branch"  "${branch}"
    line "${label}-dirty"   "${dirty}"
    if [ "${dirty}" = yes ]; then
        git -C "${path}" diff > "${OUT}/${difffile}" 2>/dev/null || \
            echo "(git diff failed)" > "${OUT}/${difffile}"
        line "${label}-diff-file" "${difffile}"
    fi
}

{
    line "build-time-utc" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # kernel release actually built (falls back to the expected constant)
    if [ -f "${OUT}/kbuild/include/config/kernel.release" ]; then
        line "kernel-version" "$(cat "${OUT}/kbuild/include/config/kernel.release")"
    else
        line "kernel-version" "${KVER} (expected; kbuild release file not found)"
    fi

    # reproducibility stamp
    if [ -f "${OUT}/staging/source-date-epoch" ]; then
        line "source-date-epoch" "$(cat "${OUT}/staging/source-date-epoch")"
    else
        line "source-date-epoch" "(missing)"
    fi

    echo
    echo "# repository state"
    repo_state "${META}"          "metarepo"  "buildinfo-meta.diff"
    repo_state "${META}/linux"    "linux"     "buildinfo-linux.diff"
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

    echo
    echo "# container images"
    line "container-image" "${IMAGE}"
    if command -v podman >/dev/null 2>&1 && podman image exists "${IMAGE}" 2>/dev/null; then
        line "container-image-digest" \
            "$(podman image inspect "${IMAGE}" --format '{{.Digest}}' 2>/dev/null || echo unavailable)"
        line "container-base-image" \
            "$(podman image inspect "${IMAGE}" --format '{{index .Labels "org.opencontainers.image.base.name"}}' 2>/dev/null || echo unavailable)"
    else
        line "container-image-digest" "unavailable (image not present)"
        line "container-base-image" "docker.io/library/ubuntu:26.04 (from Containerfile)"
    fi
    line "base-image" "docker.io/library/ubuntu:26.04"
    if command -v podman >/dev/null 2>&1 \
        && podman image exists docker.io/library/ubuntu:26.04 2>/dev/null; then
        line "base-image-digest" \
            "$(podman image inspect docker.io/library/ubuntu:26.04 --format '{{.Digest}}' 2>/dev/null || echo unavailable)"
    else
        line "base-image-digest" "unavailable (image not present)"
    fi

    echo
    echo "# podman image cache archives (OUT/podman-cache)"
    found_cache=no
    for c in "${OUT}"/podman-cache/*.tar.zst; do
        [ -f "$c" ] || continue
        found_cache=yes
        line "image-cache-sha256-$(basename "$c")" "$(sha256sum "$c" | cut -d' ' -f1)"
        line "image-cache-size-$(basename "$c")" "$(stat -c %s "$c")"
    done
    [ "${found_cache}" = yes ] || echo "(no cache archives)"

    echo
    echo "# incremental stages: SKIP/RUN of the last run and fingerprints"
    if [ -f "${OUT}/staging/stamps/last-run.txt" ]; then
        sed 's/^/last-run: /' "${OUT}/staging/stamps/last-run.txt"
    else
        echo "(staging/stamps/last-run.txt not found)"
    fi
    if [ -d "${OUT}/staging/stamps" ]; then
        for s in "${OUT}/staging/stamps"/*.stamp; do
            [ -f "$s" ] || continue
            line "stage-fingerprint-$(basename "$s" .stamp)" "$(cat "$s")"
        done
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
    echo "# artifacts"
    for f in \
        kernel.img dtb.img initrd_debug.img bootcfg_debug.img \
        bootcfg/kernel.img bootcfg_debug/kernel_debug.img \
        headers.tar.gz modules.tar.gz SHA256SUMS; do
        if [ -f "${OUT}/${f}" ]; then
            line "artifact-sha256-${f}" "$(sha256sum "${OUT}/${f}" | cut -d' ' -f1)"
            line "artifact-size-${f}" "$(stat -c %s "${OUT}/${f}")"
        else
            line "artifact-sha256-${f}" "(missing)"
        fi
done
} > "${OUT}/buildinfo.txt"

# append the in-image build environment (package versions)
{
    echo
    echo "# container /opt/build-env.txt"
    if command -v podman >/dev/null 2>&1 && podman image exists "${IMAGE}" 2>/dev/null; then
        podman run --rm "${IMAGE}" cat /opt/build-env.txt 2>/dev/null \
            || echo "(failed to read /opt/build-env.txt from image)"
    else
        echo "(image not present)"
    fi
} >> "${OUT}/buildinfo.txt"

log "wrote ${OUT}/buildinfo.txt"
