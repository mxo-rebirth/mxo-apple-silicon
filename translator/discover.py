#!/usr/bin/env python3
"""Linear-sweep disassembly of a PE's code section, cached for the profiler and the translator.

Produces <image>.map (pickle):
  entries   sorted list of function entry RVAs (direct call targets, pointers into code, exports)
  branches  list of (source rva, target rva) for every direct call/jmp/jcc
  x87       sorted list of RVAs of x87 instructions
  insn      sorted list of instruction start RVAs
"""
import os
import pickle
import struct
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from xlat import Image


def build(path, out):
    img = Image(path, 'pe')
    b = img.data
    lo, hi = img.text[0]
    code = img.bytes(lo, hi)
    with tempfile.NamedTemporaryFile(suffix='.bin', delete=False) as f:
        f.write(code)
        name = f.name
    proc = subprocess.Popen(['i686-w64-mingw32-objdump', '-D', '-b', 'binary', '-mi386', '-Mintel', '--insn-width=16',
                             '--adjust-vma=0x%x' % (img.base + lo), name], stdout=subprocess.PIPE, text=True)
    insn, x87, branches, calls = [], [], [], set()
    base = img.base
    for line in proc.stdout:
        t = line.find(':\t')
        if t < 0:
            continue
        try:
            va = int(line[:t], 16)
        except ValueError:
            continue
        rest = line[t + 2:]
        t2 = rest.find('\t')
        hexpart = rest if t2 < 0 else rest[:t2]
        first = hexpart[:2]
        rva = va - base
        insn.append(rva)
        if first[0] == 'd' and first[1] in '89abcdef':
            x87.append(rva)
            continue
        if first in ('e8', 'e9', 'eb') or first[0] == '7' or first == '0f' or first in ('e0', 'e1', 'e2', 'e3'):
            raw = bytes.fromhex(hexpart.replace(' ', ''))
            op = raw[0]
            tgt = None
            if op in (0xe8, 0xe9) and len(raw) == 5:
                tgt = rva + 5 + struct.unpack_from('<i', raw, 1)[0]
            elif (op == 0xeb or 0x70 <= op <= 0x7f or 0xe0 <= op <= 0xe3) and len(raw) == 2:
                tgt = rva + 2 + struct.unpack_from('<b', raw, 1)[0]
            elif op == 0x0f and len(raw) == 6 and 0x80 <= raw[1] <= 0x8f:
                tgt = rva + 6 + struct.unpack_from('<i', raw, 2)[0]
            if tgt is not None and lo <= tgt < hi:
                branches.append((rva, tgt))
                if op == 0xe8:
                    calls.add(tgt)
    proc.wait()
    os.unlink(name)
    insnset = set(insn)
    entries = set(t for t in calls if t in insnset)
    ptrs = 0
    for r in img.relocs:
        try:
            v = struct.unpack_from('<I', b, img.off(r))[0] - base
        except Exception:
            continue
        # pointers stored in data (vtables, callbacks). Pointers inside code are operands and checked separately
        # (the linear sweep can be out of step right after a jump table, so the pointer alone decides)
        if lo <= v < hi and not (lo <= r < hi):
            entries.add(v)
            ptrs += 1
    pe = struct.unpack_from('<I', b, 0x3c)[0]
    erva, esize = struct.unpack_from('<II', b, pe + 24 + 96)
    if erva:
        e = img.off(erva)
        nfun, afun = struct.unpack_from('<I', b, e + 20)[0], struct.unpack_from('<I', b, e + 28)[0]
        for k in range(nfun):
            v = struct.unpack_from('<I', b, img.off(afun) + 4 * k)[0]
            if lo <= v < hi:
                entries.add(v)
    # pointers to code held in code operands (push offset func, mov [x], offset func)
    codeptr = set()
    for r in img.relocs:
        if lo <= r < hi:
            v = struct.unpack_from('<I', b, img.off(r))[0] - base
            if lo <= v < hi:
                codeptr.add(v)
    m = dict(entries=sorted(entries), branches=branches, x87=x87, insn=insn, codeptr=sorted(codeptr), text=(lo, hi))
    with open(out, 'wb') as f:
        pickle.dump(m, f)
    print('instructions %d, x87 %d, direct branches %d, entries %d (%d from data pointers), code pointers in code %d'
          % (len(insn), len(x87), len(branches), len(entries), ptrs, len(codeptr)))


if __name__ == '__main__':
    build(sys.argv[1], sys.argv[2])
