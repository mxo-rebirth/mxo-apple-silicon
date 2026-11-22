#!/usr/bin/env python3
"""xlat.py <pe|flat> <image> <prefix> <out.inc> [options] <start-limit | @list> ...

Translates x87 routines of a 32-bit x86 image into SSE2 assembly text. Writes <out.inc> and, for the
tests, the table <out.inc>.tests.

  pe    the image is a PE file, addresses are RVAs
  flat  the image is a flat binary linked at 0x62000000, addresses are offsets

  <start-limit>      one routine, in hex: where it starts and the furthest it may reach
  @list              a routine list. LIST_HEAD in this file describes the format
  --map file         the map made by discover.py, to refuse routines that other code jumps into
  --ftol rva,...     the compiler's float-to-integer helper (a list names it with an ftol line)
  --min samples      leave out list entries with a smaller weight
  --max count        translate at most this many routines
  --skip rva,...     leave these routines out
  --write-list file  write the list of the routines that were translated, with sizes and hashes
  --exact-range      rounding that also matches the x87 outside the float range (slower)
"""
import bisect
import os
import pickle
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import mingw
from peimage import Fail, Image

T1, T2 = 'xmm6', 'xmm7'
MAXDEPTH = 6
MAX_SWITCH_CASES = 1024     # a jump table without a bound in the code is read at most this far
MAX_DATA_PASSES = 8         # how often a routine is disassembled again after a table was found inside it
FLOW_BUDGET = 48            # instructions a "is this value still read" search follows before it gives up
HELPER_SCAN_BYTES = 0x400   # the float-to-integer helper's first return lies within this many bytes
ABOVE_ANY_RVA = 1 << 40     # paired with an address, it sorts after every real (address, address) pair
MAX_REASONS_SHOWN = 25      # kinds of refusal the log sums up at its end

# The format of a routine list (translator/routines.list). --write-list puts these lines at the head of
# the list it writes, so this is the one description of the format.
LIST_HEAD = '''# Routines of client.dll to translate, one per line:   start limit weight size hash
# start and limit are RVAs in hex: where the routine begins and the furthest it may reach, which is
# the start of the next routine. weight is its number of profile samples, in decimal. size and hash,
# in hex, are the length of its code and FNV-1a over that code with the address fields left out.
# With them a routine is translated only if the image holds exactly the code the list was made from.
# A line without size and hash is translated unchecked, and --write-list fills them in.
# The line "ftol rva size hash" names the compiler's float-to-integer helper, checked the same way.
# The list carries no game code.
'''


class Ins:
    """One instruction: what objdump printed, and what the translator works out about it."""

    def __init__(self, va, rva, raw, text):
        self.va = va
        self.rva = rva
        self.raw = raw
        self.bad = not text or '(bad)' in text
        self.text = '(bad)' if self.bad else text
        parts = self.text.split(None, 1)
        self.mnem = parts[0]
        self.ops = parts[1] if len(parts) > 1 else ''
        self.kind = 'raw'       # raw, x87, call, icall, ftol, jmp, jcc, ijmp, switch, ret or err
        self.target = None      # rva a direct call or jump goes to
        self.x87 = None         # (name, argument) of an x87 instruction
        self.mem = None         # its memory operand as text
        self.err = None         # the Fail that stops the translation if this instruction can be reached
        self.relocs = []        # offsets of relocated address fields inside the instruction
        self.table = None       # a switch: rva of its jump table,
        self.index = None       # the register that picks the case
        self.cases = []         # and the rvas the table holds


RETURN_OPCODES = (0xc3, 0xc2)       # ret, ret n


def disassemble(img, s, e):
    """The instructions of [s, e), which have to cover the range exactly."""
    res = []
    for line in mingw.disassembly(img.bytes(s, e), img.base + s, zero_runs=True):
        found = mingw.instruction(line)
        if found:
            va, raw, text = found
            res.append(Ins(va, va - img.base, raw, text))
    if sum(len(i.raw) for i in res) != e - s:
        raise Fail('disassembly does not cover the function')
    return res


JCC = {'jo', 'jno', 'jb', 'jae', 'je', 'jne', 'jbe', 'ja', 'js', 'jns', 'jp', 'jnp', 'jl', 'jge', 'jle', 'jg',
       'jc', 'jnc', 'jz', 'jnz', 'jna', 'jnbe', 'jnae', 'jnb', 'jpe', 'jpo', 'jnge', 'jnl', 'jng', 'jnle'}
FLAG_DEF = {'add', 'sub', 'cmp', 'test', 'and', 'or', 'xor', 'neg', 'sahf', 'popf', 'popfd', 'imul', 'mul',
            'call', 'ret'}
FLAG_NEUTRAL = {'mov', 'lea', 'push', 'pop', 'movzx', 'movsx', 'xchg', 'nop', 'not', 'cdq', 'cwde', 'cbw',
                'bswap', 'fwait'}
# classify() tells jumps, calls and returns by their first byte. One that it took for an ordinary
# instruction has a prefix in front (a branch hint, "rep ret", a 16-bit form).
PREFIXED_TRANSFER = re.compile(r'(?:^|\s)(?:j[a-z,]+|l?call[a-z]*|[li]?ret[a-z]*|ljmp[a-z]*|loop[a-z]*)(?:\s|$)')


def classify(i, base):
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
    elif op in RETURN_OPCODES:
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
    # copied byte for byte, its displacement would point somewhere else, and a return would not end the routine
    if i.kind == 'raw' and PREFIXED_TRANSFER.search(i.text):
        raise Fail('jump, call or return with a prefix at %x: %s' % (i.rva, i.text))
    if re.search(r'\b(xmm|mm)\d', i.text):
        raise Fail('function already uses SSE/MMX at %x' % i.rva)


def x87_decode(i):
    """Returns (name, arg) for an x87 instruction. arg is the st index or the size of the memory operand."""
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
            return {0: ('fld_m', 32), 2: ('fst_m', 32), 3: ('fstp_m', 32)}.get(reg) or refuse(i)
        if op == 0xdd:
            return {0: ('fld_m', 64), 2: ('fst_m', 64), 3: ('fstp_m', 64)}.get(reg) or refuse(i)
        if op == 0xdb:
            return {0: ('fild_m', 32), 2: ('fist_m', 32), 3: ('fistp_m', 32)}.get(reg) or refuse(i)
        # 0xdf, the last of the eight x87 opcodes
        return {0: ('fild_m', 16), 2: ('fist_m', 16), 3: ('fistp_m', 16), 5: ('fild_m', 64),
                7: ('fistp_m', 64)}.get(reg) or refuse(i)
    if op == 0xd8:
        return ('r0_' + arith[reg], rm)                    # st0 = st0 op sti
    if op == 0xdc:
        name = ['add', 'mul', None, None, 'subr', 'sub', 'divr', 'div'][reg]
        if not name:
            refuse(i)
        return ('ri_' + name, rm)                          # sti = sti op st0 (r: st0 op sti)
    if op == 0xde:
        if modrm == 0xd9:
            return ('compp', 1)
        name = ['add', 'mul', None, None, 'subr', 'sub', 'divr', 'div'][reg]
        if not name:
            refuse(i)
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
        refuse(i)
    if op == 0xdd:
        if reg == 2:
            return ('fst_r', rm)
        if reg == 3:
            return ('fstp_r', rm)
        if reg == 4:
            return ('r0_com', rm)
        if reg == 5:
            return ('r0_comp', rm)
        refuse(i)
    if op == 0xda:
        if modrm == 0xe9:
            return ('compp', 1)
        refuse(i)
    if op == 0xdf:
        if modrm == 0xe0:
            return ('fnstsw_ax', 0)
        if reg == 5 or reg == 6:
            return ('comip', rm)
        refuse(i)
    # 0xdb, the last of the eight x87 opcodes
    if reg == 5 or reg == 6:
        return ('comi', rm)
    refuse(i)


def refuse(i):
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
    if name == 'comi':
        return (arg + 1, 0)
    if name == 'comip':
        return (arg + 1, -1)
    form, op = name.split('_', 1)       # every other name is "<operand form>_<operation>"
    if form in ('m', 'mi'):
        return (1, -1 if op == 'comp' else 0)
    if form == 'r0':
        return (arg + 1, -1 if op == 'comp' else 0)
    if form == 'ri':
        return (arg + 1, 0)
    if form == 'rp':
        return (arg + 1, -1)
    raise Fail('no stack effect for ' + name)


