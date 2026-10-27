#!/usr/bin/env bash
# In-container (arm64) stage: the native aarch64 binaries of the two
# developer packages, built in their own O= tree so the x86_64 main build
# tree is never mixed with device binaries.
#
#   kbuild_hdr/scripts/**         kernel host tools (fixdep, modpost, dtc,
#                                 sign-file, ...) -> linux-headers:
#                                 pack-headers.sh takes scripts/ from here and
#                                 everything else from kbuild
#   kbuild_hdr/tools/perf/perf    -> staging/tools/usr/lib/linux-tools-<kver>/perf
#                                 (Ubuntu linux-tools-<version> layout)
#   staging/shlibs/<package>      runtime Depends of the shipped ELFs, resolved
#                                 through ldconfig + dpkg -S in this rootfs;
#                                 build-debs.sh substitutes it for
#                                 ${shlibs:Depends} in DEBIAN/control
#
# Runs in the arm64 rootfs provisioned from podman_container/
# packages-arm64.list (qemu-user binfmt on an x86_64 host), with the main
# tree's .config so the kbuild host tool set is identical.
set -euo pipefail

SRC=/work/src
OUT=/work/out
KO="${OUT}/kbuild"
O="${OUT}/kbuild_hdr"
source "$(dirname "${BASH_SOURCE[0]}")/kernel-version.sh"
TOOLS="${OUT}/staging/tools"
SHLIBS="${OUT}/staging/shlibs"
PERF_O="${O}/tools/perf"

