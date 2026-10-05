#!/usr/bin/env bash
# In-container step 5: produce the boot-partition payload images and archives.
#
# BootApp GPT partition format: partition content = [UINT32 LE payload size]
# followed by the payload. Payloads:
#   kernel.img        arm64 Image (raw, not gzipped, not FIT)
#   dtb.img           single FDT blob (kaanapali-oneplus-iceland.dtb)
#   initrd_debug.img  zstd-compressed newc cpio
#   bootcfg_debug.img ini text, single "cmdline=..." line
# Plus byte-identical kernel copies for the bootloader slot layout and the
# modules.tar.gz / SHA256SUMS artifacts.
set -euo pipefail

OUT=/work/out
O="${OUT}/kbuild"
KVER="7.2.0-sm8850"
MODROOT="${OUT}/staging/modroot"
DTB_REL="arch/arm64/boot/dts/qcom/kaanapali-oneplus-iceland.dtb"
BOOTCFG_DEBUG_CMDLINE='cmdline=console=tty0 earlycon ignore_loglevel initcall_debug clk_ignore_unused pd_ignore_unused loglevel=8'

log() { printf '[pack-images] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

# --- BootApp length-prefix helper (with self-check) -----------------------------
prefix_img() {
    python3 - "$1" "$2" <<'PYEOF'
import os
import struct
import sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "rb") as f:
    payload = f.read()
with open(dst, "wb") as f:
    f.write(struct.pack("<I", len(payload)))
    f.write(payload)

# self-check: prefix must equal file size - 4
with open(dst, "rb") as f:
    head = f.read(4)
    size = os.fstat(f.fileno()).st_size
prefix = struct.unpack("<I", head)[0]
assert prefix == size - 4, f"{dst}: prefix {prefix} != size-4 {size - 4}"
PYEOF
}

# --- reproducibility stamp --------------------------------------------------------
if [ -f "${OUT}/staging/source-date-epoch" ]; then
    SOURCE_DATE_EPOCH="$(cat "${OUT}/staging/source-date-epoch")"
else
    SOURCE_DATE_EPOCH="$(git -C /work/src/linux log -1 --format=%ct)"
fi
export SOURCE_DATE_EPOCH

# --- inputs ----------------------------------------------------------------------
KERNEL_BIN="${O}/arch/arm64/boot/Image"
DTB_BIN="${O}/${DTB_REL}"
INITRD_CPIO="${OUT}/staging/initrd_debug.cpio.zst"
for f in "${KERNEL_BIN}" "${DTB_BIN}" "${INITRD_CPIO}"; do
    [ -f "$f" ] || die "missing input ${f}"
done

# --- prefixed images ---------------------------------------------------------------
prefix_img "${KERNEL_BIN}"   "${OUT}/kernel.img"
prefix_img "${DTB_BIN}"      "${OUT}/dtb.img"
prefix_img "${INITRD_CPIO}"  "${OUT}/initrd_debug.img"

printf '%s\n' "${BOOTCFG_DEBUG_CMDLINE}" > "${OUT}/staging/bootcfg_debug.ini"
prefix_img "${OUT}/staging/bootcfg_debug.ini" "${OUT}/bootcfg_debug.img"

# --- kernel copies for the bootloader slot layout -----------------------------------
mkdir -p "${OUT}/bootcfg" "${OUT}/bootcfg_debug"
cp -f "${OUT}/kernel.img" "${OUT}/bootcfg/kernel.img"
cp -f "${OUT}/kernel.img" "${OUT}/bootcfg_debug/kernel_debug.img"

# --- modules archive ------------------------------------------------------------------
log "packing modules.tar.gz"
[ -d "${MODROOT}/lib/modules/${KVER}" ] || die "modroot missing"
[ -f "${MODROOT}/lib/modules/${KVER}/modules.dep" ] || die "modules.dep missing in modroot"
[ -f "${MODROOT}/lib/modules/${KVER}/updates/charge_boost_lite.ko.zst" ] \
    || die "updates/charge_boost_lite.ko.zst missing; run build-oot.sh first"
tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@${SOURCE_DATE_EPOCH}" \
    -C "${MODROOT}" -c lib \
    | gzip -n > "${OUT}/modules.tar.gz"

# --- charge initrd ------------------------------------------------------------
[ -f "${OUT}/staging/initrd_charge.cpio.zst" ] || die "missing staging/initrd_charge.cpio.zst (run make-charge-initrd first)"
prefix_img "${OUT}/staging/initrd_charge.cpio.zst" "${OUT}/initrd_charge.img"

# --- deploy containers ------------------------------------------------------------
# Already self-describing blob chains ([u32]initrd[u32]deb...): no extra
# prefix here, only presence + checksums
for f in initrd_deploy_release.img initrd_deploy_debug.img; do
    [ -f "${OUT}/$f" ] || die "missing $f (run make-deploy-initrd first)"
done

# --- checksums ----------------------------------------------------------------------------
(
    cd "${OUT}"
    sha256sum \
        kernel.img dtb.img initrd_debug.img bootcfg_debug.img initrd_charge.img \
        bootcfg/kernel.img bootcfg_debug/kernel_debug.img \
        headers.tar.gz modules.tar.gz \
        initrd_deploy_release.img initrd_deploy_debug.img \
        debs/*.deb > SHA256SUMS
)

log "artifacts:"
for f in \
    kernel.img dtb.img initrd_debug.img bootcfg_debug.img initrd_charge.img \
    bootcfg/kernel.img bootcfg_debug/kernel_debug.img \
    headers.tar.gz modules.tar.gz \
    initrd_deploy_release.img initrd_deploy_debug.img SHA256SUMS; do
    log "  $(ls -l "${OUT}/${f}")"
done
log "debs:"
for f in "${OUT}"/debs/*.deb; do
    log "  $(ls -l "$f")"
done
log "done"