class Translator:
    """Static x87 to SSE2 translation of whole routines.

    Each x87 register is kept in an xmm register as a double. The game runs its FPU in 24-bit precision
    mode (Direct3D 9 default), so every add/sub/mul/div/sqrt result is rounded to a 24-bit significand
    with round-to-nearest-even while keeping the wide exponent range, as the x87 does. Translated code
    changes EFLAGS only where nothing reads them afterwards: at a status word read (flow analysis checks
    it, or the flags are saved and restored), at a call to the float-to-integer helper and on entry."""

    def __init__(self, img, prefix):
        self.img = img
        self.prefix = prefix
        self.branches = []   # sorted (target rva, source rva) of the image's direct branches, from discover.py's map
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
        self.edgeconv = 0     # float-to-double conversions placed at branches and branch targets (fast mode)
        self.fused = 0        # status word reads turned into direct branches on the compare
        self.xrcalls = 0      # calls emitted to the xmm0-returning entry of another routine
        # (import slot rva, routine rva, INLINE_IMPORTS number): one row for every call computed in place, in
        # every copy of the routine that is emitted
        self.inlined = []
        self.xr_targets = set()   # routines translated callers call directly, result in xmm0 (see translate's xr)
        self.xrdeps = set()   # (caller rva, callee rva) of such calls
        self.fpcalls = set()  # targets of direct calls whose floating-point result is used
        self.fpret_all = {}   # routine rva -> every return leaves exactly one value on the FPU stack

    def label(self):
        """A new local label. The n keeps these apart from the labels of branch targets, which are hex addresses."""
        self.uid += 1
        return 'L%s_n%d' % (self.prefix, self.uid)

    def grown_lists(self):
        return (self.out, self.absfix, self.relfix, self.funcs, self.stats, self.jumptables, self.tabledeps,
                self.info, self.inlined)

    def checkpoint(self):
        """Everything translate() adds to. With restore() a routine that fails part-way leaves nothing behind."""
        return ([len(grown) for grown in self.grown_lists()], set(self.xrdeps), set(self.fpcalls),
                dict(self.fpret_all), (self.edgeconv, self.fused, self.xrcalls))

    def restore(self, checkpoint):
        lengths, self.xrdeps, self.fpcalls, self.fpret_all, counters = checkpoint
        for grown, length in zip(self.grown_lists(), lengths):
            del grown[length:]
        self.edgeconv, self.fused, self.xrcalls = counters

    def interior_refs(self, s, e, tables=()):
        """References to addresses strictly inside (s, e): any pointer (except from the function's own
        switch tables), and direct branches from outside."""
        pointers = self.img.pointers
        hits = []
        a = bisect.bisect_right(pointers, (s, ABOVE_ANY_RVA))
        while a < len(pointers) and pointers[a][0] < e:
            loc = pointers[a][1]
            if not any(t <= loc < t + size for t, size in tables):
                hits.append('pointer at %x -> %x' % (loc, pointers[a][0]))
            a += 1
        a = bisect.bisect_right(self.branches, (s, ABOVE_ANY_RVA))
        while a < len(self.branches) and self.branches[a][0] < e:
            if not (s <= self.branches[a][1] < e):
                hits.append('branch at %x -> %x' % (self.branches[a][1], self.branches[a][0]))
            a += 1
        return hits

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
    def round_to_24_bits(self, x):
        """Rounds the double in x to a 24-bit significand, nearest-even, keeping the x87 exponent range
        (--exact-range): add and subtract 1.5 * 2^(exponent + 29) with the sign of x. Needs only T1 and
        leaves the flags alone.

        Fast mode converts to float instead (see rounded() in translate): the same result whenever the value
        lies in the float range. Beyond it the x87 keeps a finite value or a normal tiny one, where the float
        gives infinity or a denormal."""
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
    def load(dst, form, size, m):
        """Instructions that put a memory operand (form 'm' a float or double, 'mi' an integer) into dst as a
        double with a zero upper half."""
        if form == 'm' and size == 32:
            return ['movss %s, %s' % (dst, m), 'cvtps2pd %s, %s' % (dst, dst)]
        if form == 'm' and size == 64:
            return ['movsd %s, %s' % (dst, m)]
        if form == 'mi' and size == 32:
            return ['xorpd %s, %s' % (dst, dst), 'cvtsi2sd %s, %s' % (dst, m)]
        raise Fail('unsupported memory operand')

    @staticmethod
    def arith(op, dst, src):
        """dst = dst op src. Add, subtract and multiply use the full-width forms, which the
        translator under Rosetta handles without a merge step. Divide stays scalar."""
        return ['%s %s, %s' % ({'add': 'addpd', 'sub': 'subpd', 'mul': 'mulpd', 'div': 'divsd'}[op], dst, src)]

    def translate(self, s, e, xr=False):
        """Translates the function at s. e is the furthest it may extend (start of the next function). With xr, the
        variant that translated callers call directly: no entry check, and a floating-point result returned in xmm0
        (as a double) instead of on the FPU stack."""
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
                        classify(i, img.base)
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
                while len(cases) < (bound or MAX_SWITCH_CASES):
                    loc = i.table + 4 * len(cases)
                    if loc not in img.relocs:
                        break
                    t = img.dword(loc) - img.base
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
                    bt = img.dword(r0) - img.base
                    if m and s <= bt < e:
                        found.append((bt, int(m.group(1), 16) + 1))
            return ins, tables, found

        # switch tables stored inside the function are data: once found, disassemble around them
        data = []
        for _pass in range(MAX_DATA_PASSES):
            ins, tables, found = prepare(data)
            inner = [t for t in found if s <= t[0] < e and t not in data]
            if not inner:
                break
            data = sorted(set(data + inner))
        else:
            raise Fail('tables inside the function still turn up after %d passes' % MAX_DATA_PASSES)

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
                    raise Fail('FPU stack underflow at %x (function takes arguments on the FPU stack?)' % ins[u.n].rva) from u
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
        refs = self.interior_refs(s, e, tables)
        if refs:
            raise Fail('interior referenced: ' + ' and '.join(refs[:2]))
        uses_ftol = any(i.kind == 'ftol' and depth[n] is not None for n, i in enumerate(ins))

        targets = {i.target for n, i in enumerate(ins)
                   if depth[n] is not None and i.kind in ('jmp', 'jcc') and s <= i.target < e}
        for n, i in enumerate(ins):
            if depth[n] is not None and i.kind == 'switch':
                targets.update(i.cases)
        p = self.prefix
        lp = p + ('R' if xr else '')            # local labels: the xr variant is a second copy of the body
        fn = '_%s_%06x%s' % (p, s, '_xr' if xr else '')
        out = self.out
        # instructions the 5-byte entry patch overwrites. Other threads run them here and continue in the original
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
        tramp = 'L%s_tramp_%06x' % (lp, s)
        out.append('.p2align 4')
        out.append('.globl %s' % fn)
        out.append('%s:' % fn)
        # the translation assumes the FPU precision of the thread that owns the Direct3D device (the xr variant is
        # only called from translated code, which has already checked)
        if not xr:
            out.extend(['push eax', 'mov eax, DWORD PTR fs:[0x24]', 'cmp eax, DWORD PTR [_%s_tid]' % p, 'pop eax',
                      'jne %s' % tramp])
        live = [(n, i) for n, i in enumerate(ins) if depth[n] is not None]
        self.fpret_all[s] = (any(i.kind == 'ret' for n, i in live)
                             and all(depth[n] == 1 for n, i in live if i.kind == 'ret')
                             and not any(i.kind == 'ijmp' or (i.kind == 'jmp' and not (s <= i.target < e)) for n, i in live))
        # how a compare that is not yet read is held: 'pair' = operands in T1/T2 as doubles, 'pairf' = as floats,
        # 'stash' = status image in T2
        pending = None
        nfall = 0

        def t1_used():
            nonlocal pending
            if pending in ('pair', 'pairf'):
                pending = None

        def reg(d, k):
            return 'xmm%d' % (d - 1 - k)

        def spill_load(dst):        # value on the real FPU stack -> xmm
            return ['lea esp, [esp-8]', 'fstp QWORD PTR [esp]', 'movsd %s, QWORD PTR [esp]' % dst, 'lea esp, [esp+8]']

        def spill_push(src):        # xmm -> real FPU stack, esp restored afterwards
            return ['lea esp, [esp-8]', 'movsd QWORD PTR [esp], %s' % src, 'fld QWORD PTR [esp]', 'lea esp, [esp+8]']

        # Fast mode keeps every result of a rounded operation as a float, and float loads stay floats, so
        # operations between two floats are single SSE instructions: with the 24-bit precision Direct3D
        # sets, rounding the double result to float equals the float result, and fast mode already confines
        # values to the float range. held[j] says how xmm j holds its stack value: 'f' = float in the low
        # lane, 'd' = double in the low lane. Values from integers, doubles and constants other than 0 and
        # 1 stay doubles. At every branch and branch target all values are doubles.
        fast = not self.exact
        held = ['d'] * 8
        falls = True            # the previous reachable instruction can fall through to the next one

        def to_d(j):
            if held[j] == 'f':
                out.append('cvtps2pd xmm%d, xmm%d' % (j, j))
                held[j] = 'd'

        def all_d(d):
            for j in range(d):
                if held[j] == 'f':
                    self.edgeconv += 1
                to_d(j)

        def movd(j):                # instruction that copies xmm j into another register as a double
            return 'cvtps2pd' if held[j] == 'f' else 'movapd'

        idx_of = {i.rva: k for k, i in enumerate(ins)}
        fused_skip = set()          # tests folded into a preceding status word read
        fused_jump = {}             # their jcc: index -> (outcomes taken, target)

        def fuse(n):
            """At a status word read right after a compare: a direct branch on the compare when the code only tests
            ah and jumps. Returns True if emitted."""
            if os.environ.get('XLAT_NO_FUSE'):
                return False
            f = self.fused_status_branch(ins, n, targets, idx_of, s, e)
            if f is None:
                return False
            taken, target, k = f
            out.append('%s %s, %s' % ('ucomiss' if pending == 'pairf' else 'ucomisd', T1, T2))
            fused_skip.add(k)                       # the test
            fused_jump[k + 1] = (taken, target)     # the jcc: emitted there, after any FPU register moves
            self.fused += 1
            return True

        for n, i in enumerate(ins):
            d = depth[n]
            if n in fused_skip:
                continue
            if n in fused_jump:
                taken, target = fused_jump.pop(n)
                if fast:
                    all_d(d)        # branch edges carry doubles, and the conversions leave the flags alone
                skip = self.label()
                for template in self.FUSED_JUMPS[taken]:
                    out.append(template.format(T='L%s_%06x' % (lp, target), S=skip))
                continue
            if i.rva in targets:
                if fast:
                    if d is not None and falls:
                        all_d(d)
                    held[:] = ['d'] * 8
                out.append('L%s_%06x:' % (lp, i.rva))
                pending = None
            if d is None:
                continue        # never executed (padding, data)
            falls = i.kind not in ('jmp', 'ret', 'ijmp', 'switch')

            def compare(a, bload, af=False, bfload=None, i=i, n=n):
                """st0 (in a, a float if af) against the value that bload puts into T2 as a double. If that value
                is a float too, bfload puts it into T2 as it is."""
                nonlocal pending
                mova = 'cvtps2pd' if af else 'movapd'
                if self.compare_use(ins, n, targets) != 'stash':
                    if af and bfload is not None and not os.environ.get('XLAT_NO_COMISS'):
                        # two floats are compared as floats: widening both to double first changes neither their
                        # order nor whether one is a NaN
                        memfix(['movaps %s, %s' % (T1, a)] + bfload)
                        pending = 'pairf'
                    else:
                        memfix(['%s %s, %s' % (mova, T1, a)] + bload)
                        pending = 'pair'
                    return
                # FP code runs between this compare and the status word read: work the condition bits out now,
                # without touching flags or eax, and keep them in T2 (the only register that code leaves alone)
                memfix(bload + [
                    '%s %s, %s' % (mova, T1, a), 'cmpltsd %s, %s' % (T1, T2), 'andpd %s, XMMWORD PTR [_%s_sw_c0]' % (T1, p),
                    'lea esp, [esp-16]', 'movsd QWORD PTR [esp], %s' % T1,
                    '%s %s, %s' % (mova, T1, a), 'cmpeqsd %s, %s' % (T1, T2), 'andpd %s, XMMWORD PTR [_%s_sw_c3]' % (T1, p),
                    'movsd QWORD PTR [esp+8], %s' % T1,
                    '%s %s, %s' % (mova, T1, a), 'cmpunordsd %s, %s' % (T2, T1), 'andpd %s, XMMWORD PTR [_%s_sw_all]' % (T2, p),
                    'movsd %s, QWORD PTR [esp]' % T1, 'orpd %s, %s' % (T2, T1),
                    'movsd %s, QWORD PTR [esp+8]' % T1, 'orpd %s, %s' % (T2, T1), 'lea esp, [esp+16]'])
                pending = 'stash'

            def memfix(lines, i=i):
                """Appends lines. The single line holding the memory operand gets an address fixup if needed."""
                for emitted in lines:
                    out.append(emitted)
                    if i.relocs and i.mem and i.mem in emitted:
                        lab = self.label()
                        out.append(lab + ':')
                        self.absfix.append(lab + ' - 4')

            if i.kind == 'x87':
                # One path for both modes. Fast mode tracks per register whether it holds a float ('f') or a double
                # ('d'). With --exact-range every value stays a double: held[] is all 'd', to_d() emits nothing and
                # the float cases below never apply. Apart from that the modes differ in how a result is rounded
                # to 24 bits (rounded()) and in a few instruction forms.
                name, arg = i.x87
                m = i.mem
                if i.relocs and len(i.relocs) != 1:
                    raise Fail('x87 instruction with %d relocations at %x' % (len(i.relocs), i.rva))
                top = d - 1                     # xmm index of st0
                x = reg(d, 0)
                mov = 'movaps' if fast else 'movapd'
                fop = {'add': 'addps', 'sub': 'subps', 'mul': 'mulps', 'div': 'divss'}

                def rounded(j):
                    """xmm j holds the double result of an operation that the x87 rounds to 24 bits."""
                    r = 'xmm%d' % j
                    if fast:
                        out.append('cvtpd2ps %s, %s' % (r, r))
                        held[j] = 'f'
                    else:
                        out.extend(self.round_to_24_bits(r))

                if name == 'fnop':
                    continue
                if name == 'fld_m':
                    dst = 'xmm%d' % d
                    if arg == 32 and fast:
                        memfix(['movss %s, %s' % (dst, m)])
                        held[d] = 'f'
                    else:
                        memfix(self.load(dst, 'm', arg, m))
                        held[d] = 'd'
                elif name == 'fild_m':
                    dst = 'xmm%d' % d
                    if arg == 32:
                        memfix(self.load(dst, 'mi', 32, m))
                    else:
                        memfix(['fild %s' % m] + spill_load(dst))
                        nfall += 1
                    held[d] = 'd'
                elif name == 'fld_r':
                    out.append('%s xmm%d, %s' % (mov, d, reg(d, arg)))
                    held[d] = held[top - arg]
                elif name == 'fld1':
                    if fast:
                        out.append('movss xmm%d, DWORD PTR [_%s_onef]' % (d, p))
                        held[d] = 'f'
                    else:
                        out.append('movsd xmm%d, QWORD PTR [_%s_one]' % (d, p))
                        held[d] = 'd'
                elif name == 'fldz':
                    out.append('%s xmm%d, xmm%d' % ('xorps' if fast else 'xorpd', d, d))
                    held[d] = 'f' if fast else 'd'
                elif name in ('fldpi', 'fldl2e', 'fldln2', 'fldlg2', 'fldl2t'):
                    out.append('movsd xmm%d, QWORD PTR [_%s_%s]' % (d, p, name[3:]))
                    held[d] = 'd'
                elif name in ('fst_m', 'fstp_m'):
                    if arg == 32:
                        if held[top] == 'f':
                            memfix(['movss %s, %s' % (m, x)])
                        else:
                            memfix(['cvtpd2ps %s, %s' % (T1, x), 'movss %s, %s' % (m, T1)])
                            t1_used()
                    elif held[top] == 'f':
                        memfix(['cvtps2pd %s, %s' % (T1, x), 'movsd %s, %s' % (m, T1)])
                        t1_used()
                    else:
                        memfix(['movsd %s, %s' % (m, x)])
                elif name in ('fist_m', 'fistp_m'):
                    if arg == 32:
                        cvt = 'cvtps2dq' if held[top] == 'f' else 'cvtpd2dq'
                        memfix(['%s %s, %s' % (cvt, T1, x), 'movd %s, %s' % (m, T1)])
                        t1_used()
                    else:
                        if name == 'fist_m':
                            refuse(i)
                        to_d(top)
                        memfix(spill_push(x) + ['fistp %s' % m])
                        nfall += 1
                elif name in ('fst_r', 'fstp_r'):
                    if arg:
                        out.append('%s %s, %s' % (mov, reg(d, arg), x))
                        held[top - arg] = held[top]
                elif name == 'fxch':
                    if arg:
                        out.extend(['%s %s, %s' % (mov, T1, x), '%s %s, %s' % (mov, x, reg(d, arg)),
                                  '%s %s, %s' % (mov, reg(d, arg), T1)])
                        held[top], held[top - arg] = held[top - arg], held[top]
                        t1_used()
                elif name == 'fchs':
                    if held[top] == 'f':
                        out.append('xorps %s, XMMWORD PTR [_%s_signmaskf]' % (x, p))
                    else:
                        out.append('xorpd %s, XMMWORD PTR [_%s_signmask]' % (x, p))
                elif name == 'fabs':
                    if held[top] == 'f':
                        out.append('andps %s, XMMWORD PTR [_%s_absmaskf]' % (x, p))
                    else:
                        out.append('andpd %s, XMMWORD PTR [_%s_absmask]' % (x, p))
                elif name == 'fsqrt':
                    if held[top] == 'f':
                        out.append('sqrtss %s, %s' % (x, x))
                    else:
                        out.append('sqrtsd %s, %s' % (x, x))
                        rounded(top)
                        if not fast:
                            t1_used()
                elif name in ('fsin', 'fcos', 'frndint'):
                    to_d(top)
                    out.extend(['lea esp, [esp-8]', 'movsd QWORD PTR [esp], %s' % x, 'fld QWORD PTR [esp]', name,
                              'fstp QWORD PTR [esp]', 'movsd %s, QWORD PTR [esp]' % x, 'lea esp, [esp+8]'])
                    nfall += 1
                elif name in ('fpatan', 'fyl2x'):
                    to_d(top - 1)
                    to_d(top)
                    a, b = reg(d, 1), x
                    out.extend(['lea esp, [esp-16]', 'movsd QWORD PTR [esp+8], %s' % a, 'movsd QWORD PTR [esp], %s' % b,
                              'fld QWORD PTR [esp+8]', 'fld QWORD PTR [esp]', name, 'fstp QWORD PTR [esp]',
                              'movsd %s, QWORD PTR [esp]' % a, 'lea esp, [esp+16]'])
                    nfall += 1
                elif name in ('fptan', 'fsincos'):
                    to_d(top)
                    new = 'xmm%d' % d
                    out.extend(['lea esp, [esp-16]', 'movsd QWORD PTR [esp], %s' % x, 'fld QWORD PTR [esp]', name,
                              'fstp QWORD PTR [esp]', 'fstp QWORD PTR [esp+8]', 'movsd %s, QWORD PTR [esp]' % new,
                              'movsd %s, QWORD PTR [esp+8]' % x, 'lea esp, [esp+16]'])
                    held[d] = 'd'
                    nfall += 1
                elif name == 'ftst':
                    compare(x, ['xorpd %s, %s' % (T2, T2)], held[top] == 'f', ['xorps %s, %s' % (T2, T2)])
                elif name == 'compp':
                    compare(x, ['%s %s, %s' % (movd(top - 1), T2, reg(d, 1))], held[top] == 'f',
                            ['movaps %s, %s' % (T2, reg(d, 1))] if held[top - 1] == 'f' else None)
                elif name in ('comi', 'comip'):
                    if held[top] == 'f' and held[top - arg] == 'f':
                        out.append('ucomiss %s, %s' % (x, reg(d, arg)))
                    else:
                        to_d(top)
                        to_d(top - arg)
                        out.append('ucomisd %s, %s' % (x, reg(d, arg)))
                elif name == 'fnstsw_ax':
                    sw_top = (8 - d) & 7
                    if pending == 'stash':
                        out.append('movapd %s, %s' % (T1, T2))
                        if sw_top:
                            out.append('orpd %s, XMMWORD PTR [_%s_sw_top+%d]' % (T1, p, 16 * sw_top))
                        out.extend(['lea esp, [esp-4]', 'movd DWORD PTR [esp], %s' % T1, 'mov ah, BYTE PTR [esp]',
                                  'lea esp, [esp+4]'])
                    elif pending in ('pair', 'pairf') and fuse(n):
                        pass
                    elif pending in ('pair', 'pairf'):
                        seq = ['%s %s, %s' % ('ucomiss' if pending == 'pairf' else 'ucomisd', T1, T2), 'lahf', 'and ah, 0x45']
                        if sw_top:
                            seq.append('or ah, 0x%02x' % (sw_top << 3))
                        if self.flags_dead(ins, n + 1):
                            out.extend(seq)
                        else:
                            out.extend(['pushfd'] + seq + ['popfd'])
                    else:
                        raise Fail('status word read without a preceding compare at %x' % i.rva)
                else:
                    kd, op = name.split('_', 1)
                    if kd in ('m', 'mi'):
                        if kd == 'mi' and arg != 32:
                            refuse(i)
                        if op in ('com', 'comp'):
                            compare(x, self.load(T2, kd, arg, m), held[top] == 'f',
                                    ['movss %s, %s' % (T2, m)] if kd == 'm' and arg == 32 else None)
                        elif kd == 'm' and arg == 32 and held[top] == 'f':
                            memfix(['movss %s, %s' % (T1, m)])
                            if op.endswith('r'):
                                out.extend(['%s %s, %s' % (fop[op[:-1]], T1, x), 'movaps %s, %s' % (x, T1)])
                            else:
                                out.append('%s %s, %s' % (fop[op], x, T1))
                            t1_used()
                        else:
                            to_d(top)
                            memfix(self.load(T1, kd, arg, m))
                            if op.endswith('r'):
                                out.extend(self.arith(op[:-1], T1, x) + ['movapd %s, %s' % (x, T1)])
                            else:
                                out.extend(self.arith(op, x, T1))
                            rounded(top)
                            t1_used()
                    elif kd == 'r0' and op in ('com', 'comp'):
                        compare(x, ['%s %s, %s' % (movd(top - arg), T2, reg(d, arg))], held[top] == 'f',
                                ['movaps %s, %s' % (T2, reg(d, arg))] if held[top - arg] == 'f' else None)
                    else:
                        # r0: st0 = st0 op sti      ri/rp: sti = sti op st0      ...r: operands swapped
                        if kd == 'r0':
                            jd, js = top, top - arg
                        else:
                            jd, js = top - arg, top
                        dst, src = 'xmm%d' % jd, 'xmm%d' % js
                        if held[jd] == 'f' and held[js] == 'f':
                            if op.endswith('r'):
                                out.extend(['movaps %s, %s' % (T1, src), '%s %s, %s' % (fop[op[:-1]], T1, dst),
                                          'movaps %s, %s' % (dst, T1)])
                            else:
                                out.append('%s %s, %s' % (fop[op], dst, src))
                        else:
                            to_d(jd)
                            to_d(js)
                            if op.endswith('r'):
                                out.extend(['movapd %s, %s' % (T1, src)] + self.arith(op[:-1], T1, dst)
                                         + ['movapd %s, %s' % (dst, T1)])
                            else:
                                out.extend(self.arith(op, dst, src))
                            rounded(jd)
                        t1_used()
                continue

            # ---- integer / control flow instructions ----
            raw = '.byte ' + ','.join('0x%02x' % b for b in i.raw)
            if i.kind == 'ftol':
                # edx:eax = (int64)st0, truncated. Inline for the 32-bit range, the real helper otherwise.
                x = reg(d, 0)
                slow, done, lab = self.label(), self.label(), self.label()
                f = fast and held[d - 1] == 'f'
                out.extend(['%s eax, %s' % ('cvttss2si' if f else 'cvttsd2si', x), 'cmp eax, 0x80000000', 'je %s' % slow,
                          'cdq', 'jmp %s' % done, slow + ':'])
                if f:
                    out.append('cvtps2pd %s, %s' % (x, x))    # the value is popped here, so how it is held no longer matters
                out.extend(spill_push(x))
                out.append('.byte 0xe8')
                out.append('%s: .long 0' % lab)
                self.relfix.append((lab, i.target))
                out.append(done + ':')
                pending = None
                continue
            if fast and (i.kind == 'switch' or (i.kind in ('jmp', 'jcc') and s <= i.target < e)):
                all_d(d)
            if i.kind == 'switch':
                jt = self.label()
                out.append('jmp DWORD PTR [%s*4+%s]' % (i.index, jt))
                self.jumptables.append((jt, ['L%s_%06x' % (lp, t) for t in i.cases]))
                self.tabledeps.append((i.table, 4 * len(i.cases)))
            elif i.kind in ('jmp', 'jcc') and s <= i.target < e:
                out.append('%s L%s_%06x' % (i.mnem, lp, i.target))
            elif i.kind == 'call' and n in fpret and i.target in self.xr_targets:
                # a translated routine that returns its result in xmm0 when called from here: no FPU stack round trip
                out.append('call _%s_%06x_xr' % (p, i.target))
                self.xrdeps.add((s, i.target))
                self.xrcalls += 1
                pending = None
                if fast:
                    held[0] = 'd'
            elif i.kind in ('call', 'jmp'):
                if i.kind == 'call' and n in fpret:
                    self.fpcalls.add(i.target)
                lab = self.label()
                # always the form with a 32-bit displacement: a jump out of the routine can be a short one in the original
                out.append('.byte 0xe8' if i.kind == 'call' else '.byte 0xe9')
                out.append('%s: .long 0' % lab)
                self.relfix.append((lab, i.target))
                if i.kind == 'call':
                    pending = None
                    if n in fpret:
                        out.extend(spill_load('xmm0'))
                        if fast:
                            held[0] = 'd'
            elif i.kind == 'ret':
                if d == 1:
                    if fast:
                        to_d(0)
                    if not xr:
                        out.extend(spill_push('xmm0'))
                out.append(raw)
            elif i.kind == 'icall' and n in fpret and self.inline_import(i) is not None:
                # MSVCR71 floor/ceil through the import table: computed in place, the double argument is at [esp].
                # The installer keeps this routine original unless the slot still holds the runtime's own function.
                kind_no, mode = self.inline_import(i)
                out.extend(['movsd xmm0, QWORD PTR [esp]', 'roundsd xmm0, xmm0, %d' % mode])
                self.inlined.append((struct.unpack_from('<I', i.raw, 2)[0] - img.base, s, kind_no))
                pending = None
                if fast:
                    held[0] = 'd'
            else:
                if i.relocs:
                    lab = self.label()
                    out.append(lab + ':')
                    for r in i.relocs:
                        self.absfix.append('%s + %d' % (lab, r))
                out.append(raw)
                if i.kind == 'icall':
                    pending = None
                    if n in fpret:
                        out.extend(spill_load('xmm0'))
                        if fast:
                            held[0] = 'd'
        if xr:
            return
        out.append('%s:' % tramp)
        for i in head:
            if i.relocs:
                lab = self.label()
                out.append(lab + ':')
                for r in i.relocs:
                    self.absfix.append('%s + %d' % (lab, r))
            out.append('.byte ' + ','.join('0x%02x' % b for b in i.raw))
        lab = self.label()
        out.append('.byte 0xe9')
        out.append('%s: .long 0' % lab)
        self.relfix.append((lab, s + hlen))
        self.funcs.append((s, e - s, relocs, 1 if (uses_ftol or tables) else 0))
        self.stats.append((s, e - s, nx87, nfall, len(fpret)))
        self.info.append(self.describe(ins, depth, s))

    def al_after(self, i, has_value):
        """Whether al holds a value put there by the routine's integer code after instruction i, given whether
        it did before."""
        dst, _, src = i.ops.partition(',')
        dst, src = dst.strip(), src.strip()
        if dst not in ('al', 'ax', 'eax'):
            return has_value
        read = set(self.AX_PARTS.findall(src))
        if 'ah' in read:
            return False                # ah can hold a status word
        if i.mnem in ('xor', 'sub') and src == dst:
            return True
        overwrites = i.mnem in ('mov', 'movzx', 'movsx', 'lea', 'pop') or i.mnem.startswith('set')
        return True if overwrites and not read else has_value

    def al_set_at_returns(self, ins, depth):
        """True if at every return al holds a value that integer code of this routine put there, and not a
        status word or what a callee left behind. The blind test then compares al as well, the byte a bool comes
        back in. Anything unclear counts as no: such a routine is compared as before."""
        index_of = {i.rva: n for n, i in enumerate(ins)}
        known = [None] * len(ins)       # al holds such a value on every path found so far to the instruction
        work = [(0, False)]
        while work:
            n, has_value = work.pop()
            while n < len(ins):
                if known[n] is not None and (has_value or not known[n]):
                    break               # nothing new for this instruction
                known[n] = has_value
                i = ins[n]
                if i.kind == 'ret':
                    break
                if i.kind == 'ijmp' or (i.kind == 'jmp' and i.target not in index_of):
                    return False        # a tail jump: eax is whatever the routine jumped to leaves
                if i.kind == 'switch':
                    work.extend((index_of[t], has_value) for t in i.cases)
                    break
                if i.kind == 'jmp':
                    n = index_of[i.target]
                    continue
                if i.kind == 'jcc':
                    work.append((index_of[i.target], has_value))
                elif i.kind in ('call', 'icall', 'ftol') or (i.kind == 'x87' and i.x87[0] == 'fnstsw_ax'):
                    has_value = False
                elif i.kind == 'raw':
                    has_value = self.al_after(i, has_value)
                n += 1
        at_returns = [known[n] for n, i in enumerate(ins) if i.kind == 'ret' and depth[n] is not None]
        return bool(at_returns) and all(at_returns)

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
                    kinds=''.join(kinds.get(k, 'p') for k in range(nargs)), al=self.al_set_at_returns(ins, depth))

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
        img, p, out = self.img, self.prefix, self.out
        ins, end = helper_code(img, f)
        relocs = img.relocs_in(f, end)
        head, hlen = [], 0
        for i in ins:
            if hlen >= 5:
                break
            movable = not i.bad and not 0xd8 <= i.raw[0] <= 0xdf
            if movable:
                try:
                    classify(i, img.base)
                except Fail:
                    movable = False
            if not movable or i.kind != 'raw':
                raise Fail('cannot relocate the first instructions of the helper at %x' % f)
            head.append(i)
            hlen += len(i.raw)
        fn, slow = '_%s_%06x' % (p, f), self.label()
        out.extend(['.p2align 4', '.globl %s' % fn, fn + ':',
                  'lea esp, [esp-8]', 'fst QWORD PTR [esp]', 'movsd %s, QWORD PTR [esp]' % T2, 'lea esp, [esp+8]',
                  'cvttsd2si eax, %s' % T2, 'cmp eax, 0x80000000', 'je %s' % slow, 'fstp st(0)', 'cdq', 'ret',
                  slow + ':'])
        for i in head:
            rel = [r - i.rva for r in relocs if i.rva <= r < i.rva + len(i.raw)]
            if rel:
                lab = self.label()
                out.append(lab + ':')
                self.absfix.extend('%s + %d' % (lab, r) for r in rel)
            out.append('.byte ' + ','.join('0x%02x' % b for b in i.raw))
        lab = self.label()
        out.extend(['.byte 0xe9', '%s: .long 0' % lab])
        self.relfix.append((lab, f + hlen))
        self.funcs.append((f, end - f, relocs, 0))

    AX_PARTS = re.compile(r'\b(eax|ax|ah|al)\b')
    AX_IMPLICIT = {'cdq', 'cwde', 'cbw', 'cwd', 'mul', 'div', 'idiv', 'stos', 'stosb', 'stosw', 'stosd', 'lods',
                   'lodsb', 'lodsd', 'scas', 'scasb', 'scasd', 'xlat', 'xlatb', 'sahf', 'lahf', 'cmpxchg', 'aaa',
                   'aas', 'aam', 'aad', 'daa', 'das', 'in', 'out', 'rep', 'repz', 'repnz', 'repe', 'repne', 'enter',
                   'leave', 'pusha', 'pushad', 'popa', 'popad'}

    def ax_dead(self, ins, n, idx, dirty=('al', 'ah'), budget=FLOW_BUDGET, seen=None):
        """True if, on every path from instruction n, no instruction reads a byte of ax still holding the status
        word ('dirty') before it is overwritten. Calls overwrite eax (the return register). A return counts as a
        read unless al has been written since (a byte-sized return value: the caller looks at al only)."""
        seen = set() if seen is None else seen
        dirty = set(dirty)
        while n < len(ins) and budget > 0:
            if not dirty:
                return True
            if (n, tuple(sorted(dirty))) in seen:
                return True                 # a loop back to a point already being checked
            seen.add((n, tuple(sorted(dirty))))
            budget -= 1
            i = ins[n]
            if i.kind == 'x87':
                if i.x87[0] == 'fnstsw_ax':
                    return True
                n += 1
                continue
            if i.kind in ('call', 'icall', 'ftol'):
                return True
            if i.kind == 'ret':
                return 'al' not in dirty
            if i.kind in ('ijmp', 'switch', 'err'):
                return False
            if i.kind == 'jmp':
                if i.target not in idx:
                    return False
                n = idx[i.target]
                continue
            if i.kind == 'jcc':
                if i.mnem in ('loop', 'loope', 'loopne', 'jecxz') or i.target not in idx:
                    return False
                if not self.ax_dead(ins, idx[i.target], idx, tuple(dirty), budget, seen):
                    return False
                n += 1
                continue
            if i.mnem in self.AX_IMPLICIT or (i.mnem == 'imul' and ',' not in i.ops):
                return False
            if not self.AX_PARTS.search(i.ops):
                n += 1
                continue
            dst, _, src = i.ops.partition(',')
            dst, src = dst.strip(), src.strip()
            if self.AX_PARTS.search(src) and not (i.mnem in ('xor', 'sub') and src == dst):
                parts = set(self.AX_PARTS.findall(src))
                if 'eax' in parts or 'ax' in parts or parts & dirty:
                    return False
            writes_only = i.mnem in ('mov', 'movzx', 'movsx', 'lea', 'pop') or (i.mnem in ('xor', 'sub') and src == dst) \
                or i.mnem.startswith('set')
            if dst in ('eax', 'ax') and writes_only:
                return True
            if dst in ('al', 'ah') and writes_only:
                dirty.discard(dst)
                n += 1
                continue
            if self.AX_PARTS.fullmatch(dst):
                if dst in ('eax', 'ax') or dst in dirty:
                    return False            # read-modify-write of a byte still holding the status word
                n += 1
                continue
            # ax inside a memory operand (an address register) or anything else: a read
            return False
        return False

    def fused_status_branch(self, ins, n, targets, idx, s, e):
        """For 'fnstsw ax / test ah, M / jcc' at n (FPU register moves allowed before the test) with ax and the
        flags dead afterwards: the set of compare outcomes ('G', 'L', 'E', 'U') on which the jump is taken, the
        jump target and the index of the test. None otherwise."""
        k = n + 1
        # register moves of the FPU stack may sit between: they become SSE moves, which leave the flags alone
        while k < len(ins) and ins[k].kind == 'x87' and ins[k].x87[0] in ('fst_r', 'fstp_r', 'fxch') \
                and ins[k].rva not in targets:
            k += 1
        if k + 1 >= len(ins):
            return None
        t, j = ins[k], ins[k + 1]
        if t.kind != 'raw' or t.mnem != 'test' or j.kind != 'jcc' or t.rva in targets or j.rva in targets:
            return None
        m = re.match(r'^ah,\s*(0x[0-9a-f]+|\d+)$', t.ops)
        if not m or not (s <= j.target < e) or j.target not in idx:
            return None
        cond = {'je': 'z', 'jz': 'z', 'jne': 'nz', 'jnz': 'nz', 'jp': 'p', 'jpe': 'p', 'jnp': 'np', 'jpo': 'np'}.get(j.mnem)
        if cond is None:
            return None
        if not (self.flags_dead_path(ins, k + 2, idx) and self.flags_dead_path(ins, idx[j.target], idx)):
            return None
        if not (self.ax_dead(ins, k + 2, idx) and self.ax_dead(ins, idx[j.target], idx)):
            return None
        mask = int(m.group(1), 0)
        if mask & ~0x45:
            return None                 # tests other bits of ah (the FPU stack top): keep the full status word
        taken = set()
        for name, bits in (('G', 0x00), ('L', 0x01), ('E', 0x40), ('U', 0x45)):
            v = bits & mask
            even = bin(v).count('1') % 2 == 0
            if {'z': v == 0, 'nz': v != 0, 'p': even, 'np': not even}[cond]:
                taken.add(name)
        return frozenset(taken), j.target, k

    # jumps after "ucomisd st0, other" that are taken exactly on the given set of outcomes
    # (ucomisd: greater ZF=PF=CF=0, less CF=1, equal ZF=1, unordered ZF=PF=CF=1)
    FUSED_JUMPS = {
        frozenset(): [], frozenset('GLEU'): ['jmp {T}'],
        frozenset('G'): ['ja {T}'], frozenset('GE'): ['jae {T}'], frozenset('LU'): ['jb {T}'], frozenset('LEU'): ['jbe {T}'],
        frozenset('EU'): ['je {T}'], frozenset('GL'): ['jne {T}'], frozenset('U'): ['jp {T}'], frozenset('GLE'): ['jnp {T}'],
        frozenset('L'): ['jp {S}', 'jb {T}', '{S}:'], frozenset('E'): ['jp {S}', 'je {T}', '{S}:'], frozenset('LE'): ['jp {S}', 'jbe {T}', '{S}:'],
        frozenset('GU'): ['ja {T}', 'jp {T}'], frozenset('GEU'): ['jae {T}', 'jp {T}'], frozenset('GLU'): ['jne {T}', 'jp {T}'],
    }

    JCC_READS = {'jo': 'O', 'jno': 'O', 'jb': 'C', 'jc': 'C', 'jnae': 'C', 'jae': 'C', 'jnb': 'C', 'jnc': 'C',
                 'je': 'Z', 'jz': 'Z', 'jne': 'Z', 'jnz': 'Z', 'jbe': 'CZ', 'jna': 'CZ', 'ja': 'CZ', 'jnbe': 'CZ',
                 'js': 'S', 'jns': 'S', 'jp': 'P', 'jpe': 'P', 'jnp': 'P', 'jpo': 'P', 'jl': 'SO', 'jnge': 'SO',
                 'jge': 'SO', 'jnl': 'SO', 'jle': 'ZSO', 'jng': 'ZSO', 'jg': 'ZSO', 'jnle': 'ZSO'}

    def flags_dead_path(self, ins, n, idx, dirty='CZPSAO', budget=FLOW_BUDGET, seen=None):
        """True if, on every path from n, the flags in 'dirty' are redefined before any instruction reads them.
        Follows jumps. inc and dec redefine every flag but CF."""
        seen = set() if seen is None else seen
        dirty = set(dirty)
        while n < len(ins) and budget > 0:
            if not dirty:
                return True
            key = (n, tuple(sorted(dirty)))
            if key in seen:
                return True
            seen.add(key)
            budget -= 1
            i = ins[n]
            if i.kind == 'x87':
                if i.x87[0] in ('comi', 'comip'):
                    return True
                n += 1
                continue
            if i.mnem in FLAG_DEF:
                return True
            if i.mnem in ('inc', 'dec'):
                dirty &= {'C'}
                n += 1
                continue
            if i.kind == 'jmp':
                if i.target not in idx:
                    return False
                n = idx[i.target]
                continue
            if i.kind == 'jcc':
                if i.mnem not in self.JCC_READS or i.target not in idx:
                    return False
                if set(self.JCC_READS[i.mnem]) & dirty:
                    return False
                if not self.flags_dead_path(ins, idx[i.target], idx, ''.join(dirty), budget, seen):
                    return False
                n += 1
                continue
            if i.mnem in FLAG_NEUTRAL:
                n += 1
                continue
            return False
        return False

    # msvcr71.dll functions whose import slots the installer and the tests need to find: name -> number
    CRT_SLOTS = {'floor': 0, 'ceil': 1, 'sqrt': 2}
    # those computed in place: name -> (number, roundsd rounding mode)
    INLINE_IMPORTS = {'floor': (0, 9), 'ceil': (1, 10)}

    def inline_import(self, i):
        """For 'call DWORD PTR ds:[slot]' on msvcr71.dll's floor or ceil: (table number, rounding mode)."""
        if os.environ.get('XLAT_NO_INLINE') or len(i.raw) != 6 or i.raw[:2] != b'\xff\x15':
            return None
        imp = self.img.imports.get(struct.unpack_from('<I', i.raw, 2)[0] - self.img.base)
        if not imp or imp[0] != 'msvcr71.dll':
            return None
        return self.INLINE_IMPORTS.get(imp[1])

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
        lines = ['.intel_syntax noprefix', '.text', '.p2align 4', '.globl _%s_code_begin' % p, '_%s_code_begin:' % p]
        lines += self.out
        lines += ['.p2align 4', '.globl _%s_code_end' % p, '_%s_code_end:' % p]
        lines += ['.section .rdata,"dr"', '.p2align 4',
                  '_%s_signexp: .quad 0xfff0000000000000, 0xfff0000000000000' % p,
                  '_%s_signmask: .quad 0x8000000000000000, 0' % p,
                  '_%s_absmask: .quad 0x7fffffffffffffff, 0xffffffffffffffff' % p,
                  '_%s_big: .quad 0x7830000000000000, 0x7830000000000000' % p,      # 2^900
                  '_%s_nbig: .quad 0xf830000000000000, 0xf830000000000000' % p,     # -2^900
                  '_%s_k: .quad 0x41c8000000000000, 0x41c8000000000000' % p,        # 1.5 * 2^29
                  '_%s_signmaskf: .long 0x80000000, 0, 0, 0' % p,
                  '_%s_absmaskf: .long 0x7fffffff, 0xffffffff, 0xffffffff, 0xffffffff' % p,
                  '_%s_one: .quad 0x3ff0000000000000' % p,
                  '_%s_onef: .long 0x3f800000' % p,
                  '_%s_pi: .quad 0x400921fb54442d18' % p,
                  '_%s_l2e: .quad 0x3ff71547652b82fe' % p,
                  '_%s_ln2: .quad 0x3fe62e42fefa39ef' % p,
                  '_%s_lg2: .quad 0x3fd34413509f79ff' % p,
                  '_%s_l2t: .quad 0x400a934f0979a371' % p]
        lines += ['.p2align 4',
                  '_%s_sw_c0: .quad 0x01, 0' % p, '_%s_sw_c3: .quad 0x40, 0' % p, '_%s_sw_all: .quad 0x45, 0' % p,
                  '_%s_sw_top: .quad 0x00, 0, 0x08, 0, 0x10, 0, 0x18, 0, 0x20, 0, 0x28, 0, 0x30, 0, 0x38, 0' % p]
        lines += ['.p2align 2']
        for lab, cases in self.jumptables:
            lines.append('%s: .long %s' % (lab, ', '.join(cases)))
        lines += ['.p2align 2', '.globl _%s_absfix' % p, '_%s_absfix:' % p]
        lines += ['.long %s' % a for a in self.absfix] + ['.long 0']
        lines += ['.globl _%s_relfix' % p, '_%s_relfix:' % p]
        lines += ['.long %s, 0x%x' % (a, t) for a, t in self.relfix] + ['.long 0, 0']
        deps = []
        for f in sorted(self.ftol):
            end = helper_code(img, f)[1]
            deps.append((f, end - f, img.relocs_in(f, end), 0))
        for t, size in sorted(set(self.tabledeps)):
            deps.append((t, size, img.relocs_in(t, t + size), 0))
        done = set()
        for s, size, relocs, _flags in self.funcs + deps:
            if s in done:
                continue
            done.add(s)
            lines.append('L%s_orig_%06x: .byte %s' % (p, s, ','.join('0x%02x' % b for b in img.bytes(s, s + size))))
            lines.append('.p2align 2')
            lines.append('L%s_rel_%06x: .long %s' % (p, s, ','.join(['%d' % (r - s) for r in relocs] + ['0xffffffff'])))
        # functions: rva, size, replacement, original bytes, relocation offsets, flags (1 = needs every dependency intact)
        lines += ['.p2align 2', '.globl _%s_funcs' % p, '_%s_funcs:' % p]
        for s, size, _relocs, flags in self.funcs:
            lines.append('.long 0x%x, %d, _%s_%06x, L%s_orig_%06x, L%s_rel_%06x, %d' % (s, size, p, s, p, s, p, s, flags))
        lines += ['.long 0, 0, 0, 0, 0, 0']
        # code the translations rely on without replacing it (inlined helper semantics)
        lines += ['.globl _%s_deps' % p, '_%s_deps:' % p]
        for s, size, _relocs, _flags in deps:
            lines.append('.long 0x%x, %d, 0, L%s_orig_%06x, L%s_rel_%06x, 0' % (s, size, p, s, p, s))
        lines += ['.long 0, 0, 0, 0, 0, 0']
        # imports computed in place: import slot, routine, function (0 floor, 1 ceil). The installer leaves the
        # routine original unless the slot still holds msvcr71.dll's own function
        lines += ['.globl _%s_inlined' % p, '_%s_inlined:' % p]
        for slot, rva, k in self.inlined:
            lines.append('.long 0x%x, 0x%x, %d' % (slot, rva, k))
        lines += ['.long 0, 0, 0']
        # where client.dll's import table holds msvcr71.dll's floor (0), ceil (1) and sqrt (2): slot, number.
        # The installer points the sqrt slot at its own version. The tests give the unresolved image real
        # floor and ceil. This is the only place the import table is read.
        lines += ['.globl _%s_crtslots' % p, '_%s_crtslots:' % p]
        for slot, (dll, fn) in sorted(img.imports.items()):
            if dll == 'msvcr71.dll' and fn in self.CRT_SLOTS:
                lines.append('.long 0x%x, %d' % (slot, self.CRT_SLOTS[fn]))
        lines += ['.long 0, 0']
        # direct calls into the xmm0-returning variant of another translated routine: caller, callee. The installer
        # installs a caller only together with its callees.
        lines += ['.globl _%s_xrdeps' % p, '_%s_xrdeps:' % p]
        for a, b in sorted(self.xrdeps):
            lines.append('.long 0x%x, 0x%x' % (a, b))
        lines += ['.long 0, 0',
                  '.globl _%s_imagebase' % p, '_%s_imagebase: .long 0x%x' % (p, img.base),
                  '.data', '.p2align 2', '.globl _%s_tid' % p, '_%s_tid: .long 0' % p,
                  '.text', '.att_syntax prefix']
        quoted = ['  "%s\\n"\n' % line.replace('\\', '\\\\').replace('"', '\\"') for line in lines]
        replace_file(path, '// Generated by xlat.py - x87 routines translated to SSE2. Do not edit.\n__asm__(\n'
                     + ''.join(quoted) + ');\n')