log() { printf '[build-hdr-tools] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

[ "$(uname -m)" = aarch64 ]    || die "must run in the arm64 container (uname -m: $(uname -m))"
[ -f "${KO}/Module.symvers" ]  || die "no ${KO}/Module.symvers; run build-kernel.sh first"
[ -f "${OUT}/staging/source-date-epoch" ] || die "staging/source-date-epoch missing"
for t in clang ld.lld llvm-strip llvm-readelf pkg-config file; do
    command -v "$t" >/dev/null || die "$t missing in the arm64 container"
done

# --- reproducibility env (same as build-kernel.sh) ---------------------------
SOURCE_DATE_EPOCH="$(cat "${OUT}/staging/source-date-epoch")"
export SOURCE_DATE_EPOCH
export KBUILD_BUILD_TIMESTAMP="@${SOURCE_DATE_EPOCH}"
export KBUILD_BUILD_USER=builder
export KBUILD_BUILD_HOST=mainline-build
export LOCALVERSION=""
export LC_ALL=C TZ=UTC
log "SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH}, $(clang --version | head -1)"

# --- kernel host tools: make scripts prepare with the main tree's config ---
mkdir -p "${O}"
cp "${KO}/.config" "${O}/.config"
make -C "${SRC}/linux" ARCH=arm64 LLVM=1 O="${O}" olddefconfig \
    >"${OUT}/logs/kernel-hdr-olddefconfig.log" 2>&1 \
    || { tail -50 "${OUT}/logs/kernel-hdr-olddefconfig.log" >&2; die "olddefconfig failed"; }
# Tool capability probes may differ between architectures. Reject feature drift.
if diff -u "$KO/.config" "$O/.config" > "$OUT/staging/config-drift-hdr.diff"; then
    log "config drift vs kbuild: none"
else
    python3 - "$KO/.config" "$O/.config" <<'PYCONFIG'
import re
import sys
def config(path):
    result = {}
    for line in open(path):
        m = re.match(r"(CONFIG_[A-Z0-9_]+)=(.*)", line)
        if m:
            result[m[1]] = m[2]
    return result
a, b = map(config, sys.argv[1:])
allowed = {"CONFIG_CC_VERSION_TEXT", "CONFIG_PAHOLE_VERSION",
           "CONFIG_PAHOLE_HAS_BTF_TAG", "CONFIG_PAHOLE_HAS_LANG_EXCLUDE",
           "CONFIG_OPENSSL_SUPPORTS_ML_DSA"}
changed = {key for key in a.keys() | b.keys() if a.get(key, "n") != b.get(key, "n")}
if changed - allowed or (changed and any(a.get(k) == "y" for k in
    ("CONFIG_DEBUG_INFO_BTF", "CONFIG_MODULE_SIG_KEY_TYPE_MLDSA_44",
     "CONFIG_MODULE_SIG_KEY_TYPE_MLDSA_65", "CONFIG_MODULE_SIG_KEY_TYPE_MLDSA_87"))):
    raise SystemExit("unsafe native header config drift: " + ", ".join(sorted(changed)))
print("Allowed native tool capability differences: " + ", ".join(sorted(changed)))
PYCONFIG
fi

log "building host tools: make modules_prepare -j$(nproc) (log: kernel-hdr-build.log)"
# modules_prepare (not just "prepare") so the tree also gets the OOT-module
# link machinery: scripts/mod (modpost, mk_elfconfig -- prepare0), the
# scripts/ root + selinux always-tools (kallsyms sorttable asn1_compiler
# sign-file tracepoint-update mdp -- archprepare) and scripts/module.lds
if ! make -C "${SRC}/linux" -j"$(nproc)" ARCH=arm64 LLVM=1 O="${O}" modules_prepare \
        >"${OUT}/logs/kernel-hdr-build.log" 2>&1; then
    tail -80 "${OUT}/logs/kernel-hdr-build.log" >&2
    die "host tools build failed"
fi

# every file the x86 tree has under scripts/ (minus objects) must exist here:
# pack-headers.sh replaces that directory wholesale
missing="$(cd "${KO}/scripts" && find . -type f ! -name '*.o' ! -name '*.cmd' \
    | while read -r f; do [ -e "${O}/scripts/${f}" ] || printf '%s\n' "${f}"; done)"
[ -z "${missing}" ] || die "kbuild_hdr/scripts lacks files present in kbuild/scripts:
${missing}"

hdr_elfs="$(find "${O}/scripts" -type f ! -name '*.o' -exec file {} + \
    | sed -n 's/^\([^:]*\): *ELF .*/\1/p' | sort)"
[ -n "${hdr_elfs}" ] || die "no ELF host tools under ${O}/scripts"
bad="$(printf '%s\n' "${hdr_elfs}" | xargs file | grep -v 'ARM aarch64' || true)"
[ -z "${bad}" ] || die "non-aarch64 host tools:
${bad}"
log "host tools ($(printf '%s\n' "${hdr_elfs}" | wc -l) aarch64 ELFs): $(printf '%s\n' "${hdr_elfs}" | sed "s|${O}/||" | tr '\n' ' ')"

# --- perf ---------------------------------------------------------------------
# tools/perf with O= (must be absolute and exist).  Explicitly off: JVMTI
# (no JDK) and perl scripting; everything else is feature-detected against
# packages-arm64.list, which is therefore the single place that decides the
# runtime library set.
mkdir -p "${PERF_O}"
log "building perf -j$(nproc) (log: kernel-hdr-perf.log)"
if ! make -C "${SRC}/linux/tools/perf" -j"$(nproc)" O="${PERF_O}" LLVM=1 \
        NO_JVMTI=1 NO_LIBPERL=1 >"${OUT}/logs/kernel-hdr-perf.log" 2>&1; then
    tail -80 "${OUT}/logs/kernel-hdr-perf.log" >&2
    die "perf build failed"
fi
[ -x "${PERF_O}/perf" ] || die "perf binary not produced"
file "${PERF_O}/perf" | grep -q 'ARM aarch64' || die "perf is not aarch64: $(file -b "${PERF_O}/perf")"
grep -E '^\.\.\. +(libelf|libdw|libtraceevent|libslang|libnuma|libzstd|liblzma|zlib|libpython|bpf_skel|libopenssl)\b|^\.\.\. +[a-z]+: \[' \
    "${OUT}/logs/kernel-hdr-perf.log" >&2 || true

rm -rf "${TOOLS}"
install -D -m 0755 "${PERF_O}/perf" "${TOOLS}/usr/lib/linux-tools-${KVER}/perf"
llvm-strip --strip-all "${TOOLS}/usr/lib/linux-tools-${KVER}/perf"
log "perf: $(du -h "${TOOLS}/usr/lib/linux-tools-${KVER}/perf" | cut -f1) stripped"

# --- ${shlibs:Depends} ----------------------------------------------------------
# NEEDED sonames -> library path (ldconfig) -> owning package (dpkg -S on the
# canonical path, merged-usr aware); unversioned, comma-separated, sorted.
shlibs() { # shlibs <elf>...
    for f in "$@"; do
        llvm-readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\].*/\1/p'
    done | sort -u | while read -r so; do
        path="$(ldconfig -p | awk -v so="${so}" '$1 == so { print $NF; exit }')"
        [ -n "${path}" ] || die "cannot resolve shared library ${so}"
        pkg="$(dpkg -S "$(realpath "${path}")" | head -1 | cut -d: -f1)"
        [ -n "${pkg}" ] || die "no package owns ${path} (${so})"
        printf '%s\n' "${pkg}"
    done | sort -u | paste -sd, - | sed 's/,/, /g'
}
mkdir -p "${SHLIBS}"
# shellcheck disable=SC2086
shlibs ${hdr_elfs} > "${SHLIBS}/linux-headers"
shlibs "${TOOLS}/usr/lib/linux-tools-${KVER}/perf" > "${SHLIBS}/linux-tools"
log "linux-headers Depends: $(cat "${SHLIBS}/linux-headers")"
log "linux-tools   Depends: $(cat "${SHLIBS}/linux-tools")"
log "done"
