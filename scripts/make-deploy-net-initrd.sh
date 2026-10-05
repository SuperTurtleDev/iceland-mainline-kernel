#!/usr/bin/env bash
# In-container stage: the SMALL net-deploy initrds (release/debug).
#
# Booted via TestBootApp RAM fastboot: the image is flashed straight into
# RAM (`fastboot flash initrd <this file>`, RAW cpio.zst -- NO u32 size
# prefix) together with kernel/dtb/bootcfg, then `fastboot continue`.
# Everything else (sparse rootfs + provision debs) streams over the NCM
# network to deployd -- so this initrd stays tiny and no partition ever
# carries a deploy payload.
set -euo pipefail

SRC=/work/src
OUT=/work/out
ROOT="${OUT}/staging/deploy-net-root"
GIC="${OUT}/kbuild/usr/gen_init_cpio"

log() { printf '[make-deploy-net-initrd] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ -x /opt/busybox-arm64/bin/busybox ]       || die "busybox missing"
[ -f "${SRC}/deploy/init-net" ]             || die "deploy/init-net missing"
[ -f "${SRC}/initrd_debug/etc/udhcpd.conf" ] || die "udhcpd.conf missing"
[ -f "${OUT}/staging/deployd" ]             || die "deployd missing (run build-deployd first)"
[ -x "${GIC}" ]                             || die "gen_init_cpio missing"

build() { # build <release|debug>
    mode="$1"
    rm -rf "${ROOT}"
    mkdir -p "${ROOT}"/{bin,sbin,usr/bin,usr/sbin,etc,tmp,proc,sys,dev,run,root,lib,debs}
    cp /opt/busybox-arm64/bin/busybox "${ROOT}/bin/busybox"
    chmod 0755 "${ROOT}/bin/busybox"
    ln -sf busybox "${ROOT}/bin/sh"
    cp "${OUT}/staging/deployd" "${ROOT}/deployd"
    chmod 0755 "${ROOT}/deployd"
    cp "${SRC}/deploy/init-net" "${ROOT}/init"
    chmod 0755 "${ROOT}/init"
    cp "${SRC}/initrd_debug/etc/udhcpd.conf" "${ROOT}/etc/udhcpd.conf"
    printf '%s\n' "${mode}" > "${ROOT}/etc/deploy-mode"

    # /dev/console + /dev/null nodes before devtmpfs (mknod is not
    # permitted in the rootless container; gen_init_cpio emits them)
    printf 'nod /dev/console 0600 0 0 c 5 1\nnod /dev/null 0666 0 0 c 1 3\n' \
        > "${OUT}/staging/deploy-net-nodes.desc"
    "${GIC}" "${OUT}/staging/deploy-net-nodes.desc" > "${OUT}/staging/deploy-net-nodes.cpio"

    (
        cd "${ROOT}"
        find . | LC_ALL=C sort | cpio -o -H newc --owner=0:0 2>"${OUT}/logs/deploy-net-cpio.log"
    ) | cat - "${OUT}/staging/deploy-net-nodes.cpio" \
        | zstd -q -19 -T0 > "${OUT}/initrd_deploy_net_${mode}.cpio.zst"
    log "initrd_deploy_net_${mode}.cpio.zst: $(du -h "${OUT}/initrd_deploy_net_${mode}.cpio.zst" | cut -f1) (raw, RAM-flashed)"
}

build release
build debug
log "done"
