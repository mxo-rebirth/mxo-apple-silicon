// Differential test: original x87 code against its SSE2 translation, bit for bit.
#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>

#include "mxo_x87_apply.h"
#include "xt_synth.inc"
#ifdef WITH_GAME
#include "out_game.inc"
#endif

extern "C" {
  extern uint8_t  synth_begin[];
  extern uint32_t XT_funcs[], XT_absfix[], XT_relfix[];
  extern uint8_t  XT_code_begin[], XT_code_end[];
  extern uint32_t XT_tid, XT_imagebase;
  void t1(); void t2(); void t3(); void t4(); void t5(); void t6(); void t7(); void t8(); void t8h(); void t9(); void t10(); void t11();
#ifdef WITH_GAME
  extern uint32_t MxoX_funcs[], MxoX_absfix[], MxoX_relfix[], MxoX_deps[], MxoX_crtslots[];
  extern uint8_t  MxoX_code_begin[], MxoX_code_end[];
  extern uint32_t MxoX_tid, MxoX_imagebase;
#endif
  // Calls fn with ecx and stack arguments (cdecl or stdcall), returns eax. *st0 receives the FPU result if not null
  uint32_t __cdecl xcall(void* fn, uint32_t ecx, const uint32_t* args, int nargs, double* st0);
  uint32_t __cdecl fpu_tags();
  void __cdecl fpu_setcw(uint32_t cw);
}

__asm__(
  ".intel_syntax noprefix\n"
  ".text\n"
  ".globl _xcall\n"
  "_xcall:\n"
  "push ebp\n mov ebp, esp\n push ebx\n push esi\n push edi\n"
  "mov esi, [ebp+16]\n mov ecx, [ebp+20]\n"
  "1: test ecx, ecx\n jz 2f\n dec ecx\n push dword ptr [esi+ecx*4]\n jmp 1b\n"
  "2: mov ecx, [ebp+12]\n mov edx, 0x11111111\n mov eax, 0x22222222\n mov ebx, 0x33333333\n mov esi, 0x44444444\n mov edi, 0x55555555\n"
  "call dword ptr [ebp+8]\n"
  "lea esp, [ebp-12]\n"
  "mov edx, [ebp+24]\n test edx, edx\n jz 3f\n fstp qword ptr [edx]\n"
  "3: pop edi\n pop esi\n pop ebx\n pop ebp\n ret\n"
  ".globl _fpu_tags\n"
  "_fpu_tags:\n"
  "sub esp, 28\n fnstenv [esp]\n movzx eax, word ptr [esp+8]\n fldenv [esp]\n add esp, 28\n ret\n"
  ".globl _fpu_setcw\n"
  "_fpu_setcw:\n"
  "fninit\n fldcw word ptr [esp+4]\n ret\n"
  ".att_syntax prefix\n"
);

static uint64_t g_seed = 0x9E3779B97F4A7C15ull;
static uint32_t rnd32() { g_seed ^= g_seed << 13; g_seed ^= g_seed >> 7; g_seed ^= g_seed << 17; return uint32_t(g_seed >> 16); }
static float    bitsf(uint32_t u) { float f; memcpy(&f, &u, 4); return f; }
static uint32_t fbits(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }

static int g_specials = 1;

static float rndf() {
  uint32_t r = rnd32() % 100;
  float u = float(int32_t(rnd32())) / 2147483648.0f;
  if (!g_specials || r < 72) return u * 10.0f;
  if (r < 80) return float(int32_t(rnd32() % 2001) - 1000) * 0.5f;
  if (r < 86) return u * 3.0e38f;
  if (r < 90) return u * 1.0e25f;
  if (r < 95) return u * 1.0e-25f;
  if (r < 96) return u * 2.0e-38f;
  if (r < 98) return (rnd32() & 1) ? 0.0f : -0.0f;
  if (r < 99) return (rnd32() & 1) ? bitsf(0x7f800000) : bitsf(0xff800000);
  return bitsf(0x7fc00000);
}

static bool isnanf(uint32_t u) { return (u & 0x7f800000) == 0x7f800000 && (u & 0x7fffff); }

