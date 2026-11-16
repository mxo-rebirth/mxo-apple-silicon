// Blind differential test of the translated game routines against the real client.dll.
// Each routine is called with random floats / pointers into a scratch arena, once as the original
// and once as the translation; the arena, the image's global data, eax and st0 must come out identical.
#include <csetjmp>
#include <emmintrin.h>

struct GameFn { uint32_t rva; int nargs; const char* kinds; bool thisPtr; bool fpret; bool framed; };

static const GameFn g_gameFns[] = {
#include "out_game.inc.tests"
};

static jmp_buf g_crashJmp;
static volatile int g_guard = 0;
static volatile DWORD g_callStart = 0;
static volatile HANDLE g_worker = nullptr;
static volatile LONG g_timeouts = 0;

static void timeoutStub() { g_guard = 0; longjmp(g_crashJmp, 2); }

// A call that spins for too long (random loop counts) is abandoned by redirecting the worker to timeoutStub
static DWORD WINAPI watchdog(void*) {
  for (;;) {
    Sleep(50);
    HANDLE w = g_worker;
    if (!w || !g_guard || GetTickCount() - g_callStart < 700) continue;
    SuspendThread(w);
    if (g_guard && GetTickCount() - g_callStart >= 700) {
      CONTEXT ctx; ctx.ContextFlags = CONTEXT_CONTROL;
      if (GetThreadContext(w, &ctx)) { ctx.Eip = DWORD(uintptr_t(&timeoutStub)); SetThreadContext(w, &ctx); InterlockedIncrement(&g_timeouts); }
    }
    ResumeThread(w);
  }
}

static LONG CALLBACK crashHandler(EXCEPTION_POINTERS* info) {
  if (!g_guard) return EXCEPTION_CONTINUE_SEARCH;
  g_guard = 0;
  longjmp(g_crashJmp, 1);
}

// The game's client.dll: MXO_CLIENT_DLL, or the usual Rejacked location
static const char* clientPath() {
  const char* path = getenv("MXO_CLIENT_DLL");
  return path && *path ? path : "C:\\Games\\MxO\\client.dll";
}

static const size_t BlockSize = 2048, Blocks = 14;
static const int PassedArgs = 12;   // always pass this many, so a routine with more arguments than guessed reads the same values in both runs
static uint32_t* g_arena;      // live memory the routines work on
static uint32_t* g_init;
static uint32_t* g_resA;
static uint8_t*  g_data;       // the image's writable data, so side effects on globals are compared too
static size_t    g_dataSize;
static uint8_t*  g_dataInit;
static uint8_t*  g_dataA;
static uint8_t*  g_base;

struct Result { bool crashed; uint32_t eax; double st0; uint32_t tags; };
static int g_plain = 0;   // 1: only ordinary float values in the arena (no integers, pointers, huge or tiny numbers)

static Result runOne(void* fn, const GameFn& g, const uint32_t* args) {
  Result r = {}; r.st0 = 0;
  uint32_t seh; __asm__ __volatile__("movl %%fs:0, %0" : "=r"(seh));
  if (setjmp(g_crashJmp)) {
    __asm__ __volatile__("movl %0, %%fs:0" : : "r"(seh));
    fpu_setcw(0x007f);
    r.crashed = true;
    return r;
  }
  // same FPU state before every call: empty stack with the stack pointer at zero (a routine run on garbage
  // can pop an empty stack, which leaves it "empty" but rotated and shows up in later status words)
  fpu_setcw(0x007f);
  g_callStart = GetTickCount();
  g_guard = 1;
  r.eax = xcall(fn, uint32_t(uintptr_t(g_arena)), args, PassedArgs, g.fpret ? &r.st0 : nullptr);
  g_guard = 0;
  r.tags = fpu_tags();
  // a routine that hands on a callee's floating-point result leaves it on the FPU stack: compare it too
  if (!g.fpret && r.tags == 0x3fff) __asm__ __volatile__("fstpl %0" : "=m"(r.st0));
  else if (r.tags != 0xffff) fpu_setcw(0x007f);
  return r;
}

struct Job {
  const GameFn* g; MxoXFunc* f; int iterations;
  volatile LONG heartbeat, finished;
  int done, crashed, bad, stack, eaxdiff, crashdiff, databad;
  char msg[3][200]; int nmsg;
};

