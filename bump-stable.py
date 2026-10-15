#!/usr/bin/env python3
"""One-click stable-kernel version bump for the iceland metarepo.

    ./bump-stable.py <version>          # e.g. ./bump-stable.py 7.2.11

Does everything the 7.2.9 -> 7.2.10 update did by hand, in order:

  1. preflight: clean git trees, target != current KVER
  2. fetch the upstream stable tag from the gregkh GitHub mirror
     (origin is the port repo and only carries tags the porter pushed)
  3. audit the v<old>..v<new> commit list, highlighting port-relevant
     subsystems; informational only
  4. merge the tag into linux (iceland-7.2) as an anchor merge commit
     "Linux <version>" -- aborts cleanly on conflicts
  5. version sweep in this repo: KVER strings in scripts/, version-stamped
     debian/ template dirs (git mv), initrd-modules.txt paths, config header
  6. layer commits:
       linux:     the merge commit itself
       src/kernel: "linux: Linux <ver> (<sha8>); metarepo version bump ..."
       src:        "kernel: <sha8> -- Linux <ver> stable bump"

NOT done automatically (deliberately): the container build (./build.sh) and
folding staging/config-drift.diff back into ./config after the first build
(new Kconfig symbols appear on minor bumps; the build logs the drift).

Revision history convention: scripts/, debian/, config and initrd-modules.txt
hardcode <ver>-sm8850; revert.py references the v7.2.9 tag on purpose and is
deliberately NOT swept.
"""

import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LINUX = os.path.join(HERE, "linux")
META = os.path.dirname(HERE)                     # src/  (metarepo root)
STABLE_MIRROR = "https://github.com/gregkh/linux.git"

# port-relevant subsystem prefixes for the audit summary
AUDIT_PATHS = [
    "drivers/gpu/drm/msm", "drivers/gpu/drm/panel", "drivers/clk/qcom",
    "drivers/pinctrl/qcom", "drivers/iommu", "arch/arm64/boot/dts/qcom",
    "drivers/interconnect", "drivers/remoteproc", "drivers/soc/qcom",
    "drivers/thermal/qcom", "drivers/usb", "drivers/tty/serial",
    "drivers/soundwire", "sound/soc/qcom", "net/wireless", "drivers/net/wireless",
]
AUDIT_SUBJECTS = ["qcom", "dwc3", "geni", "ath11k", "ath12k", "wcd", "pmic_glink", "ucsi"]


def log(msg):
    print(f"[bump-stable] {msg}", flush=True)


