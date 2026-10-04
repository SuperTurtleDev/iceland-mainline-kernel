#!/usr/bin/env bash
# In-container stage: assemble the four Debian packages from the build
# artifacts plus the packaging trees under debian/.
#
#   linux-modules-<kver>        staging/modroot (all .ko.zst + depmod data)
#   linux-headers-<kver>        headers.tar.gz (OOT dev package)
#   linux-image-<kver>          Image + .config + System.map; postinst
#                               flashes kernel/bootcfg partitions and runs
#                               /etc/kernel/postinst.d
#   linux-firmware-iceland      firmware tree + DTB + initramfs-tools config
#                               + generated module-set hook; postinst flashes
#                               the dtb partition
set -euo pipefail

SRC=/work/src
OUT=/work/out
KVER="7.2.0-sm8850"
VER="7.2.0-sm8850-1"
O="${OUT}/kbuild"
MODROOT="${OUT}/staging/modroot"
LIST="${SRC}/initrd-modules.txt"
DTB_REL="arch/arm64/boot/dts/qcom/kaanapali-oneplus-iceland.dtb"
S="${OUT}/staging/debs"

log() { printf '[build-debs] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb missing"
[ -f "${OUT}/headers.tar.gz" ]                || die "headers.tar.gz missing (run pack-headers first)"
[ -d "${MODROOT}/lib/modules/${KVER}" ]       || die "modroot missing (run build-kernel/build-oot first)"
[ -f "${O}/arch/arm64/boot/Image" ]           || die "Image missing"
[ -f "${O}/${DTB_REL}" ]                      || die "dtb missing"
[ -f "${SRC}/firmware/qcom/gen80200_sqe.fw" ] || die "firmware tree missing"
[ -f "${LIST}" ]                              || die "initrd-modules.txt missing"

export SOURCE_DATE_EPOCH="$(cat "${OUT}/staging/source-date-epoch" 2>/dev/null \
    || git -C "${SRC}/linux" log -1 --format=%ct)"

rm -rf "${S}"
mkdir -p "${S}" "${OUT}/debs"

# --- linux-modules -----------------------------------------------------------
T="${S}/linux-modules"
mkdir -p "${T}/DEBIAN"
cp -a "${SRC}/debian/linux-modules-${KVER}/DEBIAN/." "${T}/DEBIAN/"
mkdir -p "${T}/usr"
cp -a "${MODROOT}/lib" "${T}/usr/lib"

# --- linux-headers -------------------------------------------------------------
T="${S}/linux-headers"
mkdir -p "${T}/DEBIAN" "${T}/usr/src"
cp -a "${SRC}/debian/linux-headers-${KVER}/DEBIAN/." "${T}/DEBIAN/"
tar -xzf "${OUT}/headers.tar.gz" -C "${T}/usr/src"

# --- linux-image -----------------------------------------------------------------
T="${S}/linux-image"
mkdir -p "${T}/DEBIAN" "${T}/boot"
cp -a "${SRC}/debian/linux-image-${KVER}/DEBIAN/." "${T}/DEBIAN/"
cp "${O}/arch/arm64/boot/Image" "${T}/boot/vmlinuz-${KVER}"
cp "${O}/.config"                "${T}/boot/config-${KVER}"
cp "${O}/System.map"             "${T}/boot/System.map-${KVER}"

# --- linux-firmware-iceland ---------------------------------------------------------
T="${S}/linux-firmware-iceland"
mkdir -p "${T}/DEBIAN"
cp -a "${SRC}/debian/linux-firmware-iceland/DEBIAN/." "${T}/DEBIAN/"
cp -a "${SRC}/debian/linux-firmware-iceland/etc" "${T}/etc"
mkdir -p "${T}/usr/lib/firmware" "${T}/usr/lib/linux-image-${KVER}"
rsync -a --exclude='.git' "${SRC}/firmware/" "${T}/usr/lib/firmware/"
cp "${O}/${DTB_REL}" "${T}/usr/lib/linux-image-${KVER}/kaanapali-oneplus-iceland.dtb"

# generated initramfs-tools hook carrying the curated boot module set
mkdir -p "${T}/etc/initramfs-tools/hooks"
{
    echo '#!/bin/sh'
    echo '# initramfs-tools build hook -- GENERATED from initrd-modules.txt by'
    echo '# scripts/build-debs.sh; do not edit.  Adds the curated iceland boot'
    echo '# module set (conf.d/iceland sets MODULES=list to keep the rest out).'
    printf 'for m in'
    grep -E "^/usr/lib/modules/${KVER}/.*\.ko\.zst$" "${LIST}" \
        | sed 's|.*/||; s|\.ko\.zst$||' \
        | while IFS= read -r m; do printf ' \\\n    %s' "${m}"; done
    printf ';\ndo\n    manual_add_module "$m" 2>/dev/null || true\ndone\n'
} > "${T}/etc/initramfs-tools/hooks/iceland"

# dpkg-deb archives the mode bits as they are: make scripts executable
find "${S}" -type f \( -name postinst \
        -o -path '*/etc/kernel/postinst.d/*' \
        -o -path '*/etc/initramfs-tools/hooks/*' \) -exec chmod 0755 {} +

build() { # build <tree> <deb filename>
    dpkg-deb --root-owner-group -Zxz -z9 --build "$1" "${OUT}/debs/$2" >/dev/null
    dpkg-deb -I "${OUT}/debs/$2" >/dev/null || die "dpkg-deb -I failed for $2"
    log "built $2: $(du -h "${OUT}/debs/$2" | cut -f1)"
}

build "${S}/linux-modules"          "linux-modules-${KVER}_${VER}_arm64.deb"
build "${S}/linux-headers"          "linux-headers-${KVER}_${VER}_arm64.deb"
build "${S}/linux-image"            "linux-image-${KVER}_${VER}_arm64.deb"
build "${S}/linux-firmware-iceland" "linux-firmware-iceland_${VER}_arm64.deb"
log "done"
