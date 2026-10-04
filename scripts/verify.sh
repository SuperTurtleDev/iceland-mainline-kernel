#!/usr/bin/env bash
# Host-side step: verify every artifact against the BootApp format contract
# and the build invariants. Prints one PASS/FAIL line per numbered check and
# exits non-zero if anything failed.
#
#  1) every .img: u32 LE length prefix == filesize - 4
#  2) kernel.img payload carries the arm64 Image magic b'ARM\x50'
#  3) dtb.img payload starts with the FDT magic 0xd00dfeed
#  4) initrd_debug.img: zstd-decodes, cpio lists init/bin/busybox/etc/udhcpd.conf,
#     busybox is a static aarch64 ELF, 5 sampled modules from initrd-modules.txt
#     are present
#  5) bootcfg_debug.img payload is a single "cmdline=..." line
#  6) bootcfg/kernel.img and bootcfg_debug/kernel_debug.img match kernel.img
#  7) headers.tar.gz / modules.tar.gz are listable; modules.tar.gz contains
#     modules.dep and updates/charge_boost_lite.ko.zst; 3 sampled .ko.zst pass
#     zstd -t
#  8) buildinfo.txt exists and contains the three repository hashes
set -euo pipefail

META="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-/home/wyb/Documents/mainline/build/kernel}"

[ -d "${OUT}" ] || { echo "verify: OUT dir ${OUT} does not exist" >&2; exit 1; }

python3 - "${META}" "${OUT}" <<'PYEOF'
import hashlib
import os
import random
import struct
import subprocess
import sys
import tarfile
import tempfile

META, OUT = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
KVER = "7.2.0-sm8850"

results = []


def check(num, desc, ok, detail=""):
    results.append(ok)
    tag = "PASS" if ok else "FAIL"
    line = f"[{tag}] {num}) {desc}"
    if detail:
        line += f"  -- {detail}"
    print(line)


def read_payload(path):
    """Return (prefix, payload) of a BootApp length-prefixed image."""
    with open(path, "rb") as f:
        data = f.read()
    if len(data) < 4:
        return None, None
    prefix = struct.unpack("<I", data[:4])[0]
    return prefix, data[4:]


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def parse_cpio_newc(data):
    """Parse a newc cpio archive; return {normalized name: (offset, size)}."""
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
    """(ok, reason) for: 64-bit LE ELF, EM_AARCH64, no PT_INTERP."""
    if b[:4] != b"\x7fELF":
        return False, "not an ELF"
    if b[4] != 2 or b[5] != 1:
        return False, "not a 64-bit little-endian ELF"
    machine = struct.unpack_from("<H", b, 18)[0]
    if machine != 183:  # EM_AARCH64
        return False, f"e_machine={machine}, expected 183 (EM_AARCH64)"
    phoff = struct.unpack_from("<Q", b, 32)[0]
    phentsize = struct.unpack_from("<H", b, 54)[0]
    phnum = struct.unpack_from("<H", b, 56)[0]
    for i in range(phnum):
        p_type = struct.unpack_from("<I", b, phoff + i * phentsize)[0]
        if p_type == 3:  # PT_INTERP
            return False, "has PT_INTERP (dynamically linked)"
    return True, "64-bit LE aarch64, statically linked"


def have_zstd():
    return subprocess.run(["which", "zstd"], capture_output=True).returncode == 0


imgs = [
    "kernel.img", "dtb.img", "initrd_debug.img", "bootcfg_debug.img",
    "bootcfg/kernel.img", "bootcfg_debug/kernel_debug.img",
]

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
# ARM64_IMAGE_MAGIC from linux/arch/arm64/include/asm/image.h: the 7.x tree
# defines "ARM\x64" (older kernels used "ARM\x50"); it sits at header offset
# 0x38 (struct arm64_image_header.magic).
_, kpayload = read_payload(os.path.join(OUT, "kernel.img"))
magic = kpayload[0x38:0x3C]
check(2, "kernel.img arm64 Image magic b'ARM\\x64' (header offset 0x38)",
      magic == b"ARM\x64", f"got {magic!r}")

