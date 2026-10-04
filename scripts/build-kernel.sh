#!/usr/bin/env bash
# In-container step 1: build the kernel (Image + dtbs + modules).
#
# Source tree: /work/src (read-only mount of the metarepo)
# Build dir:   /work/out/kbuild (kernel O= directory)
# Modules:     /work/out/staging/modroot/lib/modules/7.2.0-sm8850/
#
# Determinism: SOURCE_DATE_EPOCH is taken from the linux submodule HEAD
# commit time and exported as KBUILD_BUILD_TIMESTAMP; user/host are fixed.
set -euo pipefail

SRC=/work/src
OUT=/work/out
O="${OUT}/kbuild"
KVER="7.2.0-sm8850"
DTB_REL="arch/arm64/boot/dts/qcom/kaanapali-oneplus-iceland.dtb"

log() { printf '[build-kernel] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ -f "${SRC}/config" ]            || die "${SRC}/config missing"
[ -d "${SRC}/linux" ]             || die "${SRC}/linux missing"
command -v git >/dev/null          || die "git missing in container"

# --- reproducibility env -----------------------------------------------------
SOURCE_DATE_EPOCH="$(git -C "${SRC}/linux" log -1 --format=%ct)"
[ -n "${SOURCE_DATE_EPOCH}" ] || die "could not read commit time from linux submodule"
mkdir -p "${OUT}/staging"
printf '%s\n' "${SOURCE_DATE_EPOCH}" > "${OUT}/staging/source-date-epoch"
export SOURCE_DATE_EPOCH
export KBUILD_BUILD_TIMESTAMP="@${SOURCE_DATE_EPOCH}"
export KBUILD_BUILD_USER=builder
export KBUILD_BUILD_HOST=mainline-build
export LC_ALL=C TZ=UTC
log "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}"

# --- prepare O= dir and .config ----------------------------------------------
mkdir -p "${O}"
cp "${SRC}/config" "${O}/.config"

log "running olddefconfig"
make -C "${SRC}/linux" ARCH=arm64 LLVM=1 O="${O}" olddefconfig >"${OUT}/logs/kernel-olddefconfig.log" 2>&1 \
    || { tail -50 "${OUT}/logs/kernel-olddefconfig.log" >&2; die "olddefconfig failed"; }

# record config drift introduced by olddefconfig (expected to be empty)
cp "${O}/.config" "${O}/.config.after"
cp "${SRC}/config" "${O}/.config.before"
if diff -u "${O}/.config.before" "${O}/.config.after" > "${OUT}/staging/config-drift.diff"; then
    log "config drift: none (as expected)"
else
    log "WARNING: olddefconfig changed the config, see staging/config-drift.diff"
fi

# --- build -------------------------------------------------------------------
log "building Image dtbs modules with -j$(nproc) (log: kernel-build.log)"
if ! make -C "${SRC}/linux" -j"$(nproc)" ARCH=arm64 LLVM=1 O="${O}" Image dtbs modules \
        >"${OUT}/logs/kernel-build.log" 2>&1; then
    tail -80 "${OUT}/logs/kernel-build.log" >&2
    die "kernel build failed"
fi

IMAGE_BIN="${O}/arch/arm64/boot/Image"
DTB_BIN="${O}/${DTB_REL}"
[ -f "${IMAGE_BIN}" ] || die "Image not produced"
[ -f "${DTB_BIN}" ]   || die "dtb ${DTB_REL} not produced"

# --- modules_install -----------------------------------------------------------
log "running modules_install into staging/modroot"
MODROOT="${OUT}/staging/modroot"
rm -rf "${MODROOT}"
make -C "${SRC}/linux" ARCH=arm64 LLVM=1 O="${O}" INSTALL_MOD_PATH="${MODROOT}" modules_install \
    >"${OUT}/logs/kernel-modules-install.log" 2>&1 \
    || { tail -50 "${OUT}/logs/kernel-modules-install.log" >&2; die "modules_install failed"; }

# drop the build/source symlinks: they point at container-internal paths and
# would dangle (and leak them) in modules.tar.gz
rm -f "${MODROOT}/lib/modules/${KVER}/build" "${MODROOT}/lib/modules/${KVER}/source"

depmod -b "${MODROOT}" "${KVER}"

# --- report --------------------------------------------------------------------
log "kernel release: $(cat "${O}/include/config/kernel.release" 2>/dev/null || echo "${KVER}")"
log "Image: $(ls -l "${IMAGE_BIN}")"
log "dtb:   $(ls -l "${DTB_BIN}")"
log "modules under: ${MODROOT}/lib/modules/${KVER}"
log "done"
