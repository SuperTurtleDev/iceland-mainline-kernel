#!/usr/bin/env bash
# In-container stage: assemble the debug initrd.
#
# Tree assembled at /work/out/staging/initrd-root:
#   /bin/busybox                    arm64 static (from /opt/busybox-arm64)
#   /init, /etc/udhcpd.conf         from the metarepo initrd_debug/ skeleton
#   /etc/modules.order              load order built by module-order.py
#   /lib/modules/<kver>/...         module subset, as BARE .ko files
#   /lib/firmware/...               firmware subset
#
# busybox insmod/modprobe only support uncompressed modules, so every module
# entering the initrd is decompressed (zstd -d) from the modroot .ko.zst; the
# compressed .ko.zst copies remain exclusive to modules.tar.gz (the rootfs
# side has kmod).  After the subset copy, depmod -b regenerates modules.dep
# & friends for exactly the modules present, and scripts/module-order.py
# topologically sorts modules.dep (dependencies first) into /etc/modules.order
# which /init follows with busybox modprobe.
#
# List entries missing from modroot are recorded in
# /work/out/staging/initrd-missing.txt and only produce a warning.
#
# Output: /work/out/staging/initrd_debug.cpio.zst
set -euo pipefail

SRC=/work/src
OUT=/work/out
KVER="7.2.0-sm8850"
MODROOT="${OUT}/staging/modroot"
ROOT="${OUT}/staging/initrd-root"
LIST="${SRC}/initrd-modules.txt"
MISSING="${OUT}/staging/initrd-missing.txt"
KMODDIR="lib/modules/${KVER}"

log() { printf '[make-initrd] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ -x /opt/busybox-arm64/bin/busybox ]          || die "/opt/busybox-arm64/bin/busybox missing"
[ -f "${LIST}" ]                               || die "${LIST} missing"
[ -d "${MODROOT}/lib/modules/${KVER}" ]        || die "modroot missing; run build-kernel.sh first"
[ -f "${SRC}/initrd_debug/init" ]              || die "${SRC}/initrd_debug/init missing"
[ -f "${SRC}/scripts/module-order.py" ]        || die "${SRC}/scripts/module-order.py missing"

# --- assemble the tree ---------------------------------------------------------
rm -rf "${ROOT}"
mkdir -p "${ROOT}"/{bin,sbin,usr/bin,usr/sbin,etc,tmp,proc,sys,dev/pts,run,root,lib}
mkdir -p "${ROOT}/${KMODDIR}" "${ROOT}/lib/firmware"

cp /opt/busybox-arm64/bin/busybox "${ROOT}/bin/busybox"
chmod 0755 "${ROOT}/bin/busybox"
# the kernel resolves /init's "#!/bin/sh" shebang BEFORE /init can run
# busybox --install: the interpreter symlink must exist in the cpio itself
ln -sf busybox "${ROOT}/bin/sh"

# /dev/console and /dev/null as device nodes: the kernel opens /dev/console
# for init's stdio before devtmpfs is mounted.  mknod is not permitted inside
# the rootless container, so the kernel's own gen_init_cpio emits them from a
# description file; the small archive is concatenated onto the main cpio
# (initramfs unpacks concatenated archives in order).
GIC="${OUT}/kbuild/usr/gen_init_cpio"
[ -x "${GIC}" ] || die "gen_init_cpio missing at ${GIC}"
printf 'nod /dev/console 0600 0 0 c 5 1\nnod /dev/null 0666 0 0 c 1 3\n' \
    > "${OUT}/staging/initrd-nodes.desc"
"${GIC}" "${OUT}/staging/initrd-nodes.desc" > "${OUT}/staging/initrd-nodes.cpio"

# initrd_debug/ skeleton (init, etc/udhcpd.conf, ...); README.md is
# repository documentation, not initrd content
cp -a "${SRC}/initrd_debug/." "${ROOT}/"
rm -f "${ROOT}/README.md"
chmod 0755 "${ROOT}/init"

: > "${MISSING}"
n_mod=0; n_mod_miss=0; n_fw=0; n_fw_miss=0

# --- module subset: decompress .ko.zst -> bare .ko -------------------------------
while IFS= read -r line; do
    case "$line" in
        "/usr/lib/modules/${KVER}/"*.ko.zst)
            rel="${line#/usr/lib/modules/${KVER}/}"
            src="${MODROOT}/lib/modules/${KVER}/${rel}"
            if [ -f "${src}" ]; then
                # strip the .zst suffix: initrd modules are bare .ko
                dst="${ROOT}/${KMODDIR}/${rel%.zst}"
                mkdir -p "$(dirname "${dst}")"
                zstd -q -d -f "${src}" -o "${dst}"
                n_mod=$((n_mod + 1))
            else
                printf 'module  %s\n' "${line}" >> "${MISSING}"
                n_mod_miss=$((n_mod_miss + 1))
            fi
            ;;
    esac
done < "${LIST}"

# --- firmware subset ---------------------------------------------------------------
while IFS= read -r line; do
    case "$line" in
        "/usr/lib/firmware/"*)
            rel="${line#/usr/lib/firmware/}"
            src="${SRC}/firmware/${rel}"
            if [ -f "${src}" ]; then
                dst="${ROOT}/lib/firmware/${rel}"
                mkdir -p "$(dirname "${dst}")"
                cp -a "${src}" "${dst}"
                n_fw=$((n_fw + 1))
            else
                printf 'firmware  %s\n' "${line}" >> "${MISSING}"
                n_fw_miss=$((n_fw_miss + 1))
            fi
            ;;
    esac
done < "${LIST}"

log "modules: ${n_mod} copied (bare .ko), ${n_mod_miss} missing"
log "firmware: ${n_fw} copied, ${n_fw_miss} missing"
if [ -s "${MISSING}" ]; then
    log "WARNING: missing entries recorded in staging/initrd-missing.txt"
fi

# modules.builtin lets busybox modprobe skip modules built into the kernel
# (also silences depmod's warning about it being absent)
cp "${MODROOT}/lib/modules/${KVER}/modules.builtin" "${ROOT}/${KMODDIR}/modules.builtin" 2>/dev/null || true

# --- dependency metadata for exactly the subset present ---------------------------
depmod -b "${ROOT}" "${KVER}"

# --- module load order: topological sort of modules.dep ---------------------------
python3 "${SRC}/scripts/module-order.py" "${ROOT}/${KMODDIR}/modules.dep" \
    > "${ROOT}/etc/modules.order"
n_order="$(grep -c -v '^[[:space:]]*$' "${ROOT}/etc/modules.order" || true)"
log "modules.order: ${n_order} entries"

# --- pack (deterministic entry ordering) ---------------------------------------------
log "packing initrd_debug.cpio.zst"
(
    cd "${ROOT}"
    find . | LC_ALL=C sort | cpio -o -H newc --owner=0:0 2>"${OUT}/logs/initrd-cpio.log"
) | cat - "${OUT}/staging/initrd-nodes.cpio" \
    | zstd -q -19 -T0 > "${OUT}/staging/initrd_debug.cpio.zst"

log "initrd: $(du -h "${OUT}/staging/initrd_debug.cpio.zst" | cut -f1)"
log "done"
