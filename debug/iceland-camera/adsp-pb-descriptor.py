#!/usr/bin/env python3
"""Inspect nanopb 0.4 compact descriptors in an ELF32 little-endian image.

Read-only. Addresses are build-specific virtual addresses. Layout reference:
https://github.com/nanopb/nanopb/blob/0.4.9.1/pb_common.c
Names/semantics are not present in these descriptors; offsets and wire types are.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct


class Image:
    def __init__(self, path):
        self.data = Path(path).read_bytes()
        if self.data[:6] != b'\x7fELF\x01\x01':
            raise ValueError('expected little-endian ELF32')
        h = struct.unpack_from('<16sHHIIIIIHHHHHH', self.data)
        self.loads = [struct.unpack_from('<8I', self.data, h[5] + i * h[9])
                      for i in range(h[10])]

    def read(self, va, length):
        for kind, off, base, _, size, *_ in self.loads:
            if kind == 1 and base <= va and va + length <= base + size:
                return self.data[off + va - base:off + va - base + length]
        raise ValueError(f'address {va:#x}+{length:#x} is not file-backed')

    def word(self, va):
        return struct.unpack('<I', self.read(va, 4))[0]

    def descriptor(self, va, ancestors=()):
        if va in ancestors or len(ancestors) > 16:
            return {'ref': hex(va)}
        info, sub, default, callback, count, required, largest = struct.unpack(
            '<4I3H', self.read(va, 22))
        if count > 512 or required > count:
            raise ValueError('invalid descriptor counts')
        result = dict(address=hex(va), default=hex(default), callback=hex(callback),
                      required=required, largest_tag=largest, fields=[])
        subindex = 0
        for _ in range(count):
            w = self.word(info)
            fmt, typ = w & 3, (w >> 8) & 255
            tag = (w >> 2) & 63
            if fmt == 0:
                array, offset, size = 1, (w >> 16) & 255, w >> 28
                delta = (w >> 24) & 15
            else:
                w1 = self.word(info + 4)
                if fmt == 1:
                    tag |= (w1 >> 28) << 6
                    array, offset, size = (w >> 16) & 4095, w1 & 65535, (w1 >> 16) & 4095
                    delta = w >> 28
                else:
                    tag |= (w1 >> 8) << 6
                    offset, size = self.word(info + 8), self.word(info + 12)
                    array = w >> 16 if fmt == 2 else self.word(info + 16)
                    delta = w1 & 255
                    if delta >= 128:
                        delta -= 256
            field = dict(tag=tag, type=hex(typ), offset=offset, size=size,
                         size_offset=delta, array=array)
            if typ & 15 in (8, 9):
                field['submessage'] = self.descriptor(self.word(sub + subindex * 4), ancestors + (va,))
                subindex += 1
            result['fields'].append(field)
            info += 4 * (1 << fmt)
        return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('image')
    parser.add_argument('address', type=lambda x: int(x, 0), nargs='+')
    args = parser.parse_args()
    image = Image(args.image)
    print(json.dumps({'sha256': hashlib.sha256(image.data).hexdigest(),
                      'descriptors': [image.descriptor(a) for a in args.address]}, indent=2))
