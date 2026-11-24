#!/usr/bin/env python3
"""discover.py <pe file> <out.map>

Maps the code section of a PE file with a linear-sweep disassembly, for the profiler and the translator.

The map is a pickle of a dict:
  entries   sorted RVAs of function entries (direct call targets, pointers into code, exports)
  branches  (source rva, target rva) of every direct call/jmp/jcc
  x87       sorted RVAs of the x87 instructions
  text      (start, end) of the code section as RVAs
  size      size of the image in memory, in bytes
"""
import bisect
import os
import pickle
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mingw
from peimage import Fail, Image


def direct_target(rva, raw):
    """Where a direct call, jump or conditional jump at rva goes, None for any other instruction."""
    op = raw[0]
    if op in (0xe8, 0xe9) and len(raw) == 5:
        return rva + 5 + struct.unpack_from('<i', raw, 1)[0]
    if (op == 0xeb or 0x70 <= op <= 0x7f or 0xe0 <= op <= 0xe3) and len(raw) == 2:
        return rva + 2 + struct.unpack_from('<b', raw, 1)[0]
    if op == 0x0f and len(raw) == 6 and 0x80 <= raw[1] <= 0x8f:
        return rva + 6 + struct.unpack_from('<i', raw, 2)[0]
    return None


def starts_instruction(starts, rva):
    """True if rva is one of the instruction starts, which are in ascending order."""
    k = bisect.bisect_left(starts, rva)
    return k < len(starts) and starts[k] == rva


def build(path, out):
    img = Image(path)
    lo, hi = img.text[0]
    if len(img.text) > 1:
        print('only the first of %d executable sections is mapped' % len(img.text))
    starts, x87, branches, calls = [], [], [], set()
    for line in mingw.disassembly(img.bytes(lo, hi), img.base + lo):
        found = mingw.instruction(line)
        if not found:
            continue
        rva, raw = found[0] - img.base, found[1]
        starts.append(rva)
        if 0xd8 <= raw[0] <= 0xdf:
            x87.append(rva)
            continue
        target = direct_target(rva, raw)
        if target is not None and lo <= target < hi:
            branches.append((rva, target))
            if raw[0] == 0xe8:
                calls.add(target)
    # a call into the middle of an instruction comes from bytes that are data, not code
    entries = {target for target in calls if starts_instruction(starts, target)}
    from_data = 0
    for value, location in img.pointers:
        # pointers stored in data (vtables, callbacks) name functions. The sweep can be out of step after a jump
        # table, so the pointer alone decides. A pointer held in code is an operand and names nothing
        if lo <= value < hi and not (lo <= location < hi):
            entries.add(value)
            from_data += 1
    entries.update(rva for rva in img.exports()[0] if lo <= rva < hi)
    with open(out + '.tmp', 'wb') as file:
        pickle.dump(dict(entries=sorted(entries), branches=branches, x87=x87, text=(lo, hi), size=img.size), file)
    os.replace(out + '.tmp', out)
    print('instructions %d, x87 %d, direct branches %d, entries %d (%d from data pointers)'
          % (len(starts), len(x87), len(branches), len(entries), from_data))


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    try:
        build(sys.argv[1], sys.argv[2])
    except (Fail, OSError) as failure:
        raise SystemExit('discover.py: %s' % failure) from failure
