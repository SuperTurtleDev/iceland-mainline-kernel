#!/usr/bin/env python3
"""Validate the actual Debian payloads without running maintainer scripts."""
import hashlib
import io
from pathlib import Path
import struct
import subprocess
import sys
import tarfile

meta = Path(__file__).resolve().parent.parent
out = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else meta.parent.parent / 'build/kernel'
kver, ver = subprocess.check_output(
    ['bash', '-ec', 'source "$1"; printf "%s\\n%s\\n" "$KVER" "$VER"',
     'kernel-version', str(meta / 'scripts/kernel-version.sh')], text=True).splitlines()
required = {
    'image': {f'boot/vmlinuz-{kver}', f'boot/config-{kver}', f'boot/System.map-{kver}'},
    'modules': {f'usr/lib/modules/{kver}/modules.dep', f'usr/lib/modules/{kver}/updates/charge_boost_lite.ko.zst',
                'usr/share/gunyah/gh_vmtest.py', 'usr/share/gunyah/gh_accepttest.py', 'etc/modules-load.d/gunyah.conf'},
    'headers': {f'usr/src/linux-headers-{kver}/' + name for name in
                ('Makefile', 'Module.symvers', '.config', 'scripts/basic/fixdep', 'scripts/mod/modpost')},
    'tools': {f'usr/lib/linux-tools-{kver}/perf'},
    'firmware': {f'usr/lib/linux-image-{kver}/kaanapali-oneplus-iceland.dtb', 'etc/initramfs-tools/hooks/iceland'},
}
errors = []

def require(condition, message):
    if not condition:
        errors.append(message)

def output(*args):
    return subprocess.check_output(args)

for kind, needs in required.items():
    pkg = f'linux-{kind}-iceland'
    deb = out / 'debs' / f'{pkg}_{ver}_arm64.deb'
    if not deb.is_file():
        errors.append(f'missing {deb}')
        continue
    fields = output('dpkg-deb', '-f', str(deb)).decode()
    control = dict(line.split(': ', 1) for line in fields.splitlines() if line and not line.startswith(' ') and ': ' in line)
    for key, value in {'Package': pkg, 'Version': ver, 'Architecture': 'arm64'}.items():
        require(control.get(key) == value, f'{pkg}: incorrect {key}')
    require(not any(x in fields for x in ('@KVER@', '@VERSION@', '${')), f'{pkg}: unresolved control template')
    if kind == 'image':
        for dep in ('modules', 'firmware'):
            require(f'linux-{dep}-iceland (= {ver})' in control.get('Depends', ''), f'{pkg}: missing exact {dep} dependency')
    control_tar = output('dpkg-deb', '--ctrl-tarfile', str(deb))
    with tarfile.open(fileobj=io.BytesIO(control_tar)) as tf:
        for member in tf:
            if not member.isfile():
                continue
            data = tf.extractfile(member).read()
            require(b'@KVER@' not in data and b'@VERSION@' not in data, f'{pkg}: unrendered {member.name}')
            if data.startswith(b'#!'):
                result = subprocess.run(['sh', '-n'], input=data, capture_output=True)
                require(result.returncode == 0, f'{pkg}: invalid {member.name}: {result.stderr.decode()}')
    seen = set()
    elfs = 0
    proc = subprocess.Popen(['dpkg-deb', '--fsys-tarfile', str(deb)], stdout=subprocess.PIPE)
    with tarfile.open(fileobj=proc.stdout, mode='r|') as tf:
        for member in tf:
            name = member.name.removeprefix('./')
            seen.add(name)
            require(not name.startswith('usr/src/usr/'), f'{pkg}: nested headers path {name}')
            if kind == 'headers' and name == f'usr/lib/modules/{kver}/build':
                require(member.issym() and member.linkname == f'/usr/src/linux-headers-{kver}', f'{pkg}: incorrect build symlink')
            if not member.isfile():
                continue
            f = tf.extractfile(member)
            if kind in ('headers', 'tools'):
                header = f.read(64)
                if header.startswith(b'\x7fELF'):
                    elfs += 1
                    require(len(header) >= 20 and header[4:6] == b'\x02\x01' and struct.unpack_from('<H', header, 18)[0] == 183,
                            f'{pkg}: non-aarch64 ELF {name}')
            if name in (f'boot/config-{kver}', f'usr/src/linux-headers-{kver}/.config'):
                f = tf.extractfile(member) if kind == 'image' else f
                data = (header if kind == 'headers' else b'') + f.read()
                require(data == (out / 'kbuild/.config').read_bytes(), f'{pkg}: config differs from built kernel')
            if kind == 'image' and name == f'boot/vmlinuz-{kver}':
                data = f.read()
                require(data[0x38:0x3c] == b'ARM\x64', f'{pkg}: invalid arm64 Image')
                require(hashlib.sha256(data).digest() == hashlib.sha256((out / 'kbuild/arch/arm64/boot/Image').read_bytes()).digest(), f'{pkg}: Image differs from build')
            if kind == 'modules' and name == f'usr/lib/modules/{kver}/updates/charge_boost_lite.ko.zst':
                module = subprocess.run(['zstd', '-qd'], input=f.read(), capture_output=True, check=True).stdout
                require(b'vermagic=' + kver.encode() + b' ' in module, f'{pkg}: OOT vermagic differs')
    proc.stdout.close()
    require(proc.wait() == 0, f'{pkg}: dpkg-deb extraction failed')
    require(needs <= seen, f'{pkg}: missing {sorted(needs - seen)}')
    if kind == 'headers':
        require(f'usr/lib/modules/{kver}/build' in seen, f'{pkg}: missing build symlink')
    if kind in ('headers', 'tools'):
        require(elfs > 0, f'{pkg}: no native tools found')
    print(f'Checked {pkg}: {len(seen)} paths, {elfs} native tools')

require((out / 'kbuild/.config').read_bytes() == (meta / 'config').read_bytes(), 'root config differs from build config')
require((out / 'kbuild/include/config/kernel.release').read_text().strip() == kver, 'kernel release differs')
if errors:
    print('\n'.join('FAIL: ' + error for error in errors), file=sys.stderr)
    sys.exit(1)
print(f'PASS: five Debian packages, {ver}, ABI {kver}')
