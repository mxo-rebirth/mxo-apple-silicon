#!/usr/bin/env python3
"""profile2.py <samples.bin> <client.map> <d3d9.dll with symbols> <wine i386 dll dir> [skip-records]

Reads the all-thread samples written by the DLL's profiler (sample.flag) and prints, per thread, where the
time goes: game code, translated routines, graphics layer, Vulkan calls, and waits with their callers."""
import sys, struct, pickle, bisect, subprocess, collections, os

data = open(sys.argv[1], 'rb').read()
cmap = pickle.load(open(sys.argv[2], 'rb'))
winedir = sys.argv[4]
skip = int(sys.argv[5]) if len(sys.argv) > 5 else 0
entries, x87 = cmap['entries'], cmap['x87']
tlo, thi = cmap['text']


def exports(path):
    b = open(path, 'rb').read()
    pe = struct.unpack_from('<I', b, 0x3c)[0]
    nsec = struct.unpack_from('<H', b, pe + 6)[0]
    opt = struct.unpack_from('<H', b, pe + 20)[0]
    size = struct.unpack_from('<I', b, pe + 24 + 56)[0]
    secs = [struct.unpack_from('<IIII', b, pe + 24 + opt + 40 * i + 8) for i in range(nsec)]

    def off(rva):
        for vs, va, rs, raw in secs:
            if va <= rva < va + max(vs, rs):
                return raw + rva - va
    erva = struct.unpack_from('<I', b, pe + 24 + 96)[0]
    if not erva:
        return [], size
    e = off(erva)
    nfun, nnames, afun, anames, aord = struct.unpack_from('<IIIII', b, e + 20)
    funcs = struct.unpack_from('<%dI' % nfun, b, off(afun))
    names = struct.unpack_from('<%dI' % nnames, b, off(anames))
    ords = struct.unpack_from('<%dH' % nnames, b, off(aord))
    tab = sorted((funcs[ords[i]], b[off(names[i]):b.index(b'\0', off(names[i]))].decode()) for i in range(nnames))
    return tab, size


def nearest(tab, addrs, rva):
    i = bisect.bisect_right(addrs, rva) - 1
    return tab[i][1] if i >= 0 else '?'


# symbols of the profiled DLL
syms = []
for l in subprocess.run(['i686-w64-mingw32-nm', '-n', '-C', sys.argv[3]], capture_output=True, text=True).stdout.splitlines():
    p = l.split(None, 2)
    if len(p) == 3 and p[1] in 'tT':
        syms.append((int(p[0], 16), p[2]))
syms.sort()
symaddr = [a for a, n in syms]
hdr = subprocess.run(['i686-w64-mingw32-objdump', '-p', sys.argv[3]], capture_output=True, text=True).stdout
dbase = int([l for l in hdr.splitlines() if 'ImageBase' in l][0].split()[1], 16)

nt_tab, nt_size = exports(os.path.join(winedir, 'ntdll.dll'))
nt_addr = [a for a, n in nt_tab]
vk_tab, vk_size = exports(os.path.join(winedir, 'winevulkan.dll'))
vk_addr = [a for a, n in vk_tab]


def dsym(addr, base):
    n = syms[bisect.bisect_right(symaddr, addr - base + dbase) - 1][1]
    n = n.replace('dxvk::', '')
    return n[:n.index('(')] if '(' in n else n


WAITS = ('WaitForAlertByThreadId', 'WaitForSingleObject', 'WaitForMultipleObjects', 'DelayExecution',
         'WaitForKeyedEvent', 'RemoveIoCompletion', 'NotifyChangeKey', 'SignalAndWaitForSingleObject', 'YieldExecution')

threads = collections.defaultdict(collections.Counter)      # tid -> category -> samples
detail = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
names = {}
present = 0
total = 0
ntbase = None
recs = 0
o = 0
allsamples = []
while o + 40 <= len(data):
    magic, count, cbase, sbase, ssize, vbase, vsize, ptid, nnames, _ = struct.unpack_from('<10I', data, o)
    o += 40
    if magic not in (0x33504d53, 0x34504d53):
        raise SystemExit('not an SMP3/SMP4 file')
    nwords = 7 if magic == 0x33504d53 else 9
    for k in range(nnames):
        tid = struct.unpack_from('<I', data, o)[0]
        names[tid] = data[o + 4:o + 32].split(b'\0')[0].decode()
        o += 32
    recs += 1
    present = ptid or present
    for k in range(count):
        s = struct.unpack_from('<%dI' % nwords, data, o)
        o += 4 * nwords
        if nwords == 7:   # SMP3: one game return address; pad to the SMP4 layout
            s = s[:5] + (s[5], 0, 0, s[6])
        if recs > skip:
            allsamples.append((s, cbase, sbase, ssize, vbase, vsize))

# ntdll base: most waits sit at <Nt stub> + 0xc
cnt = collections.Counter(s[0][1] for s in allsamples if s[0][1] >> 24 in (0x7b, 0x7c, 0x7d, 0x7e, 0x7f))
for addr, _ in cnt.most_common(5):
    c = [(addr - 0xc - a) for a, n in nt_tab if n[:2] in ('Nt', 'Zw') and (addr - 0xc - a) & 0xffff == 0]
    if c:
        ntbase = c[0]
        break