static DWORD WINAPI gameWorker(void* param) {
  Job& j = *(Job*)param;
  const GameFn& g = *j.g;
  fpu_setcw(0x007f);
  MxoX_tid = GetCurrentThreadId();
  for (int it = 0; it < j.iterations && g_timeouts < 5; it++) {
    InterlockedIncrement(&j.heartbeat);
    g_specials = !g_plain && (it & 3) == 3;
    for (size_t k = 0; k < BlockSize * Blocks / 4; k++) {
      uint32_t r = g_plain ? 0 : rnd32() % 64;
      // mostly floats; a few small integers and in-arena pointers so counts and links are sometimes sane
      g_init[k] = r < 56 ? fbits(rndf()) : r < 61 ? rnd32() % 5 : uint32_t(uintptr_t(g_arena)) + (rnd32() % (BlockSize * (Blocks - 1) / 4)) * 4;
    }
    uint32_t args[PassedArgs];
    for (int a = 0; a < PassedArgs; a++)
      args[a] = (a < g.nargs && g.kinds[a] == 'f') ? fbits(rndf()) : uint32_t(uintptr_t(g_arena)) + uint32_t(BlockSize * (a + 1));
    memcpy(g_data, g_dataInit, g_dataSize);
    memcpy(g_arena, g_init, BlockSize * Blocks);
    Result ra = runOne(g_base + g.rva, g, args);
    memcpy(g_resA, g_arena, BlockSize * Blocks);
    memcpy(g_dataA, g_data, g_dataSize);
    memcpy(g_data, g_dataInit, g_dataSize);
    memcpy(g_arena, g_init, BlockSize * Blocks);
    Result rb = runOne(j.f->replacement, g, args);
    if (ra.crashed || rb.crashed) { j.crashed++; if (ra.crashed != rb.crashed) j.crashdiff++; continue; }
    j.done++;
    size_t where = 0;
    if (diff(g_dataA, g_data, g_dataSize, &where)) {
      if (!j.databad++ && j.nmsg < 3) snprintf(j.msg[j.nmsg++], 200, "global data differs at .data+%x: orig %08x xlat %08x", unsigned(where), *(uint32_t*)(g_dataA + where), *(uint32_t*)(g_data + where));
    }
    if (ra.tags != rb.tags) { if (!j.stack++ && j.nmsg < 3) snprintf(j.msg[j.nmsg++], 200, "FPU stack differs: orig %04x xlat %04x", ra.tags, rb.tags); }
    if ((ra.eax ^ rb.eax) & 0xffffff00) { if (!j.eaxdiff++ && j.nmsg < 3) snprintf(j.msg[j.nmsg++], 200, "eax orig %08x xlat %08x", ra.eax, rb.eax); }
    if (diff(g_resA, g_arena, BlockSize * Blocks, &where) || diff(&ra.st0, &rb.st0, 8, &where)) {
      if (!j.bad++ && j.nmsg < 3) snprintf(j.msg[j.nmsg++], 200, "result differs at arena+%u: orig %08x xlat %08x (iteration %d)", unsigned(where), g_resA[where / 4], g_arena[where / 4], it);
    }
  }
  j.finished = 1;
  return 0;
}

static const char* FuzzFile = "fuzz.txt";   // in the current folder

