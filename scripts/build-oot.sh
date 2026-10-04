#!/usr/bin/env bash
# In-container step 3: build the out-of-tree charge_boost module against the
# freshly packed headers.tar.gz.
#
# This doubles as the acceptance test for the headers package: the module is
# built ONLY from the unpacked tarball, never from the kernel tree/O= dir.
# The upstream Makefile's KDIR/ODIR defaults point at stale host paths, so we
# do not use that Makefile at all and drive kbuild directly with M=.
set -euo pipefail

SRC=/work/src
OUT=/work/out
KVER="7.2.0-sm8850"
HDR_TEST="${OUT}/staging/hdr-test"
HDR="${HDR_TEST}/usr/src/linux-headers-${KVER}"
OOT_SRC="${OUT}/staging/charge_boost"
MODROOT="${OUT}/staging/modroot"
UPD_DIR="${MODROOT}/lib/modules/${KVER}/updates"

log() { printf '[build-oot] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ -f "${OUT}/headers.tar.gz" ] || die "headers.tar.gz missing; run pack-headers.sh first"
[ -d "${MODROOT}/lib/modules/${KVER}" ] || die "modroot missing; run build-kernel.sh first"

# --- unpack headers package into a clean test dir -----------------------------
rm -rf "${HDR_TEST}" "${OOT_SRC}"
mkdir -p "${HDR_TEST}"
tar -xzf "${OUT}/headers.tar.gz" -C "${HDR_TEST}"
[ -f "${HDR}/Makefile" ] || die "unpacked headers package has no Makefile"

# --- copy module source (metarepo mount is read-only) --------------------------
cp -a "${SRC}/oot/charge_boost" "${OOT_SRC}"
[ -f "${OOT_SRC}/charge_boost_lite.c" ] || die "charge_boost_lite.c missing in oot/charge_boost"

# --- build against the headers package only ------------------------------------
log "building charge_boost_lite against ${HDR}"
if ! make -C "${HDR}" M="${OOT_SRC}" ARCH=arm64 LLVM=1 modules \
        >"${OUT}/logs/oot-build.log" 2>&1; then
    tail -80 "${OUT}/logs/oot-build.log" >&2
    die "OOT module build against headers.tar.gz failed (headers package incomplete?)"
fi
tail -5 "${OUT}/logs/oot-build.log" >&2 || true

KO="${OOT_SRC}/charge_boost_lite.ko"
[ -f "${KO}" ] || die "charge_boost_lite.ko was not produced"
file "${KO}" >&2 || true

# --- install as compressed module into modroot/updates -------------------------
mkdir -p "${UPD_DIR}"
zstd -q -f -19 -T0 "${KO}" -o "${UPD_DIR}/charge_boost_lite.ko.zst"
depmod -b "${MODROOT}" "${KVER}"

log "installed ${UPD_DIR}/charge_boost_lite.ko.zst"
log "done"
