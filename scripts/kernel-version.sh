# Shared by host and container build stages (Bash).
# Use upstream's exact tag/count/hash/dirty rules, including on read-only trees.
# A small temporary auto.conf lets setlocalversion run before the first build.
kernel_release() (
    set -e
    local meta scratch
    meta="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || return 1
    # Do not silently drop the hash when Git metadata is missing or inaccessible.
    git -C "$meta/linux" rev-parse --verify HEAD >/dev/null || return 1
    if [ "$(git -C "$meta/linux" rev-parse --show-toplevel)" != "$meta/linux" ]; then
        echo "kernel-version: linux must be the root of its own Git checkout" >&2
        return 1
    fi
    scratch="$(mktemp -d)" || return 1
    trap 'rm -rf "$scratch"' EXIT
    mkdir -p "$scratch/include/config" || return 1
    sed -n '/^CONFIG_LOCALVERSION=/s/"//gp; /^CONFIG_LOCALVERSION_AUTO=/p' \
        "$meta/config" > "$scratch/include/config/auto.conf" || return 1
    cd "$scratch" || return 1
    KERNELVERSION="$KERNEL_VERSION" LOCALVERSION= \
        "$meta/linux/scripts/setlocalversion" "$meta/linux"
)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/version.env"
KVER="$(kernel_release)" || return 1
export KVER
export VER="${KVER}-${DEB_REVISION}"
