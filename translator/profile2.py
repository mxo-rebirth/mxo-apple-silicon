#!/usr/bin/env python3
"""profile2.py <samples.bin> <client.map> <d3d9.dll with symbols> <wine i386 dll dir> [skip-records]

Reads the samples written by the DLL's profiler (sample.flag or sample-light.flag) and prints, per thread,
where the time goes: game code, translated routines, graphics layer, Vulkan calls, and waits with their
callers. skip-records leaves out that many ten-second records from the start of the file.

Writes <samples.bin>.hot next to the samples: the game routines containing x87 code that the presenting
thread was sampled in, as "start limit samples" lines that xlat.py reads as a routine list. Only that
thread counts, because the translations run on no other.

Environment:
  THREADS  how many threads to report, busiest first (default 6)
  TOP      how many game routines to list per thread (default 12)
"""
import bisect
import collections
import os
import pickle
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mingw
from peimage import Fail, Image

SMP4 = 0x34504d53                   # the magic number of a record, "SMP4"
HEADER_BYTES = 40
NAME_BYTES = 32                     # a thread id and its name
SAMPLE_WORDS = 9                    # tid, eip, three return addresses in the DLL, three in the game, one in winevulkan

# Wine loads its system DLLs into the top of the address space
SYSTEM_DLL_TOP_BYTES = (0x7b, 0x7c, 0x7d, 0x7e, 0x7f)
NT_STUB_RETURN = 0xc                # a thread waiting in the kernel sits this far into its Nt stub
DLL_ALIGNMENT = 0x10000             # modules are loaded at multiples of 64 KB
BASE_GUESSES = 5                    # the most common system addresses are tried as "inside a wait"

WAITS = ('WaitForAlertByThreadId', 'WaitForSingleObject', 'WaitForMultipleObjects', 'DelayExecution',
         'WaitForKeyedEvent', 'RemoveIoCompletion', 'NotifyChangeKey', 'SignalAndWaitForSingleObject', 'YieldExecution')

# Symbols of the DLL that are game math and not the graphics layer: the hand-written replacements (MxoMatMulSSE,
# MxoQuatToMatSSE, MxoSqrtSSE) and the translated routines with their local labels. scripts/build.sh passes
# the prefix MxoX to xlat.py.
GAME_MATH_SYMBOLS = ('Mxo', 'LMxoX')

MIN_BUSY_SHARE = 0.02               # a thread that is busy for less of the time is left out
UNKNOWN = '?'


def read_samples(data, skip):
    """(samples, thread names, presenting thread id, record count) of a samples file.

    A sample is (the nine words of the DLL's SampleRecord, client base, DLL base, DLL size, winevulkan base).
    The profiler appends a record every ten seconds, so a file can end in the middle of one: that record is
    left out and said so."""
    samples, names, present, records = [], {}, 0, 0
    position = 0
    while position + HEADER_BYTES <= len(data):
        magic, count, client_base, dll_base, dll_size, vulkan_base, _vulkan_size, present_tid, name_count, _ = \
            struct.unpack_from('<10I', data, position)
        if magic != SMP4:
            raise Fail('not a samples file of this profiler: no SMP4 record at offset %d' % position)
        names_at = position + HEADER_BYTES
        samples_at = names_at + NAME_BYTES * name_count
        end = samples_at + 4 * SAMPLE_WORDS * count
        if end > len(data):
            break
        for k in range(name_count):
            tid = struct.unpack_from('<I', data, names_at + NAME_BYTES * k)[0]
            name = data[names_at + NAME_BYTES * k + 4:names_at + NAME_BYTES * (k + 1)]
            names[tid] = name.split(b'\0')[0].decode(errors='replace')
        records += 1
        present = present_tid or present
        if records > skip:
            for k in range(count):
                words = struct.unpack_from('<%dI' % SAMPLE_WORDS, data, samples_at + 4 * SAMPLE_WORDS * k)
                samples.append((words, client_base, dll_base, dll_size, vulkan_base))
        position = end
    if position != len(data):
        print('the file ends inside a record: the last %d bytes are left out' % (len(data) - position), file=sys.stderr)
    return samples, names, present, records