def die(msg):
    print(f"[bump-stable] ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def sh(cwd, *argv, check=True, capture=False):
    r = subprocess.run(argv, cwd=cwd, text=True,
                       capture_output=capture or check is False)
    if check and r.returncode != 0:
        die(f"`{' '.join(argv[:3])}...` failed (rc={r.returncode}):\n{r.stderr}")
    return r.stdout if capture else None


def git(repo, *argv, check=True, capture=False):
    return sh(repo, "git", *argv, check=check, capture=capture)


def current_kver():
    s = open(os.path.join(HERE, "scripts", "build-kernel.sh")).read()
    m = re.search(r'^KVER="(.+?)"', s, re.M)
    if not m:
        die("cannot parse KVER from scripts/build-kernel.sh")
    kver = m.group(1)
    m = re.match(r"^(\d+\.\d+\.\d+)-sm8850$", kver)
    if not m:
        die(f"unexpected KVER format: {kver}")
    return kver, m.group(1)


def main():
    if len(sys.argv) != 2 or not re.match(r"^\d+\.\d+\.\d+$", sys.argv[1]):
        die("usage: ./bump-stable.py <version>   (e.g. 7.2.11)")
    new = sys.argv[1]
    kver, old = current_kver()
    if new == old:
        die(f"already at {new}")
    new_kver = f"{new}-sm8850"
    tag_new, tag_old = f"v{new}", f"v{old}"
    log(f"{kver} -> {new_kver}")

    # --- 1. preflight ----------------------------------------------------------
    s = git(LINUX, "status", "--porcelain", capture=True)
    if s.strip():
        die(f"{LINUX} is not clean (uncommitted/untracked): {s.strip()!r}")
    s = git(HERE, "status", "--porcelain", capture=True)
    if [l for l in s.splitlines() if not l.startswith("??")]:
        die(f"{HERE} has uncommitted tracked changes; commit or stash first")
    s = git(META, "status", "--porcelain", capture=True)
    if [l for l in s.splitlines() if not l.startswith("??")]:
        log(f"NOTE: metarepo has unrelated uncommitted changes "
            f"(only 'kernel' will be staged): {s.strip()!r}")
    branch = git(LINUX, "rev-parse", "--abbrev-ref", "HEAD", capture=True).strip()
    log(f"linux branch: {branch}, trees clean")

    # --- 2. fetch the stable tag -----------------------------------------------
    log(f"fetching {tag_new} from {STABLE_MIRROR}")
    git(LINUX, "fetch", STABLE_MIRROR, f"refs/tags/{tag_new}:refs/tags/{tag_new}",
        check=False)
    if git(LINUX, "rev-parse", "--verify", f"{tag_new}^{{commit}}", check=False,
           capture=True) is None:
        die(f"{tag_new} not reachable after fetch (typo? not released yet?)")
    n = int(git(LINUX, "rev-list", "--count", f"{tag_old}..{tag_new}",
                capture=True).strip())
    log(f"{tag_old}..{tag_new}: {n} commits")

    # --- 3. audit ---------------------------------------------------------------
    subjects = git(LINUX, "log", "--format=%s", f"{tag_old}..{tag_new}",
                   capture=True).splitlines()
    hits = []
    for s in subjects:
        low = s.lower()
        if any(p in low for p in AUDIT_SUBJECTS):
            hits.append(s)
    for path in AUDIT_PATHS:
        c = git(LINUX, "rev-list", "--count", f"{tag_old}..{tag_new}", "--", path,
                capture=True).strip()
        if c != "0":
            hits.append(f"[{path}] {c} commits")
    print("\n  port-relevant commits in this range:")
    for h in hits or ["  (none: display/SoC paths untouched)"]:
        print(f"    {h}")
    print()

    # --- 4. merge ---------------------------------------------------------------
    log(f"merging {tag_new} (anchor merge, like every prior stable bump)")
    git(LINUX, "merge", "--no-ff", "-m", f"Linux {new}", tag_new, check=False)
    st = git(LINUX, "status", "--porcelain", capture=True)
    if any(l.startswith(("UU", "AA", "DD")) for l in st.splitlines()):
        git(LINUX, "merge", "--abort")
        die("merge conflicts -- port patches touched upstream files; "
            "merge manually, then re-run with --skip-merge (not implemented: "
            "finish the sweep by hand as documented in the README)")
    merge_sha = git(LINUX, "rev-parse", "--short=9", "HEAD", capture=True).strip()
    log(f"merged: Linux {new} ({merge_sha})")

    # --- 5. version sweep -------------------------------------------------------
    log(f"sweeping version strings {kver} -> {new_kver}")
    targets = []
    for d in ("scripts",):
        targets += [os.path.join(HERE, d, f) for f in os.listdir(os.path.join(HERE, d))]
    for root, _, files in os.walk(os.path.join(HERE, "debian")):
        targets += [os.path.join(root, f) for f in files]
    targets += [os.path.join(HERE, "initrd-modules.txt"), os.path.join(HERE, "config")]
    for t in targets:
        if not os.path.isfile(t):
            continue
        s = open(t, encoding="utf-8", errors="surrogateescape").read()
        s2 = s.replace(kver, new_kver).replace(old, new)
        if s2 != s:
            open(t, "w", encoding="utf-8", errors="surrogateescape").write(s2)
            log(f"  rewrote {os.path.relpath(t, HERE)}")

    for name in ("linux-image", "linux-modules", "linux-headers"):
        srcdir = os.path.join(HERE, "debian", f"{name}-{kver}")
        dstdir = os.path.join(HERE, "debian", f"{name}-{new_kver}")
        if os.path.isdir(srcdir):
            git(HERE, "mv", f"debian/{name}-{kver}", f"debian/{name}-{new_kver}")
            log(f"  debian/{name}-{kver} -> {name}-{new_kver}")

    # --- 6. layer commits --------------------------------------------------------
    git(HERE, "add", "-u", "scripts", "debian", "config", "initrd-modules.txt", "linux")
    git(HERE, "commit", "-m",
        f"linux: Linux {new} ({merge_sha}); metarepo version bump to {new_kver}")
    sha = git(HERE, "rev-parse", "--short=9", "HEAD", capture=True).strip()
    git(META, "add", "kernel")
    git(META, "commit", "-m", f"kernel: {sha} -- Linux {new} stable bump")
    log(f"commits: linux {merge_sha} / kernel {sha} / metarepo bumped")
    log("next: ./build.sh, then fold staging/config-drift.diff into ./config "
        "if the build warns about drift, and commit --amend")


if __name__ == "__main__":
    main()
