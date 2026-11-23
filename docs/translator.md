# The x87 to SSE2 translator

`translator/xlat.py` reads a routine of `client.dll` and writes SSE2 assembly that does the same
thing. The DLL carries the result and swaps it in for the original at startup. This describes
the translation rules, what happens at run time and how the result was checked.

Why it is needed: Rosetta 2 emulates x87 instructions in software, at about 25 ns each, and
80–90% of the game's main thread was x87 math ([client-notes.md](client-notes.md)). On their
own, translated routines run 5 to 120 times faster.

Current output for the reference `client.dll`:

| | |
|---|---|
| Routines translated | 535 of 535 in `routines.list` |
| Instructions emitted | 66,336 |
| Compare branches taken directly | 1,365 of 1,698 |
| `floor`/`ceil` calls computed in place | 12 |
| Calls that return a float in `xmm0` | 244, to 47 routines |
| Float compares (`ucomiss`) | 1,490 |

## Translation rules

### Registers

Each x87 register becomes an SSE register. The x87 registers form a stack, and the depth of that
stack at each instruction can be worked out in advance, so every stack slot gets a fixed SSE
register. `xmm6` and `xmm7` are scratch.

### Rounding

Direct3D 9 puts the FPU in 24-bit precision mode. In that mode every add, subtract, multiply,
divide and square root is rounded to 24 significant bits, the precision of a `float`, but can
still hold far larger and smaller numbers than a `float` can.

The translation computes in double precision and rounds each result by converting it to `float`
and back (two instructions). **That is exact as long as both operands have at most 24
significant bits and the result fits in a `float`.** Every `float` and every earlier result has
24 bits. Outside the `float` range it differs: a value above `FLT_MAX` becomes infinity where
the FPU would keep it, and a value below the smallest normal `float` loses precision.
Bounding-box code uses values like `FLT_MAX` to mean "no limit", so this is a real trade-off.

An operand with more bits (a double from memory, a 32-bit integer, the constant π) makes the
result be rounded twice, first to a double and then to 24 bits. Where the exact result lies
almost halfway between two floats, that can differ from the FPU in the last bit. This is rare
and `--exact-range` does not change it.

`xlat.py --exact-range` produces the other form, which reproduces the extended range bit for
bit at 13 instructions per rounding instead of 2. The game has been played with the faster form
without visible problems. If something looks wrong, build with `--exact-range` first.

### Single precision

In the faster form, every value loaded from a `float` and every result of two such values stays
a `float` in the low lane of its SSE register and is computed with single-precision
instructions (`addps`, `mulps`, `divss`, `sqrtss`, `ucomiss`, `cvttss2si`). A double is made only
when a value meets a double operand, and at branches, labels and returns, where every register
holds a double again.

A 24-bit result rounded once more to 24 bits does not change, so this gives the same bits as
computing in double and rounding. When it was introduced, 527 routines went from 78,600
instructions to 55,500, and conversions between float and double from 27,600 to 6,100.

Two floats are compared as floats: widening both to double first changes neither their order
nor whether one is a NaN.

One difference from the x87 that the tests cannot see, because they treat every NaN as equal: a
signalling NaN that is loaded from a `float` and stored again keeps its bits, where the x87
would turn it into a quiet NaN.

### Compares

The original reads the FPU status word (`fnstsw ax`), tests bits of `ah` and jumps. Rebuilding
that status word from an SSE compare takes `lahf` and the parity flag, which Rosetta computes in
software.

Where the code only tests `ah` and jumps, the translation branches on the SSE compare itself.
It does so only if flow analysis, following jumps, shows that neither the flags nor the bytes
of `ax` holding the status word are read again before being overwritten. It applies to tests of
the three condition bits. A test of any other bit of `ah` (the FPU stack pointer) keeps the full
status word. FPU register moves between `fnstsw` and `test` are allowed.

Everywhere else a compare followed by `fnstsw ax` produces the same condition bits in `ah` as
the original.

