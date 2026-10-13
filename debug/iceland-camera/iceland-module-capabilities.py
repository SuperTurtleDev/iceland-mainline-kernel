#!/usr/bin/env python3
"""Read capability arrays from the two audited Iceland CamX module binaries.

Offsets apply only to the SHA256-pinned binaries below, not arbitrary Chromatix
files. This is an offline evidence tool, not a camera configuration generator.
See vendor-protocol/stock-camera-capabilities.md for the parser derivation.
"""

import argparse
import hashlib
import json
import struct
from pathlib import Path


MODULES = {
    "7d081442cc73d13c099522d94322e21792e5d0b94143386cb2ecfaa0a93e78a2":
        ("icelandfront", 3),
    "a94533c4ebf7cf213c432520719e0437d1a93b65ff4e102aad63c3118cd077fc":
        ("icelandmain", 4),
}


def inspect(path):
    blob = path.read_bytes()
    digest = hashlib.sha256(blob).hexdigest()
    if digest not in MODULES:
        raise ValueError(f"{path}: unaudited binary SHA256 {digest}")
    name, expected_modes = MODULES[digest]
    section_count, = struct.unpack_from("<I", blob, 0xa4)
    sections = {
        kind: (offset, size)
        for kind, offset, size in struct.iter_unpack(
            "<III", blob[0xa8:0xa8 + 12 * section_count])
    }
    symbols, symbols_size = sections[3]
    data, data_size = sections[1]

    def entry(index):
        assert (index + 1) * 12 <= symbols_size
        offset, size, _ = struct.unpack_from("<III", blob, symbols + index * 12)
        assert offset + size <= data_size
        return blob[data + offset:data + offset + size]

    # ResolutionInformation has a length prefix, optional selector count/ptr,
    # and resolutionDataCount/ptr. Symbol indices are zero-based.
    info = entry(31)
    assert len(info) == 20
    limit, selector_count, selector, count, modes_pointer = struct.unpack("<5I", info)
    assert (limit, selector_count, selector, count, modes_pointer) == (
        16, 1, 32, expected_modes, 33)
    modes = entry(modes_pointer)
    assert len(modes) == count * 460
    result = []
    for index in range(count):
        mode = modes[index * 460:(index + 1) * 460]
        assert struct.unpack_from("<I", mode)[0] == 456
        # 440 explicit bytes + two 4-byte limits + SettingsInfo's 12 bytes.
        # capabilityCount is at 248 + 4 + 4 + 12 = 268.
        capability_count, pointer = struct.unpack_from("<II", mode, 268)
        capabilities = entry(pointer)
        assert len(capabilities) == capability_count * 4
        values = list(struct.unpack(f"<{capability_count}I", capabilities))
        result.append({"mode": index, "capability_symbol": pointer,
                       "serialized_capabilities": values,
                       "has_aon_capability_2": 2 in values})
    return {"module": name, "sha256": digest, "modes": result}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("modules", nargs="+", type=Path)
    args = parser.parse_args()
    print(json.dumps([inspect(path) for path in args.modules], indent=2))
