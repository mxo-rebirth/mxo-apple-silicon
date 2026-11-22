#!/usr/bin/env python3
"""dis.py <pe file> <start>-<end> ...

Disassembles address ranges of a PE file. The ranges are RVAs in hex."""
import os
import struct
import subprocess
import sys
import tempfile


def load(path):
    data = open(path, 'rb').read()
    pe = struct.unpack_from('<I', data, 0x3c)[0]
    section_count = struct.unpack_from('<H', data, pe + 6)[0]
    optional_size = struct.unpack_from('<H', data, pe + 20)[0]
    base = struct.unpack_from('<I', data, pe + 24 + 28)[0]
    sections = [struct.unpack_from('<IIII', data, pe + 24 + optional_size + 40 * i + 8) for i in range(section_count)]
    return data, sections, base


def offset_of(sections, rva):
    for virtual_size, virtual_address, raw_size, raw in sections:
        if virtual_address <= rva < virtual_address + max(virtual_size, raw_size):
            return raw + rva - virtual_address
    return None


def disassemble(data, sections, base, start, end):
    code = data[offset_of(sections, start):offset_of(sections, end)]
    with tempfile.NamedTemporaryFile(suffix='.bin', delete=False) as file:
        file.write(code)
        name = file.name
    command = ['i686-w64-mingw32-objdump', '-D', '-b', 'binary', '-mi386', '-Mintel', '--adjust-vma=0x%x' % (base + start), name]
    out = subprocess.run(command, capture_output=True, text=True).stdout
    os.unlink(name)
    return [line for line in out.splitlines() if ':\t' in line]


if __name__ == '__main__':
    data, sections, base = load(sys.argv[1])
    print('image base %x' % base)
    for arg in sys.argv[2:]:
        start, end = [int(part, 16) for part in arg.split('-')]
        print('==== %x-%x' % (start, end))
        for line in disassemble(data, sections, base, start, end):
            print(line)
