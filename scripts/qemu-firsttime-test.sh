#!/usr/bin/env bash
# QEMU test of the netdeploy initrd's factory-first-boot repartitioning.
#
# Boots the real initrd_deploy_net_release.cpio.zst once on a synthetic
# stock-like disk (super/userdata, no esp), waits for the firsttime block
# to run (mkgpt + unsparse), then asserts the on-disk result:
#   - kernel/bootcfg/dtb/initrd/esp/rootfs present, super/userdata gone
#   - esp partition bytes identical to the bootloader esp.img (simg2img)
#   - console shows the provisioning log lines
set -euo pipefail

META="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-${META}/../../build/kernel}"
W="${OUT}/qemu-firsttime"

log() { printf '[qemu-firsttime-test] %s\n' "$*"; }
die() { log "FAIL: $*"; exit 1; }

command -v qemu-system-aarch64 >/dev/null || die "qemu-system-aarch64 missing"
command -v sfdisk >/dev/null          || die "sfdisk missing"
command -v simg2img >/dev/null        || die "simg2img missing"

INITRD="${OUT}/initrd_deploy_net_release.cpio.zst"
KERNEL="${OUT}/kbuild/arch/arm64/boot/Image"
ESPIMG="${OUT}/../bootloader/esp.img"
[ -f "$INITRD" ] || die "initrd missing (run ./build.sh)"
[ -f "$KERNEL" ] || die "kernel Image missing"
[ -f "$ESPIMG" ] || die "bootloader esp.img missing"

rm -rf "$W"; mkdir -p "$W"
truncate -s 4096MiB "$W/stock.raw"
sfdisk --no-reread -q "$W/stock.raw" <<'EOF'
label: gpt
name=misc, size=4MiB
name=modem, size=128MiB
name=persist, size=8MiB
name=super, size=1024MiB
name=userdata
EOF

log "booting the release initrd once (console -> console.log)"
qemu-system-aarch64 -M virt -cpu max -smp 2 -m 512M -nographic -no-reboot \
    -kernel "$KERNEL" -initrd "$INITRD" \
    -append 'console=ttyAMA0 clk_ignore_unused pd_ignore_unused' \
    -drive "if=none,id=hd,file=${W}/stock.raw,format=raw" \
    -device virtio-blk-device,drive=hd \
    >"$W/console.log" 2>&1 &
QPID=$!
trap 'kill $QPID 2>/dev/null || true' EXIT

ok=0
for _ in $(seq 60); do
    grep -q 'firsttime: LUN0 provisioned' "$W/console.log" && { ok=1; break; }
    grep -qE 'firsttime: (mkgpt failed|no esp and no candidate)' "$W/console.log" && break
    kill -0 $QPID 2>/dev/null || break
    sleep 3
done
sleep 2
kill $QPID 2>/dev/null || true
trap - EXIT

[ "$ok" = 1 ] || { log "provisioning marker never appeared:"; tail -30 "$W/console.log"; exit 1; }

# --- assertions on the resulting disk --------------------------------------
sfdisk -d "$W/stock.raw" >"$W/table.txt"

for n in kernel bootcfg dtb initrd esp rootfs; do
    grep -q "name=\"$n\"" "$W/table.txt" || die "partition $n missing"
done
if grep -qE 'name="(super|userdata)"' "$W/table.txt"; then
    die "super/userdata still present"
fi
grep -q 'mkgpt: create rootfs' "$W/console.log" || die "no mkgpt create log"
grep -q 'unsparse: done' "$W/console.log" || die "unsparse did not complete"

# esp partition bytes must equal the decoded bootloader image
start=$(grep 'name="esp"' "$W/table.txt" | sed -n 's/.*start= *\([0-9]*\).*/\1/p' | head -1)
size=$(grep  'name="esp"' "$W/table.txt" | sed -n 's/.*size= *\([0-9]*\).*/\1/p' | head -1)
[ -n "$start" ] && [ -n "$size" ] || die "cannot locate esp in table"
simg2img "$ESPIMG" "$W/esp-ref.raw"
dd if="$W/stock.raw" of="$W/esp-got.raw" bs=512 skip="$start" count="$size" status=none
cmp "$W/esp-got.raw" "$W/esp-ref.raw" || die "esp partition content differs"
truncate -s $(( size * 512 )) "$W/esp-got.raw" 2>/dev/null || true

log "PASS: table rewritten (super/userdata gone, linux set + rootfs-to-end), ESP byte-identical"
