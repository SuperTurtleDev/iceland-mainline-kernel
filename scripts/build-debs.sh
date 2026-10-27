#!/usr/bin/env bash
# In-container stage: assemble the five Debian packages from the build
# artifacts plus the packaging trees under debian/.
#
#   linux-modules-iceland        staging/modroot (all .ko.zst + depmod data)
#   linux-headers-iceland        headers.tar.gz (OOT dev package)
#   linux-tools-iceland          staging/tools (perf under
#                               /usr/lib/linux-tools-<kver>/, built by the
#                               arm64 stage); postinst/prerm maintain the
#                               /usr/bin/perf-<kver> symlink
#   linux-image-iceland          Image + .config + System.map; postinst
#                               flashes kernel/bootcfg partitions and runs
#                               /etc/kernel/postinst.d
#   linux-firmware-iceland      firmware tree + DTB + initramfs-tools config
#                               + generated module-set hook; postinst flashes
#                               the dtb partition
#
# DEBIAN/control may carry ${shlibs:Depends}; it is replaced with the
# dependency list build-hdr-tools.sh computed from the shipped aarch64 ELFs
# (staging/shlibs/<package>).
set -euo pipefail

SRC=/work/src
OUT=/work/out
source "$(dirname "${BASH_SOURCE[0]}")/kernel-version.sh"
O="${OUT}/kbuild"
MODROOT="${OUT}/staging/modroot"
TOOLS="${OUT}/staging/tools"
SHLIBS="${OUT}/staging/shlibs"
LIST="${OUT}/staging/initrd-modules.txt"
sed "s/@KVER@/${KVER}/g" "${SRC}/initrd-modules.txt" > "${LIST}"
DTB_REL="arch/arm64/boot/dts/qcom/kaanapali-oneplus-iceland.dtb"
S="${OUT}/staging/debs"

