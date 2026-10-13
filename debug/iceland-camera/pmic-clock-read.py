import json
import os
import re
import time
from pathlib import Path


regmap = Path("/sys/kernel/debug/regmap/0-00")
if (regmap / "name").read_text().strip() != "pmic-spmi":
    raise SystemExit("Unexpected regmap driver")
if (regmap / "range").read_text().strip() != "0-ffff":
    raise SystemExit("Unexpected register ranges")
descriptor = os.open(regmap / "registers", os.O_RDONLY | os.O_CLOEXEC)
try:
    for address in (0x5004, 0x5005, 0x5008, 0x5046, 0x5904, 0x5905,
                    0x5908, 0x5946, 0x5E04, 0x5E05, 0x5E08, 0x5E46):
        started = time.monotonic()
        raw = os.pread(descriptor, 9, address * 9)
        match = re.fullmatch(rb"([0-9a-f]{4}): ([0-9a-f]{2}|XX)\n", raw)
        if not match or int(match[1], 16) != address:
            raise RuntimeError(f"Unexpected register response: {raw!r}")
        print(json.dumps({"monotonic": started, "end": time.monotonic(),
                          "address": hex(address), "raw": raw.decode().strip()}),
              flush=True)
finally:
    os.close(descriptor)
