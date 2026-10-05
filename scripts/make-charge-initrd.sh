#!/usr/bin/env bash
# In-container stage: charging initrd (initrd_charge.img payload).
#
# The debug-initrd base, NOT a stripped-down image: the full curated
# module set (bare .ko) + firmware subset from initrd-modules.txt, depmod
# metadata, /etc/modules.order topological load list, USB NCM/telnet
# debug stack -- plus the out-of-tree charge_boost_lite module added to
# the module set and initrd_charge/init as /init (9 V / 2 A fixed-PDO
# session with console telemetry and the pd-boost safety gates).
set -euo pipefail

SRC=/work/src
OUT=/work/out
KVER="7.2.0-sm8850"
MODROOT="${OUT}/staging/modroot"
ROOT="${OUT}/staging/charge-root"
LIST="${SRC}/initrd-modules.txt"
MISSING="${OUT}/staging/charge-missing.txt"
KMODDIR="lib/modules/${KVER}"
GIC="${OUT}/kbuild/usr/gen_init_cpio"

log() { printf '[make-charge-initrd] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ -x /opt/busybox-arm64/bin/busybox ]          || die "/opt/busybox-arm64/bin/busybox missing"
[ -f "${LIST}" ]                               || die "${LIST} missing"
[ -d "${MODROOT}/lib/modules/${KVER}" ]        || die "modroot missing (run build-kernel/build-oot first)"
[ -f "${SRC}/initrd_charge/init" ]             || die "initrd_charge/init missing"
[ -f "${SRC}/initrd_debug/etc/udhcpd.conf" ]   || die "initrd_debug/etc/udhcpd.conf missing"
[ -f "${SRC}/scripts/module-order.py" ]        || die "scripts/module-order.py missing"
[ -f "${MODROOT}/lib/modules/${KVER}/updates/charge_boost_lite.ko.zst" ] \
    || die "charge_boost_lite.ko.zst missing (run build-oot first)"
[ -x "${GIC}" ] || die "gen_init_cpio missing at ${GIC}"

# --- assemble the tree (mirrors make-initrd.sh) --------------------------------
rm -rf "${ROOT}"
mkdir -p "${ROOT}"/{bin,sbin,usr/bin,usr/sbin,etc,tmp,proc,sys,dev/pts,run,root,lib}
mkdir -p "${ROOT}/${KMODDIR}" "${ROOT}/lib/firmware"

cp /opt/busybox-arm64/bin/busybox "${ROOT}/bin/busybox"
chmod 0755 "${ROOT}/bin/busybox"
ln -sf busybox "${ROOT}/bin/sh"

cp "${SRC}/initrd_charge/init" "${ROOT}/init"
chmod 0755 "${ROOT}/init"
cp "${SRC}/initrd_debug/etc/udhcpd.conf" "${ROOT}/etc/udhcpd.conf"

: > "${MISSING}"
n_mod=0; n_mod_miss=0; n_fw=0; n_fw_miss=0

# module subset: decompress .ko.zst -> bare .ko (busybox insmod/modprobe)
while IFS= read -r line; do
    case "$line" in
        "/usr/lib/modules/${KVER}/"*.ko.zst)
            rel="${line#/usr/lib/modules/${KVER}/}"
            src="${MODROOT}/lib/modules/${KVER}/${rel}"
            if [ -f "${src}" ]; then
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

# the charging module joins the same set, as a bare .ko under updates/
mkdir -p "${ROOT}/${KMODDIR}/updates"
zstd -q -d -f "${MODROOT}/lib/modules/${KVER}/updates/charge_boost_lite.ko.zst" \
    -o "${ROOT}/${KMODDIR}/updates/charge_boost_lite.ko"
n_mod=$((n_mod + 1))

# firmware subset
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

log "modules: ${n_mod} copied bare (curated set + charge_boost_lite), ${n_mod_miss} missing"
log "firmware: ${n_fw} copied, ${n_fw_miss} missing"

# dependency metadata for exactly the set present (charge_boost included)
cp "${MODROOT}/lib/modules/${KVER}/modules.builtin" "${ROOT}/${KMODDIR}/modules.builtin" 2>/dev/null || true
depmod -b "${ROOT}" "${KVER}"

# topologically sorted load order
python3 "${SRC}/scripts/module-order.py" "${ROOT}/${KMODDIR}/modules.dep" \
    > "${ROOT}/etc/modules.order"
log "modules.order: $(grep -c -v '^[[:space:]]*$' "${ROOT}/etc/modules.order") entries"

# device nodes the kernel opens before devtmpfs is mounted (mknod is not
# permitted in the rootless container; same trick as make-initrd.sh)
printf 'nod /dev/console 0600 0 0 c 5 1\nnod /dev/null 0666 0 0 c 1 3\n' \
    > "${OUT}/staging/charge-nodes.desc"
"${GIC}" "${OUT}/staging/charge-nodes.desc" > "${OUT}/staging/charge-nodes.cpio"

log "packing initrd_charge.cpio.zst"
(
    cd "${ROOT}"
    find . | LC_ALL=C sort | cpio -o -H newc --owner=0:0 2>"${OUT}/logs/charge-cpio.log"
) | cat - "${OUT}/staging/charge-nodes.cpio" \
    | zstd -q -19 -T0 > "${OUT}/staging/initrd_charge.cpio.zst"

log "initrd_charge: $(du -h "${OUT}/staging/initrd_charge.cpio.zst" | cut -f1)"
log "done"