def helper_code(img, rva):
    """(instructions from rva on, rva where the helper ends) of the compiler's float-to-integer helper,
    which ends with its first return."""
    ins = disassemble(img, rva, rva + HELPER_SCAN_BYTES)
    for i in ins:
        if i.raw[0] in RETURN_OPCODES:
            return ins, i.rva + len(i.raw)
    raise Fail('the float-to-integer helper at %x does not return within %d bytes' % (rva, HELPER_SCAN_BYTES))


def code_hash(img, s, size):
    """FNV-1a over the bytes of [s, s + size), relocated address fields left out. Identifies a routine
    without carrying its code."""
    data = img.bytes(s, s + size)
    if len(data) != size:
        raise Fail('%x to %x reaches past the end of the image' % (s, s + size))
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
    """The instruction at index n uses an FPU value that the code before it did not push."""

    def __init__(self, n):
        self.n = n


def replace_file(path, text):
    """Writes a file under a temporary name and renames it, so a run that stops early leaves the old file whole."""
    with open(path + '.tmp', 'w') as file:
        file.write(text)
    os.replace(path + '.tmp', path)


def read_list(path, img, min_weight):
    """What a routine list names: the routines as (start, limit, weight, (size, hash) or None) and the
    float-to-integer helpers. LIST_HEAD describes the format. A line that does not fit it stops the run."""
    routines, helpers = [], set()
    with open(path) as file:
        for number, line in enumerate(file, 1):
            fields = line.split('#')[0].split()
            if not fields:
                continue
            try:
                if fields[0] == 'ftol' and len(fields) == 4:
                    rva, size, wanted = [int(field, 16) for field in fields[1:]]
                elif fields[0] != 'ftol' and len(fields) in (3, 5):
                    start, limit, weight = int(fields[0], 16), int(fields[1], 16), int(fields[2])
                    check = (int(fields[3], 16), int(fields[4], 16)) if len(fields) == 5 else None
                else:
                    raise ValueError
            except ValueError:
                raise SystemExit('%s:%d: not a line of a routine list (LIST_HEAD in xlat.py describes them): %s'
                                 % (path, number, line.strip())) from None
            if fields[0] == 'ftol':
                try:
                    found = code_hash(img, rva, size)
                except Fail:
                    found = None
                if found != wanted:
                    raise SystemExit('the float-to-integer helper at %x is not the one this list was made for: '
                                     'wrong client.dll?' % rva)
                helpers.add(rva)
            elif weight >= min_weight:
                routines.append((start, limit, weight, check))
    return routines, helpers