// Compares two memory images dword by dword. Any NaN equals any NaN.
static int diff(const void* a, const void* b, size_t size, size_t* where) {
  const uint32_t* x = (const uint32_t*)a; const uint32_t* y = (const uint32_t*)b;
  for (size_t i = 0; i < size / 4; i++) {
    if (x[i] == y[i]) continue;
    if (isnanf(x[i]) && isnanf(y[i])) continue;
    // high half of a double NaN
    if ((x[i] & 0x7ff00000) == 0x7ff00000 && (y[i] & 0x7ff00000) == 0x7ff00000) continue;
    *where = i * 4; return 1;
  }
  return 0;
}

static MxoXFunc* findFunc(uint32_t* table, uint32_t rva) {
  for (MxoXFunc* f = (MxoXFunc*)table; f->size; f++)
    if (f->rva == rva) return f;
  return nullptr;
}

struct In  { float f[16]; int32_t i[4]; double d[4]; int16_t w[2]; int64_t q; } __attribute__((packed));
struct Out { float o[16]; double od[4]; int32_t oi[4]; int16_t ow[2]; int64_t oq; uint32_t pad[8]; } __attribute__((packed));

static int runSynth(const char* name, void (*fn)(), bool fpret, int iterations) {
  uint32_t rva = uint32_t((uint8_t*)fn - synth_begin);
  MxoXFunc* f = findFunc(XT_funcs, rva);
  if (!f) { printf("%-6s NOT TRANSLATED\n", name); return 1; }
  int bad = 0, stackbad = 0;
  for (int it = 0; it < iterations; it++) {
    In in;
    for (int k = 0; k < 16; k++) in.f[k] = (k && rnd32() % 12 == 0) ? in.f[k - 1] : rndf();
    for (int k = 0; k < 4; k++) in.i[k] = (rnd32() & 3) ? int32_t(rnd32() % 2001) - 1000 : int32_t(rnd32());
    for (int k = 0; k < 4; k++) in.d[k] = (rnd32() & 1) ? double(rndf()) : double(rndf()) * 1.0000001234567;
    if (rnd32() % 8 == 0) in.d[0] = double(in.f[7]);
    in.w[0] = int16_t(rnd32()); in.w[1] = int16_t(rnd32());
    in.q = (rnd32() & 1) ? int64_t(int32_t(rnd32())) : (int64_t(rnd32()) << 32 | rnd32());
    Out a, b; memset(&a, 0xA5, sizeof(a)); memset(&b, 0xA5, sizeof(b));
    double ra = 0, rb = 0;
    uint32_t args[2];
    args[0] = uint32_t(uintptr_t(&in)); args[1] = uint32_t(uintptr_t(&a));
    xcall((void*)fn, 0, args, 2, fpret ? &ra : nullptr);
    uint32_t t1 = fpu_tags();
    args[1] = uint32_t(uintptr_t(&b));
    xcall(f->replacement, 0, args, 2, fpret ? &rb : nullptr);
    uint32_t t2 = fpu_tags();
    if (t1 != 0xffff || t2 != 0xffff) { if (!stackbad++) printf("%-6s FPU stack not empty: orig %04x xlat %04x\n", name, t1, t2); fpu_setcw(0x007f); }
    size_t where = 0;
    if (diff(&a, &b, sizeof(a), &where) || diff(&ra, &rb, 8, &where)) {
      if (bad++ < 4) {
        printf("%-6s MISMATCH at out+%u: orig %08x xlat %08x (iteration %d)\n", name, unsigned(where),
          *(uint32_t*)((char*)&a + where), *(uint32_t*)((char*)&b + where), it);
        printf("        in.f:"); for (int k = 0; k < 16; k++) printf(" %08x", fbits(in.f[k])); printf("\n");
      }
    }
  }
  printf("%-6s %d cases, %d mismatches, %d stack errors\n", name, iterations, bad, stackbad);
  return bad + stackbad;
}


