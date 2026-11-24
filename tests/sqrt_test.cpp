// Compares MxoSqrtSSE (src/d3d9/d3d9_mxo_fastmath_asm.inc of the patched DXVK) with the sqrt of Wine's msvcr71.dll,
// bit for bit, under several FPU control words. Build from the repository root after scripts/build.sh:
//   i686-w64-mingw32-g++ -O2 -msse2 -mfpmath=sse -static -I build/dxvk/src/d3d9 -o sqrt_test.exe tests/sqrt_test.cpp
// and run it in a bottle: wine --bottle <bottle> -- sqrt_test.exe 1000000
#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include "d3d9_mxo_fastmath_asm.inc"
typedef double (__cdecl *SqrtFn)(double);
static uint64_t g_seed = 0x243F6A8885A308D3ull;
static uint64_t rnd() { g_seed ^= g_seed << 13; g_seed ^= g_seed >> 7; g_seed ^= g_seed << 17; return g_seed; }
static void setcw(uint16_t cw) { __asm__ __volatile__("fldcw %0" : : "m"(cw)); }
static double fromBits(uint64_t b) { double d; memcpy(&d, &b, 8); return d; }
static uint64_t bits(double d) { uint64_t b; memcpy(&b, &d, 8); return b; }
int main(int argc, char** argv) {
  int n = argc > 1 ? atoi(argv[1]) : 1000000;
  HMODULE m = LoadLibraryA("msvcr71.dll");
  SqrtFn orig = (SqrtFn)GetProcAddress(m, "sqrt");
  if (!orig) { printf("no msvcr71 sqrt\n"); return 2; }
  MxoSqrtOriginal = (uint32_t)(uintptr_t)orig;
  SqrtFn mine = (SqrtFn)(void*)&MxoSqrtSSE;
  const uint16_t cws[] = { 0x007f, 0x027f, 0x037f, 0x0c7f, 0x047f, 0x087f, 0x0e7f };
  int bad = 0;
  for (uint16_t cw : cws) {
    int diffs = 0, mid = 0;
    for (int i = 0; i < n; i++) {
      double x;
      uint32_t kind = uint32_t(rnd() % 10);
      if (kind < 3) x = fromBits(rnd() & 0x7fffffffffffffffull);                           // any positive pattern incl. NaN/inf/denormal
      else if (kind < 5) { float f; uint32_t b = uint32_t(rnd()) & 0x7fffffff; memcpy(&f, &b, 4); x = f; }
      else if (kind < 8) {                                                                 // around squares of 24-bit midpoints
        uint64_t mm = (uint64_t(1) << 23) | (rnd() & 0x7fffff); mm = mm * 2 + 1;           // 25-bit odd: halfway between two 24-bit values
        double sq = double(mm) * double(mm);                                                // exact (at most 50 bits)
        int64_t k = int64_t(rnd() % 7) - 3;
        x = fromBits(bits(sq) + k);
        int e = int(rnd() % 200) - 100; x = x * fromBits(uint64_t(1023 + 2 * e) << 52);    // even power of two keeps it a midpoint square
        mid++;
      }
      else if (kind < 9) x = fromBits((uint64_t(0x380 + rnd() % 0x100) << 52) | (rnd() & 0xfffffffffffffull)); // float range edges
      else { const double sp[] = { 0.0, -0.0, -1.0, -1e-300, 1e-310, 4.9e-324, 1.0, 4.0, 3.4028234663852886e38, 1.1754943508222875e-38, 1e300 };
             x = sp[rnd() % 11]; }
      setcw(cw); double a = orig(x); setcw(0x027f);
      setcw(cw); double b = mine(x); setcw(0x027f);
      if (bits(a) != bits(b) && !(a != a && b != b && bits(a) == bits(b))) {
        if (diffs++ < 5) printf("  cw %04x x %016llx orig %016llx mine %016llx\n", cw, (unsigned long long)bits(x), (unsigned long long)bits(a), (unsigned long long)bits(b));
      }
    }
    printf("cw %04x: %d cases (%d near midpoint squares), %d differences\n", cw, n, mid, diffs);
    bad += diffs;
  }
  // speed at the game's setting
  double xs[1024]; for (int i = 0; i < 1024; i++) xs[i] = 1.0 + double(rnd() % 100000);
  for (int which = 0; which < 2; which++) {
    SqrtFn f = which ? mine : orig; volatile double sink = 0;
    LARGE_INTEGER q0, q1, fq; QueryPerformanceFrequency(&fq);
    setcw(0x007f); QueryPerformanceCounter(&q0);
    for (int r = 0; r < 2000; r++) for (int i = 0; i < 1024; i++) sink = f(xs[i]);
    QueryPerformanceCounter(&q1); setcw(0x027f);
    printf("%s: %.1f ns per call\n", which ? "MxoSqrtSSE" : "msvcr71 sqrt", double(q1.QuadPart - q0.QuadPart) * 1e9 / fq.QuadPart / (2000 * 1024));
  }
  printf("TOTAL differences: %d\n", bad);
  return bad != 0;
}
