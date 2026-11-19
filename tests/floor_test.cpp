// Compares SSE4.1 roundsd (what the translator emits in place of msvcr71's floor and ceil) with the floor and
// ceil of Wine's msvcr71.dll, bit for bit, as the translated caller sees them: the original result travels
// through the x87 stack (fld in the runtime, fstp QWORD in the caller), roundsd's stays in an SSE register.
//   i686-w64-mingw32-g++ -O2 -msse4.1 -mfpmath=sse -static -o floor_test.exe tests/floor_test.cpp
// Run it in a bottle: wine --bottle <bottle> -- floor_test.exe 2000000
#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <smmintrin.h>
#include <initializer_list>
typedef double (__cdecl *Fn)(double);
static uint64_t g_seed = 0x9E3779B97F4A7C15ull;
static uint64_t rnd() { g_seed ^= g_seed << 13; g_seed ^= g_seed >> 7; g_seed ^= g_seed << 17; return g_seed; }
static void setcw(uint16_t cw) { __asm__ __volatile__("fldcw %0" : : "m"(cw)); }
static double fromBits(uint64_t b) { double d; memcpy(&d, &b, 8); return d; }
static uint64_t bits(double d) { uint64_t b; memcpy(&b, &d, 8); return b; }
int main(int argc, char** argv) {
  int n = argc > 1 ? atoi(argv[1]) : 1000000;
  HMODULE m = LoadLibraryA("msvcr71.dll");
  Fn fns[2] = { (Fn)GetProcAddress(m, "floor"), (Fn)GetProcAddress(m, "ceil") };
  const char* names[2] = { "floor", "ceil" };
  if (!fns[0] || !fns[1]) { printf("msvcr71 floor/ceil missing\n"); return 2; }
  int bad = 0;
  for (int f = 0; f < 2; f++) {
    for (uint16_t cw : { (uint16_t)0x007f, (uint16_t)0x027f, (uint16_t)0x037f }) {
      int diffs = 0;
      for (int i = 0; i < n; i++) {
        double x;
        switch (rnd() % 6) {
          case 0: x = fromBits(rnd()); break;                                                   // any pattern
          case 1: x = double(int64_t(rnd() % 2000001) - 1000000) / double(1 + rnd() % 64); break;
          case 2: x = double(int64_t(rnd() % 200001) - 100000) * 0.5; break;                   // halves and integers
          case 3: x = fromBits((uint64_t(rnd() % 2) << 63) | (uint64_t(1023 + rnd() % 60) << 52) | (rnd() & 0xfffffffffffffull));
                  break;                                                                        // around 2^52
          case 4: x = fromBits((uint64_t(rnd() % 2) << 63) | (rnd() & 0xfffffffffffffull)); break;   // denormal or zero
          default: { const double sp[] = { 0.0, -0.0, 0.5, -0.5, 1e300, -1e300, 4503599627370496.5, -0.9999999999999999 };
                     x = sp[rnd() % 8];
                     if (rnd() % 3 == 0) x = fromBits(rnd() % 2 ? 0x7ff0000000000000ull : 0xfff0000000000000ull);
                     if (rnd() % 5 == 0) x = fromBits(0x7ff0000000000001ull | (rnd() & 0x7ffffffffffffull) | (uint64_t(rnd() % 2) << 63));
                   }
        }
        setcw(cw);
        double a = fns[f](x);                          // through st0, then stored as a double
        setcw(0x027f);
        __m128d v = _mm_set_sd(x);
        double b = _mm_cvtsd_f64(f ? _mm_round_sd(v, v, 10) : _mm_round_sd(v, v, 9));
        if (bits(a) != bits(b)) {
          if (diffs++ < 5) printf("  %s cw %04x x %016llx runtime %016llx roundsd %016llx\n", names[f], cw,
            (unsigned long long)bits(x), (unsigned long long)bits(a), (unsigned long long)bits(b));
        }
      }
      printf("%s cw %04x: %d cases, %d differences\n", names[f], cw, n, diffs);
      bad += diffs;
    }
  }
  printf("TOTAL differences: %d\n", bad);
  return bad != 0;
}