for s, cbase, sbase, ssize, vbase, vsize in allsamples:
    tid, eip, r1, r2, r3, rc1, rc2, rc3, rvk = s
    rclient = rc1
    rself = r1
    total += 1
    t = threads[tid]
    if cbase and cbase <= eip < cbase + 0xbb4000:
        r = eip - cbase
        t['game code (client.dll)'] += 1
        if tlo <= r < thi:
            e = entries[bisect.bisect_right(entries, r) - 1]
            i = bisect.bisect_right(entries, e)
            nxt = entries[i] if i < len(entries) else thi
            nx = bisect.bisect_left(x87, nxt) - bisect.bisect_left(x87, e)
            detail[tid]['game'][(e, nxt, nx)] += 1
    elif sbase <= eip < sbase + ssize:
        n = dsym(eip, sbase)
        if n.startswith('_MxoX_') or n.startswith('LMxoX') or n.startswith('_Mxo'):
            t['translated routines'] += 1
            detail[tid]['xl'][n] += 1
        else:
            t['graphics layer (d3d9.dll)'] += 1
            detail[tid]['d3d9'][n] += 1
    else:
        nm = None
        if ntbase is not None and ntbase <= eip < ntbase + nt_size:
            nm = nearest(nt_tab, nt_addr, eip - ntbase)
        caller = ' < '.join(dsym(r, sbase)[:44] for r in (r1, r2, r3) if r) or '-'
        if rclient and cbase:
            caller += '  [game ' + ' < '.join('%x' % (entries[bisect.bisect_right(entries, r - cbase) - 1])
                                            for r in (rc1, rc2, rc3) if r) + ']'
        if nm and any(w in nm for w in WAITS):
            t['waiting'] += 1
            detail[tid]['wait'][(nm, caller)] += 1
        elif rvk and vbase:
            t['inside Vulkan / Metal'] += 1
            detail[tid]['vk'][(nearest(vk_tab, vk_addr, rvk - vbase), caller)] += 1
        else:
            t['other system code'] += 1
            detail[tid]['other'][(nm or '%08x' % (eip & 0xfffff000), caller)] += 1

sweeps = max(sum(t.values()) for t in threads.values())
print('records %d (skipped %d), %d sweeps over %d threads' % (recs, skip, sweeps, len(threads)))
order = sorted(threads, key=lambda tid: -(sum(threads[tid].values()) - threads[tid]['waiting']))
for tid in order[:int(os.environ.get('THREADS', '6'))]:
    t = threads[tid]
    n = sum(t.values())
    busy = n - t['waiting']
    if busy < n * 0.02:
        continue
    label = names.get(tid, 'game main thread' if tid == present else 'thread')
    print('\n== %s (tid %d)%s: busy %.0f%% of the time' % (label, tid, ' [calls Present]' if tid == present else '', 100.0 * busy / n))
    for k, v in t.most_common():
        print('   %5.1f%%  %s' % (100.0 * v / n, k))
    d = detail[tid]
    if d['wait']:
        print('   waits by caller:')
        for (nm, caller), v in d['wait'].most_common(6):
            print('      %5.1f%%  %s  <-  %s' % (100.0 * v / n, nm, caller[:150]))
    if d['vk']:
        print('   Vulkan calls:')
        for (nm, caller), v in d['vk'].most_common(10):
            print('      %5.1f%%  %s  <-  %s' % (100.0 * v / n, nm, caller[:110]))
    if d['d3d9']:
        print('   graphics layer code:')
        for nm, v in d['d3d9'].most_common(10):
            print('      %5.1f%%  %s' % (100.0 * v / n, nm[:90]))
    if d['other']:
        print('   other:')
        for (nm, caller), v in d['other'].most_common(5):
            print('      %5.1f%%  %s  <-  %s' % (100.0 * v / n, nm, caller[:60]))
    if d['game']:
        g = d['game']
        gx = sum(v for (e, nxt, nx), v in g.items() if nx)
        print('   game code: %.1f%% of this thread in routines containing x87 code; top routines:' % (100.0 * gx / n))
        for (e, nxt, nx), v in g.most_common(int(os.environ.get('TOP', '12'))):
            print('      %5.1f%%  %06x-%06x  x87 %d' % (100.0 * v / n, e, nxt, nx))
    if d['xl']:
        print('   translated: ' + ', '.join('%s %.1f%%' % (k, 100.0 * v / n) for k, v in d['xl'].most_common(6)))

# routines worth translating: game-thread samples in routines with x87 code
with open(sys.argv[1] + '.hot', 'w') as f:
    agg = collections.Counter()
    for tid in threads:
        for (e, nxt, nx), v in detail[tid]['game'].items():
            if nx:
                agg[(e, nxt)] += v
    for (e, nxt), v in agg.most_common():
        f.write('%x %x %d\n' % (e, nxt, v))