NO_LIMIT = 1 << 30


def parse_arguments(args):
    """(options, sources) of the command line. A source is a (start, limit) pair or the path of a list."""
    options = {'map': None, 'ftol': set(), 'min': 0, 'max': NO_LIMIT, 'skip': set(), 'write-list': None, 'exact': False}
    sources = []
    args = list(args)
    try:
        while args:
            word = args.pop(0)
            if word in ('--map', '--write-list'):
                options[word[2:]] = args.pop(0)
            elif word in ('--min', '--max'):
                options[word[2:]] = int(args.pop(0))
            elif word in ('--ftol', '--skip'):
                options[word[2:]] = {int(rva, 16) for rva in args.pop(0).split(',')}
            elif word == '--exact-range':
                options['exact'] = True
            elif word.startswith('@'):
                sources.append(word[1:])
            else:
                start, limit = [int(rva, 16) for rva in word.split('-')]
                sources.append((start, limit))
    except (IndexError, ValueError):
        raise SystemExit(__doc__) from None
    return options, sources


def translate_checked(translator, s, e, check):
    """Translates one routine and returns its size. Fails if a list says the routine holds other code."""
    translator.translate(s, e)
    size = translator.funcs[-1][1]
    if check and (size, code_hash(translator.img, s, size)) != check:
        raise Fail('differs from the code the list was made from')
    return size


