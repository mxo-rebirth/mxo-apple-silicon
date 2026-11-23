# Tests

Two differential tests, both in one small Windows program that runs under Wine. Each calls a
routine as original x87 code and as its SSE2 translation on the same random input and compares
everything the routine wrote, bit for bit. Any NaN counts as equal to any other NaN. An infinity
equals only itself.

| Part | Compares |
|---|---|
| synthetic | hand-written x87 routines in `synth.s` for the instruction forms the translator handles, a jump out of a routine in its short and its long form, and the path other threads take through the stub back into the original. Three things need a PE image and are left to the game part: jump tables, the call to the float-to-integer helper, and the `floor` and `ceil` imports |
| game | the translated routines of `client.dll` against the originals in your `client.dll`, plus the float-to-integer helper |

## Build

From the repository root, after `scripts/build.sh` has run once (it leaves `build/client.map`):

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

## Run

Copy `xtest.exe` into the bottle and run it with CrossOver's `wine`:

```sh
wine --bottle MatrixOnline -- 'C:\somewhere\xtest.exe' 200000          # synthetic part, 200000 cases per routine
MXO_CLIENT_DLL='C:\Games\MxO\client.dll' \
wine --bottle MatrixOnline -- 'C:\somewhere\xtest.exe' 100 game        # game routines, 100 cases each
```

`xtest.exe <iterations> synth` runs only the synthetic part. Run one test program at a time per folder:
the game part writes `fuzz.txt` in the current folder. Without `-DWITH_GAME` the program holds the
synthetic part alone and needs no `out_game.inc`.

The synthetic part runs three passes. With ordinary inputs and on the other-thread path it must report
zero mismatches. The pass with huge, tiny, zero, infinite and NaN inputs reports zero only for a
translation made with `--exact-range`. The default, faster form differs there where a value leaves the
float range ([docs/translator.md](../docs/translator.md#rounding)), and its counts must not change from one translator version to the
next. A translated caller reaches the translation of its callee directly, so such a difference in a
callee shows in its callers too. After the passes the program prints the time per call of eight of the
routines, as x87 code and as translation.

With `MXO_PLAIN=1` the game part fills the scratch area with ordinary float values only (no integers,
pointers, huge or tiny numbers). The translation keeps values in the float range, so on such input it
must match the original exactly: any routine listed as different is a translation fault. Fewer routines
run to completion that way, because many need pointers to work on. Two routines are the exception,
`0x2FE4D0` and `0x2FE670`: they read a table of floats that starts two bytes into a word, so the ordinary
values reach them as arbitrary bit patterns. `MXO_SHAPE=1` gives them a proper table, and on that they
must match too.

With `MXO_SHAPE=1` some routines get plausible input instead of random memory, because random memory
rarely gets far into them. So far that is the map routine at `0x47DDB0` (world position to map grid
cell): a map object with sane bounds, grid size and cell size, and positions mostly inside the map. The
`reached=` count in `fuzz.txt` says how many calls got all the way to the result. The sort comparator at
`0x4859D0` gets two elements with boxes and a direction in the image's globals. Those globals are put back
to what the image holds before the next routine runs. The three routines that look a value up in a table
of keys (`0x2FE4D0`, `0x2FE560`, `0x2FE670`) get a table with rising times, a time that mostly lies between
two keys and a weight from 0 to 1. For them `reached=` counts the calls with a time between two keys.

The image is loaded without its imports. Originals that call msvcr71's `floor` or `ceil` would crash
where their translations compute the result in place, so those two import slots get the real functions.
The translator's table (`MxoX_crtslots`) says where they are.

The game part calls each routine blind: random floats, a few small integers and pointers into a
scratch area, with no idea what the routine expects. Many routines crash on that (in both
versions, which is caught and not counted) and some block. Each batch runs in its own process
so one stuck routine does not stop the rest. Results go to `fuzz.txt` in the current folder.
What matters is the list of routines where the two versions *differ*.

Of `eax` the low byte, `al`, is compared and counted for the routines where the translator can tell
that the routine's own integer code sets it before every return. That is the byte a `bool` comes back
in. The last column of `out_game.inc.tests` says which routines those are, and their line in `fuzz.txt`
has `al=` with the number of differences (`al=-1` where `al` is not compared). Differences in the other
three bytes are listed as `eax=` and summed up in the last line of the run, but not counted: after a
status word read they hold other bits than the translation leaves there.

On the reference `client.dll` the differences that remain all come from the garbage input:

- the double-precision helpers at `0xDE70`, `0xDEB0`, `0xDEF0`, `0x66EBF0`, `0x66ED40` differ
  when random bit patterns are read as doubles and happen to be denormal or larger than 2^900.
  on ordinary values they are identical.
- `eax` left over from `fnstsw ax` can differ in the bits that report the FPU stack pointer
  when a callee that should have returned a float did not.
- when two NaNs meet, x87 and SSE2 keep a different one.
- a routine that returns a `bool` in `al` can leave a different `ah` (the status word is no longer put
  into `ax` where nothing reads it), and a routine that returns a float leaves whatever `eax` held.

## sqrt

`sqrt_test.cpp` checks the replacement for the game's `MSVCR71!sqrt` import (`MxoSqrtSSE`) against
Wine's own `sqrt`: random and edge-case inputs, values whose root lies exactly halfway between two
floats, under seven FPU control words. It must report zero differences. It also prints the time per
call of both (about 500 ns for Wine's x87 version under Rosetta, about 50 ns for the replacement).

## floor and ceil

`floor_test.cpp` checks that SSE4.1 `roundsd`, which the translator puts in place of calls to msvcr71's
`floor` and `ceil`, gives the same bits as Wine's functions after the x87 round trip the original caller
makes (NaNs, infinities, zeros, denormals and values around 2^52 included). It must report zero differences.