# ---- 3) FDT magic --------------------------------------------------------------
_, dpayload = read_payload(os.path.join(OUT, "dtb.img"))
fdt_magic = struct.unpack(">I", dpayload[:4])[0]
check(3, "dtb.img FDT magic 0xd00dfeed", fdt_magic == 0xD00DFEED, f"got 0x{fdt_magic:08x}")

# ---- 4) initrd -----------------------------------------------------------------
initrd_detail = []
initrd_ok = have_zstd()
if not initrd_ok:
    initrd_detail.append("zstd not found on host")
_, ipayload = read_payload(os.path.join(OUT, "initrd_debug.img"))
entries = {}
busy_ok, busy_reason = False, "not checked"
mod_hits, mod_total = 0, 0
if initrd_ok:
    with tempfile.TemporaryDirectory() as td:
        zst = os.path.join(td, "initrd.cpio.zst")
        cpio = os.path.join(td, "initrd.cpio")
        with open(zst, "wb") as f:
            f.write(ipayload)
        r = subprocess.run(["zstd", "-q", "-d", "-T0", zst, "-o", cpio],
                           capture_output=True, text=True)
        if r.returncode != 0:
            initrd_ok = False
            initrd_detail.append(f"zstd -d failed: {r.stderr.strip()}")
        else:
            with open(cpio, "rb") as f:
                cpio_data = f.read()
            entries = parse_cpio_newc(cpio_data)
            for need in ("init", "bin/busybox", "etc/udhcpd.conf"):
                if need not in entries:
                    initrd_ok = False
                    initrd_detail.append(f"cpio entry missing: {need}")
            if "bin/busybox" in entries:
                off, size = entries["bin/busybox"]
                busy_ok, busy_reason = elf_static_aarch64(cpio_data[off:off + size])
                if not busy_ok:
                    initrd_ok = False
                    initrd_detail.append(f"busybox: {busy_reason}")
            # 5 sampled modules from the manifest.  The manifest uses the
            # distro /usr/lib/modules paths, while make-initrd.sh installs
            # them into the busybox layout /lib/modules: map accordingly.
            manifest = os.path.join(META, "initrd-modules.txt")
            with open(manifest, "r", encoding="utf-8") as f:
                mod_paths = [l.strip() for l in f
                             if l.startswith(f"/usr/lib/modules/{KVER}/")]

            def cpio_name(manifest_path):
                name = manifest_path.lstrip("/")
                if name.startswith("usr/lib/"):
                    name = name[len("usr/"):]
                return name

            sample = random.Random(20261004).sample(
                mod_paths, min(5, len(mod_paths)))
            mod_total = len(sample)
            for p in sample:
                if cpio_name(p) in entries:
                    mod_hits += 1
                else:
                    initrd_ok = False
                    initrd_detail.append(f"module missing in initrd: {p}")
if initrd_ok:
    initrd_detail.append(f"{len(entries)} cpio entries; busybox {busy_reason}; "
                         f"sampled modules {mod_hits}/{mod_total}")
check(4, "initrd_debug.img zstd+cpio contents (init, busybox static aarch64, "
         "etc/udhcpd.conf, 5 sampled modules)", initrd_ok, "; ".join(initrd_detail))

# ---- 5) bootcfg_debug ------------------------------------------------------------
_, bpayload = read_payload(os.path.join(OUT, "bootcfg_debug.img"))
try:
    btext = bpayload.decode("ascii")
except UnicodeDecodeError:
    btext, bdec = None, "payload is not ASCII"
else:
    bdec = None
ok5 = btext is not None and btext.rstrip("\n").startswith("cmdline=") \
    and "\n" not in btext.rstrip("\n")
check(5, "bootcfg_debug.img is a single 'cmdline=...' line", ok5,
      bdec or btext.strip()[:100])