def direct_call_targets(translator, jobs, skip, max_count):
    """A dry run that finds the routines which return a float on every path and are called for it by
    translated code. Those get a second entry that returns in xmm0 (translate's xr)."""
    if os.environ.get('XLAT_NO_XR'):
        return set()
    trial = Translator(translator.img, translator.prefix)
    trial.ftol, trial.exact, trial.branches = set(translator.ftol), translator.exact, translator.branches
    done, seen = set(), set()
    for s, e, _weight, check in jobs:
        if s in seen or s in skip:
            continue
        seen.add(s)
        if len(done) >= max_count:
            continue
        before = trial.checkpoint()
        try:
            translate_checked(trial, s, e, check)
            done.add(s)
        except Fail:
            trial.restore(before)       # the calls of a routine that is left out do not count
    return {callee for callee in trial.fpcalls if callee in done and trial.fpret_all.get(callee)}


def list_text(translator, done):
    """The routine list of what was translated, as --write-list writes it."""
    img = translator.img
    entries = []
    for rva in sorted(translator.ftol):
        size = helper_code(img, rva)[1] - rva
        entries.append('ftol %x %x %016x\n' % (rva, size, code_hash(img, rva, size)))
    for s, e, weight, size in done:
        entries.append('%x %x %d %x %016x\n' % (s, e, weight, size, code_hash(img, s, size)))
    return LIST_HEAD + ''.join(entries)


