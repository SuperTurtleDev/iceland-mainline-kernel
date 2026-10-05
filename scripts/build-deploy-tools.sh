#!/usr/bin/env bash
# In-container stage: host-side deploy tools (makeblob, deployclient) and
# the RAM-deploy boot file set (initrd_ramdeploy.bin etc.).
set -euo pipefail

SRC=/work/src
OUT=/work/out
O="${OUT}/kbuild"
DTB_REL="arch/arm64/boot/dts/qcom/kaanapali-oneplus-iceland.dtb"
RAM="${OUT}/ramdeploy"

log() { printf '[build-deploy-tools] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

command -v gcc >/dev/null 2>&1 || die "gcc missing"
[ -f "${SRC}/deploy/makeblob.c" ]   || die "makeblob.c missing"
[ -f "${SRC}/deploy/deployclient.c" ] || die "deployclient.c missing"
[ -f "${OUT}/staging/deployd" ]     || die "deployd missing (run build-deployd first)"
[ -f "${OUT}/initrd_deploy_net_release.cpio.zst" ] || die "net initrd missing (run make-deploy-net-initrd)"
[ -f "${O}/arch/arm64/boot/Image" ] || die "kernel Image missing"
[ -f "${O}/${DTB_REL}" ]            || die "dtb missing"

mkdir -p "${OUT}/tools" "${RAM}"

# host tools (x86_64, same container)
gcc -O2 -Wall -Wextra -o "${OUT}/tools/makeblob"     "${SRC}/deploy/makeblob.c"
gcc -O2 -Wall -Wextra -o "${OUT}/tools/deployclient" "${SRC}/deploy/deployclient.c"
log "tools: makeblob + deployclient ($(du -h ${OUT}/tools/makeblob | cut -f1) / $(du -h ${OUT}/tools/deployclient | cut -f1))"

# RAM boot file set (TestBootApp stages these verbatim: RAW, no prefixes)
cp "${O}/arch/arm64/boot/Image" "${RAM}/kernel"
cp "${O}/${DTB_REL}"            "${RAM}/dtb"
printf 'console=tty0 clk_ignore_unused pd_ignore_unused\n' > "${RAM}/bootcfg"
cp "${OUT}/initrd_deploy_net_release.cpio.zst" "${RAM}/initrd_ramdeploy.bin"
cp "${OUT}/initrd_deploy_net_debug.cpio.zst"   "${RAM}/initrd_ramdeploy_debug.bin"

cat > "${RAM}/ramdeploy.sh" <<'EOS'
#!/usr/bin/env bash
# One-shot RAM deploy: stage the environment with TestBootApp, boot it,
# then stream the blob.  Run from the directory holding this file set.
#   ./ramdeploy.sh <deploy.blob> [debug]
set -eu
D=$(cd "$(dirname "$0")" && pwd)
INITRD=initrd_ramdeploy.bin
[ "${2:-}" = debug ] && INITRD=initrd_ramdeploy_debug.bin
fastboot flash bootcfg "$D/bootcfg"
fastboot flash kernel   "$D/kernel"
fastboot flash dtb      "$D/dtb"
fastboot flash initrd   "$D/$INITRD"
fastboot continue || true                      # device re-enumerates down
echo "== waiting for deploy NCM (60 s)..."
for i in $(seq 15); do ip -o addr show 2>/dev/null | grep -q enx && break; sleep 4; done
ip -4 -o addr show | grep enx | head -1
"${DEPLOYCLIENT:-$D/../tools/deployclient}" 192.168.42.42 5190 "$1"
EOS
chmod +x "${RAM}/ramdeploy.sh"

log "ramdeploy set: kernel dtb bootcfg initrd_ramdeploy.bin (+debug) + ramdeploy.sh"
log "done"
