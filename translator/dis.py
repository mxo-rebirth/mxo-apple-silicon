#!/usr/bin/env python3
"""dis.py <pe file> <start>-<end> ...

Disassembles address ranges of a PE file. The ranges are RVAs in hex."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mingw
from peimage import Fail, Image


def code_of(img, start, end):
    """The bytes of [start, end), which have to lie in one section of the file."""
    if end <= start:
        raise Fail('the range %x-%x is empty' % (start, end))
    code = img.bytes(start, end)
    if len(code) != end - start or img.offset_of(end - 1) != img.offset_of(start) + end - 1 - start:
        raise Fail('the range %x-%x does not lie in one section of the file' % (start, end))
    return code


def main(args):
    try:
        ranges = [tuple(int(part, 16) for part in arg.split('-')) for arg in args[1:]]
    except ValueError:
        ranges = []
    if not ranges or any(len(pair) != 2 for pair in ranges):
        raise SystemExit(__doc__)
    img = Image(args[0])
    print('image base %x' % img.base)
    for start, end in ranges:
        code = code_of(img, start, end)
        print('==== %x-%x' % (start, end))
        for line in mingw.disassembly(code, img.base + start, wide=False):
            if ':\t' in line:
                print(line.rstrip('\n'))


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except (Fail, OSError) as failure:
        raise SystemExit('dis.py: %s' % failure) from failure