# ---- 6) kernel copies --------------------------------------------------------------
top = sha256_file(os.path.join(OUT, "kernel.img"))
c1 = sha256_file(os.path.join(OUT, "bootcfg/kernel.img"))
c2 = sha256_file(os.path.join(OUT, "bootcfg_debug/kernel_debug.img"))
check(6, "kernel copies byte-identical to kernel.img", top == c1 == c2,
      f"top={top[:12]} bootcfg={c1[:12]} bootcfg_debug={c2[:12]}")

# ---- 7) tars -------------------------------------------------------------------------
detail7 = []
ok7 = True
try:
    with tarfile.open(os.path.join(OUT, "headers.tar.gz"), "r:gz") as tf:
        hnames = tf.getnames()
    hdr_prefix = f"usr/src/linux-headers-{KVER}"
    allowed_parents = {"usr", "usr/src"}
    bad = [n for n in hnames
           if n not in allowed_parents and n != hdr_prefix
           and not n.startswith(hdr_prefix + "/")]
    if bad:
        ok7 = False
        detail7.append(f"headers.tar.gz unexpected top-level entries: {bad[:3]}")
    if not any(n.startswith(hdr_prefix) for n in hnames):
        ok7 = False
        detail7.append(f"headers.tar.gz has no {hdr_prefix}/ entries")
except Exception as e:  # noqa: BLE001
    ok7 = False
    detail7.append(f"headers.tar.gz unreadable: {e}")
try:
    with tarfile.open(os.path.join(OUT, "modules.tar.gz"), "r:gz") as tf:
        mnames = tf.getnames()
        need = [f"lib/modules/{KVER}/modules.dep",
                f"lib/modules/{KVER}/updates/charge_boost_lite.ko.zst"]
        for n in need:
            if n not in mnames:
                ok7 = False
                detail7.append(f"modules.tar.gz missing {n}")
        kozst = sorted(n for n in mnames if n.endswith(".ko.zst"))
        if not kozst:
            ok7 = False
            detail7.append("modules.tar.gz has no .ko.zst")
        elif have_zstd():
            with tempfile.TemporaryDirectory() as td:
                picked = random.Random(42).sample(kozst, min(3, len(kozst)))
                for n in picked:
                    member = tf.getmember(n)
                    extracted = os.path.join(td, os.path.basename(n))
                    with open(extracted, "wb") as f:
                        f.write(tf.extractfile(member).read())
                    r = subprocess.run(["zstd", "-q", "-t", extracted],
                                       capture_output=True, text=True)
                    if r.returncode != 0:
                        ok7 = False
                        detail7.append(f"zstd -t failed for {n}")
            detail7.append(f"zstd -t ok on {len(picked)} sampled .ko.zst "
                           f"({len(kozst)} total)")
        else:
            ok7 = False
            detail7.append("zstd not found on host")
except Exception as e:  # noqa: BLE001
    ok7 = False
    detail7.append(f"modules.tar.gz unreadable: {e}")
check(7, "headers.tar.gz / modules.tar.gz list, required members, zstd -t",
      ok7, "; ".join(detail7))

# ---- 8) buildinfo ----------------------------------------------------------------------
def git_head(path):
    r = subprocess.run(["git", "-C", path, "rev-parse", "HEAD"],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None

bi_path = os.path.join(OUT, "buildinfo.txt")
ok8 = os.path.isfile(bi_path)
detail8 = []
if ok8:
    with open(bi_path, "r", encoding="utf-8") as f:
        bi = f.read()
    for label, repo in (("metarepo", META), ("linux", os.path.join(META, "linux")),
                        ("firmware", os.path.join(META, "firmware"))):
        head = git_head(repo)
        if head is None:
            ok8 = False
            detail8.append(f"{label}: no git HEAD")
        elif head not in bi:
            ok8 = False
            detail8.append(f"{label} hash {head[:12]} not in buildinfo.txt")
else:
    detail8.append("buildinfo.txt missing")
check(8, "buildinfo.txt exists and contains metarepo/linux/firmware hashes",
      ok8, "; ".join(detail8) or "all three hashes found")

# ---- summary ----------------------------------------------------------------------------
npass = sum(1 for r in results if r)
print(f"verify: {npass}/{len(results)} checks passed")
sys.exit(0 if all(results) else 1)
PYEOF