def tests_text(translator):
    """The rows of the blind test's table (GameFn in tests/game_tests.inc), one per translated routine."""
    rows = []
    for d in translator.info:
        flags = ['true' if d[flag] else 'false' for flag in ('this', 'fpret', 'framed', 'al')]
        rows.append('  { 0x%x, %d, "%s", %s },\n' % (d['rva'], d['nargs'], d['kinds'], ', '.join(flags)))
    return ''.join(rows)


def main(args):
    if len(args) < 5 or args[0] not in ('pe', 'flat'):
        raise SystemExit(__doc__)
    mode, path, prefix, out = args[:4]
    options, sources = parse_arguments(args[4:])
    img = Image(path, mode)
    translator = Translator(img, prefix)
    translator.exact = options['exact']
    translator.ftol = set(options['ftol'])
    if options['map']:
        with open(options['map'], 'rb') as file:
            translator.branches = sorted((target, source) for source, target in pickle.load(file)['branches'])
    # the lists are read after all options, so that --min counts wherever it stands
    jobs = []
    for source in sources:
        if isinstance(source, tuple):
            jobs.append(source + (0, None))
        else:
            routines, helpers = read_list(source, img, options['min'])
            jobs.extend(routines)
            translator.ftol |= helpers
    skip, max_count = options['skip'], options['max']
    translator.xr_targets = direct_call_targets(translator, jobs, skip, max_count)
    limits = {}
    for s, e, _weight, _check in jobs:
        limits.setdefault(s, e)         # a routine listed twice is translated with its first limit
    weight_done = weight_total = 0
    reasons = {}
    seen = set()
    done = []
    for s, e, weight, check in jobs:
        if s in seen or s in skip:
            continue
        seen.add(s)
        weight_total += weight
        if len(done) >= max_count:
            continue
        before = translator.checkpoint()
        try:
            size = translate_checked(translator, s, e, check)
            weight_done += weight
            done.append((s, e, weight, size))
            print('ok   %06x size %4d  x87 %3d  x87-fallbacks %d  fp-returning calls %d  weight %d'
                  % (translator.stats[-1] + (weight,)))
        except Fail as failure:
            translator.restore(before)
            print('SKIP %06x-%06x weight %d: %s' % (s, e, weight, failure))
            reason = re.sub(r'\b[0-9a-f]{4,8}\b', 'X', str(failure))[:70]
            reasons.setdefault(reason, [0, 0])
            reasons[reason][0] += 1
            reasons[reason][1] += weight
    translated = {s for s, _e, _weight, _size in done}
    if translator.xr_targets - translated:
        raise SystemExit('internal error: direct-call targets not translated: %s' % sorted(translator.xr_targets - translated))
    for callee in sorted(translator.xr_targets):
        try:
            translator.translate(callee, limits[callee], xr=True)
        except Fail as failure:
            raise SystemExit('internal error: no direct-call entry for %x: %s' % (callee, failure)) from failure
    if options['write-list']:
        replace_file(options['write-list'], list_text(translator, done))
    for helper in sorted(translator.ftol):
        if helper not in {function[0] for function in translator.funcs}:
            translator.emit_ftol(helper)
            print('ok   %06x float-to-integer helper replaced' % helper)
    translator.write(out)
    replace_file(out + '.tests', tests_text(translator))
    if not translator.exact:
        print('compare branches fused: %d, floor/ceil calls computed in place: %d, direct float-returning calls: %d to %d routines'
              % (translator.fused, len(translator.inlined), translator.xrcalls, len(translator.xr_targets)))
        print('float-to-double conversions at branches: %d, instructions emitted: %d'
              % (translator.edgeconv, sum(1 for emitted in translator.out if not emitted.endswith(':') and not emitted.startswith('.'))))
    for reason, (count, weight) in sorted(reasons.items(), key=lambda item: -item[1][1])[:MAX_REASONS_SHOWN]:
        print('  skipped %4d functions, weight %6d: %s' % (count, weight, reason))
    # the summary comes last: scripts/build.sh shows the last line of this output
    print('%d of %d functions translated, sample weight covered %d of %d' % (len(done), len(seen), weight_done, weight_total))


if __name__ == '__main__':
    try:
        main(sys.argv[1:])
    except (Fail, OSError) as failure:
        raise SystemExit('xlat.py: %s' % failure) from failure
