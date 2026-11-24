# The x87 to SSE2 translator

The game does its float math with x87 instructions, the floating-point unit (FPU) of old x86
CPUs. Rosetta 2 emulates each x87 instruction in software, at about 25 ns, and 80–90% of the
game's main thread was x87 math ([client-notes.md](client-notes.md)).

`translator/xlat.py` reads a routine of `client.dll` and writes SSE2 assembly that does the same.
SSE2 is the newer x86 instruction set for float math. The DLL carries the result and swaps it in
for the original at startup. On their own, translated routines run 5 to 120 times faster.

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

The x87 registers form a stack. Its depth at each instruction is known in advance, so each stack
slot gets a fixed SSE register. `xmm6` and `xmm7` are scratch.

### Rounding

Direct3D 9 puts the FPU in 24-bit precision mode. Every add, subtract, multiply, divide and
square root is then rounded to 24 significant bits, the precision of a `float`. The FPU can still
hold far larger and smaller numbers than a `float` can.

The translation computes in double precision and rounds each result by converting it to `float`
and back (two instructions). **That is exact as long as both operands have at most 24 significant
bits and the result fits in a `float`.** Every `float` and every earlier result has 24 bits.

Where it differs from the FPU:

- A value above `FLT_MAX` becomes infinity, where the FPU keeps it. Bounding-box code uses values
  like `FLT_MAX` to mean "no limit", so this is a real trade-off.
- A value below the smallest normal `float` loses precision.
- An operand with more bits (a double from memory, a 32-bit integer, the constant π) makes the
  result be rounded twice: first to a double, then to 24 bits. When the exact result lies almost
  halfway between two floats, the last bit can differ. This is rare, and `--exact-range` does not
  change it.

`xlat.py --exact-range` reproduces the FPU's larger range bit for bit, at 13 instructions per
rounding instead of 2. The game has been played with the faster form without visible problems.
If something looks wrong, build with `--exact-range` first.

### Single precision

In the faster form, a value loaded from a `float`, or computed from two such values, stays a
`float` in the low lane of its SSE register. It is computed with single-precision instructions
(`addps`, `mulps`, `divss`, `sqrtss`, `ucomiss`, `cvttss2si`). A value becomes a double only when
it meets a double operand, and at branches, labels and returns, where every register holds a
double again.

This gives the same bits as computing in double and rounding, because a 24-bit result rounded
again to 24 bits does not change. Two floats are compared as floats: widening both to double
changes neither their order nor whether one is a NaN (not a number).

One difference from the x87 that the tests cannot see, because they treat every NaN as equal: a
signalling NaN loaded from a `float` and stored again keeps its bits. The x87 would turn it into a
quiet NaN.

### Compares

The original compares, copies the FPU status word to `ax` (`fnstsw ax`), tests bits of `ah` and
jumps. Rebuilding that status word from an SSE compare takes `lahf` and the parity flag, which
Rosetta computes in software.

So where the code only tests the three condition bits of `ah` and jumps, the translation branches
on the SSE compare itself. Flow analysis, following jumps, must show that neither the flags nor
the status word in `ax` are read again before they are overwritten. FPU register moves between
`fnstsw` and `test` are allowed. A test of any other bit of `ah` (the FPU stack pointer) keeps the
full status word.

Everywhere else a compare followed by `fnstsw ax` puts the same condition bits in `ah` as the
original. A routine that returns a `bool` in `al` may return a different `ah`, which nothing uses.

### `floor` and `ceil`

Calls to msvcr71's `floor` and `ceil` through the import table are computed in place with SSE4.1
`roundsd`, which gives the same bits.

### Float results between translated routines

A translated routine whose every return leaves one value on the FPU stack gets a second entry
that returns it in `xmm0`. Translated callers call that entry, so the value never passes through
the x87 stack.

### Everything else

- Integer instructions are copied unchanged.
- x87 code leaves the CPU flags alone, and the integer code around it expects that. Translated
  code changes them only where nothing reads them afterwards: at a status word read (flow
  analysis proves it, or the flags are saved and restored), at a call to the float-to-integer
  helper and on entry to the routine.
- Calls into other client routines, absolute addresses and switch tables are adjusted at load
  time to wherever `client.dll` sits in memory.

### What it refuses

The translator refuses anything it cannot prove safe, and the routine then stays as it is. For
example:

- code that reads or changes the FPU control word
- FPU stacks deeper than six
- routines that take arguments on the FPU stack
- routines that other code jumps into the middle of
- a jump, call, return or x87 instruction with a prefix in front of it
- a read of the status word after a sine, cosine or tangent, which set a status bit of their own
- code that reads or changes the SSE control register, or uses MMX or SSE already

## The routine list