A routine that returns a `bool` in `al` may return a different, unused `ah`.

### `floor` and `ceil`

Calls to msvcr71's `floor` and `ceil` through the import table are computed in place with SSE4.1
`roundsd`, which gives the same bits. The DLL keeps such a routine original if the import slot
does not hold msvcr71's own function.

### Float results between translated routines

A translated routine whose every return leaves one value on the FPU stack gets a second entry
that returns it in `xmm0`. Translated callers call that entry, so the value never passes through
the x87 stack. The DLL installs a caller only together with its callees.

### Everything else

- Integer instructions are copied unchanged.
- x87 code leaves the CPU flags alone, and the surrounding integer code expects that. Translated
  code changes them only where nothing reads them afterwards: at a status word read (flow
  analysis proves it, or the flags are saved and restored), at a call to the float-to-integer
  helper and on entry to the routine.
- Calls into other client routines, absolute addresses and switch tables are adjusted at load
  time to wherever `client.dll` sits in memory.

### What it refuses

The translator refuses anything it cannot prove safe, and the routine then stays as it is:

- code that reads or changes the FPU control word.
- FPU stacks deeper than six.
- routines that take arguments on the FPU stack.
- routines that other code jumps into the middle of.
- a jump, call or return with a prefix in front of it.

## The routine list

`translator/routines.list` names the routines to translate: start, limit, profile weight, length
and a hash. The hash is FNV-1a over the routine with address fields left out. The list contains
no game code. It was built from sampling profiles of the game. A routine is translated only if
its code matches the hash.

The line `ftol 6a92d8 75 401dfa8ffc792418` names the compiler's float-to-integer helper, with
its length and hash.

The head of the list describes the format. That text is `LIST_HEAD` in `translator/xlat.py`,
which `--write-list` puts at the head of every list it writes. A line that does not fit the
format stops the run.

## Hand-written replacements

Four routines are replaced by code written for them:

| Routine | Replacement |
|---|---|
| `0x45E10`, 4×4 matrix multiply | hand-written SSE in the DLL |
| `0x46510`, quaternion to rotation matrix | hand-written SSE in the DLL |
| `0x6A92D8`, `_ftol2` | written out by `xlat.py`: handles the 32-bit range with SSE2, falls back to the original otherwise |
| `msvcr71!sqrt` (import slot `0x8682AC`) | `MxoSqrtSSE` in the DLL, below |

The two matrix routines are not on the routine list. The DLL recognises them by position,
length and hash, and installs them together with the translated routines. A game add-on that
names an address inside one keeps it original, and `x87max.txt` counts them after the
translated routines. Unlike a translation they make no assumption about the FPU setup, so they
run on every thread. No test in `tests/` covers them.

**`sqrt`.** Wine implements `msvcr71!sqrt` with the x87 `fsqrt`: about 500 ns per call under
Rosetta, 3% of the main thread. The client's import now points at an SSE2 version (about 50 ns)
that gives the same bits. It computes only when the thread runs at 24-bit or 53-bit precision
with rounding to nearest, the input is positive and finite, and (at 24 bits) the result is a
normal float that does not sit exactly halfway between two floats. Anything else goes to Wine's
`sqrt`. `DXVK_MXO_SQRT=0` turns it off.

## At run time

When the game creates its Direct3D device, the DLL:

1. checks each routine in the loaded `client.dll` byte for byte against the code its replacement
   was generated from, and skips any that differ (for example because a wrapper has hooked it).
2. skips routines whose `floor`/`ceil` import slot is not msvcr71's, and callers whose callees
   were skipped.
3. pins itself, so that nothing can unload it while `client.dll` jumps into it.
4. pauses all other threads, writes a 5-byte jump at the start of each remaining routine, and
   resumes them. A routine that a thread is just entering is left out.
5. on every frame checks that the FPU control word is still what the translation assumes
   (24-bit precision, round to nearest) and switches the replacements off if it is not.