static uint32_t g_benchCw = 0x007f;
static void benchSynth(const char* name, void (*fn)(), int calls) {
  fpu_setcw(g_benchCw);
  MxoXFunc* f = findFunc(XT_funcs, uint32_t((uint8_t*)fn - synth_begin));
  if (!f) return;
  g_specials = 0;
  In in; Out out;
  for (int k = 0; k < 16; k++) in.f[k] = rndf();
  for (int k = 0; k < 4; k++) { in.i[k] = int32_t(rnd32() % 2001) - 1000; in.d[k] = rndf(); }
  in.w[0] = 5; in.w[1] = 7; in.q = 123456789;
  uint32_t args[2] = { uint32_t(uintptr_t(&in)), uint32_t(uintptr_t(&out)) };
  LARGE_INTEGER q0, q1, q2, fq; QueryPerformanceFrequency(&fq);
  double dummy;
  bool fp = fn == t8 || fn == t8h;
  QueryPerformanceCounter(&q0);
  for (int k = 0; k < calls; k++) xcall((void*)fn, 0, args, 2, fp ? &dummy : nullptr);
  QueryPerformanceCounter(&q1);
  for (int k = 0; k < calls; k++) xcall(f->replacement, 0, args, 2, fp ? &dummy : nullptr);
  QueryPerformanceCounter(&q2);
  double a = double(q1.QuadPart - q0.QuadPart) * 1e9 / double(fq.QuadPart) / calls;
  double b = double(q2.QuadPart - q1.QuadPart) * 1e9 / double(fq.QuadPart) / calls;
  fpu_setcw(0x027f);
  printf("%-6s x87 %7.1f ns/call   SSE2 %7.1f ns/call   %.1fx\n", name, a, b, a / b);
  fpu_setcw(0x007f);
}

#ifdef WITH_GAME
#include "game_tests.inc"
#endif

int main(int argc, char** argv) {
  int iterations = argc > 1 ? atoi(argv[1]) : 200000;
  int bad = 0;
  setvbuf(stdout, nullptr, _IONBF, 0);
#ifdef WITH_GAME
  if (argc > 4 && !strcmp(argv[2], "child")) { g_plain = argc > 5 || (getenv("MXO_PLAIN") && *getenv("MXO_PLAIN")); fpu_setcw(0x007f); return runGameChild(iterations, atoi(argv[3]), atoi(argv[4])); }
#endif
  const bool synthOnly = argc > 2 && !strcmp(argv[2], "synth");   // "synth": only the synthetic part
  if (argc > 2 && !synthOnly) goto game;   // any other second argument: skip the synthetic part
  fpu_setcw(0x007f);   // 24-bit precision, round to nearest, exceptions masked: what Direct3D 9 sets
  if (!MxoXFixups(synth_begin, 0x62000000, XT_absfix, XT_relfix, XT_code_begin, XT_code_end)) { printf("fixups failed\n"); return 2; }
  for (int pass = 0; pass < 3; pass++) {
    g_specials = pass != 0;
    // pass 2: pretend to be another thread, so every call must take the trampoline into the original code
    XT_tid = pass == 2 ? 1 : GetCurrentThreadId();
    printf("== synthetic, %s\n", pass == 2 ? "other-thread path (runs the original through the trampoline)" : g_specials ? "with huge/tiny/zero/inf/NaN inputs" : "ordinary inputs");
    bad += runSynth("t1", t1, false, iterations);
    bad += runSynth("t2", t2, false, iterations);
    bad += runSynth("t3", t3, false, iterations);
    bad += runSynth("t4", t4, false, iterations);
    bad += runSynth("t5", t5, false, iterations);
    bad += runSynth("t6", t6, false, iterations);
    bad += runSynth("t7", t7, false, iterations);
    bad += runSynth("t8h", t8h, true, iterations);
    bad += runSynth("t8", t8, true, iterations);
    bad += runSynth("t9", t9, false, iterations);
    bad += runSynth("t10", t10, false, iterations);
    bad += runSynth("t11", t11, false, iterations);
  }
  XT_tid = GetCurrentThreadId();
  for (int m = 0; m < 1; m++) {
  g_benchCw = m == 0 ? 0x007f : m == 1 ? 0x027f : 0x037f;
  printf("== speed, FPU control word %04x (%s precision)\n", g_benchCw, m == 0 ? "24-bit" : m == 1 ? "53-bit" : "64-bit");
  benchSynth("t1", t1, 1000000); benchSynth("t2", t2, 1000000); benchSynth("t3", t3, 1000000); benchSynth("t4", t4, 1000000);
  benchSynth("t5", t5, 1000000); benchSynth("t6", t6, 1000000); benchSynth("t9", t9, 1000000); benchSynth("t10", t10, 1000000);
  }
  fpu_setcw(0x007f);
  if (synthOnly) { printf("TOTAL problems: %d\n", bad); return bad ? 1 : 0; }
game:
#ifdef WITH_GAME
  fpu_setcw(0x007f);
  bad += runGame(iterations);
#endif
  printf("TOTAL problems: %d\n", bad);
  return bad ? 1 : 0;
}
