# Tests

The tests check that the faster code gives the same results as the game's own code. One small
Windows program, run under Wine, calls each routine twice on the same random input: once as the
original x87 code and once as its SSE2 translation. It then compares everything the two wrote,
bit for bit. Any NaN counts as equal to any other NaN.

| Part | What it tests |
|---|---|
| synthetic | small hand-written routines in `synth.s`, one for each kind of instruction the translator handles |
| game | every translated routine of the game against the original in your `client.dll` |
| sqrt | the replacement for the game's `sqrt` (`sqrt_test.cpp`) |
| floor and ceil | the instruction that replaces the game's `floor` and `ceil` calls (`floor_test.cpp`) |

## Build

From the repository root, after `scripts/build.sh` has run once:

```sh
cd tests
i686-w64-mingw32-as synth.s -o synth.o
i686-w64-mingw32-objcopy -O binary -j .text synth.o synth.bin
i686-w64-mingw32-nm -n synth.o | python3 -I -c '
import sys
s = {n: int(a, 16) for a, t, n in (l.split() for l in sys.stdin) if n.startswith("_t")}
print(" ".join("%x-%x" % (s[n], s[n + "_end"]) for n in s if not n.endswith("_end")))' > synth.ranges

python3 -I ../translator/xlat.py flat synth.bin XT xt_synth.inc $(cat synth.ranges)
python3 -I ../translator/xlat.py pe /path/to/client.dll MxoX out_game.inc \
    --map ../build/client.map @../translator/routines.list

i686-w64-mingw32-g++ -O2 -msse2 -mfpmath=sse -static -fpermissive -w -DWITH_GAME \
    -I ../translator -o xtest.exe harness.cpp synth.o
```

Without `-DWITH_GAME` the program has only the synthetic part and needs no `out_game.inc`.

## Run

Copy `xtest.exe` into the bottle and run it with CrossOver's `wine`:

```sh
wine --bottle MatrixOnline -- 'C:\somewhere\xtest.exe' 200000 synth     # synthetic part, 200000 calls per routine
MXO_CLIENT_DLL='C:\Games\MxO\client.dll' \
wine --bottle MatrixOnline -- 'C:\somewhere\xtest.exe' 100 game        # game part, 100 calls per routine
```

The game part writes its results to `fuzz.txt` in the current folder, so run one test at a
time per folder.

## What a good result looks like

**Synthetic part:** zero differences with ordinary input. With extreme input (huge, tiny,
infinite, NaN) the default translation may differ where a value leaves the range of a `float`
([why](../docs/translator.md#rounding)). Those counts must not change between versions. Then
`left out ... wrongly` for the light filter must be 0.

**Game part:** it feeds each routine random memory, so many routines crash (in both versions,
which is not counted). What matters is the list of routines whose results differ. On random
input a few always do, because of the input, not the translation:

- the double-precision helpers `0xDE70`, `0xDEB0`, `0xDEF0`, `0x66EBF0`, `0x66ED40`, when
  random bits make extreme doubles
- when two NaNs meet, x87 and SSE2 keep a different one
- leftover bits in `eax` that nothing reads

For a strict check, set both `MXO_PLAIN=1` and `MXO_SHAPE=1`: then any difference is a fault.

**sqrt, floor and ceil:** zero differences.

## Switches

| Variable | Effect |
|---|---|
| `MXO_PLAIN=1` | ordinary float values only, no pointers or extreme numbers. Fewer routines get far, but those that do must match exactly. Two key-table routines (`0x2FE4D0`, `0x2FE670`) also need `MXO_SHAPE=1` for that |
| `MXO_SHAPE=1` | realistic input for the routines that random memory cannot reach: the map lookup, the sort, the key tables and the light loop. `reached=` in `fuzz.txt` counts the calls that got through |
| `MXO_LIGHT_FILTER=0` | test the light loop without the light filter |

The light loop is tested with filter and translation together, as the game runs them, and with
the translation alone. `lights-detail.txt` lists the first calls that differ.