The log names every routine it left alone and why: its code in memory differs, an add-on uses
it, a routine it calls was left alone, a thread was entering it, or its code could not be made
writable.

The replacements run only on the thread that owns the Direct3D device. Other threads have a
different FPU precision, so for them the jump leads to a few instructions that do what the jump
overwrote and then continue in the original routine.

Installed in the last sessions: 534 of 536 in Revived. In Rejacked 535 of 538, taken while the
two matrix routines were still on the list. Without them that should read 535 of 536, which has
not been looked at in the game yet. The exceptions are listed in
[client-notes.md](client-notes.md#routines-something-else-has-changed).

## How it was checked

The test programs are in [`tests/`](../tests/README.md). They call a routine as original x87
code and as translation on the same input and compare everything it wrote, bit for bit.

| Check | Result |
|---|---|
| Synthetic routines for the instruction forms the translator handles, random inputs including huge, tiny, zero, infinite and NaN values, `--exact-range` | 10.8 million comparisons, all identical |
| Synthetic routines, faster rounding, ordinary values | 200,000 cases per routine, no differences |
| Synthetic routines, single precision against the double form | 3.3 million cases identical |
| The game's routines on random memory (taken with 468 routines, 278 could be run this way) | 20,504 comparisons. 262 routines identical in every run, 16 differed only in situations random input creates and the game does not |
| The 535 routines on random memory, with the `al` comparison | 284 could be run, 19,457 comparisons. 32 routines differ, 2 of them on ordinary values too (below) |
| The map routine `0x47DDB0` on plausible input | 100,000 calls, about 60,000 reach the result, all identical |
| The sort comparator `0x4859D0` on plausible input, its yes or no included | 100 calls, all identical |
| The translation of the 537 routines then on the list against the one before it | no differing line, with ordinary and with random input |
| The current translation of the 535 routines against that one | the same assembly text apart from label names, and the same bytes once assembled |
| `_ftol2` replacement | 400,000 values over the whole range, identical |
| `sqrt` replacement against Wine's, under seven FPU control words | 7 million cases, no differences |
| `roundsd` against Wine's `floor` and `ceil` | no differences |

The synthetic routines do not cover jump tables, the call to the float-to-integer helper and the
`floor` and `ceil` imports. Those need a PE image and are left to the game part.

The game part also compares `al`, the byte a `bool` comes back in, for the 266 routines whose
own integer code sets it before every return. On ordinary values 130 of them could be run:
34,761 comparisons, no difference. On random memory 168 could be run, and 2 of them differ, in
5 of 11,875 comparisons: `0x4D1F80` and `0x1B3B20`. The first difference of each is in a call
with huge values, infinities and NaNs among the input. `0x1B3B20` asks whether a point lies
within a radius, and its squared distances leave the `float` range there.

The differences that random input produces and the game does not:

- doubles too small or too large to occur in practice (denormal, or above 2^900).
- two NaNs meeting in one operation: x87 and SSE2 keep a different one.
- a called routine that fails to return a value it should have, which leaves different FPU
  stack bits in `eax`.
- an unused `ah` after a `bool` return, and whatever `eax` held after a float return.

With ordinary values only (`MXO_PLAIN=1`), two routines differ: `0x2FE4D0` and `0x2FE670`. Both
look a value up in a table of keys and interpolate. The table's floats start two bytes into a
word, so the test's ordinary values reach these routines as arbitrary bit patterns, and an
intermediate product then exceeds the `float` range. With a table as the game holds it they
are not tested.

## Translator switches

Environment variables for `xlat.py`, for finding a fault by elimination:

| Variable | Effect |
|---|---|
| `XLAT_NO_FUSE` | compares always rebuild the status word |
| `XLAT_NO_INLINE` | `floor` and `ceil` stay calls |
| `XLAT_NO_XR` | no `xmm0` return entries |
| `XLAT_NO_COMISS` | floats are widened to double before a compare |

The DLL's own switches are in [building.md](building.md#switches).