`translator/routines.list` names the routines to translate, one per line: start, limit, profile
weight, length and hash. The hash is FNV-1a over the routine's code with the address fields left
out. A routine is translated only if its code matches the hash. The list holds no game code. It
is built from sampling profiles of the game
([development.md](development.md#profiling-and-adding-routines)).

The line `ftol 6a92d8 75 401dfa8ffc792418` names the compiler's float-to-integer helper, with its
length and hash.

The head of the list describes the format. That text is `LIST_HEAD` in `translator/xlat.py`, and
`--write-list` writes it at the head of every list. A line that does not fit the format stops the
run.

## Hand-written replacements

Four routines are replaced by code written for them:

| Routine | Replacement |
|---|---|
| `0x45E10`, 4×4 matrix multiply | hand-written SSE in the DLL |
| `0x46510`, quaternion to rotation matrix | hand-written SSE in the DLL |
| `0x6A92D8`, `_ftol2` | written out by `xlat.py`: SSE2 in the 32-bit range, the original otherwise |
| `msvcr71!sqrt` (import slot `0x8682AC`) | `MxoSqrtSSE` in the DLL, below |

The `_ftol2` replacement reads the value as a double. A value that takes more than 53 bits and
lies just below a whole number converts to that number, where the original gives the one below.
Only a function result, such as a cosine, converted without any arithmetic in between can be such
a value: the game's arithmetic runs at 24 bits. Not seen in the tests, which feed it doubles.

The two matrix routines are not on the routine list. The DLL recognises them by position, length
and hash (`MxoXCodeHash`) and installs them with the translated routines. A game add-on that names
an address inside one keeps it original, and `x87max.txt` counts them after the translated
routines. They make no assumption about the FPU setup, so they run on every thread. No test in
`tests/` covers them.

**`sqrt`.** Wine implements `msvcr71!sqrt` with the x87 `fsqrt`: about 500 ns per call under
Rosetta, 3% of the main thread. The client's import slot points at an SSE2 version instead (about
50 ns) that gives the same bits. It computes the result itself only when:

- the thread runs at 24-bit or 53-bit precision with rounding to nearest
- the input is positive and finite
- at 24 bits, the result is a normal float that does not sit exactly halfway between two floats

Anything else goes to Wine's `sqrt`. `DXVK_MXO_SQRT=0` turns it off.

**The light filter.** The routine at `0x48FA40` chooses the projector lights for one object. For
every light in the scene it makes three calls through the light's table of functions and one to a
distance routine, then compares the light's reach with the distance to the object's box. At night
among many characters that was 27 to 31% of the main thread.

The DLL enters the routine through a filter (`translator/mxo_lights.h`). It works out the same
distance from the same fields and leaves out every light whose squared reach, plus 1%, is below
it. The routine decides each remaining light itself. Its result is the same, because the calls it
no longer makes only read the light.

A light of an unknown kind (told by the reach function in its table) or with a reach that is not
a number always goes to the routine. An axis on which the position or the box is not a number
adds nothing to the distance, as in the routine. With more than 256 lights in reach of one object
the routine gets the whole list. The list itself can have any length.

The filter is used only when the routine's translation is installed and the game code it relies
on is the known one: the two functions that return a light's reach match their hashes, a light
without the part that holds the reach has reach 0, and the routine scales the box by 0.75. No game
add-on may name an address inside those two functions, since the filter reads the reach itself
(`DXVK_MXO_RESPECT_ADDONS=0` lifts this, as for the routines).

The log says `light filter on`, or why it is off. `DXVK_MXO_LIGHT_FILTER=0` turns it off. With
`debug.flag` the log gets a `LIGHTS` line every five seconds ([development.md](development.md#diagnostics)).

Measured in a crowd at night ([measurements.md](measurements.md#in-a-crowd)): the filter looked at
40,000 to 160,000 lights per frame and passed on 80 to 180. The light loop went from 27 to 31% of
the main thread to under 1%, and the filter itself takes 1 to 3%.

## At run time

When the game creates its Direct3D device, the DLL:

1. compares each routine in the loaded `client.dll` byte for byte with the code its replacement
   was made from, and skips any that differ (for example because a wrapper has hooked it)
2. skips routines that compute `floor` or `ceil` in place if the import slot does not hold
   msvcr71's own function, and callers whose callees were skipped
3. pins itself in memory, so that nothing can unload it while `client.dll` jumps into it
4. pauses all other threads, writes a 5-byte jump at the start of each remaining routine, and
   resumes them. A routine that a thread is just entering is left out.
5. checks, at once and then on every frame, that the FPU control word and the SSE control
   register (MXCSR) are what the translation assumes (24-bit precision, round to nearest,
   exceptions masked, no flushing to zero), and switches the translated routines off while they
   are not

The log names every routine it left alone and why: its code in memory differs, an add-on uses
it, a routine it calls was left alone, a thread was entering it, or its code could not be made
writable.

Translated routines run only on the thread that owns the Direct3D device. Other threads have a
different FPU precision, so for them the jump leads to a few instructions that do what the jump
overwrote and then continue in the original routine. The hand-written replacements run on every
thread.

Installed in the last sessions:

| Client | Installed |
|---|---|
| Revived | 534 of 536 |
| MxOEmu launcher (the `client.dll` Rejacked runs) | 535 of 536 |
| Rejacked | 535 of 538, counted while the two matrix routines were still on the list |

The exceptions are in [client-notes.md](client-notes.md#routines-something-else-has-changed).

## How it was checked

The test programs are in [`tests/`](../tests/README.md). They call a routine as original x87 code
and as translation on the same input and compare everything it wrote, bit for bit.

| Check | Result |
|---|---|
| Synthetic routines, `--exact-range`, random input with huge, tiny, zero, infinite and NaN values | 10.8 million comparisons, all identical |
| Synthetic routines, faster rounding, ordinary values | 200,000 cases per routine, no differences |
| Synthetic routines, single precision against the double form | 3.3 million cases, identical |
| The 535 routines on random memory, `al` included | 284 could run, 19,457 comparisons. 32 routines differ, 2 of them on ordinary values too (below) |
| Map routine `0x47DDB0`, plausible input | 100,000 calls, about 60,000 reach the result, all identical |
| Sort comparator `0x4859D0`, plausible input, its yes or no included | 100 calls, all identical |
| Key table routines `0x2FE4D0`, `0x2FE560`, `0x2FE670`, well-formed tables | 20,000 calls each, about 13,750 with a time between two keys, all identical |
| Translation of the 537 routines then on the list, against the one before it | no differing line, ordinary and random input |
| Current translation of the 535 routines, against that one | same assembly apart from label names, same bytes once assembled |
| `_ftol2` replacement | 400,000 values over the whole range, identical |
| Light filter against a plain reading of the light loop's decision, made-up lights | 200,000 lights, 150,282 left out, none wrongly |
| Light loop `0x48FA40`, plausible lists of up to 456 lights, ordinary values, translation alone and behind the filter | 20,000 calls, all identical both ways. The filter left a light out in 16,093 |
| The same with huge, tiny and NaN values among them | 33 of 20,000 calls differ, the same 33 with and without the filter: values that leave the `float` range |
| `sqrt` replacement against Wine's, under seven FPU control words | 7 million cases, no differences |
| `roundsd` against Wine's `floor` and `ceil` | no differences |

The synthetic routines do not cover jump tables, the call to the float-to-integer helper or the
`floor` and `ceil` imports. Those need a PE image (a Windows executable or DLL), so the game part
covers them.

**`al`**, the byte a `bool` comes back in, is compared for the 266 routines whose own integer code
sets it before every return. Ordinary values: 130 could run, 34,761 comparisons, no difference.
Random memory: 168 could run, and `0x4D1F80` and `0x1B3B20` differ in 5 of 11,875 comparisons,
first in a call with huge values, infinities and NaNs among the input. `0x1B3B20` asks whether a
point lies within a radius, and its squared distances leave the `float` range there.

**Differences that random input causes and the game does not:**

- doubles too small or too large to occur in practice (denormal, or above 2^900)
- two NaNs meeting in one operation: x87 and SSE2 keep a different one
- a called routine that fails to return a value it should, which leaves different FPU stack bits
  in `eax`
- an unused `ah` after a `bool` return, and whatever `eax` held after a float return

**The two routines that differ on ordinary values** (`MXO_PLAIN=1`) are `0x2FE4D0` and
`0x2FE670`. Both look a value up in a table of keys and interpolate. The table's floats start two
bytes into a word, so ordinary test values reach them as arbitrary bit patterns, and an
intermediate product leaves the `float` range: the original returns a finite value, the
translation infinity. On a well-formed table (`MXO_SHAPE=1`) they match, as the table above shows.

## Translator switches

Environment variables for `xlat.py`, for finding a fault by switching one part off at a time:

| Variable | Effect |
|---|---|
| `XLAT_NO_FUSE` | compares always rebuild the status word |
| `XLAT_NO_INLINE` | `floor` and `ceil` stay calls |
| `XLAT_NO_XR` | no `xmm0` return entries |
| `XLAT_NO_COMISS` | floats are widened to double before a compare. Compares that set the processor flags themselves (`fcomi` and its relatives) are not changed by it |

The DLL's own switches are in [building.md](building.md#switches).
