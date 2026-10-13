import argparse
import re
from pathlib import Path


parser = argparse.ArgumentParser()
parser.add_argument("log_dir", type=Path)
parser.add_argument("output_dir", type=Path)
parser.add_argument("windows", nargs="+", help="START:END in monotonic seconds")
arguments = parser.parse_args()
windows = [tuple(map(float, window.split(":"))) for window in arguments.windows]
if any(start >= end for start, end in windows):
    parser.error("Each window must have START < END")
arguments.output_dir.mkdir(parents=True, exist_ok=True)
pattern = re.compile(rb"\s(\d+\.\d+):\s")
outputs = [(start, end, (arguments.output_dir / f"{start:g}-{end:g}.trace").open("wb"))
           for start, end in windows]
latest = max(end for start, end in windows)
try:
    with (arguments.log_dir / "trace.log").open("rb") as source:
        for line in source:
            match = pattern.search(line)
            if not match:
                continue
            stamp = float(match[1])
            for start, end, output in outputs:
                if start <= stamp <= end:
                    output.write(line)
            if stamp > latest + 2:
                break
finally:
    for start, end, output in outputs:
        output.close()
