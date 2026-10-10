#!/usr/bin/env python3
"""Revert N newest stable commits. Snapshot-based: conflicts don't destroy accumulated reverts."""
import subprocess, sys, os, time

LINUX = os.path.join(os.path.dirname(os.path.abspath(__file__)), "linux")
BASE = "8d3ae5928"

# 9-char hash prefixes of commits our local patches depend on
WHITELIST = {
    "a8deb8980","61862ed65","0ff49320a","57dba479a",  # remoteproc late-attach
    "0f00f6848",                                        # DPU v13 SSPP REC
    "49fbcd3da","6cc6c28c9",                            # battmgr
    "6bd10931a","cb83cfff8","7a52e76b6",                # iris
    "a5e341a25","cfcaa26b3","d7f34cbac","14f49e457","b141852e6",
}

def sh(cmd, check=True):
    r = subprocess.run(cmd, shell=True, cwd=LINUX, capture_output=True, text=True)
    if check and r.returncode != 0:
        print(f"FAIL: {cmd}\n{r.stderr[:200]}", file=sys.stderr)
        sys.exit(1)
    return r.stdout.strip()

def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    if n <= 0:
        print("usage: revert.py <num_newest>", file=sys.stderr); sys.exit(1)

    hashes = sh(f"git log --format=%H --no-merges {BASE}..v7.2.9").split()
    total = len(hashes)

    to_revert = [h for h in hashes[:n] if h[:9] not in WHITELIST]
    wl_skipped = len(hashes[:n]) - len(to_revert)

    print(f"total {total}, revert {n} newest -> {len(to_revert)} after whitelist ({wl_skipped} skipped)")
    if to_revert:
        print(f"  newest: {to_revert[0][:12]}  oldest: {to_revert[-1][:12]}")

    # Clean slate
    sh("git reset --hard HEAD")
    sh("git clean -fd")

    t0 = time.time(); ok = 0; conflict = 0
    for h in to_revert:
        # Snapshot current index state
        tree = sh("git write-tree")

        r = subprocess.run(["git","revert","--no-commit",h], cwd=LINUX,
                          capture_output=True, text=True)
        if r.returncode != 0:
            # Restore to snapshot (only undoes THIS failed revert)
            sh(f"git read-tree --reset -u {tree}", check=False)
            # Clear any revert state
            subprocess.run(["git","revert","--quit"], cwd=LINUX,
                          capture_output=True, text=True)
            conflict += 1
        else:
            ok += 1

        if ok > 0 and ok % 500 == 0:
            print(f"  {ok}/{len(to_revert)} ({time.time()-t0:.0f}s)")

    # Stage everything
    sh("git add -A")

    # Force SUBLEVEL=9
    mf = os.path.join(LINUX, "Makefile")
    lines = open(mf).readlines()
    for i, l in enumerate(lines):
        if l.startswith("SUBLEVEL ="):
            lines[i] = "SUBLEVEL = 9\n"; break
    open(mf, "w").writelines(lines)
    sh("git add Makefile")

    stat = sh("git diff --cached --stat HEAD").splitlines()
    print(f"OK: {ok} reverted, {conflict} conflicts, {wl_skipped} whitelisted, {time.time()-t0:.0f}s")
    print(f"staged vs HEAD: {stat[-1] if stat else 'none'}")

if __name__ == "__main__":
    main()
