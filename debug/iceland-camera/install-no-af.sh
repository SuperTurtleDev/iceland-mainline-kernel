#!/bin/bash
set -euo pipefail

package_dir=${1:-/home/ubuntu/debs-test}
expected_dtb_sha=${2:?expected DTB SHA256 required}
kernel_version=7.2.9-sm8850
package_version=7.2.9-sm8850-1
install_log=/var/tmp/iceland-no-af-install-$(date -u +%Y%m%dT%H%M%SZ).log
dtb_path=/usr/lib/linux-image-$kernel_version/kaanapali-oneplus-iceland.dtb
packages=(
	"linux-modules-${kernel_version}_${package_version}_arm64.deb"
	"linux-firmware-iceland_${package_version}_arm64.deb"
	"linux-image-${kernel_version}_${package_version}_arm64.deb"
	"linux-headers-${kernel_version}_${package_version}_arm64.deb"
)

[ "$EUID" -eq 0 ]
[ "$(uname -r)" = "$kernel_version" ]
for package in "${packages[@]}"; do
	[ -f "$package_dir/$package" ]
done

exec > >(tee "$install_log") 2>&1
printf 'INSTALL_BEGIN log=%s\n' "$install_log"
if [ -f "$dtb_path" ]; then
	cp -a "$dtb_path" "${install_log%.log}-previous.dtb"
fi
for package in "${packages[@]}"; do
	dpkg --force-depends -i "$package_dir/$package"
done

printf '%s  %s\n' "$expected_dtb_sha" "$dtb_path" | sha256sum --check
grep -F "iceland: initrd.img-${kernel_version} flashed to partition 'initrd'" "$install_log"
printf 'INSTALL_COMPLETE_NO_REBOOT log=%s\n' "$install_log"
