#!/usr/bin/env bash
# In-container step 2: assemble the OOT module development package
# (Ubuntu linux-headers-<kver> style) and pack it as headers.tar.gz.
#
# Layout inside the tarball: the full source-tree skeleton (Ubuntu
# filter: Makefile*/Kconfig*/Kbuild*/*.sh/*.pl/*.lds everywhere) plus
# include/, scripts/ and arch/*/include/ wholesale, overlaid with the
# O= build artifacts (.config, Module.symvers, System.map, generated
# headers, built host tools).
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
# Content follows the Ubuntu kernel packaging recipe (debian/rules.d/
# 3-binary-indep.mk stamp-install-headers, checked against the actual
# linux-headers-7.0.0-30 package): the FULL source-tree skeleton plus the
# build artifacts, so external modules build exactly as against a distro
# headers package:
#   whole tree   Makefile*, Kconfig*, Kbuild*, *.sh, *.pl, *.lds
#   wholesale    scripts/ and include/
#   wholesale    every arch/*/include/ directory
#   from O=      .config Module.symvers System.map include/generated +
#                include/config/auto.conf, arch/arm64/include/generated,
#                built host tools under scripts/, objtool
#   removed      *.o *.cmd ("Do not ship .o and .cmd artifacts")
rm -rf "${HDR_ROOT}"
mkdir -p "${HDR}"

# skeleton: the Ubuntu find filter, run from the linux source root
(
    cd "${SRC}/linux"
    find . -path './.git' -prune -o -path './include' -prune \
        -o -path './scripts' -prune -o -type f \
        \( -name 'Makefile*' -o -name 'Kconfig*' -o -name 'Kbuild*' \
           -o -name '*.sh' -o -name '*.pl' -o -name '*.lds' \) -print \
    | cpio -pd --preserve-modification-time "${HDR}" 2>/dev/null
)

# wholesale: scripts/ and include/ from source, overlaid with O= generated
cp -a "${SRC}/linux/scripts" "${HDR}/scripts"
cp -a "${SRC}/linux/include" "${HDR}/include"
rsync -a "${O}/include/" "${HDR}/include/"

# every arch/*/include from source, overlaid with O= generated headers
find "${SRC}/linux/arch" -name include -type d | while read -r d; do
    rel="${d#"${SRC}/linux/"}"
    mkdir -p "${HDR}/${rel}"
    rsync -a "$d/" "${HDR}/${rel}/"
done
rsync -a "${O}/arch/arm64/include/" "${HDR}/arch/arm64/include/"

# top-level build artifacts
cp -a "${O}/.config"              "${HDR}/.config"
cp -a "${O}/Module.symvers"       "${HDR}/Module.symvers"
cp -a "${O}/System.map"           "${HDR}/System.map"
[ -f "${O}/include/config/kernel.release" ] && \
    cp -a "${O}/include/config/kernel.release" "${HDR}/" || true

# objtool is needed for module post-linking when STACK_VALIDATION is on
if grep -q '^CONFIG_OBJTOOL=y' "${O}/.config" && [ -d "${O}/tools" ]; then
    log "CONFIG_OBJTOOL=y: copying O=/tools"
    rsync -a "${O}/tools/" "${HDR}/tools/"
fi

# built host tools over the source scripts/ (fixdep, modpost, module.lds, ...)
rsync -a "${O}/scripts/" "${HDR}/scripts/"

# Ubuntu: "Do not ship .o and .cmd artifacts in headers"
find "${HDR}" \( -name '*.o' -o -name '*.cmd' \) -exec rm -f {} +

# --- pack --------------------------------------------------------------------
log "creating ${OUT}/headers.tar.gz"
tar --sort=name --owner=0 --group=0 --numeric-owner \
    --mtime="@${SOURCE_DATE_EPOCH}" \
    -C "${HDR_ROOT}" -c usr \
    | gzip -n > "${OUT}/headers.tar.gz"

log "headers package: $(du -sh "${OUT}/headers.tar.gz" | cut -f1), $(tar -tzf "${OUT}/headers.tar.gz" | wc -l) entries"
log "done"
