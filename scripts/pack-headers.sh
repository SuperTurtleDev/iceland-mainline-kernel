#!/usr/bin/env bash
# In-container step 2: assemble the OOT module development package
# (Debian linux-headers-<kver> style) and pack it as headers.tar.gz.
#
# Layout inside the tarball:
#   usr/src/linux-headers-7.2.0-sm8850/
#     Makefile  .config  Module.symvers  System.map
#     include/            (source include/ + O/include generated+auto.conf)
#     arch/arm64/Makefile
#     arch/arm64/include/ (source + generated)
#     scripts/            (source scripts/ + O/scripts built host tools)
#
# Correctness is proven by scripts/build-oot.sh, which builds the
# oot/charge_boost module against the unpacked tarball (and nothing else).
set -euo pipefail

SRC=/work/src
OUT=/work/out
O="${OUT}/kbuild"
KVER="7.2.0-sm8850"
HDR_ROOT="${OUT}/staging/headers"
HDR="${HDR_ROOT}/usr/src/linux-headers-${KVER}"

log() { printf '[pack-headers] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ -f "${O}/Module.symvers" ] || die "no ${O}/Module.symvers; run build-kernel.sh first"

# SOURCE_DATE_EPOCH is produced by build-kernel.sh; fall back to the linux
# submodule commit time if the marker file is missing.
if [ -f "${OUT}/staging/source-date-epoch" ]; then
    SOURCE_DATE_EPOCH="$(cat "${OUT}/staging/source-date-epoch")"
else
    SOURCE_DATE_EPOCH="$(git -C "${SRC}/linux" log -1 --format=%ct)"
fi
export SOURCE_DATE_EPOCH
log "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}"

# --- assemble ----------------------------------------------------------------
rm -rf "${HDR_ROOT}"
mkdir -p "${HDR}/arch/arm64"

# top-level files: Makefile (+Kbuild) from source, generated bits from O=
cp -a "${SRC}/linux/Makefile"     "${HDR}/Makefile"
[ -f "${SRC}/linux/Kbuild" ] && cp -a "${SRC}/linux/Kbuild" "${HDR}/Kbuild" || true
cp -a "${O}/.config"              "${HDR}/.config"
cp -a "${O}/Module.symvers"       "${HDR}/Module.symvers"
cp -a "${O}/System.map"           "${HDR}/System.map"
[ -f "${O}/include/config/kernel.release" ] && \
    cp -a "${O}/include/config/kernel.release" "${HDR}/" || true

# include/: source headers first, then overlay O=/include (auto.conf,
# include/generated, include/config tristate bits, ...)
cp -a "${SRC}/linux/include" "${HDR}/include"
rsync -a "${O}/include/" "${HDR}/include/"

# arch/arm64: Makefile (+ optional postlink/module lds if the kernel tree
# ships them), include/ from source and O=
cp -a "${SRC}/linux/arch/arm64/Makefile" "${HDR}/arch/arm64/Makefile"
for f in Makefile.postlink kernel/module.lds kernel/module.lds.S; do
    if [ -f "${SRC}/linux/arch/arm64/${f}" ]; then
        mkdir -p "${HDR}/arch/arm64/$(dirname "${f}")"
        cp -a "${SRC}/linux/arch/arm64/${f}" "${HDR}/arch/arm64/${f}"
    fi
done
if [ -d "${SRC}/linux/arch/arm64/include" ]; then
    cp -a "${SRC}/linux/arch/arm64/include" "${HDR}/arch/arm64/include"
fi
if [ -d "${O}/arch/arm64/include" ]; then
    rsync -a "${O}/arch/arm64/include/" "${HDR}/arch/arm64/include/"
fi
# objtool is needed for module post-linking when STACK_VALIDATION is on
if grep -q '^CONFIG_OBJTOOL=y' "${O}/.config" && [ -d "${O}/tools" ]; then
    log "CONFIG_OBJTOOL=y: copying O=/tools"
    rsync -a "${O}/tools/" "${HDR}/tools/"
fi

# scripts/: source first, then overlay O=/scripts (built host tools such as
# basic/fixdep, mod/modpost, generated module.lds, ...)
cp -a "${SRC}/linux/scripts" "${HDR}/scripts"
rsync -a "${O}/scripts/" "${HDR}/scripts/"

# --- pack --------------------------------------------------------------------
log "creating ${OUT}/headers.tar.gz"
tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@${SOURCE_DATE_EPOCH}" \
    -C "${HDR_ROOT}" -c usr \
    | gzip -n > "${OUT}/headers.tar.gz"

log "headers package: $(du -sh "${OUT}/headers.tar.gz" | cut -f1), $(tar -tzf "${OUT}/headers.tar.gz" | wc -l) entries"
log "done"
