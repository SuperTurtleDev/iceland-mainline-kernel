#!/usr/bin/env bash
# In-container step 3: accept the shipped headers with an independent smoke
# module, then confirm the in-tree charging modules are the only packaged path.
set -euo pipefail

OUT=/work/out
source "$(dirname "${BASH_SOURCE[0]}")/kernel-version.sh"
HDR_TEST="${OUT}/staging/hdr-test"
HDR="${HDR_TEST}/usr/src/linux-headers-${KVER}"
SMOKE="${OUT}/staging/header-smoke"
MODROOT="${OUT}/staging/modroot"
MODULE_DIR="${MODROOT}/lib/modules/${KVER}"
CHARGER_DIR="${MODULE_DIR}/kernel/drivers/power/supply"

log() { printf '[verify-modules] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ "$(uname -m)" = aarch64 ] || die "must run in the arm64 container"
[ -f "${OUT}/headers.tar.gz" ] || die "headers.tar.gz missing"
[ -d "${MODULE_DIR}" ] || die "modroot missing"

rm -rf "${HDR_TEST}" "${SMOKE}"
mkdir -p "${HDR_TEST}" "${SMOKE}"
tar -xzf "${OUT}/headers.tar.gz" -C "${HDR_TEST}"
[ -f "${HDR}/Makefile" ] || die "headers package has no Makefile"

printf 'obj-m += iceland_header_smoke.o\n' > "${SMOKE}/Makefile"
cat > "${SMOKE}/iceland_header_smoke.c" <<'EOF'
#include <linux/init.h>
#include <linux/module.h>
static int __init smoke_init(void) { return 0; }
static void __exit smoke_exit(void) { }
module_init(smoke_init);
module_exit(smoke_exit);
MODULE_LICENSE("GPL");
EOF
log "building header acceptance module against ${HDR}"
if ! make -C "${HDR}" M="${SMOKE}" ARCH=arm64 LLVM=1 modules \
        >"${OUT}/logs/header-smoke-build.log" 2>&1; then
    tail -80 "${OUT}/logs/header-smoke-build.log" >&2
    die "headers acceptance build failed"
fi
[ -f "${SMOKE}/iceland_header_smoke.ko" ] || die "acceptance module missing"

[ -f "${CHARGER_DIR}/oplus-sc8547d/oplus-sc8547d-charger.ko.zst" ] || die "missing in-tree fast charging module"
[ -f "${CHARGER_DIR}/oplus-sc8547d/sc8547d.ko.zst" ] || die "missing in-tree SC8547D module"
depmod -b "${MODROOT}" "${KVER}"
resolved="$(modprobe -d "${MODROOT}" -S "${KVER}" --resolve-alias 'of:NchargerTCoplus,sc8547d-fastcharger')"
[ "${resolved}" = oplus_sc8547d_charger ] || die "fast charger DT alias resolves to '${resolved}'"
resolved="$(modprobe -d "${MODROOT}" -S "${KVER}" --resolve-alias 'of:Ncharge-pumpTCsouthchip,sc8547d')"
[ "${resolved}" = sc8547d ] || die "SC8547D DT alias resolves to '${resolved}'"
modinfo -F depends "${CHARGER_DIR}/oplus-sc8547d/oplus-sc8547d-charger.ko.zst" | tr ',' '\n' | grep -qx sc8547d \
    || die "missing sc8547d symbol dependency"
log "in-tree fast charging modules and DT aliases verified"
