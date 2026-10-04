#!/usr/bin/env bash
# In-container step 4: build the debug initrd.
#
# Tree assembled at /work/out/staging/initrd-root:
#   /bin/busybox            (arm64 static, from /opt/busybox-arm64)
#   /init, /etc/udhcpd.conf (from the metarepo initrd_debug/ directory)
#   /lib/modules/7.2.0-sm8850/...  subset listed in initrd-modules.txt
#   /lib/firmware/...               subset listed in initrd-modules.txt
#
# Missing module/firmware entries are recorded in
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

log() { printf '[make-initrd] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ -x /opt/busybox-arm64/bin/busybox ] || die "/opt/busybox-arm64/bin/busybox missing"
[ -f "${LIST}" ]                     || die "${LIST} missing"
[ -d "${MODROOT}/lib/modules/${KVER}" ] || die "modroot missing; run build-kernel.sh first"
[ -f "${SRC}/initrd_debug/init" ]    || die "${SRC}/initrd_debug/init missing"

# --- assemble the tree ---------------------------------------------------------
rm -rf "${ROOT}"
mkdir -p "${ROOT}"/{bin,sbin,usr/bin,usr/sbin,etc,tmp,proc,sys,dev/pts,run,root,lib}
mkdir -p "${ROOT}/lib/modules/${KVER}" "${ROOT}/lib/firmware"

cp /opt/busybox-arm64/bin/busybox "${ROOT}/bin/busybox"
chmod 0755 "${ROOT}/bin/busybox"

# initrd_debug/ skeleton (init, etc/udhcpd.conf, ...); README.md is
# repository documentation, not initrd content
cp -a "${SRC}/initrd_debug/." "${ROOT}/"
rm -f "${ROOT}/README.md"
chmod 0755 "${ROOT}/init"

: > "${MISSING}"
n_mod=0; n_mod_miss=0; n_fw=0; n_fw_miss=0

# --- module subset ---------------------------------------------------------------
while IFS= read -r line; do
    case "$line" in
        "/usr/lib/modules/${KVER}/"*)
            rel="${line#/usr/lib/modules/${KVER}/}"
            src="${MODROOT}/lib/modules/${KVER}/${rel}"
            if [ -f "${src}" ]; then
                dst="${ROOT}/lib/modules/${KVER}/${rel}"
                mkdir -p "$(dirname "${dst}")"
                cp -a "${src}" "${dst}"
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

log "modules: ${n_mod} copied, ${n_mod_miss} missing"
log "firmware: ${n_fw} copied, ${n_fw_miss} missing"
if [ -s "${MISSING}" ]; then
    log "WARNING: missing entries recorded in staging/initrd-missing.txt:"
    cat "${MISSING}" >&2 || true
fi

# --- module dependency metadata ------------------------------------------------------
depmod -b "${ROOT}" "${KVER}"

# --- pack (deterministic ordering) ---------------------------------------------------
log "packing initrd_debug.cpio.zst"
(
    cd "${ROOT}"
    find . | LC_ALL=C sort | cpio -o -H newc --owner=0:0 2>"${OUT}/logs/initrd-cpio.log" \
        | zstd -q -19 -T0 > "${OUT}/staging/initrd_debug.cpio.zst"
)

log "initrd: $(du -h "${OUT}/staging/initrd_debug.cpio.zst" | cut -f1)"
log "done"
