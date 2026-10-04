#!/usr/bin/env bash
# In-container stage: build the deploy bootstrap initrds (release/debug) and
# the initrd-partition container images.
#
# The GPT initrd partition holds a blob chain:
#     [u32 LE n0] bootstrap initrd   <-- the ONLY part BootApp loads
#     [u32 LE nK] .deb blobs         <-- read off the partition at runtime
# Keeping the debs out of the loaded initrd minimises bootloader memory
# use; the bootstrap init (deploy/init) walks the chain from disk into
# tmpfs and chroot-installs them.
set -euo pipefail

SRC=/work/src
OUT=/work/out
KVER="7.2.0-sm8850"
VER="7.2.0-sm8850-1"
ROOT="${OUT}/staging/deploy-root"
DEBS="${OUT}/debs"
GIC="${OUT}/kbuild/usr/gen_init_cpio"

log() { printf '[make-deploy-initrd] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ -x /opt/busybox-arm64/bin/busybox ]  || die "/opt/busybox-arm64/bin/busybox missing"
[ -f "${SRC}/deploy/init" ]            || die "deploy/init missing"
[ -f "${SRC}/initrd_debug/etc/udhcpd.conf" ] || die "initrd_debug/etc/udhcpd.conf missing"
[ -x "${GIC}" ]                        || die "gen_init_cpio missing at ${GIC}"
for d in "linux-modules-${KVER}_${VER}_arm64.deb" \
         "linux-firmware-iceland_${VER}_arm64.deb" \
         "linux-image-${KVER}_${VER}_arm64.deb" \
         "linux-headers-${KVER}_${VER}_arm64.deb"; do
    [ -f "${DEBS}/$d" ] || die "${DEBS}/$d missing (run build-debs first)"
done

build_initrd() { # build_initrd <release|debug>
    mode="$1"
    rm -rf "${ROOT}"
    mkdir -p "${ROOT}"/{bin,sbin,usr/bin,usr/sbin,etc,tmp,proc,sys,dev,run,root,lib}
    cp /opt/busybox-arm64/bin/busybox "${ROOT}/bin/busybox"
    chmod 0755 "${ROOT}/bin/busybox"
    ln -sf busybox "${ROOT}/bin/sh"   # /init needs its interpreter in-cpio
    cp "${SRC}/deploy/init" "${ROOT}/init"
    chmod 0755 "${ROOT}/init"
    cp "${SRC}/initrd_debug/etc/udhcpd.conf" "${ROOT}/etc/udhcpd.conf"
    printf '%s\n' "${mode}" > "${ROOT}/etc/deploy-mode"

    # device nodes the kernel opens before devtmpfs is mounted (mknod is not
    # permitted in the rootless container; see make-initrd.sh)
    printf 'nod /dev/console 0600 0 0 c 5 1\nnod /dev/null 0666 0 0 c 1 3\n' \
        > "${OUT}/staging/deploy-nodes.desc"
    "${GIC}" "${OUT}/staging/deploy-nodes.desc" > "${OUT}/staging/deploy-nodes.cpio"

    (
        cd "${ROOT}"
        find . | LC_ALL=C sort | cpio -o -H newc --owner=0:0 2>"${OUT}/logs/deploy-cpio.log"
    ) | cat - "${OUT}/staging/deploy-nodes.cpio" \
        | zstd -q -19 -T0 > "${OUT}/staging/initrd_deploy_${mode}.cpio.zst"
    log "initrd_deploy_${mode}.cpio.zst: $(du -h "${OUT}/staging/initrd_deploy_${mode}.cpio.zst" | cut -f1)"
}

pack_container() { # pack_container <release|debug>
    mode="$1"
    python3 - "${OUT}/initrd_deploy_${mode}.img" \
        "${OUT}/staging/initrd_deploy_${mode}.cpio.zst" \
        "${DEBS}/linux-modules-${KVER}_${VER}_arm64.deb" \
        "${DEBS}/linux-firmware-iceland_${VER}_arm64.deb" \
        "${DEBS}/linux-image-${KVER}_${VER}_arm64.deb" \
        "${DEBS}/linux-headers-${KVER}_${VER}_arm64.deb" <<'PYEOF'
import struct
import sys

out_path, *blob_paths = sys.argv[1:]
blobs = [open(p, "rb").read() for p in blob_paths]
with open(out_path, "wb") as f:
    for b in blobs:
        f.write(struct.pack("<I", len(b)))
        f.write(b)

# self-check: the chain must consume the file exactly
with open(out_path, "rb") as f:
    data = f.read()
pos, count = 0, 0
while pos < len(data):
    (n,) = struct.unpack_from("<I", data, pos)
    pos += 4 + n
    count += 1
assert pos == len(data), f"{out_path}: chain over/under-run at {pos}/{len(data)}"
assert count == len(blobs), f"{out_path}: {count} blobs, expected {len(blobs)}"
PYEOF
    log "initrd_deploy_${mode}.img: $(du -h "${OUT}/initrd_deploy_${mode}.img" | cut -f1) (initrd + 4 debs)"
}

build_initrd release
build_initrd debug
pack_container release
pack_container debug
log "done"
