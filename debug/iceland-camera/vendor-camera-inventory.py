#!/usr/bin/env python3
"""Inventory camera protocol artifacts in a stock EROFS image without mounting it.

Requires dump.erofs. Does not extract or execute vendor binaries. The JSON
inventory includes all directory entries, so absence checks are reproducible.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess


def inventory(image):
    pending = ["/"]
    entries = []
    while pending:
        directory = pending.pop()
        output = subprocess.check_output(
            ["dump.erofs", "--ls", "--path=" + directory, str(image)], text=True)
        for line in output.splitlines():
            match = re.fullmatch(r"\s*(\d+)\s+(\d+)\s+(.+)", line)
            if not match:
                continue
            nid, kind, name = match.groups()
            if name in (".", ".."):
                continue
            path = directory.rstrip("/") + "/" + name
            entries.append({"path": path, "type": int(kind), "nid": int(nid)})
            if kind == "2":
                pending.append(path)
    return sorted(entries, key=lambda entry: entry["path"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    parser.add_argument("output", type=Path, help="JSON inventory output")
    args = parser.parse_args()
    if args.image.resolve() == args.output.resolve():
        parser.error("output must differ from the input image")
    entries = inventory(args.image)
    # Refuse to overwrite an existing artifact accidentally.
    with args.output.open("x") as stream:
        json.dump(entries, stream, indent=2)
        stream.write("\n")
    print(f"{args.image.name}: {len(entries)} entries; {args.output}")
    for entry in entries:
        path = entry["path"]
        if path.endswith(".pb") or ("iceland" in path.lower() and "camera" in path):
            print(path)


if __name__ == "__main__":
    main()
