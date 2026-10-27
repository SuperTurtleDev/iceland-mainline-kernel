#!/usr/bin/env python3
"""Update within the current stable kernel series.

    ./bump-stable.py 7.3.1

Requires clean tracked inputs. Fetch and merge the stable tag, update only
version.env, normalize config with the build container, then commit the
linux / kernel / src layers. Package templates and initrd manifests are
version-independent. The subsequent ./build.sh produces and verifies artifacts.
Major/minor port migrations require explicit review and are rejected here.
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
    if r.returncode != 0:
        return None
    return r.stdout if capture else ""


def git(repo, *argv, check=True, capture=False):
    return sh(repo, "git", *argv, check=check, capture=capture)


def current_kver():
    values = {}
    with open(os.path.join(HERE, "version.env")) as f:
        for line in f:
            if line.strip() and not line.startswith("#"):
                key, value = line.strip().split("=", 1)
                values[key] = value
    version = values["KERNEL_VERSION"]
    return version + values["KERNEL_LOCALVERSION"], version


def release_tag(version):
    parts = version.split(".")
    return "v" + (".".join(parts[:2]) if parts[2] == "0" else version)


def main():
    if len(sys.argv) != 2 or not re.match(r"^\d+\.\d+\.\d+$", sys.argv[1]):
        die("usage: ./bump-stable.py <version>   (e.g. 7.3.1)")
    new = sys.argv[1]
    kver, old = current_kver()
    if new == old:
        die(f"already at {new}")
    if tuple(map(int, new.split("."))) <= tuple(map(int, old.split("."))):
        die("target must be newer than the current version")
    if new.split(".")[:2] != old.split(".")[:2]:
        die("this script handles stable updates within one series; port major/minor changes explicitly")
    new_kver = new + kver[len(old):]
    tag_new, tag_old = release_tag(new), release_tag(old)
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
    merged = git(LINUX, "merge", "--no-ff", "-m", f"Linux {new}", tag_new, check=False)
    if merged is None:
        git(LINUX, "merge", "--abort", check=False)
        die("merge failed; resolve the stable update manually before changing version.env")
    merge_sha = git(LINUX, "rev-parse", "--short=9", "HEAD", capture=True).strip()
    log(f"merged: Linux {new} ({merge_sha})")

    # --- 5. one version source + canonical Kconfig regeneration ----------------
    version_file = os.path.join(HERE, "version.env")
    text = open(version_file).read()
    text = re.sub(r"(?m)^KERNEL_VERSION=.*$", f"KERNEL_VERSION={new}", text)
    text = re.sub(r"(?m)^DEB_REVISION=.*$", "DEB_REVISION=1", text)
    with open(version_file, "w") as f:
        f.write(text)
    sh(HERE, "bash", "scripts/normalize-config.sh")

    # --- 6. layer commits --------------------------------------------------------
    git(HERE, "add", "-u", "version.env", "config", "linux")
    git(HERE, "commit", "-m",
        f"linux: Linux {new} ({merge_sha}); metarepo version bump to {new_kver}")
    sha = git(HERE, "rev-parse", "--short=9", "HEAD", capture=True).strip()
    git(META, "add", "kernel")
    git(META, "commit", "--only", "-m", f"kernel: {sha} -- Linux {new} stable bump", "--", "kernel")
    log(f"commits: linux {merge_sha} / kernel {sha} / metarepo bumped")
    log("next: ./build.sh (config drift is a fatal error; package names remain stable)")


if __name__ == "__main__":
    main()