log() { printf '[build-debs] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb missing"
[ -f "${OUT}/headers.tar.gz" ]                || die "headers.tar.gz missing (run pack-headers first)"
[ -x "${TOOLS}/usr/lib/linux-tools-${KVER}/perf" ] || die "staging/tools perf missing (run build-hdr-tools first)"
[ -s "${SHLIBS}/linux-headers" ] && [ -s "${SHLIBS}/linux-tools" ] \
                                              || die "staging/shlibs missing (run build-hdr-tools first)"
[ -d "${MODROOT}/lib/modules/${KVER}" ]       || die "modroot missing (run build-kernel/build-oot first)"
[ -f "${O}/arch/arm64/boot/Image" ]           || die "Image missing"
[ -f "${O}/${DTB_REL}" ]                      || die "dtb missing"
[ -f "${SRC}/firmware/qcom/gen80200_sqe.fw" ] || die "firmware tree missing"
[ -f "${LIST}" ]                              || die "initrd-modules.txt missing"

export SOURCE_DATE_EPOCH="$(cat "${OUT}/staging/source-date-epoch" 2>/dev/null \
    || git -C "${SRC}/linux" log -1 --format=%ct)"

rm -rf "${S}"
mkdir -p "${S}" "${OUT}/debs"

# control <linux-headers|linux-tools> <tree>: copy debian/<name>-iceland/DEBIAN
# and fill in ${shlibs:Depends} from staging/shlibs/<name>
control() {
    mkdir -p "$2/DEBIAN"
    cp -a "${SRC}/debian/$1-iceland/DEBIAN/." "$2/DEBIAN/"
    if grep -q '\${shlibs:Depends}' "$2/DEBIAN/control"; then
        sed -i "s|\${shlibs:Depends}|$(cat "${SHLIBS}/$1")|" "$2/DEBIAN/control"
    fi
    grep -q '\${' "$2/DEBIAN/control" && die "unsubstituted variable in $1 control"
    return 0
}

# --- linux-modules -----------------------------------------------------------
T="${S}/linux-modules"
mkdir -p "${T}/DEBIAN"
cp -a "${SRC}/debian/linux-modules-iceland/DEBIAN/." "${T}/DEBIAN/"
mkdir -p "${T}/usr"
cp -a "${MODROOT}/lib" "${T}/usr/lib"
# gunyah auto-load config + the verified VM smoke-test tools
mkdir -p "${T}/etc/modules-load.d" "${T}/usr/share/gunyah"
cp "${SRC}/debian/linux-modules-iceland/etc/modules-load.d/gunyah.conf" \
    "${T}/etc/modules-load.d/gunyah.conf"
for f in gh_vmtest.py gh_trace.sh gh_accepttest.py gh_sharetest.py gh_rmproxy.S; do
    [ -f "${SRC}/linux/tools/virt/gunyah/$f" ] \
        && cp "${SRC}/linux/tools/virt/gunyah/$f" "${T}/usr/share/gunyah/$f"
done

# --- linux-headers -------------------------------------------------------------
T="${S}/linux-headers"
mkdir -p "${T}/usr/src"
control "linux-headers" "${T}"
tar -xzf "${OUT}/headers.tar.gz" -C "${T}"
# the /lib/modules/<kver>/build symlink external-module builds resolve
# (Ubuntu flavour headers package does the same)
mkdir -p "${T}/usr/lib/modules/${KVER}"
ln -s "/usr/src/linux-headers-${KVER}" "${T}/usr/lib/modules/${KVER}/build"

# --- linux-tools ---------------------------------------------------------------
T="${S}/linux-tools"
mkdir -p "${T}"
cp -a "${TOOLS}/." "${T}/"
control "linux-tools" "${T}"

# --- linux-image -----------------------------------------------------------------
T="${S}/linux-image"
mkdir -p "${T}/DEBIAN" "${T}/boot"
cp -a "${SRC}/debian/linux-image-iceland/DEBIAN/." "${T}/DEBIAN/"
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

# generated initramfs-tools hook: curated boot module set + explicit
# firmware copy.  Follows the canonical hook contract (see hooks/kmod in
# the initramfs-tools package): handle the "prereqs" probe pass, source
# hook-functions, and mark modules with manual_add_modules -- the marks
# propagate through the exported $__MODULES_TO_ADD file and mkinitramfs
# installs them (deps + firmware included) via dracut-install in
# apply_add_modules().  A hook WITHOUT the prereqs guard runs its whole
# body during the probe pass and derails the mark/apply phasing.
mkdir -p "${T}/etc/initramfs-tools/hooks"
{
    echo '#!/bin/sh -e'
    echo '# initramfs-tools build hook -- GENERATED from initrd-modules.txt by'
    echo '# scripts/build-debs.sh; do not edit.  Marks the curated iceland boot'
    echo '# module set (conf.d/iceland sets MODULES=list to keep the rest out)'
    echo '# and copies the curated boot firmware explicitly.'
    echo 'if [ "$1" = "prereqs" ]; then exit 0; fi'
    echo '. /usr/share/initramfs-tools/hook-functions'
    printf 'manual_add_modules'
    grep -E "^/usr/lib/modules/${KVER}/.*\.ko\.zst$" "${LIST}" \
        | sed 's|.*/||; s|\.ko\.zst$||' \
        | while IFS= read -r m; do printf ' \\\n    %s' "${m}"; done
    printf '\n'
    echo 'echo "I: iceland hook: module set marked for install" >&2'
    echo '# dracut-install only includes firmware referenced by the modinfo of'
    echo '# installed modules -- copy the curated boot set unconditionally.'
    echo '# DESTDIR is usr-merged (lib -> usr/lib), so use the canonical path.'
    echo '# NOTE: mkinitramfs packs a 2-segment archive (uncompressed cpio with'
    echo '# the .ko.zst files, then a zstd cpio with everything else, firmware'
    echo '# included): verify with "3cpio --list", not grep or busybox cpio.'
    printf 'for f in'
    grep -E '^/usr/lib/firmware/' "${LIST}" \
        | sed 's|^/usr/lib/firmware/||' \
        | while IFS= read -r f; do printf ' \\\n    %s' "${f}"; done
    printf ';\ndo\n'
    printf '    if [ -f "/usr/lib/firmware/$f" ]; then\n'
    printf '        mkdir -p "${DESTDIR}/usr/lib/firmware/$(dirname "$f")"\n'
    printf '        cp "/usr/lib/firmware/$f" "${DESTDIR}/usr/lib/firmware/$f"\n'
    printf '    else\n'
    printf '        echo "W: iceland hook: firmware missing: $f" >&2\n'
    printf '    fi\ndone\n'
} > "${T}/etc/initramfs-tools/hooks/iceland"

# Render all package metadata and maintainer scripts from stable templates.
find "${S}" -path '*/DEBIAN/*' -type f -exec sed -i "s/@KVER@/${KVER}/g; s/@VERSION@/${VER}/g" {} +
if grep -RE '@(KVER|VERSION)@' "${S}"/*/DEBIAN/control; then
    die "unrendered package metadata"
fi

# dpkg-deb archives the mode bits as they are: make scripts executable
find "${S}" -type f \( -name postinst -o -name prerm \
        -o -path '*/etc/kernel/postinst.d/*' \
        -o -path '*/etc/initramfs-tools/hooks/*' \) -exec chmod 0755 {} +

build() { # build <tree> <deb filename>
    dpkg-deb --root-owner-group -Zxz -z9 --build "$1" "${OUT}/debs/$2" >/dev/null
    dpkg-deb -I "${OUT}/debs/$2" >/dev/null || die "dpkg-deb -I failed for $2"
    log "built $2: $(du -h "${OUT}/debs/$2" | cut -f1)"
}

build "${S}/linux-modules"          "linux-modules-iceland_${VER}_arm64.deb"
build "${S}/linux-headers"          "linux-headers-iceland_${VER}_arm64.deb"
build "${S}/linux-tools"            "linux-tools-iceland_${VER}_arm64.deb"
build "${S}/linux-image"            "linux-image-iceland_${VER}_arm64.deb"
build "${S}/linux-firmware-iceland" "linux-firmware-iceland_${VER}_arm64.deb"
log "done"
