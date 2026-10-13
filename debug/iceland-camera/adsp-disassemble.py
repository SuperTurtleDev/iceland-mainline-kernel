#!/usr/bin/env python3
"""Disassemble a file-offset range of Hexagon ELF using libLLVM 21.1 (v79).

Pass a range beginning at an instruction packet boundary. This is linear
disassembly, not code/data classification or a decompiler.
"""
import argparse
import ctypes
import struct
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--image', type=Path, required=True)
parser.add_argument('--offset', type=lambda text: int(text, 0), default=0x7c3000)
parser.add_argument('--length', type=lambda text: int(text, 0), default=0x4aa2d4)
arguments = parser.parse_args()
image = arguments.image.read_bytes()
header = struct.unpack_from('<16sHHIIIIIHHHHHH', image)
programs = [struct.unpack_from('<IIIIIIII', image, header[5] + index * header[9]) for index in range(header[10])]
base_address = next(program[2] - program[1] for program in programs if program[0] == 1 and program[1] <= arguments.offset < program[1] + program[4])
library = ctypes.CDLL('libLLVM.so.21.1')
for suffix in ['TargetInfo', 'Target', 'TargetMC', 'AsmPrinter', 'Disassembler']:
    getattr(library, 'LLVMInitializeHexagon' + suffix)()
library.LLVMCreateDisasmCPUFeatures.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p]
library.LLVMCreateDisasmCPUFeatures.restype = ctypes.c_void_p
library.LLVMSetDisasmOptions.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
library.LLVMDisasmInstruction.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint64, ctypes.c_uint64, ctypes.c_char_p, ctypes.c_size_t]
library.LLVMDisasmInstruction.restype = ctypes.c_size_t
context = library.LLVMCreateDisasmCPUFeatures(b'hexagon-unknown-elf', b'hexagonv79', b'', None, 0, None, None)
library.LLVMSetDisasmOptions(context, 2)
data = ctypes.create_string_buffer(image)
output = ctypes.create_string_buffer(4096)
offset = arguments.offset
end = min(offset + arguments.length, len(image))
print('# ELF SHA256:', __import__('hashlib').sha256(image).hexdigest())
print('# Packet boundaries from instruction parse bits; registers use pre-packet values unless .new.')
while offset < end:
    consumed = library.LLVMDisasmInstruction(context, ctypes.byref(data, offset), end - offset, base_address + offset, output, len(output))
    if consumed:
        instructions = output.value.decode().strip().replace('\n', '; ')
        print(f'{base_address + offset:08x} file={offset:x} {instructions}')
        for word_offset in range(offset, offset + consumed, 4):
            if (struct.unpack_from('<I', image, word_offset)[0] >> 14) & 3 in (0, 3):
                print('    # END_PACKET')
        offset += consumed
    else:
        print(f'{base_address + offset:08x} file={offset:x} .word 0x{struct.unpack_from("<I", image, offset)[0]:08x}')
        offset += 4
