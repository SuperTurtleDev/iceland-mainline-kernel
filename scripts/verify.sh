#!/usr/bin/env bash
# Host-side step: verify every artifact against the BootApp format contract
# and the build invariants.  One PASS/FAIL line per check, non-zero exit on
# any failure.
#
#  1) every .img: u32 LE length prefix == filesize - 4
#  2) kernel.img payload: arm64 Image magic b'ARM\x64' at header offset 0x38
#  3) dtb.img payload: FDT magic 0xd00dfeed
#  4) initrd_debug.img: zstd-decodes, cpio lists init/bin/busybox (static
#     aarch64 ELF)/etc/udhcpd.conf/etc/modules.order and sampled manifest
#     modules as bare .ko
#  5) bootcfg_debug.img payload is exactly the expected cmdline line
#  6) bootcfg/kernel.img and bootcfg_debug/kernel_debug.img match kernel.img
#  7) headers.tar.gz / modules.tar.gz list, required members present
#  8) buildinfo.txt contains the four repository hashes
set -euo pipefail

META="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-/home/wyb/Documents/mainline/build/kernel}"

[ -d "${OUT}" ] || { echo "verify: OUT dir ${OUT} does not exist" >&2; exit 1; }
command -v zstd >/dev/null 2>&1 || { echo "verify: zstd not found on host" >&2; exit 1; }

python3 - "${META}" "${OUT}" <<'PYEOF'
import hashlib
import os
import struct
import subprocess
import sys
import tarfile
import tempfile

META, OUT = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
KVER = "7.2.0-sm8850"
BOOTCFG_CMDLINE = ("cmdline=console=tty0 console=ttyMSM0,115200n8 earlycon "
                   "ignore_loglevel initcall_debug clk_ignore_unused "
                   "pd_ignore_unused loglevel=8\n")

results = []


def check(num, desc, ok, detail=""):
    results.append(ok)
    tag = "PASS" if ok else "FAIL"
    line = f"[{tag}] {num}) {desc}"
    if detail:
        line += f"  -- {detail}"
    print(line)


def read_payload(path):
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 4:
        return None, None
    return struct.unpack("<I", data[:4])[0], data[4:]


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_cpio_newc(data):
    entries = {}
    pos = 0
    while pos + 110 <= len(data):
        if data[pos:pos + 6] not in (b"070701", b"070702"):
            break
        try:
            fields = [int(data[pos + 6 + i * 8: pos + 14 + i * 8], 16) for i in range(13)]
        except ValueError:
            break
        filesize, namesize = fields[6], fields[11]
        name = data[pos + 110: pos + 110 + namesize - 1].decode("utf-8", "replace")
        dstart = pos + 110 + namesize + (-(110 + namesize) % 4)
        if name == "TRAILER!!!":
            break
        if name.startswith("./"):
            name = name[2:]
        entries[name] = (dstart, filesize)
        pos = dstart + filesize + (-filesize % 4)
    return entries


def elf_static_aarch64(b):
    if b[:4] != b"\x7fELF" or b[4] != 2 or b[5] != 1:
        return False, "not a 64-bit little-endian ELF"
    if struct.unpack_from("<H", b, 18)[0] != 183:
        return False, "not EM_AARCH64"
    phoff = struct.unpack_from("<Q", b, 32)[0]
    phentsize = struct.unpack_from("<H", b, 54)[0]
    phnum = struct.unpack_from("<H", b, 56)[0]
    for i in range(phnum):
        if struct.unpack_from("<I", b, phoff + i * phentsize)[0] == 3:
            return False, "has PT_INTERP (dynamically linked)"
    return True, "64-bit LE aarch64, statically linked"


imgs = ["kernel.img", "dtb.img", "initrd_debug.img", "bootcfg_debug.img",
        "bootcfg/kernel.img", "bootcfg_debug/kernel_debug.img"]

# ---- 1) length prefix ---------------------------------------------------------
fails = []
for rel in imgs:
    path = os.path.join(OUT, rel)
    if not os.path.isfile(path):
        fails.append(f"{rel}: missing")
        continue
    prefix, _ = read_payload(path)
    size = os.path.getsize(path)
    if prefix != size - 4:
        fails.append(f"{rel}: prefix={prefix}, size-4={size - 4}")
check(1, "u32 LE prefix == filesize-4 for all .img", not fails, "; ".join(fails))
if fails:
    print("verify: length-prefixed images missing, aborting further checks")
    sys.exit(1)

# ---- 2) arm64 Image magic -----------------------------------------------------
_, kpayload = read_payload(os.path.join(OUT, "kernel.img"))
magic = kpayload[0x38:0x3C]
check(2, "kernel.img arm64 Image magic b'ARM\\x64' at offset 0x38",
      magic == b"ARM\x64", f"got {magic!r}")

# ---- 3) FDT magic --------------------------------------------------------------
_, dpayload = read_payload(os.path.join(OUT, "dtb.img"))
fdt_magic = struct.unpack(">I", dpayload[:4])[0]
check(3, "dtb.img FDT magic 0xd00dfeed", fdt_magic == 0xD00DFEED,
      f"got 0x{fdt_magic:08x}")

