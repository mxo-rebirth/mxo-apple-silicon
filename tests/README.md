# Tests

Two differential tests, both in one small Windows program that runs under Wine. Each calls a
routine as original x87 code and as its SSE2 translation on the same random input and compares
everything the routine wrote, bit for bit.

| Part | Compares |
|---|---|
| synthetic | hand-written x87 routines in `synth.s` that cover every instruction form the translator handles, including the path other threads take through the stub back into the original |
| game | the translated routines of `client.dll` against the originals in your `client.dll`, plus the float-to-integer helper |

## Build

From the repository root, after `scripts/build.sh` has run once (it leaves `build/client.map`):

```sh
cd tests
i686-w64-mingw32-as synth.s -o synth.o
i686-w64-mingw32-objcopy -O binary -j .text synth.o synth.bin
i686-w64-mingw32-nm -n synth.o | python3 -c '
import sys
s = {n: int(a, 16) for a, t, n in (l.split() for l in sys.stdin) if n.startswith("_t")}
print(" ".join("%x-%x" % (s[n], s[n + "_end"]) for n in s if not n.endswith("_end")))' > synth.ranges

python3 ../translator/xlat.py flat synth.bin XT xt_synth.inc $(cat synth.ranges)
python3 ../translator/xlat.py pe /path/to/client.dll MxoX out_game.inc \
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

The synthetic part must report zero mismatches.

With `MXO_PLAIN=1` the game part fills the scratch area with ordinary float values only (no integers,
pointers, huge or tiny numbers). The translation keeps values in the float range, so on such input it
must match the original exactly: any routine listed as different is a translation fault. Fewer routines
run to completion that way, because many need pointers to work on.

The game part calls each routine blind: random floats, a few small integers and pointers into a
scratch area, with no idea what the routine expects. Many routines crash on that (in both
versions, which is caught and not counted) and some block; each batch runs in its own process
so one stuck routine does not stop the rest. Results go to `fuzz.txt` in the current folder.
What matters is the list of routines where the two versions *differ*. On the reference
`client.dll` the differences that remain all come from the garbage input:

- the double-precision helpers at `0xDE70`, `0xDEB0`, `0xDEF0`, `0x66EBF0`, `0x66ED40` differ
  when random bit patterns are read as doubles and happen to be denormal or larger than 2^900;
  on ordinary values they are identical;
- `eax` left over from `fnstsw ax` can differ in the bits that report the FPU stack pointer
  when a callee that should have returned a float did not;
- when two NaNs meet, x87 and SSE2 keep a different one.
