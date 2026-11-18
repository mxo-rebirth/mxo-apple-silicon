#!/usr/bin/env python3
"""Static x87 -> SSE2 translator for whole functions of a 32-bit x86 image.

Each x87 register is kept in an xmm register as a double. The game runs its FPU in 24-bit
precision mode (Direct3D 9 default), so every add/sub/mul/div/sqrt result is rounded to a
24-bit significand with round-to-nearest-even while keeping the wide exponent range, exactly
as the x87 does. No translated sequence changes EFLAGS (x87 code does not either), except
where the original reads the FPU status word.

Usage: xlat.py <mode> <image> <prefix> <out.inc> <start-end> [...]
  mode  pe   : image is a PE file, ranges are RVAs
        flat : image is a flat binary linked at 0x62000000, ranges are offsets
"""
import sys, struct, subprocess, tempfile, os, re, bisect, pickle

T1, T2 = 'xmm6', 'xmm7'
MAXDEPTH = 6


class Fail(Exception):
    pass


class Image:
    def __init__(self, path, mode):
        self.data = open(path, 'rb').read()
        self.mode = mode
        self.relocs = set()
        if mode == 'pe':
            b = self.data
            pe = struct.unpack_from('<I', b, 0x3c)[0]
            nsec = struct.unpack_from('<H', b, pe + 6)[0]
            opt = struct.unpack_from('<H', b, pe + 20)[0]
            self.base = struct.unpack_from('<I', b, pe + 24 + 28)[0]
            self.secs = [struct.unpack_from('<IIII', b, pe + 24 + opt + 40 * i + 8) for i in range(nsec)]
            self.text = [(va, va + vs) for (vs, va, rs, raw), i in zip(self.secs, range(nsec))
                         if struct.unpack_from('<I', b, pe + 24 + opt + 40 * i + 36)[0] & 0x20000000]
            rrva, rsize = struct.unpack_from('<II', b, pe + 24 + 96 + 8 * 5)
            o = self.off(rrva)
            end = o + rsize
            while o < end:
                page, size = struct.unpack_from('<II', b, o)
                if size < 8:
                    break
                for k in range((size - 8) // 2):
                    e = struct.unpack_from('<H', b, o + 8 + 2 * k)[0]
                    if e >> 12 == 3:
                        self.relocs.add(page + (e & 0xfff))
                o += size
        else:
            self.base = 0x62000000
            self.secs = [(len(self.data), 0, len(self.data), 0)]
            self.text = [(0, len(self.data))]
        self.relocs_sorted = sorted(self.relocs)
        # (value rva, location rva) of every relocated pointer, to find who points into a function
        self.pointers = []
        for r in self.relocs_sorted:
            try:
                self.pointers.append((struct.unpack_from('<I', self.data, self.off(r))[0] - self.base, r))
            except Fail:
                pass
        self.pointers.sort()
        self.branches = []     # (target rva, source rva) of direct branches, from discover.py

    def relocs_in(self, s, e):
        a = bisect.bisect_left(self.relocs_sorted, s)
        b = bisect.bisect_left(self.relocs_sorted, e)
        return self.relocs_sorted[a:b]

    def interior_refs(self, s, e, tables=()):
        """References to addresses strictly inside (s, e): any pointer (except from the function's own
        switch tables), and direct branches from outside."""
        hits = []
        a = bisect.bisect_right(self.pointers, (s, 1 << 40))
        while a < len(self.pointers) and self.pointers[a][0] < e:
            loc = self.pointers[a][1]
            if not any(t <= loc < t + size for t, size in tables):
                hits.append('pointer at %x -> %x' % (loc, self.pointers[a][0]))
            a += 1
        a = bisect.bisect_right(self.branches, (s, 1 << 40))
        while a < len(self.branches) and self.branches[a][0] < e:
            if not (s <= self.branches[a][1] < e):
                hits.append('branch at %x -> %x' % (self.branches[a][1], self.branches[a][0]))
            a += 1
        return hits

    def off(self, rva):
        for vs, va, rs, raw in self.secs:
            if va <= rva < va + max(vs, rs):
                return raw + rva - va
        raise Fail('rva %x not in image' % rva)

    def bytes(self, s, e):
        return self.data[self.off(s):self.off(s) + (e - s)]


class Ins:
    pass


def disassemble(img, s, e):
    code = img.bytes(s, e)
    with tempfile.NamedTemporaryFile(suffix='.bin', delete=False) as f:
        f.write(code)
        name = f.name
    out = subprocess.run(['i686-w64-mingw32-objdump', '-D', '-z', '-b', 'binary', '-mi386', '-Mintel', '--insn-width=16',
                          '--adjust-vma=0x%x' % (img.base + s), name], capture_output=True, text=True).stdout
    os.unlink(name)
    res = []
    for l in out.splitlines():
        m = re.match(r'^\s*([0-9a-f]+):\t((?:[0-9a-f]{2} )+)\s*(?:\t(.*))?$', l)
        if not m:
            continue
        i = Ins()
        i.va = int(m.group(1), 16)
        i.rva = i.va - img.base
        i.raw = bytes.fromhex(m.group(2).replace(' ', ''))
        i.text = (m.group(3) or '').strip()
        i.bad = not i.text or '(bad)' in i.text
        if i.bad:
            i.text = '(bad)'
        parts = i.text.split(None, 1)
        i.mnem = parts[0]
        i.ops = parts[1] if len(parts) > 1 else ''
        res.append(i)
    if sum(len(i.raw) for i in res) != e - s:
        raise Fail('disassembly does not cover the function')
    return res


JCC = {'jo', 'jno', 'jb', 'jae', 'je', 'jne', 'jbe', 'ja', 'js', 'jns', 'jp', 'jnp', 'jl', 'jge', 'jle', 'jg',
       'jc', 'jnc', 'jz', 'jnz', 'jna', 'jnbe', 'jnae', 'jnb', 'jpe', 'jpo', 'jnge', 'jnl', 'jng', 'jnle'}
FLAG_DEF = {'add', 'sub', 'cmp', 'test', 'and', 'or', 'xor', 'neg', 'sahf', 'popf', 'popfd', 'imul', 'mul',
            'call', 'ret'}
FLAG_NEUTRAL = {'mov', 'lea', 'push', 'pop', 'movzx', 'movsx', 'xchg', 'nop', 'not', 'cdq', 'cwde', 'cbw',
                'bswap', 'fwait'}


def classify(i, s, e, base):
    """Fills in control-flow information for a non-x87 instruction."""
    r = i.raw
    i.kind = 'raw'
    i.target = None
    op = r[0]
    if op == 0xe8:
        i.kind = 'call'
        i.target = i.rva + 5 + struct.unpack_from('<i', r, 1)[0]
    elif op == 0xe9:
        i.kind = 'jmp'
        i.target = i.rva + 5 + struct.unpack_from('<i', r, 1)[0]
    elif op == 0xeb:
        i.kind = 'jmp'
        i.target = i.rva + 2 + struct.unpack_from('<b', r, 1)[0]
    elif 0x70 <= op <= 0x7f:
        i.kind = 'jcc'
        i.target = i.rva + 2 + struct.unpack_from('<b', r, 1)[0]
    elif op == 0x0f and len(r) >= 2 and 0x80 <= r[1] <= 0x8f:
        i.kind = 'jcc'
        i.target = i.rva + 6 + struct.unpack_from('<i', r, 2)[0]
    elif 0xe0 <= op <= 0xe3:
        i.kind = 'jcc'
        i.target = i.rva + 2 + struct.unpack_from('<b', r, 1)[0]
    elif op in (0xc3, 0xc2):
        i.kind = 'ret'
    elif op in (0xcb, 0xca, 0xcf, 0xea, 0x9a):
        raise Fail('far control transfer at %x' % i.rva)
    elif op == 0xff and len(r) >= 2:
        sub = (r[1] >> 3) & 7
        if sub == 2:
            i.kind = 'icall'
        elif sub == 4:
            if r[1] == 0x25:
                i.kind = 'ijmp'
            elif r[1] == 0x24 and len(r) == 7 and (r[2] & 0xc7) == 0x85 and r[2] != 0xa5:
                # jmp [index*4 + table]: a switch
                i.kind = 'switch'
                i.table = struct.unpack_from('<I', r, 3)[0] - base
                i.index = ['eax', 'ecx', 'edx', 'ebx', None, 'ebp', 'esi', 'edi'][(r[2] >> 3) & 7]
            else:
                raise Fail('indirect jump at %x (%s)' % (i.rva, i.text))
        elif sub in (3, 5):
            raise Fail('far indirect transfer at %x' % i.rva)
    if i.kind in ('jmp', 'jcc') and i.mnem not in JCC and i.mnem not in ('jmp', 'loop', 'loope', 'loopne', 'jecxz'):
        raise Fail('unexpected branch mnemonic %s at %x' % (i.text, i.rva))
    if re.search(r'\b(xmm|mm)\d', i.text):
        raise Fail('function already uses SSE/MMX at %x' % i.rva)


def x87_decode(i):
    """Returns (name, arg) for an x87 instruction; arg is st index or memory size keyword."""
    op, modrm = i.raw[0], i.raw[1]
    mod, reg, rm = modrm >> 6, (modrm >> 3) & 7, modrm & 7
    arith = ['add', 'mul', 'com', 'comp', 'sub', 'subr', 'div', 'divr']
    if mod != 3:
        if 'PTR' not in i.ops:
            raise Fail('memory operand expected: %s' % i.text)
        i.mem = i.ops
        if op == 0xd8:
            return ('m_' + arith[reg], 32)
        if op == 0xdc:
            return ('m_' + arith[reg], 64)
        if op == 0xda:
            return ('mi_' + arith[reg], 32)
        if op == 0xde:
            return ('mi_' + arith[reg], 16)
        if op == 0xd9:
            return {0: ('fld_m', 32), 2: ('fst_m', 32), 3: ('fstp_m', 32)}.get(reg) or _bad(i)
        if op == 0xdd:
            return {0: ('fld_m', 64), 2: ('fst_m', 64), 3: ('fstp_m', 64)}.get(reg) or _bad(i)
        if op == 0xdb:
            return {0: ('fild_m', 32), 2: ('fist_m', 32), 3: ('fistp_m', 32)}.get(reg) or _bad(i)
        if op == 0xdf:
            return {0: ('fild_m', 16), 2: ('fist_m', 16), 3: ('fistp_m', 16), 5: ('fild_m', 64),
                    7: ('fistp_m', 64)}.get(reg) or _bad(i)
        _bad(i)
    if op == 0xd8:
        return ('r0_' + arith[reg], rm)                    # st0 = st0 op sti
    if op == 0xdc:
        name = ['add', 'mul', None, None, 'subr', 'sub', 'divr', 'div'][reg]
        if not name:
            _bad(i)
        return ('ri_' + name, rm)                          # sti = sti op st0 (r: st0 op sti)
    if op == 0xde:
        if modrm == 0xd9:
            return ('compp', 1)
        name = ['add', 'mul', None, None, 'subr', 'sub', 'divr', 'div'][reg]
        if not name:
            _bad(i)
        return ('rp_' + name, rm)                          # like ri_, then pop
    if op == 0xd9:
        if reg == 0:
            return ('fld_r', rm)
        if reg == 1:
            return ('fxch', rm)
        simple = {0xd0: 'fnop', 0xe0: 'fchs', 0xe1: 'fabs', 0xe4: 'ftst', 0xe8: 'fld1', 0xee: 'fldz', 0xeb: 'fldpi',
                  0xfa: 'fsqrt', 0xfe: 'fsin', 0xff: 'fcos', 0xfc: 'frndint', 0xf3: 'fpatan', 0xf2: 'fptan',
                  0xfb: 'fsincos', 0xf1: 'fyl2x', 0xea: 'fldl2e', 0xed: 'fldln2', 0xec: 'fldlg2', 0xe9: 'fldl2t'}
        if modrm in simple:
            return (simple[modrm], 0)
        _bad(i)
    if op == 0xdd:
        if reg == 2:
            return ('fst_r', rm)
        if reg == 3:
            return ('fstp_r', rm)
        if reg == 4:
            return ('r0_com', rm)
        if reg == 5:
            return ('r0_comp', rm)
        _bad(i)
    if op == 0xda:
        if modrm == 0xe9:
            return ('compp', 1)
        _bad(i)
    if op == 0xdf:
        if modrm == 0xe0:
            return ('fnstsw_ax', 0)
        if reg == 5 or reg == 6:
            return ('comip', rm)
        _bad(i)
    if op == 0xdb:
        if reg == 5 or reg == 6:
            return ('comi', rm)
        _bad(i)
    _bad(i)


def _bad(i):
    raise Fail('unsupported x87 instruction at %x: %s' % (i.rva, i.text))


def stack_effect(name, arg):
    """(registers that must exist before, net depth change)"""
    if name in ('fld_m', 'fild_m', 'fld1', 'fldz', 'fldpi', 'fldl2e', 'fldln2', 'fldlg2', 'fldl2t'):
        return (0, 1)
    if name == 'fld_r':
        return (arg + 1, 1)
    if name in ('fptan', 'fsincos'):
        return (1, 1)
    if name in ('fst_m', 'fist_m', 'fchs', 'fabs', 'ftst', 'fsqrt', 'fsin', 'fcos', 'frndint'):
        return (1, 0)
    if name in ('fstp_m', 'fistp_m'):
        return (1, -1)
    if name in ('fst_r', 'fxch'):
        return (arg + 1, 0)
    if name == 'fstp_r':
        return (arg + 1, -1)
    if name in ('fpatan', 'fyl2x'):
        return (2, -1)
    if name == 'compp':
        return (2, -2)
    if name in ('fnstsw_ax', 'fnop'):
        return (0, 0)
    kind, op = name.split('_', 1)
    if kind in ('m', 'mi'):
        return (1, -1 if op == 'comp' else 0)
    if kind == 'r0':
        return (arg + 1, -1 if op == 'comp' else 0)
    if kind == 'ri':
        return (arg + 1, 0)
    if kind == 'rp':
        return (arg + 1, -1)
    if name == 'comi':
        return (arg + 1, 0)
    if name == 'comip':
        return (arg + 1, -1)
    raise Fail('no stack effect for ' + name)


class Translator:
    def __init__(self, img, prefix):
        self.img = img
        self.prefix = prefix
        self.out = []        # asm lines
        self.absfix = []     # expressions of locations holding image-absolute addresses
        self.relfix = []     # (location expression, target rva)
        self.funcs = []      # (rva, size, [reloc offsets])
        self.uid = 0
        self.stats = []
        self.ftol = set()    # RVAs of the compiler's float-to-integer helper (takes st0, returns edx:eax)
        self.exact = False   # True: rounding that also matches x87 outside the float range (slower)
        self.jumptables = [] # (label, [case labels]) of translated switches
        self.tabledeps = []  # (rva, size) of original switch tables the translations were made from
        self.info = []

    def label(self):
        self.uid += 1
        return 'L%s_%d' % (self.prefix, self.uid)

    # ---- analysis --------------------------------------------------------------------------
    def analyse(self, ins, s, e, fpret):
        idx = {i.rva: n for n, i in enumerate(ins)}
        depth = [None] * len(ins)
        work = [(0, 0)]
        while work:
            n, d = work.pop()
            while True:
                if n >= len(ins):
                    raise Fail('execution runs past the end of the function')
                i = ins[n]
                if depth[n] is not None:
                    if depth[n] != d:
                        raise Fail('inconsistent FPU stack depth at %x' % i.rva)
                    break
                depth[n] = d
                if i.err:
                    raise i.err
                if i.x87:
                    need, delta = stack_effect(*i.x87)
                    if d < need:
                        raise Underflow(n)
                    d += delta
                    if d > MAXDEPTH:
                        raise Fail('FPU stack deeper than %d at %x' % (MAXDEPTH, i.rva))
                elif i.kind == 'ftol':
                    if d < 1:
                        raise Underflow(n)      # the call before it returned the value
                    d -= 1
                elif i.kind in ('call', 'icall'):
                    if d != 0:
                        raise Fail('call at %x to %s with %d values on the FPU stack'
                                   % (i.rva, '%x' % i.target if i.target else 'a pointer', d))
                    if n in fpret:
                        d += 1
                elif i.kind == 'ret':
                    if d not in (0, 1):
                        raise Fail('return at %x with FPU depth %d' % (i.rva, d))
                    break
                elif i.kind == 'ijmp':
                    if d != 0:
                        raise Fail('tail jump at %x with FPU depth %d' % (i.rva, d))
                    break
                elif i.kind == 'switch':
                    for t in i.cases:
                        if t not in idx:
                            raise Fail('switch case in the middle of an instruction at %x' % i.rva)
                        work.append((idx[t], d))
                    break
                elif i.kind in ('jmp', 'jcc'):
                    if s <= i.target < e:
                        if i.target not in idx:
                            raise Fail('branch into the middle of an instruction at %x' % i.rva)
                        work.append((idx[i.target], d))
                    else:
                        if i.kind == 'jcc' or d != 0:
                            raise Fail('branch out of the function at %x' % i.rva)
                    if i.kind == 'jmp':
                        break
                n += 1
        return depth

    # ---- emission --------------------------------------------------------------------------
    def rnd(self, x):
        """Rounds x to a 24-bit significand, nearest-even.

        Default: convert to float and back. Both are full-width forms, which the translator under
        Rosetta handles in one step each. This equals the x87 result whenever the value lies in the
        float range; beyond it the x87 keeps a finite value or a normal tiny one, where this gives
        infinity or a float denormal.

        With exact: add and subtract 1.5 * 2^(exponent + 29) with the sign of x, which keeps the
        x87 exponent range. Needs only T1; no flags."""
        if not self.exact:
            return ['cvtpd2ps %s, %s' % (x, x), 'cvtps2pd %s, %s' % (x, x)]
        p = self.prefix
        return ['movapd %s, %s' % (T1, x),
                'andpd %s, XMMWORD PTR [_%s_signexp]' % (T1, p),
                'minpd %s, XMMWORD PTR [_%s_big]' % (T1, p),
                'maxpd %s, XMMWORD PTR [_%s_nbig]' % (T1, p),
                'mulpd %s, XMMWORD PTR [_%s_k]' % (T1, p),
                'addpd %s, %s' % (x, T1),
                'subpd %s, %s' % (x, T1),
                'andpd %s, XMMWORD PTR [_%s_signmask]' % (T1, p),
                'orpd %s, %s' % (x, T1)]

    @staticmethod
    def load(dst, kind, size, m):
        """Instructions that put a memory operand into dst as a double with a zero upper half."""
        if kind == 'm' and size == 32:
            return ['movss %s, %s' % (dst, m), 'cvtps2pd %s, %s' % (dst, dst)]
        if kind == 'm' and size == 64:
            return ['movsd %s, %s' % (dst, m)]
        if kind == 'mi' and size == 32:
            return ['xorpd %s, %s' % (dst, dst), 'cvtsi2sd %s, %s' % (dst, m)]
        raise Fail('unsupported memory operand')

    @staticmethod
    def arith(op, dst, src):
        """dst = dst op src. Add, subtract and multiply use the full-width forms, which the
        translator under Rosetta handles without a merge step; divide stays scalar."""
        return ['%s %s, %s' % ({'add': 'addpd', 'sub': 'subpd', 'mul': 'mulpd', 'div': 'divsd'}[op], dst, src)]

    def translate(self, s, e):
        """Translates the function at s; e is the furthest it may extend (start of the next function)."""
        img = self.img
        relocs = img.relocs_in(s, e)

        def prepare(data):
            """Disassembles [s, e) around the given data ranges and classifies every instruction."""
            ins, pos = [], s
            for t, size in sorted(data) + [(e, 0)]:
                if t > pos:
                    ins.extend(disassemble(img, pos, t))
                pos = max(pos, t + size)
            for i in ins:
                i.x87 = None
                i.mem = None
                i.err = None
                i.kind = 'raw'
                i.target = None
                i.relocs = [r - i.rva for r in relocs[bisect.bisect_left(relocs, i.rva):bisect.bisect_left(relocs, i.rva + len(i.raw))]]
                try:
                    if i.bad:
                        raise Fail('undecodable bytes at %x' % i.rva)
                    first = i.raw[0]
                    if 0xd8 <= first <= 0xdf:
                        i.x87 = x87_decode(i)
                        i.kind = 'x87'
                    else:
                        if i.mnem.startswith('f') and i.mnem != 'fwait':
                            raise Fail('prefixed x87 instruction at %x: %s' % (i.rva, i.text))
                        classify(i, s, e, img.base)
                        if i.kind == 'call' and i.target in self.ftol:
                            i.kind = 'ftol'
                    for r in i.relocs:
                        if r + 4 > len(i.raw):
                            raise Fail('relocation crosses an instruction boundary at %x' % i.rva)
                except Fail as f:
                    # only a problem if the instruction can actually be reached
                    i.err = f
                    i.x87 = None
                    i.kind = 'err'
            tables, found = [], []
            for n, i in enumerate(ins):
                if i.kind != 'switch':
                    continue
                # number of cases: from "cmp index, N / ja default" right before the jump, else as far as the
                # table holds relocated pointers into this function
                bound = None
                if n >= 2 and ins[n - 1].mnem == 'ja':
                    m = re.match(r'cmp\s+%s,0x([0-9a-f]+)$' % i.index, ins[n - 2].text)
                    if m:
                        bound = int(m.group(1), 16) + 1
                cases = []
                while len(cases) < (bound or 1024):
                    loc = i.table + 4 * len(cases)
                    if loc not in img.relocs:
                        break
                    t = struct.unpack_from('<I', img.data, img.off(loc))[0] - img.base
                    if not (s <= t < e):
                        break
                    cases.append(t)
                if not cases or (bound and len(cases) != bound):
                    i.err = Fail('cannot read the switch table at %x' % i.rva)
                    i.kind = 'err'
                    continue
                i.cases = cases
                tables.append((i.table, 4 * len(cases)))
                found.append((i.table, 4 * len(cases)))
                # two-level switch: "cmp x, N / ja / movzx index, byte [x + bytes] / jmp" picks the case through
                # a byte table, which is data as well
                if n >= 3 and ins[n - 1].mnem == 'movzx' and 'BYTE PTR' in ins[n - 1].text and ins[n - 1].relocs \
                        and ins[n - 2].mnem == 'ja':
                    m = re.match(r'cmp\s+\w+,0x([0-9a-f]+)$', ins[n - 3].text)
                    r0 = ins[n - 1].rva + ins[n - 1].relocs[0]
                    bt = struct.unpack_from('<I', img.data, img.off(r0))[0] - img.base
                    if m and s <= bt < e:
                        found.append((bt, int(m.group(1), 16) + 1))
            return ins, tables, found

        # switch tables stored inside the function are data: once found, disassemble around them
        data = []
        for attempt in range(8):
            ins, tables, found = prepare(data)
            inner = [t for t in found if s <= t[0] < e and t not in data]
            if not inner:
                break
            data = sorted(set(data + inner))

        fpret = set()
        while True:
            try:
                depth = self.analyse(ins, s, e, fpret)
                break
            except Underflow as u:
                # a value is used that the code did not push: the closest preceding call returned it
                n = u.n - 1
                while n >= 0 and ins[n].kind not in ('call', 'icall'):
                    if ins[n].kind in ('jmp', 'jcc', 'ret', 'ijmp'):
                        n = -1
                        break
                    n -= 1
                if n < 0 or n in fpret:
                    raise Fail('FPU stack underflow at %x (function takes arguments on the FPU stack?)' % ins[u.n].rva)
                fpret.add(n)
                # every call of the same function returns the same way
                if ins[n].kind == 'call':
                    fpret.update(k for k, j in enumerate(ins) if j.kind == 'call' and j.target == ins[n].target)

        # the function ends with its last reachable instruction
        last = max(n for n in range(len(ins)) if depth[n] is not None)
        e = ins[last].rva + len(ins[last].raw)
        del ins[last + 1:]
        del depth[last + 1:]
        relocs = img.relocs_in(s, e)
        nx87 = sum(1 for n, i in enumerate(ins) if depth[n] is not None and i.kind == 'x87')
        if not nx87:
            raise Fail('no x87 code')
        tables = [t for t in tables if any(j.kind == 'switch' and j.table == t[0] and depth[k] is not None
                                           for k, j in enumerate(ins))]
        refs = img.interior_refs(s, e, tables)
        if refs:
            raise Fail('interior referenced: ' + '; '.join(refs[:2]))
        uses_ftol = any(i.kind == 'ftol' and depth[n] is not None for n, i in enumerate(ins))

        targets = {i.target for n, i in enumerate(ins)
                   if depth[n] is not None and i.kind in ('jmp', 'jcc') and s <= i.target < e}
        for n, i in enumerate(ins):
            if depth[n] is not None and i.kind == 'switch':
                targets.update(i.cases)
        p = self.prefix
        fn = '_%s_%06x' % (p, s)
        o = self.out
        # instructions the 5-byte entry patch overwrites; other threads run them here and continue in the original
        head, hlen = [], 0
        for n, i in enumerate(ins):
            if hlen >= 5:
                break
            if depth[n] is None or i.kind not in ('raw', 'x87') or (i.rva != s and i.rva in targets):
                raise Fail('cannot relocate the first instructions (%s)' % i.text)
            head.append(i)
            hlen += len(i.raw)
        if hlen < 5:
            raise Fail('function shorter than the entry patch')
        tramp = 'L%s_tramp_%06x' % (p, s)
        o.append('.p2align 4')
        o.append('.globl %s' % fn)
        o.append('%s:' % fn)
        # the translation assumes the FPU precision of the thread that owns the Direct3D device
        o.extend(['push eax', 'mov eax, DWORD PTR fs:[0x24]', 'cmp eax, DWORD PTR [_%s_tid]' % p, 'pop eax',
                  'jne %s' % tramp])
        cs = [None]      # how a pending compare is held: 'pair' = operands in T1/T2, 'stash' = status image in T2
        nfall = 0

        def t1_used():
            if cs[0] == 'pair':
                cs[0] = None

        def reg(d, k):
            return 'xmm%d' % (d - 1 - k)

        def spill_load(dst):        # value on the real FPU stack -> xmm
            return ['lea esp, [esp-8]', 'fstp QWORD PTR [esp]', 'movsd %s, QWORD PTR [esp]' % dst, 'lea esp, [esp+8]']

        def spill_push(src):        # xmm -> real FPU stack, esp restored afterwards
            return ['lea esp, [esp-8]', 'movsd QWORD PTR [esp], %s' % src, 'fld QWORD PTR [esp]', 'lea esp, [esp+8]']

        for n, i in enumerate(ins):
            d = depth[n]
            if i.rva in targets:
                o.append('L%s_%06x:' % (p, i.rva))
                cs[0] = None
            if d is None:
                continue        # never executed (padding, data)

            def compare(a, bload, i=i, n=n):
                """st0 (in a) against the value that bload puts into T2."""
                if self.compare_use(ins, n, targets) != 'stash':
                    memfix(['movapd %s, %s' % (T1, a)] + bload)
                    cs[0] = 'pair'
                    return
                # FP code runs between this compare and the status word read: work the condition bits out now,
                # without touching flags or eax, and keep them in T2 (the only register that code leaves alone)
                memfix(bload + [
                    'movapd %s, %s' % (T1, a), 'cmpltsd %s, %s' % (T1, T2), 'andpd %s, XMMWORD PTR [_%s_sw_c0]' % (T1, p),
                    'lea esp, [esp-16]', 'movsd QWORD PTR [esp], %s' % T1,
                    'movapd %s, %s' % (T1, a), 'cmpeqsd %s, %s' % (T1, T2), 'andpd %s, XMMWORD PTR [_%s_sw_c3]' % (T1, p),
                    'movsd QWORD PTR [esp+8], %s' % T1,
                    'movapd %s, %s' % (T1, a), 'cmpunordsd %s, %s' % (T2, T1), 'andpd %s, XMMWORD PTR [_%s_sw_all]' % (T2, p),
                    'movsd %s, QWORD PTR [esp]' % T1, 'orpd %s, %s' % (T2, T1),
                    'movsd %s, QWORD PTR [esp+8]' % T1, 'orpd %s, %s' % (T2, T1), 'lea esp, [esp+16]'])
                cs[0] = 'stash'

            def memfix(lines, i=i):
                """Appends lines; the single line holding the memory operand gets an address fixup if needed."""
                for l in lines:
                    o.append(l)
                    if i.relocs and i.mem and i.mem in l:
                        lab = self.label()
                        o.append(lab + ':')
                        self.absfix.append(lab + ' - 4')

            if i.kind == 'x87':
                name, arg = i.x87
                m = i.mem
                if i.relocs and len(i.relocs) != 1:
                    raise Fail('x87 instruction with %d relocations at %x' % (len(i.relocs), i.rva))
                if name == 'fnop':
                    continue
                if name == 'fld_m':
                    dst = 'xmm%d' % d
                    memfix(self.load(dst, 'm', arg, m))
                elif name == 'fild_m':
                    dst = 'xmm%d' % d
                    if arg == 32:
                        memfix(self.load(dst, 'mi', 32, m))
                    else:
                        memfix(['fild %s' % m] + spill_load(dst))
                        nfall += 1
                elif name == 'fld_r':
                    o.append('movapd xmm%d, %s' % (d, reg(d, arg)))
                elif name == 'fld1':
                    o.append('movsd xmm%d, QWORD PTR [_%s_one]' % (d, p))
                elif name == 'fldz':
                    o.append('xorpd xmm%d, xmm%d' % (d, d))
                elif name in ('fldpi', 'fldl2e', 'fldln2', 'fldlg2', 'fldl2t'):
                    o.append('movsd xmm%d, QWORD PTR [_%s_%s]' % (d, p, name[3:]))
                elif name in ('fst_m', 'fstp_m'):
                    if arg == 32:
                        # A popping float store right after the rounding: the store's own conversion
                        # to float rounds the same way, and the popped value is never read again.
                        x = reg(d, 0)
                        if (name == 'fstp_m' and not self.exact
                                and o[-2:] == ['cvtpd2ps %s, %s' % (x, x), 'cvtps2pd %s, %s' % (x, x)]):
                            del o[-2:]
                        memfix(['cvtpd2ps %s, %s' % (T1, x), 'movss %s, %s' % (m, T1)])
                    else:
                        memfix(['movsd %s, %s' % (m, reg(d, 0))])
                    if arg == 32:
                        t1_used()
                elif name in ('fist_m', 'fistp_m'):
                    if arg == 32:
                        memfix(['cvtpd2dq %s, %s' % (T1, reg(d, 0)), 'movd %s, %s' % (m, T1)])
                        t1_used()
                    else:
                        if name == 'fist_m':
                            _bad(i)
                        memfix(spill_push(reg(d, 0)) + ['fistp %s' % m])
                        nfall += 1
                elif name in ('fst_r', 'fstp_r'):
                    if arg:
                        o.append('movapd %s, %s' % (reg(d, arg), reg(d, 0)))
                elif name == 'fxch':
                    if arg:
                        o.extend(['movapd %s, %s' % (T1, reg(d, 0)), 'movapd %s, %s' % (reg(d, 0), reg(d, arg)),
                                  'movapd %s, %s' % (reg(d, arg), T1)])
                        t1_used()
                elif name == 'fchs':
                    o.append('xorpd %s, XMMWORD PTR [_%s_signmask]' % (reg(d, 0), p))
                elif name == 'fabs':
                    o.append('andpd %s, XMMWORD PTR [_%s_absmask]' % (reg(d, 0), p))
                elif name == 'fsqrt':
                    o.append('sqrtsd %s, %s' % (reg(d, 0), reg(d, 0)))
                    o.extend(self.rnd(reg(d, 0)))
                    t1_used()
                elif name in ('fsin', 'fcos', 'frndint'):
                    x = reg(d, 0)
                    o.extend(['lea esp, [esp-8]', 'movsd QWORD PTR [esp], %s' % x, 'fld QWORD PTR [esp]', name,
                              'fstp QWORD PTR [esp]', 'movsd %s, QWORD PTR [esp]' % x, 'lea esp, [esp+8]'])
                    nfall += 1
                elif name in ('fpatan', 'fyl2x'):
                    a, b = reg(d, 1), reg(d, 0)
                    o.extend(['lea esp, [esp-16]', 'movsd QWORD PTR [esp+8], %s' % a, 'movsd QWORD PTR [esp], %s' % b,
                              'fld QWORD PTR [esp+8]', 'fld QWORD PTR [esp]', name, 'fstp QWORD PTR [esp]',
                              'movsd %s, QWORD PTR [esp]' % a, 'lea esp, [esp+16]'])
                    nfall += 1
                elif name in ('fptan', 'fsincos'):
                    x, new = reg(d, 0), 'xmm%d' % d
                    o.extend(['lea esp, [esp-16]', 'movsd QWORD PTR [esp], %s' % x, 'fld QWORD PTR [esp]', name,
                              'fstp QWORD PTR [esp]', 'fstp QWORD PTR [esp+8]', 'movsd %s, QWORD PTR [esp]' % new,
                              'movsd %s, QWORD PTR [esp+8]' % x, 'lea esp, [esp+16]'])
                    nfall += 1
                elif name == 'ftst':
                    compare(reg(d, 0), ['xorpd %s, %s' % (T2, T2)])
                elif name == 'compp':
                    compare(reg(d, 0), ['movapd %s, %s' % (T2, reg(d, 1))])
                elif name in ('comi', 'comip'):
                    o.append('ucomisd %s, %s' % (reg(d, 0), reg(d, arg)))
                elif name == 'fnstsw_ax':
                    top = (8 - d) & 7
                    if cs[0] == 'stash':
                        o.append('movapd %s, %s' % (T1, T2))
                        if top:
                            o.append('orpd %s, XMMWORD PTR [_%s_sw_top+%d]' % (T1, p, 16 * top))
                        o.extend(['lea esp, [esp-4]', 'movd DWORD PTR [esp], %s' % T1, 'mov ah, BYTE PTR [esp]',
                                  'lea esp, [esp+4]'])
                    elif cs[0] == 'pair':
                        seq = ['ucomisd %s, %s' % (T1, T2), 'lahf', 'and ah, 0x45']
                        if top:
                            seq.append('or ah, 0x%02x' % (top << 3))
                        if self.flags_dead(ins, n + 1):
                            o.extend(seq)
                        else:
                            o.extend(['pushfd'] + seq + ['popfd'])
                    else:
                        raise Fail('status word read without a preceding compare at %x' % i.rva)
                else:
                    kind, op = name.split('_', 1)
                    if kind in ('m', 'mi'):
                        if kind == 'mi' and arg != 32:
                            _bad(i)
                        x = reg(d, 0)
                        if op in ('com', 'comp'):
                            compare(x, self.load(T2, kind, arg, m))
                        else:
                            memfix(self.load(T1, kind, arg, m))
                            if op.endswith('r'):
                                o.extend(self.arith(op[:-1], T1, x) + ['movapd %s, %s' % (x, T1)])
                            else:
                                o.extend(self.arith(op, x, T1))
                            o.extend(self.rnd(x))
                            t1_used()
                    elif kind == 'r0' and op in ('com', 'comp'):
                        compare(reg(d, 0), ['movapd %s, %s' % (T2, reg(d, arg))])
                    else:
                        # r0: st0 = st0 op sti      ri/rp: sti = sti op st0      ...r: operands swapped
                        if kind == 'r0':
                            dst, src = reg(d, 0), reg(d, arg)
                        else:
                            dst, src = reg(d, arg), reg(d, 0)
                        if op.endswith('r'):
                            o.extend(['movapd %s, %s' % (T1, src)] + self.arith(op[:-1], T1, dst)
                                     + ['movapd %s, %s' % (dst, T1)])
                        else:
                            o.extend(self.arith(op, dst, src))
                        o.extend(self.rnd(dst))
                        t1_used()
                continue

            # ---- integer / control flow instructions ----
            raw = '.byte ' + ','.join('0x%02x' % b for b in i.raw)
            if i.kind == 'ftol':
                # edx:eax = (int64)st0, truncated. Inline for the 32-bit range, the real helper otherwise.
                x = reg(d, 0)
                slow, done, lab = self.label(), self.label(), self.label()
                o.extend(['cvttsd2si eax, %s' % x, 'cmp eax, 0x80000000', 'je %s' % slow, 'cdq', 'jmp %s' % done,
                          slow + ':'])
                o.extend(spill_push(x))
                o.append('.byte 0xe8')
                o.append('%s: .long 0' % lab)
                self.relfix.append((lab, i.target))
                o.append(done + ':')
                cs[0] = None
                continue
            if i.kind == 'switch':
                jt = self.label()
                o.append('jmp DWORD PTR [%s*4+%s]' % (i.index, jt))
                self.jumptables.append((jt, ['L%s_%06x' % (p, t) for t in i.cases]))
                self.tabledeps.append((i.table, 4 * len(i.cases)))
            elif i.kind in ('jmp', 'jcc') and s <= i.target < e:
                o.append('%s L%s_%06x' % (i.mnem, p, i.target))
            elif i.kind in ('call', 'jmp'):
                lab = self.label()
                o.append('.byte 0x%02x' % i.raw[0])
                o.append('%s: .long 0' % lab)
                self.relfix.append((lab, i.target))
                if i.kind == 'call':
                    cs[0] = None
                    if n in fpret:
                        o.extend(spill_load('xmm0'))
            elif i.kind == 'ret':
                if d == 1:
                    o.extend(spill_push('xmm0'))
                o.append(raw)
            else:
                if i.relocs:
                    lab = self.label()
                    o.append(lab + ':')
                    for r in i.relocs:
                        self.absfix.append('%s + %d' % (lab, r))
                o.append(raw)
                if i.kind == 'icall':
                    cs[0] = None
                    if n in fpret:
                        o.extend(spill_load('xmm0'))
        o.append('%s:' % tramp)
        for i in head:
            if i.relocs:
                lab = self.label()
                o.append(lab + ':')
                for r in i.relocs:
                    self.absfix.append('%s + %d' % (lab, r))
            o.append('.byte ' + ','.join('0x%02x' % b for b in i.raw))
        lab = self.label()
        o.append('.byte 0xe9')
        o.append('%s: .long 0' % lab)
        self.relfix.append((lab, s + hlen))
        self.funcs.append((s, e - s, relocs, 1 if (uses_ftol or tables) else 0))
        self.stats.append((s, e - s, nx87, nfall, len(fpret)))
        self.info.append(self.describe(ins, depth, s))

    def describe(self, ins, depth, s):
        """Guesses the calling interface, for the blind differential test only."""
        retn = max([struct.unpack_from('<H', i.raw, 1)[0] for i in ins if i.kind == 'ret' and i.raw[0] == 0xc2] or [0])
        fpret = any(depth[n] == 1 for n, i in enumerate(ins) if i.kind == 'ret')
        framed = ins[0].raw == b'\x55' and ins[1].raw in (b'\x8b\xec', b'\x89\xe5')
        this = False
        for i in ins:
            if not re.search(r'\b(ecx|cx|cl|ch)\b', i.text):
                continue
            if re.match(r'(mov|lea|pop|movzx|movsx)\s+ecx,', i.text) and not re.search(r',.*\becx\b', i.text):
                break
            if i.text == 'xor    ecx,ecx' or i.text == 'push   ecx':
                if i.text.startswith('xor'):
                    break
                continue
            this = True
            break
        kinds = {}
        for i in ins:
            for m in re.finditer(r'(DWORD|QWORD) PTR \[ebp\+0x([0-9a-f]+)\]', i.text):
                k = (int(m.group(2), 16) - 8) // 4
                if k < 0 or k > 7:
                    continue
                if i.kind == 'x87' and not i.x87[0].startswith(('fst', 'fist')):
                    kinds.setdefault(k, 'f')
                    if m.group(1) == 'QWORD':
                        kinds.setdefault(k + 1, 'f')
                else:
                    kinds.setdefault(k, 'p')
        nargs = retn // 4 if retn else (max(kinds) + 1 if kinds else 0)
        return dict(rva=s, retn=retn, fpret=fpret, framed=framed, this=this, nargs=nargs,
                    kinds=''.join(kinds.get(k, 'p') for k in range(nargs)))

    @staticmethod
    def compare_use(ins, n, targets):
        """How the result of the compare at n is consumed: 'pair' if the next status word read follows with
        no FP code in between, 'stash' if FP code runs in between, None if it is not read in this block."""
        fp = False
        k = n + 1
        while k < len(ins):
            j = ins[k]
            if j.rva in targets:
                return None
            if j.kind == 'x87':
                name = j.x87[0]
                if name == 'fnstsw_ax':
                    return 'stash' if fp else 'pair'
                if name in ('ftst', 'compp', 'comi', 'comip') or name.endswith(('_com', '_comp')):
                    return None
                if name != 'fnop':
                    fp = True
            elif j.kind != 'raw':
                return None
            k += 1
        return None

    def emit_ftol(self, f):
        """Replacement for the compiler's float-to-integer helper itself (st0 -> edx:eax, truncated, st0 popped):
        two FPU instructions instead of nine for everything in the 32-bit range, the original otherwise.
        Makes no assumption about the FPU precision, so it serves every thread."""
        img, p, o = self.img, self.prefix, self.out
        ins = disassemble(img, f, f + 0x200)
        end = next(i.rva + len(i.raw) for i in ins if i.raw[0] in (0xc3, 0xc2))
        relocs = img.relocs_in(f, end)
        head, hlen = [], 0
        for i in ins:
            if hlen >= 5:
                break
            b = i.raw[0]
            if i.bad or b in (0xe8, 0xe9, 0xeb, 0xc3, 0xc2, 0xff) or 0x70 <= b <= 0x7f or 0xd8 <= b <= 0xdf:
                raise Fail('cannot relocate the first instructions of the helper at %x' % f)
            head.append(i)
            hlen += len(i.raw)
        fn, slow = '_%s_%06x' % (p, f), self.label()
        o.extend(['.p2align 4', '.globl %s' % fn, fn + ':',
                  'lea esp, [esp-8]', 'fst QWORD PTR [esp]', 'movsd %s, QWORD PTR [esp]' % T2, 'lea esp, [esp+8]',
                  'cvttsd2si eax, %s' % T2, 'cmp eax, 0x80000000', 'je %s' % slow, 'fstp st(0)', 'cdq', 'ret',
                  slow + ':'])
        for i in head:
            rel = [r - i.rva for r in relocs if i.rva <= r < i.rva + len(i.raw)]
            if rel:
                lab = self.label()
                o.append(lab + ':')
                self.absfix.extend('%s + %d' % (lab, r) for r in rel)
            o.append('.byte ' + ','.join('0x%02x' % b for b in i.raw))
        lab = self.label()
        o.extend(['.byte 0xe9', '%s: .long 0' % lab])
        self.relfix.append((lab, f + hlen))
        self.funcs.append((f, end - f, relocs, 0))

    def flags_dead(self, ins, n):
        while n < len(ins):
            i = ins[n]
            if i.kind == 'x87':
                if i.x87[0] in ('comi', 'comip'):
                    return True
                n += 1
                continue
            if i.mnem in FLAG_DEF:
                return True
            if i.mnem in FLAG_NEUTRAL:
                n += 1
                continue
            return False
        return False

    # ---- output ----------------------------------------------------------------------------
    def write(self, path):
        p = self.prefix
        img = self.img
        L = ['.intel_syntax noprefix', '.text', '.p2align 4', '.globl _%s_code_begin' % p, '_%s_code_begin:' % p]
        L += self.out
        L += ['.p2align 4', '.globl _%s_code_end' % p, '_%s_code_end:' % p]
        L += ['.section .rdata,"dr"', '.p2align 4',
              '_%s_signexp: .quad 0xfff0000000000000, 0xfff0000000000000' % p,
              '_%s_signmask: .quad 0x8000000000000000, 0' % p,
              '_%s_absmask: .quad 0x7fffffffffffffff, 0xffffffffffffffff' % p,
              '_%s_big: .quad 0x7830000000000000, 0x7830000000000000' % p,      # 2^900
              '_%s_nbig: .quad 0xf830000000000000, 0xf830000000000000' % p,     # -2^900
              '_%s_k: .quad 0x41c8000000000000, 0x41c8000000000000' % p,        # 1.5 * 2^29
              '_%s_one: .quad 0x3ff0000000000000' % p,
              '_%s_pi: .quad 0x400921fb54442d18' % p,
              '_%s_l2e: .quad 0x3ff71547652b82fe' % p,
              '_%s_ln2: .quad 0x3fe62e42fefa39ef' % p,
              '_%s_lg2: .quad 0x3fd34413509f79ff' % p,
              '_%s_l2t: .quad 0x400a934f0979a371' % p]
        L += ['.p2align 4',
              '_%s_sw_c0: .quad 0x01, 0' % p, '_%s_sw_c3: .quad 0x40, 0' % p, '_%s_sw_all: .quad 0x45, 0' % p,
              '_%s_sw_top: .quad 0x00, 0, 0x08, 0, 0x10, 0, 0x18, 0, 0x20, 0, 0x28, 0, 0x30, 0, 0x38, 0' % p]
        L += ['.p2align 2']
        for lab, cases in self.jumptables:
            L.append('%s: .long %s' % (lab, ', '.join(cases)))
        L += ['.p2align 2', '.globl _%s_absfix' % p, '_%s_absfix:' % p]
        L += ['.long %s' % a for a in self.absfix] + ['.long 0']
        L += ['.globl _%s_relfix' % p, '_%s_relfix:' % p]
        L += ['.long %s, 0x%x' % (a, t) for a, t in self.relfix] + ['.long 0, 0']
        deps = []
        for f in sorted(self.ftol):
            end = f
            for i in disassemble(img, f, f + 0x400):
                end = i.rva + len(i.raw)
                if i.raw[0] in (0xc3, 0xc2):
                    break
            deps.append((f, end - f, img.relocs_in(f, end), 0))
        for t, size in sorted(set(self.tabledeps)):
            deps.append((t, size, img.relocs_in(t, t + size), 0))
        done = set()
        for s, size, relocs, flags in self.funcs + deps:
            if s in done:
                continue
            done.add(s)
            L.append('L%s_orig_%06x: .byte %s' % (p, s, ','.join('0x%02x' % b for b in img.bytes(s, s + size))))
            L.append('.p2align 2')
            L.append('L%s_rel_%06x: .long %s' % (p, s, ','.join(['%d' % (r - s) for r in relocs] + ['0xffffffff'])))
        # functions: rva, size, replacement, original bytes, relocation offsets, flags (1 = needs every dependency intact)
        L += ['.p2align 2', '.globl _%s_funcs' % p, '_%s_funcs:' % p]
        for s, size, relocs, flags in self.funcs:
            L.append('.long 0x%x, %d, _%s_%06x, L%s_orig_%06x, L%s_rel_%06x, %d' % (s, size, p, s, p, s, p, s, flags))
        L += ['.long 0, 0, 0, 0, 0, 0']
        # code the translations rely on without replacing it (inlined helper semantics)
        L += ['.globl _%s_deps' % p, '_%s_deps:' % p]
        for s, size, relocs, flags in deps:
            L.append('.long 0x%x, %d, 0, L%s_orig_%06x, L%s_rel_%06x, 0' % (s, size, p, s, p, s))
        L += ['.long 0, 0, 0, 0, 0, 0',
              '.globl _%s_imagebase' % p, '_%s_imagebase: .long 0x%x' % (p, img.base),
              '.data', '.p2align 2', '.globl _%s_tid' % p, '_%s_tid: .long 0' % p,
              '.text', '.att_syntax prefix']
        with open(path, 'w') as f:
            f.write('// Generated by xlat.py - x87 routines translated to SSE2. Do not edit.\n__asm__(\n')
            for l in L:
                f.write('  "%s\\n"\n' % l.replace('\\', '\\\\').replace('"', '\\"'))
            f.write(');\n')


def code_hash(img, s, size):
    """FNV-1a over the bytes of [s, s + size), relocated address fields left out. Identifies a routine
    without carrying its code."""
    data = img.bytes(s, s + size)
    skip = {r - s for r in img.relocs_in(s, s + size)}
    h = 0xcbf29ce484222325
    i = 0
    while i < size:
        if i in skip:
            i += 4
            continue
        h = ((h ^ data[i]) * 0x100000001b3) & 0xffffffffffffffff
        i += 1
    return h


class Underflow(Exception):
    def __init__(self, n):
        self.n = n


def main():
    """xlat.py <pe|flat> <image> <prefix> <out.inc> [--map file] [--ftol rva,...] [--min samples] [--max count]
               [--skip rva,...] [--write-list file] [--exact-range] <start-limit | @list> ...

    A list holds one routine per line: "start limit weight [size hash]" (hex, weight decimal). With size
    and hash present, a routine is translated only if the image holds exactly the code the list was made
    from. A line "ftol rva size hash" names the compiler's float-to-integer helper."""
    mode, path, prefix, out = sys.argv[1:5]
    img = Image(path, mode)
    t = Translator(img, prefix)
    jobs, minsamples, maxcount, skip, writelist = [], 0, 1 << 30, set(), None
    args = sys.argv[5:]
    while args:
        a = args.pop(0)
        if a == '--map':
            m = pickle.load(open(args.pop(0), 'rb'))
            img.branches = sorted((tgt, src) for src, tgt in m['branches'])
        elif a == '--ftol':
            t.ftol = {int(x, 16) for x in args.pop(0).split(',')}
        elif a == '--min':
            minsamples = int(args.pop(0))
        elif a == '--max':
            maxcount = int(args.pop(0))
        elif a == '--skip':
            skip = {int(x, 16) for x in args.pop(0).split(',')}
        elif a == '--write-list':
            writelist = args.pop(0)
        elif a == '--exact-range':
            t.exact = True
        elif a.startswith('@'):
            for l in open(a[1:]):
                f = l.split('#')[0].split()
                if len(f) >= 4 and f[0] == 'ftol':
                    rva, size, want = int(f[1], 16), int(f[2], 16), int(f[3], 16)
                    if code_hash(img, rva, size) != want:
                        raise SystemExit('the float-to-integer helper at %x is not the one this list was made for: '
                                         'wrong client.dll?' % rva)
                    t.ftol.add(rva)
                elif len(f) >= 3 and int(f[2]) >= minsamples:
                    check = (int(f[3], 16), int(f[4], 16)) if len(f) >= 5 else None
                    jobs.append((int(f[0], 16), int(f[1], 16), int(f[2]), check))
        else:
            s, e = [int(x, 16) for x in a.split('-')]
            jobs.append((s, e, 0, None))
    ok = 0
    okw = totw = 0
    reasons = {}
    seen = set()
    done = []
    for s, e, weight, check in jobs:
        if s in seen or s in skip:
            continue
        seen.add(s)
        totw += weight
        if ok >= maxcount:
            continue
        mark = (len(t.out), len(t.absfix), len(t.relfix), len(t.jumptables), len(t.tabledeps),
                len(t.funcs), len(t.stats), len(t.info))
        try:
            t.translate(s, e)
            size = t.funcs[-1][1]
            if check and (size, code_hash(img, s, size)) != check:
                raise Fail('differs from the code the list was made from')
            ok += 1
            okw += weight
            done.append((s, e, weight, size))
            st = t.stats[-1]
            print('ok   %06x size %4d  x87 %3d  x87-fallbacks %d  fp-returning calls %d  weight %d' % (st + (weight,)))
        except Fail as f:
            del t.out[mark[0]:], t.absfix[mark[1]:], t.relfix[mark[2]:], t.jumptables[mark[3]:], t.tabledeps[mark[4]:]
            del t.funcs[mark[5]:], t.stats[mark[6]:], t.info[mark[7]:]
            print('SKIP %06x-%06x weight %d: %s' % (s, e, weight, f))
            key = re.sub(r'\b[0-9a-f]{4,8}\b', 'X', str(f))[:70]
            reasons.setdefault(key, [0, 0])
            reasons[key][0] += 1
            reasons[key][1] += weight
    if writelist:
        with open(writelist, 'w') as f:
            f.write('# Routines of client.dll to translate: start limit weight size hash (hex; weight = profile samples).\n')
            f.write('# The hash is FNV-1a over the routine with address fields left out; it carries no game code.\n')
            for rva in sorted(t.ftol):
                end = rva
                for i in disassemble(img, rva, rva + 0x400):
                    end = i.rva + len(i.raw)
                    if i.raw[0] in (0xc3, 0xc2):
                        break
                f.write('ftol %x %x %016x\n' % (rva, end - rva, code_hash(img, rva, end - rva)))
            for s, e, weight, size in done:
                f.write('%x %x %d %x %016x\n' % (s, e, weight, size, code_hash(img, s, size)))
    for f in sorted(t.ftol):
        if f not in {fn[0] for fn in t.funcs}:
            t.emit_ftol(f)
            print('ok   %06x float-to-integer helper replaced' % f)
    t.write(out)
    with open(out + '.tests', 'w') as f:
        for d in t.info:
            f.write('  { 0x%x, %d, "%s", %s, %s, %s },\n' % (d['rva'], d['nargs'], d['kinds'], 'true' if d['this'] else 'false',
                    'true' if d['fpret'] else 'false', 'true' if d['framed'] else 'false'))
    print('%d of %d functions translated; sample weight covered %d of %d' % (ok, len(seen), okw, totw))
    for k, v in sorted(reasons.items(), key=lambda kv: -kv[1][1])[:25]:
        print('  skipped %4d functions, weight %6d: %s' % (v[0], v[1], k))


if __name__ == '__main__':
    main()