def text_symbols(path):
    """Sorted (address, name) of the code symbols of a DLL."""
    symbols = []
    for line in mingw.run([mingw.NM, '-n', '-C', path]).splitlines():
        fields = line.split(None, 2)
        if len(fields) == 3 and fields[1] in 'tT':
            symbols.append((int(fields[0], 16), fields[2]))
    if not symbols:
        raise Fail('%s has no symbols: the profile needs the DLL as built, before it is stripped' % path)
    symbols.sort()
    return symbols


def named(table, addresses, address):
    """The name of the last entry of a sorted (address, name) table at or below address."""
    k = bisect.bisect_right(addresses, address) - 1
    return table[k][1] if k >= 0 else UNKNOWN


def ntdll_base(samples, nt_exports):
    """Where ntdll.dll is loaded, which the samples do not say: most waits sit a fixed distance into an Nt stub."""
    counts = collections.Counter(words[1] for words, *_ in samples if words[1] >> 24 in SYSTEM_DLL_TOP_BYTES)
    for address, _count in counts.most_common(BASE_GUESSES):
        bases = [address - NT_STUB_RETURN - rva for rva, name in nt_exports
                 if name[:2] in ('Nt', 'Zw') and (address - NT_STUB_RETURN - rva) % DLL_ALIGNMENT == 0]
        if bases:
            return bases[0]
    return None


