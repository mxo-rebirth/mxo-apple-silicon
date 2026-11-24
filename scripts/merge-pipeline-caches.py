#!/usr/bin/env python3
"""merge-pipeline-caches.py <cache> <cache>...

Merges DXVK pipeline caches (*.dxvk-cache). Rejacked (matrix.exe) and Revived (mxorev.exe) run the same
engine, but DXVK keeps one cache per executable name, so each hitches while it builds pipelines the
other already has. DXVK skips entries it cannot use, so merging is safe.

    scripts/merge-pipeline-caches.py "$BOTTLE/drive_c/Games/dxvk"/*.dxvk-cache

Every file given gets the union of all entries. The original of each file is kept once as
<file>.merge-backup. Close the games first.
"""

import os
import shutil
import struct
import sys

HEADER_BYTES = 12               # magic, version, entry size
ENTRY_HEADER_BYTES = 24         # stage mask and size, then the SHA-1 of the entry


def read_cache(path):
    """(header, version, entries) of a cache file. An entry is (its SHA-1, its bytes with the header)."""
    with open(path, 'rb') as file:
        data = file.read()
    if len(data) < HEADER_BYTES or data[:4] != b'DXVK':
        raise SystemExit('%s: not a DXVK state cache' % path)
    version = struct.unpack_from('<I', data, 4)[0]
    if version < 8:
        raise SystemExit('%s: cache version %d is too old to merge' % (path, version))
    entries, offset = [], HEADER_BYTES
    while offset + ENTRY_HEADER_BYTES <= len(data):
        size = struct.unpack_from('<I', data, offset)[0] >> 8   # 8 bits stage mask, 24 bits size
        end = offset + ENTRY_HEADER_BYTES + size
        if end > len(data):
            break                                                 # truncated last entry: drop it
        entries.append((data[offset + 4:offset + ENTRY_HEADER_BYTES], data[offset:end]))
        offset = end
    return data[:HEADER_BYTES], version, entries


def main(paths):
    if len(paths) < 2:
        raise SystemExit(__doc__)
    caches = [(p,) + read_cache(p) for p in paths]
    versions = {c[2] for c in caches}
    if len(versions) != 1:
        raise SystemExit('the caches have different versions (%s), not merging' % sorted(versions))
    seen, merged = set(), []
    for path, _header, _version, entries in caches:
        print('%s: %d entries' % (os.path.basename(path), len(entries)))
        for digest, raw in entries:
            if digest not in seen:
                seen.add(digest)
                merged.append(raw)
    blob = caches[0][1] + b''.join(merged)
    for path, *_ in caches:
        if not os.path.exists(path + '.merge-backup'):
            shutil.copy2(path, path + '.merge-backup')
        with open(path + '.tmp', 'wb') as f:
            f.write(blob)
        os.replace(path + '.tmp', path)
    print('merged: %d entries in each file' % len(merged))


if __name__ == '__main__':
    main(sys.argv[1:])
