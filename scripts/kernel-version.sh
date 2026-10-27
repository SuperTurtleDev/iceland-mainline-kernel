# Shared by host and container build stages (Bash).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/version.env"
export KVER="${KERNEL_VERSION}${KERNEL_LOCALVERSION}"
export VER="${KERNEL_VERSION}-${DEB_REVISION}"