# ---- 4) initrd -----------------------------------------------------------------
detail = []
ok = True
_, ipayload = read_payload(os.path.join(OUT, "initrd_debug.img"))
with tempfile.TemporaryDirectory() as td:
    zst, cpio = os.path.join(td, "i.cpio.zst"), os.path.join(td, "i.cpio")
    with open(zst, "wb") as f:
        f.write(ipayload)
    r = subprocess.run(["zstd", "-q", "-d", "-T0", zst, "-o", cpio],
                       capture_output=True, text=True)
    entries = {}
    if r.returncode != 0:
        ok = False
        detail.append(f"zstd -d failed: {r.stderr.strip()}")
    else:
        with open(cpio, "rb") as f:
            cpio_data = f.read()
        entries = parse_cpio_newc(cpio_data)
        for need in ("init", "bin/busybox", "etc/udhcpd.conf", "etc/modules.order"):
            if need not in entries:
                ok = False
                detail.append(f"cpio entry missing: {need}")
        if "bin/busybox" in entries:
            off, size = entries["bin/busybox"]
            good, reason = elf_static_aarch64(cpio_data[off:off + size])
            if not good:
                ok = False
                detail.append(f"busybox: {reason}")
        # sampled manifest modules must be present as bare .ko (manifest uses
        # distro /usr/lib/modules paths with .ko.zst; initrd layout is
        # /lib/modules with .ko)
        manifest = os.path.join(META, "initrd-modules.txt")
        with open(manifest, encoding="utf-8") as f:
            mod_paths = [l.strip() for l in f
                         if l.startswith(f"/usr/lib/modules/{KVER}/") and l.endswith(".ko.zst")]
        sample = mod_paths[:3]
        for p in sample:
            name = p[len(f"/usr/lib/modules/{KVER}/"):]
            name = "lib/modules/" + KVER + "/" + name[:-len(".zst")]
            if name not in entries:
                ok = False
                detail.append(f"bare .ko missing in initrd: {name}")
        # modules.dep must exist alongside the bare modules
        if f"lib/modules/{KVER}/modules.dep" not in entries:
            ok = False
            detail.append(f"lib/modules/{KVER}/modules.dep missing in initrd")
if ok:
    detail.append(f"{len(entries)} cpio entries; sampled modules ok; modules.dep present")
check(4, "initrd_debug.img zstd+cpio (init, static aarch64 busybox, "
         "etc/udhcpd.conf, etc/modules.order, bare .ko subset, modules.dep)",
      ok, "; ".join(detail))

# ---- 5) bootcfg_debug ------------------------------------------------------------
_, bpayload = read_payload(os.path.join(OUT, "bootcfg_debug.img"))
check(5, "bootcfg_debug.img payload is exactly the expected cmdline line",
      bpayload.decode("ascii", "replace") == BOOTCFG_CMDLINE,
      bpayload.decode("ascii", "replace").strip()[:100])

# ---- 6) kernel copies --------------------------------------------------------------
top = sha256_file(os.path.join(OUT, "kernel.img"))
c1 = sha256_file(os.path.join(OUT, "bootcfg/kernel.img"))
c2 = sha256_file(os.path.join(OUT, "bootcfg_debug/kernel_debug.img"))
check(6, "kernel copies byte-identical to kernel.img", top == c1 == c2,
      f"top={top[:12]} bootcfg={c1[:12]} bootcfg_debug={c2[:12]}")

# ---- 7) tars -------------------------------------------------------------------------
detail = []
ok = True
try:
    with tarfile.open(os.path.join(OUT, "headers.tar.gz"), "r:gz") as tf:
        hnames = set(tf.getnames())
    hdr = f"usr/src/linux-headers-{KVER}"
    for need in (f"{hdr}/Makefile", f"{hdr}/Module.symvers", f"{hdr}/.config"):
        if need not in hnames:
            ok = False
            detail.append(f"headers.tar.gz missing {need}")
except Exception as e:  # noqa: BLE001
    ok = False
    detail.append(f"headers.tar.gz unreadable: {e}")
try:
    with tarfile.open(os.path.join(OUT, "modules.tar.gz"), "r:gz") as tf:
        mnames = set(tf.getnames())
    for need in (f"lib/modules/{KVER}/modules.dep",
                 f"lib/modules/{KVER}/updates/charge_boost_lite.ko.zst"):
        if need not in mnames:
            ok = False
            detail.append(f"modules.tar.gz missing {need}")
    n_ko = sum(1 for n in mnames if n.endswith(".ko.zst"))
    if n_ko == 0:
        ok = False
        detail.append("modules.tar.gz has no .ko.zst")
    else:
        detail.append(f"modules.tar.gz: {n_ko} .ko.zst")
except Exception as e:  # noqa: BLE001
    ok = False
    detail.append(f"modules.tar.gz unreadable: {e}")
check(7, "headers.tar.gz / modules.tar.gz listable with required members", ok,
      "; ".join(detail))

# ---- 8) buildinfo ----------------------------------------------------------------------
def git_head(path):
    r = subprocess.run(["git", "-C", path, "rev-parse", "HEAD"],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None

bi_path = os.path.join(OUT, "buildinfo.txt")
ok = os.path.isfile(bi_path)
detail = []
if ok:
    with open(bi_path, encoding="utf-8") as f:
        bi = f.read()
    for label, repo in (("metarepo", META),
                        ("linux", os.path.join(META, "linux")),
                        ("firmware", os.path.join(META, "firmware")),
                        ("podman_container",
                         os.path.join(os.path.dirname(META), "podman_container"))):
        head = git_head(repo)
        if head is None:
            ok = False
            detail.append(f"{label}: no git HEAD")
        elif head not in bi:
            ok = False
            detail.append(f"{label} hash {head[:12]} not in buildinfo.txt")
else:
    detail.append("buildinfo.txt missing")
check(8, "buildinfo.txt contains metarepo/linux/firmware/podman_container hashes",
      ok, "; ".join(detail) or "all four hashes found")

# ---- summary ----------------------------------------------------------------------------
npass = sum(1 for r in results if r)
print(f"verify: {npass}/{len(results)} checks passed")
sys.exit(0 if all(results) else 1)
PYEOF