// Child: tests routines [first, first + count) and appends one line per routine. A routine that blocks
// for good ends the process, because whatever it holds would block everything after it too.
static int runGameChild(int iterations, int first, int count) {
  HMODULE mod = LoadLibraryExA(clientPath(), nullptr, DONT_RESOLVE_DLL_REFERENCES);
  if (!mod) return 2;
  uint8_t* base = g_base = (uint8_t*)mod;
  auto nt = (const IMAGE_NT_HEADERS32*)(base + ((const IMAGE_DOS_HEADER*)base)->e_lfanew);
  uint32_t imageSize = nt->OptionalHeader.SizeOfImage;
  if (!MxoXFixups(base, MxoX_imagebase, MxoX_absfix, MxoX_relfix, MxoX_code_begin, MxoX_code_end)) return 2;
  AddVectoredExceptionHandler(1, crashHandler);
  CreateThread(nullptr, 0, watchdog, nullptr, 0, nullptr);
  g_arena = (uint32_t*)VirtualAlloc(nullptr, BlockSize * Blocks, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
  g_init  = (uint32_t*)malloc(BlockSize * Blocks);
  g_resA  = (uint32_t*)malloc(BlockSize * Blocks);
  const IMAGE_SECTION_HEADER* sec = IMAGE_FIRST_SECTION(nt);
  for (int k = 0; k < nt->FileHeader.NumberOfSections; k++)
    if (!memcmp(sec[k].Name, ".data", 6)) { g_data = base + sec[k].VirtualAddress; g_dataSize = sec[k].Misc.VirtualSize & ~3u; }
  DWORD old; VirtualProtect(g_data, g_dataSize, PAGE_READWRITE, &old);
  g_dataInit = (uint8_t*)malloc(g_dataSize); g_dataA = (uint8_t*)malloc(g_dataSize);
  memcpy(g_dataInit, g_data, g_dataSize);
  g_seed ^= uint64_t(first + 1) * 0x9E3779B97F4A7C15ull;
  FILE* out = fopen(FuzzFile, "a");
  const int total = int(sizeof(g_gameFns) / sizeof(g_gameFns[0]));
  for (int idx = first; idx < first + count && idx < total; idx++) {
    const GameFn& g = g_gameFns[idx];
    MxoXFunc* f = findFunc(MxoX_funcs, g.rva);
    if (!f || !MxoXMatches(base, imageSize, MxoX_imagebase, *f)) { fprintf(out, "%d %06x NOMATCH\n", idx, g.rva); fflush(out); continue; }
    static Job j; memset(&j, 0, sizeof(j));
    j.g = &g; j.f = f; j.iterations = iterations;
    g_timeouts = 0; g_guard = 0;
    HANDLE th = CreateThread(nullptr, 0, gameWorker, &j, 0, nullptr);
    g_worker = th;
    LONG lastBeat = -1; DWORD lastChange = GetTickCount();
    bool killed = false;
    while (WaitForSingleObject(th, 100) == WAIT_TIMEOUT) {
      if (j.heartbeat != lastBeat) { lastBeat = j.heartbeat; lastChange = GetTickCount(); }
      else if (GetTickCount() - lastChange > 4000) { killed = true; break; }
    }
    fprintf(out, "%d %06x %s ran=%d crashed=%d crashdiff=%d timeouts=%ld result=%d data=%d eax=%d stack=%d sig=%s%s\n", idx, g.rva,
      killed ? "BLOCKED" : "DONE", j.done, j.crashed, j.crashdiff, long(g_timeouts), j.bad, j.databad, j.eaxdiff, j.stack, g.thisPtr ? "this," : "", g.kinds);
    for (int k = 0; k < j.nmsg; k++) fprintf(out, "# %06x %s\n", g.rva, j.msg[k]);
    fflush(out);
    if (killed) { fclose(out); TerminateProcess(GetCurrentProcess(), 3); }
    g_worker = nullptr;
    CloseHandle(th);
  }
  fclose(out);
  return 0;
}

static int lastIndexDone() {
  FILE* in = fopen(FuzzFile, "r");
  if (!in) return -1;
  char line[512]; int last = -1;
  while (fgets(line, sizeof(line), in)) { if (line[0] != '#') { int v = atoi(line); if (v > last) last = v; } }
  fclose(in);
  return last;
}

static int runGame(int iterations) {
  int problems = 0;
  DeleteFileA(FuzzFile);
  const int total = int(sizeof(g_gameFns) / sizeof(g_gameFns[0]));
  printf("== game routines: %d translations, each compared with the original in client.dll\n", total);
  {
    // the float-to-integer helper against the inline fast path used by the translations
    HMODULE mod = LoadLibraryExA(clientPath(), nullptr, DONT_RESOLVE_DLL_REFERENCES);
    if (mod && MxoX_deps[0]) {
      void* ftol = (uint8_t*)mod + MxoX_deps[0];
      int badf = 0, fast = 0;
      for (int it = 0; it < 400000; it++) {
        g_specials = it & 1;
        double v = (it % 5 == 0) ? double(int32_t(rnd32())) * 0.5 : (it % 5 == 1) ? double(rndf()) * 1000.0 : double(rndf());
        uint32_t lo, hi;
        __asm__ __volatile__("fldl %2\n call *%3\n" : "=a"(lo), "=d"(hi) : "m"(v), "r"(ftol) : "ecx", "st");
        int32_t t = _mm_cvttsd_si32(_mm_set_sd(v));
        if (uint32_t(t) == 0x80000000u) continue;
        fast++;
        if (lo != uint32_t(t) || hi != uint32_t(t >> 31)) { if (badf++ < 4) printf("ftol MISMATCH v=%g helper %08x:%08x inline %08x\n", v, hi, lo, t); }
      }
      printf("float-to-integer helper vs inline path: %d cases on the fast path, %d mismatches\n", fast, badf);
      problems += badf;
      // the replacement for the helper itself, over the whole range including huge values, infinities and NaN
      if (MxoXFunc* rf = findFunc(MxoX_funcs, MxoX_deps[0])) {
        MxoXFixups((uint8_t*)mod, MxoX_imagebase, MxoX_absfix, MxoX_relfix, MxoX_code_begin, MxoX_code_end);
        int badr = 0, stackr = 0;
        for (int it = 0; it < 400000; it++) {
          g_specials = it & 1;
          double v = (it % 6 == 0) ? double(int32_t(rnd32())) * 0.5 : (it % 6 == 1) ? double(rndf()) * 1000.0
                   : (it % 6 == 2) ? double(int64_t(uint64_t(rnd32()) << 32 | rnd32())) : (it % 6 == 3) ? double(rndf()) * 4.0e9 : double(rndf());
          uint32_t lo1, hi1, lo2, hi2;
          __asm__ __volatile__("fldl %2\n call *%3\n" : "=a"(lo1), "=d"(hi1) : "m"(v), "r"(ftol) : "ecx", "st");
          uint32_t t1 = fpu_tags();
          __asm__ __volatile__("fldl %2\n call *%3\n" : "=a"(lo2), "=d"(hi2) : "m"(v), "r"(rf->replacement) : "ecx", "st");
          uint32_t t2 = fpu_tags();
          if (t1 != 0xffff || t2 != 0xffff) { stackr++; fpu_setcw(0x007f); }
          if (lo1 != lo2 || hi1 != hi2) { if (badr++ < 4) printf("helper replacement MISMATCH v=%g original %08x:%08x replacement %08x:%08x\n", v, hi1, lo1, hi2, lo2); }
        }
        printf("float-to-integer helper replacement: 400000 cases, %d mismatches, %d FPU stack errors\n", badr, stackr);
        problems += badr + stackr;
      }
    }
  }
  char self[MAX_PATH]; GetModuleFileNameA(nullptr, self, MAX_PATH);
  int next = 0, lost = 0;
  while (next < total) {
    char cmd[600]; snprintf(cmd, sizeof(cmd), "\"%s\" %d child %d %d", self, iterations, next, 40);
    STARTUPINFOA si = {}; si.cb = sizeof(si); PROCESS_INFORMATION pi = {};
    if (!CreateProcessA(nullptr, cmd, nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) { printf("cannot start child\n"); return problems + 1; }
    int before = lastIndexDone(); DWORD lastChange = GetTickCount();
    while (WaitForSingleObject(pi.hProcess, 500) == WAIT_TIMEOUT) {
      int now = lastIndexDone();
      if (now != before) { before = now; lastChange = GetTickCount(); }
      else if (GetTickCount() - lastChange > 120000) { TerminateProcess(pi.hProcess, 4); break; }
    }
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
    int done = lastIndexDone();
    if (done < next) { FILE* out = fopen(FuzzFile, "a"); fprintf(out, "%d %06x LOST\n", next, g_gameFns[next].rva); fclose(out); lost++; done = next; }
    next = done + 1;
    printf("... %d of %d\n", next, total);
  }
  // summary
  FILE* in = fopen(FuzzFile, "r");
  char line[512]; int tested = 0, exercised = 0, clean = 0, blocked = 0; long runs = 0;
  while (in && fgets(line, sizeof(line), in)) {
    if (line[0] == '#') { printf("   %s", line); continue; }
    int idx, ran = 0, crashed = 0, crashdiff = 0, result = 0, data = 0, eax = 0, stack = 0; long timeouts = 0; unsigned rva; char status[32] = "";
    if (sscanf(line, "%d %x %31s ran=%d crashed=%d crashdiff=%d timeouts=%ld result=%d data=%d eax=%d stack=%d", &idx, &rva, status, &ran, &crashed, &crashdiff, &timeouts, &result, &data, &eax, &stack) < 3) continue;
    tested++; runs += ran; if (ran) exercised++;
    if (!strcmp(status, "BLOCKED") || !strcmp(status, "LOST")) blocked++;
    if (result || data || eax || stack || crashdiff || strcmp(status, "DONE")) printf("%s", line);
    else if (ran) clean++;
    problems += result + data + stack + crashdiff;
  }
  if (in) fclose(in);
  printf("game routines: %d tested; %d ran to completion at least once (%ld comparisons); %d of those identical in every run; %d blocked or lost\n",
    tested, exercised, runs, clean, blocked);
  return problems;
}