def main(args):
    if len(args) not in (4, 5):
        raise SystemExit(__doc__)
    samples_path, map_path, dll_path, wine_folder = args[:4]
    try:
        skip = int(args[4]) if len(args) == 5 else 0
    except ValueError:
        raise SystemExit(__doc__) from None
    with open(samples_path, 'rb') as file:
        samples, names, present, records = read_samples(file.read(), skip)
    if not samples:
        raise Fail('no samples in %s (%d records, %d skipped)' % (samples_path, records, skip))
    with open(map_path, 'rb') as file:
        client_map = pickle.load(file)
    if 'size' not in client_map:
        raise Fail('%s is from an older discover.py: make it again' % map_path)
    entries, x87, client_size = client_map['entries'], client_map['x87'], client_map['size']
    text_start, text_end = client_map['text']

    symbols = text_symbols(dll_path)
    symbol_addresses = [address for address, _name in symbols]
    dll_preferred_base = Image(dll_path).base
    ntdll = Image(os.path.join(wine_folder, 'ntdll.dll'))
    nt_exports = ntdll.exports()[1]
    nt_addresses = [rva for rva, _name in nt_exports]
    vulkan_exports = Image(os.path.join(wine_folder, 'winevulkan.dll')).exports()[1]
    vulkan_addresses = [rva for rva, _name in vulkan_exports]
    nt_base = ntdll_base(samples, nt_exports)

    def dll_symbol(address, base):
        name = named(symbols, symbol_addresses, address - base + dll_preferred_base)
        name = name.replace('dxvk::', '')
        return name[:name.index('(')] if '(' in name else name

    def routine_start(rva):
        """The entry at or below an address of the game, None if there is none."""
        k = bisect.bisect_right(entries, rva) - 1
        return entries[k] if k >= 0 else None

    threads = collections.defaultdict(collections.Counter)      # tid -> category -> samples
    detail = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
    for words, client_base, dll_base, dll_size, vulkan_base in samples:
        tid, eip, dll_return1, dll_return2, dll_return3, game_return1, game_return2, game_return3, vulkan_return = words
        counts = threads[tid]
        if client_base and client_base <= eip < client_base + client_size:
            rva = eip - client_base
            counts['game code (client.dll)'] += 1
            start = routine_start(rva) if text_start <= rva < text_end else None
            if start is not None:
                k = bisect.bisect_right(entries, start)
                limit = entries[k] if k < len(entries) else text_end
                x87_count = bisect.bisect_left(x87, limit) - bisect.bisect_left(x87, start)
                detail[tid]['game'][(start, limit, x87_count)] += 1
        elif dll_base <= eip < dll_base + dll_size:
            name = dll_symbol(eip, dll_base)
            if name.lstrip('_').startswith(GAME_MATH_SYMBOLS):
                counts['translated routines'] += 1
                detail[tid]['xl'][name] += 1
            else:
                counts['graphics layer (d3d9.dll)'] += 1
                detail[tid]['d3d9'][name] += 1
        else:
            system_name = None
            if nt_base is not None and nt_base <= eip < nt_base + ntdll.size:
                system_name = named(nt_exports, nt_addresses, eip - nt_base)
            caller = ' < '.join(dll_symbol(address, dll_base)[:44] for address in (dll_return1, dll_return2, dll_return3) if address) or '-'
            if game_return1 and client_base:
                starts = [routine_start(address - client_base) for address in (game_return1, game_return2, game_return3) if address]
                caller += '  [game ' + ' < '.join(UNKNOWN if start is None else '%x' % start for start in starts) + ']'
            if system_name and any(wait in system_name for wait in WAITS):
                counts['waiting'] += 1
                detail[tid]['wait'][(system_name, caller)] += 1
            elif vulkan_return and vulkan_base:
                counts['inside Vulkan / Metal'] += 1
                detail[tid]['vk'][(named(vulkan_exports, vulkan_addresses, vulkan_return - vulkan_base), caller)] += 1
            else:
                counts['other system code'] += 1
                detail[tid]['other'][(system_name or '%08x' % (eip & 0xfffff000), caller)] += 1

    sweeps = max(sum(counts.values()) for counts in threads.values())
    print('records %d (skipped %d), %d sweeps over %d threads' % (records, skip, sweeps, len(threads)))
    busiest = sorted(threads, key=lambda tid: -(sum(threads[tid].values()) - threads[tid]['waiting']))
    for tid in busiest[:int(os.environ.get('THREADS', '6'))]:
        counts = threads[tid]
        total = sum(counts.values())
        busy = total - counts['waiting']
        if busy < total * MIN_BUSY_SHARE:
            continue
        label = names.get(tid, 'game main thread' if tid == present else 'thread')
        print('\n== %s (tid %d)%s: busy %.0f%% of the time'
              % (label, tid, ' [calls Present]' if tid == present else '', 100.0 * busy / total))
        for category, count in counts.most_common():
            print('   %5.1f%%  %s' % (100.0 * count / total, category))
        found = detail[tid]
        if found['wait']:
            print('   waits by caller:')
            for (name, caller), count in found['wait'].most_common(6):
                print('      %5.1f%%  %s  <-  %s' % (100.0 * count / total, name, caller[:150]))
        if found['vk']:
            print('   Vulkan calls:')
            for (name, caller), count in found['vk'].most_common(10):
                print('      %5.1f%%  %s  <-  %s' % (100.0 * count / total, name, caller[:110]))
        if found['d3d9']:
            print('   graphics layer code:')
            for name, count in found['d3d9'].most_common(10):
                print('      %5.1f%%  %s' % (100.0 * count / total, name[:90]))
        if found['other']:
            print('   other:')
            for (name, caller), count in found['other'].most_common(5):
                print('      %5.1f%%  %s  <-  %s' % (100.0 * count / total, name, caller[:60]))
        if found['game']:
            in_x87_routines = sum(count for (_start, _limit, x87_count), count in found['game'].items() if x87_count)
            print('   game code: %.1f%% of this thread in routines containing x87 code, top routines:' % (100.0 * in_x87_routines / total))
            for (start, limit, x87_count), count in found['game'].most_common(int(os.environ.get('TOP', '12'))):
                print('      %5.1f%%  %06x-%06x  x87 %d' % (100.0 * count / total, start, limit, x87_count))
        if found['xl']:
            print('   translated: ' + ', '.join('%s %.1f%%' % (name, 100.0 * count / total) for name, count in found['xl'].most_common(6)))

    # routines worth translating: what the presenting thread ran that contains x87 code. The translations run
    # on that thread only, so time other threads spend in a routine is no reason to translate it
    hot = collections.Counter()
    for (start, limit, x87_count), count in detail[present]['game'].items():
        if x87_count:
            hot[(start, limit)] += count
    with open(samples_path + '.hot', 'w') as file:
        for (start, limit), count in hot.most_common():
            file.write('%x %x %d\n' % (start, limit, count))


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except (Fail, OSError) as failure:
        raise SystemExit('profile2.py: %s' % failure) from failure
