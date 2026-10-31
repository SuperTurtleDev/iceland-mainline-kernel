#!/usr/bin/env bash
# Regenerate config with the same toolchain used for the kernel.
set -euo pipefail
META="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${META}/scripts/kernel-version.sh"
OUT="${OUT:-${META}/../../build/kernel}"
mkdir -p "${OUT}"
OUT="$(cd "${OUT}" && pwd)"
CONTAINER_DATA="${OUT}/podman-data" \
EXTRA_MOUNTS="-v ${META}:/work/src:ro -v ${OUT}:/work/out" \
bash "${META}/../podman_container/runin.sh" bash -eu -c '
    source /work/src/scripts/kernel-version.sh
    mkdir -p /work/out/config-normalize
    cp /work/src/config /work/out/config-normalize/.config
    /work/src/linux/scripts/config --file /work/out/config-normalize/.config --set-str LOCALVERSION "" --enable LOCALVERSION_AUTO
    make -C /work/src/linux ARCH=arm64 LLVM=1 O=/work/out/config-normalize LOCALVERSION= olddefconfig
'
cp "${OUT}/config-normalize/.config" "${META}/config"
