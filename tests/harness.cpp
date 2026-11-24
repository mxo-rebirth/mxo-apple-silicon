// Differential test: original x87 code against its SSE2 translation, bit for bit.
#include <windows.h>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>

#include "mxo_x87_apply.h"
#include "mxo_lights.h"
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
  void t12(); void t13(); void t14(); void t15(); void t15b(); void t16();
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

// FPU control words. The game's is what Direct3D 9 sets: 24-bit precision, round to nearest, exceptions masked
static const uint32_t CwGame = 0x007f;
static const uint32_t Cw53 = 0x027f;   // 53-bit precision, what a Windows thread starts with
static const uint32_t FpuEmpty = 0xffff;   // the FPU tag word with all eight registers empty

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

// The high half of a double infinity has the bits of a float NaN. It is told apart by the zero low half before it
static bool infHigh(const uint32_t* v, size_t i) { return i > 0 && (v[i] & 0x7fffffff) == 0x7ff00000 && v[i - 1] == 0; }

// Any NaN equals any NaN, as a float and as the high half of a double. An infinity equals only itself.
static int diff(const void* a, const void* b, size_t size, size_t* where) {
  const uint32_t* x = (const uint32_t*)a; const uint32_t* y = (const uint32_t*)b;
  for (size_t i = 0; i < size / 4; i++) {
    if (x[i] == y[i]) continue;
    if (isnanf(x[i]) && isnanf(y[i]) && !infHigh(x, i) && !infHigh(y, i)) continue;
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
    // the same FPU state before every call: on a huge value a routine can pop an empty stack (fptan pushes
    // nothing then), which moves the stack pointer, and that shows in later status words
    fpu_setcw(CwGame);
    xcall((void*)fn, 0, args, 2, fpret ? &ra : nullptr);
    uint32_t tagsOriginal = fpu_tags();
    args[1] = uint32_t(uintptr_t(&b));
    fpu_setcw(CwGame);
    xcall(f->replacement, 0, args, 2, fpret ? &rb : nullptr);
    uint32_t tagsTranslated = fpu_tags();
    if (tagsOriginal != FpuEmpty || tagsTranslated != FpuEmpty) {
      if (!stackbad++) printf("%-6s FPU stack not empty: orig %04x xlat %04x\n", name, tagsOriginal, tagsTranslated);
      fpu_setcw(CwGame);
    }
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


static const int BenchCalls = 1000000;

// Only for routines that return nothing on the FPU stack
static void benchSynth(const char* name, void (*fn)(), int calls) {
  fpu_setcw(CwGame);
  MxoXFunc* f = findFunc(XT_funcs, uint32_t((uint8_t*)fn - synth_begin));
  if (!f) return;
  g_specials = 0;
  In in; Out out;
  for (int k = 0; k < 16; k++) in.f[k] = rndf();
  for (int k = 0; k < 4; k++) { in.i[k] = int32_t(rnd32() % 2001) - 1000; in.d[k] = rndf(); }
  in.w[0] = 5; in.w[1] = 7; in.q = 123456789;
  uint32_t args[2] = { uint32_t(uintptr_t(&in)), uint32_t(uintptr_t(&out)) };
  LARGE_INTEGER q0, q1, q2, fq; QueryPerformanceFrequency(&fq);
  QueryPerformanceCounter(&q0);
  for (int k = 0; k < calls; k++) xcall((void*)fn, 0, args, 2, nullptr);
  QueryPerformanceCounter(&q1);
  for (int k = 0; k < calls; k++) xcall(f->replacement, 0, args, 2, nullptr);
  QueryPerformanceCounter(&q2);
  double a = double(q1.QuadPart - q0.QuadPart) * 1e9 / double(fq.QuadPart) / calls;
  double b = double(q2.QuadPart - q1.QuadPart) * 1e9 / double(fq.QuadPart) / calls;
  fpu_setcw(Cw53);   // printf rounds the digits of a double with FPU arithmetic, which 24-bit precision spoils
  printf("%-6s x87 %7.1f ns/call   SSE2 %7.1f ns/call   %.1fx\n", name, a, b, a / b);
  fpu_setcw(CwGame);
}

// The light filter against a plain reading, in double precision, of what the game's light loop decides:
// it may leave out no light the loop would keep.
static int lightFilterCheck(int cases) {
  const uint32_t base = 0x10000000;   // stands for where client.dll is loaded: the filter only compares with it
  uint32_t known[16] = {}, other[16] = {};
  known[MxoLightReachSlot / 4] = base + MxoLightReachRva;
  other[MxoLightReachSlot / 4] = base + MxoLightReachRva + 4;
  uint8_t object[0x40], light[0x40], part[0x50];
  auto put = [] (uint8_t* at, float v) { memcpy(at, &v, 4); };
  int leftOut = 0, wrong = 0, passedOn = 0;
  g_specials = 0;
  for (int k = 0; k < cases; k++) {
    float low[3], size[3], pos[3];
    for (int axis = 0; axis < 3; axis++) {
      low[axis] = rndf();
      size[axis] = rnd32() % 30 ? float(rnd32() % 6000) / 100.0f : -float(rnd32() % 100);
      put(object + MxoBoxMinOffset + 4 * axis, low[axis]);
      put(object + MxoBoxMaxOffset + 4 * axis, low[axis] + size[axis]);
    }
    const MxoLightBox box = MxoLightBoxOf(object);
    float reach = float(rnd32() % 15000) / 100.0f;
    if (rnd32() % 30 == 0) reach = rnd32() % 2 ? -reach : 0.0f;
    const bool hasPart = rnd32() % 10 != 0, isKnown = rnd32() % 8 != 0;
    const uint32_t where = rnd32() % 4;
    for (int axis = 0; axis < 3; axis++) {
      pos[axis] = box.middle[axis] + float(int32_t(rnd32() % 60001) - 30000) / 100.0f;
      if (where == 0) pos[axis] = box.middle[axis] + box.extent[axis] * (float(rnd32() % 2001) / 1000.0f - 1.0f);
    }
    if (where <= 1) {   // about as far from one side as the reach goes
      const int axis = int(rnd32() % 3);
      pos[axis] = box.middle[axis] + (rnd32() % 2 ? 1.0f : -1.0f) * (box.extent[axis] + reach * (0.97f + float(rnd32() % 61) / 1000.0f));
    }
    const uint32_t table = uint32_t(uintptr_t(isKnown ? known : other)), partAt = hasPart ? uint32_t(uintptr_t(part)) : 0;
    memcpy(light, &table, 4);
    memcpy(light + MxoLightPartOffset, &partAt, 4);
    for (int axis = 0; axis < 3; axis++) put(light + MxoLightPosOffset + 4 * axis, pos[axis]);
    put(part + MxoPartReachOffset, reach);

    // the loop's decision, from the box as the loop rounds it
    const double r = hasPart ? double(reach) : 0.0;
    double distance = 0.0;
    for (int axis = 0; axis < 3; axis++) {
      const double offset = double(pos[axis]) - double(box.middle[axis]), extent = double(box.extent[axis]);
      if (offset < -extent) distance += (offset + extent) * (offset + extent);
      else if (offset > extent) distance += (offset - extent) * (offset - extent);
    }
    const bool loopDrops = r * r < distance;
    const bool out = MxoLightOutOfReach(box, light, base);
    if (out) leftOut++;
    if (out && (!loopDrops || !isKnown)) wrong++;
    if (!out && loopDrops && isKnown) passedOn++;
  }
  printf("== light filter: %d lights, %d left out, %d of them wrongly, %d passed on that the loop drops\n", cases, leftOut, wrong, passedOn);
  return wrong;
}

#ifdef WITH_GAME
#include "game_tests.inc"
#endif

int main(int argc, char** argv) {
  int iterations = argc > 1 ? atoi(argv[1]) : 200000;
  int bad = 0;
  setvbuf(stdout, nullptr, _IONBF, 0);
#ifdef WITH_GAME
  if (argc > 4 && !strcmp(argv[2], "child")) { g_plain = getenv("MXO_PLAIN") && *getenv("MXO_PLAIN"); fpu_setcw(CwGame); return runGameChild(iterations, atoi(argv[3]), atoi(argv[4])); }
#endif
  const bool synthOnly = argc > 2 && !strcmp(argv[2], "synth");
  if (argc > 2 && !synthOnly) goto game;   // any other second argument: skip the synthetic part
  fpu_setcw(CwGame);
  if (!MxoXFixups(synth_begin, XT_imagebase, XT_absfix, XT_relfix, XT_code_begin, XT_code_end)) { printf("fixups failed\n"); return 2; }
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
    bad += runSynth("t12", t12, false, iterations);
    bad += runSynth("t13", t13, false, iterations);
    bad += runSynth("t14", t14, false, iterations);
    bad += runSynth("t15", t15, false, iterations);
    bad += runSynth("t15b", t15b, false, iterations);
    bad += runSynth("t16", t16, false, iterations);
  }
  XT_tid = GetCurrentThreadId();
  bad += lightFilterCheck(iterations);
  printf("== speed, FPU control word %04x (24-bit precision)\n", CwGame);
  benchSynth("t1", t1, BenchCalls); benchSynth("t2", t2, BenchCalls); benchSynth("t3", t3, BenchCalls); benchSynth("t4", t4, BenchCalls);
  benchSynth("t5", t5, BenchCalls); benchSynth("t6", t6, BenchCalls); benchSynth("t9", t9, BenchCalls); benchSynth("t10", t10, BenchCalls);
  fpu_setcw(CwGame);
  if (synthOnly) { printf("TOTAL problems: %d\n", bad); return bad ? 1 : 0; }
game:
#ifdef WITH_GAME
  fpu_setcw(CwGame);
  bad += runGame(iterations);
#endif
  printf("TOTAL problems: %d\n", bad);
  return bad ? 1 : 0;
}
