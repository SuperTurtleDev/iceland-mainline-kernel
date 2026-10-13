import json
import os
import re
import time
from pathlib import Path


def read_registers(regmap_name, driver, maximum, stride, value_digits, addresses):
    regmap = Path("/sys/kernel/debug/regmap") / regmap_name
    if (regmap / "name").read_text().strip() != driver:
        raise RuntimeError(f"Unexpected regmap driver: {regmap_name}")
    if (regmap / "range").read_text().strip() != f"0-{maximum:x}":
        raise RuntimeError(f"Unexpected register ranges: {regmap_name}")
    address_digits = len(f"{maximum:x}")
    line_length = address_digits + value_digits + 3
    descriptor = os.open(regmap / "registers", os.O_RDONLY | os.O_CLOEXEC)
    values = {}
    try:
        for label, address in addresses:
            if address % stride or address > maximum:
                raise ValueError(f"Invalid address {address:x}")
            started = time.monotonic()
            raw = os.pread(descriptor, line_length, address // stride * line_length)
            match = re.fullmatch(rb"([0-9a-f]+): ([0-9a-f]+|X+)\n", raw)
            if not match or int(match[1], 16) != address:
                raise RuntimeError(f"Unexpected register response: {raw!r}")
            value = None if b"X" in match[2] else int(match[2], 16)
            values[label] = value
            print(json.dumps({"monotonic": started, "end": time.monotonic(),
                              "regmap": regmap_name, "label": label,
                              "address": hex(address), "value": value}), flush=True)
    finally:
        os.close(descriptor)
    return values


rails = (("L1F", 5, 0xC100), ("L2F", 5, 0xC200), ("S7F", 5, 0xAD00),
         ("S8F", 5, 0xB000), ("L14B", 1, 0xCE00), ("L1B", 1, 0xC100),
         ("L2B", 1, 0xC200), ("L18B", 1, 0xD200), ("S8G_LCX", 6, 0xB000),
         ("L1I_LMX", 8, 0xC100), ("S7G", 6, 0xAD00), ("L3I", 8, 0xC300),
         ("BOB1", 1, 0xE400))
for rail, sid, base in rails:
    identity = read_registers(f"0-{sid:02x}", "pmic-spmi", 0xFFFF, 1, 2,
                              [(rail + "_type", base + 4),
                               (rail + "_subtype", base + 5)])
    if identity[rail + "_type"] not in (0x04, 0x1C, 0x29):
        raise RuntimeError(f"Unexpected regulator type: {rail}")
    read_registers(f"0-{sid:02x}", "pmic-spmi", 0xFFFF, 1, 2,
                   [(f"{rail}_{offset:02x}", base + offset)
                    for offset in (0x08, 0x40, 0x41, 0x42, 0x43, 0x45, 0x46)])

for pin, sid, base in (("front_mclk", 0, 0xB800), ("rear_mclk", 0, 0xB900),
                       ("front_reset", 6, 0x9400), ("rear_reset", 6, 0x9500)):
    identity = read_registers(f"0-{sid:02x}", "pmic-spmi", 0xFFFF, 1, 2,
                              [(pin + "_type", base + 4),
                               (pin + "_subtype", base + 5)])
    if identity[pin + "_type"] != 0x10:
        raise RuntimeError(f"Unexpected GPIO type: {pin}")
    read_registers(f"0-{sid:02x}", "pmic-spmi", 0xFFFF, 1, 2,
                   [(f"{pin}_{offset:02x}", base + offset)
                    for offset in (0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46)])

read_registers("100000.clock-controller", "gcc-kaanapali", 0x1F41F0, 4, 8,
               [(f"gcc_{address:x}", address)
                for address in (0x1E140, 0x1E150, 0x1E154, 0x1E158, 0x1E15C,
                                0x1E160, 0x1E164, 0x23298, 0x2329C,
                                0x52010, 0x55010)])
