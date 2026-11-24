// Blind differential test of the translated game routines against the real client.dll (tests/README.md).
// Of eax only al counts, and only with alResult (the routine's own integer code sets it before every return):
// a status word read leaves other bits in the rest than its translation does.
#include <csetjmp>
#include <emmintrin.h>

struct GameFn { uint32_t rva; int nargs; const char* kinds; bool thisPtr; bool fpret; bool framed; bool alResult; };

static const GameFn g_gameFns[] = {
#include "out_game.inc.tests"
};

static const DWORD CallTimeoutMs = 700;        // a call that runs longer is abandoned
static const DWORD WatchdogPollMs = 50;
static const LONG  MaxTimeouts = 5;            // a routine with this many abandoned calls is not called again
static const DWORD BlockedAfterMs = 4000;      // a worker without a heartbeat for this long is blocked for good
static const DWORD ChildSilentMs = 120000;     // a child that reports nothing for this long is ended
static const int   BatchSize = 40;             // routines per child process
static const int   HelperCases = 400000;       // values the float-to-integer helper is tried with
static const uint32_t FpuOneValue = 0x3fff;    // the FPU tag word with one value on the stack

// Routines that get plausible input with MXO_SHAPE=1, and the globals the second one reads
static const uint32_t MapRoutine = 0x47ddb0;       // world position to map grid cell
static const uint32_t SortComparator = 0x4859d0;
static const uint32_t SortDirection = 0xa76a08;    // three floats
static const uint32_t KeyTable = 0x2fe4d0;         // a value from a table of keys, between two keys by their times
static const uint32_t KeyTableStep = 0x2fe560;     // two values per key, blended by a weight, from the last key reached
static const uint32_t KeyTableBlend = 0x2fe670;    // two values per key, between two keys and blended
static const uint32_t MaxKeys = 24;                // the longest table the shaping makes
static const uint32_t LightKind = 0x8c19ec;        // the table of functions of the kind of light the filter knows
static const uint32_t LightKindSlots = 20;         // how much of that table a made-up kind copies
static const uint32_t ShapedLights = 32;           // light objects the shaping makes. A list can name them more than once
static const size_t   ShapedLightSize = 96, ShapedPartSize = 128;   // room for each of them and for its part
static const size_t   LightsBlock = 4, PartsBlock = 7;   // the arena blocks they start in
static const size_t   LightEntrySize = 0x54;       // what the loop writes for a light it takes
static const uint32_t LightEntries = MxoLightEntryCount;   // the loop stops at this many
static const uint32_t QuietNan = 0x7fc00000;

static jmp_buf g_crashJmp;
static volatile int g_guard = 0;
static volatile DWORD g_callStart = 0;
static volatile HANDLE g_worker = nullptr;
static volatile LONG g_timeouts = 0;

static void timeoutStub() { g_guard = 0; longjmp(g_crashJmp, 2); }

// Redirects the worker to timeoutStub when a call spins for too long (random loop counts)
static DWORD WINAPI watchdog(void*) {
  for (;;) {
    Sleep(WatchdogPollMs);
    HANDLE w = g_worker;
    if (!w || !g_guard || GetTickCount() - g_callStart < CallTimeoutMs) continue;
    SuspendThread(w);
    if (g_guard && GetTickCount() - g_callStart >= CallTimeoutMs) {
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
static const int PassedArgs = 12;   // so a routine with more arguments than guessed reads the same values in both runs
static uint32_t* g_arena;      // live memory the routines work on
static uint32_t* g_init;
static uint32_t* g_resA;
static uint8_t*  g_data;       // the image's writable data, so side effects on globals are compared too
static size_t    g_dataSize;
static uint8_t*  g_dataInit;    // what the image's data is reset to before every call
static uint8_t*  g_dataPristine;   // the image's data as loaded, from which g_dataInit starts for every routine
static uint8_t*  g_dataA;
static uint8_t*  g_base;
static uint32_t  g_imageSize;

struct Result { bool crashed; uint32_t eax; double st0; uint32_t tags; };
static int g_plain = 0;   // 1: only ordinary float values in the arena (no integers, pointers, huge or tiny numbers)

static Result runOne(void* fn, const GameFn& g, const uint32_t* args) {
  Result r = {}; r.st0 = 0;
  uint32_t seh; __asm__ __volatile__("movl %%fs:0, %0" : "=r"(seh));
  if (setjmp(g_crashJmp)) {
    __asm__ __volatile__("movl %0, %%fs:0" : : "r"(seh));
    fpu_setcw(CwGame);
    r.crashed = true;
    return r;
  }
  // the same FPU state before every call: a routine run on garbage can pop an empty stack, which leaves it
  // "empty" but rotated and shows up in later status words
  fpu_setcw(CwGame);
  g_callStart = GetTickCount();
  g_guard = 1;
  r.eax = xcall(fn, uint32_t(uintptr_t(g_arena)), args, PassedArgs, g.fpret ? &r.st0 : nullptr);
  g_guard = 0;
  r.tags = fpu_tags();
  // a routine that hands on a callee's floating-point result leaves it on the FPU stack: compare it too
  if (!g.fpret && r.tags == FpuOneValue) __asm__ __volatile__("fstpl %0" : "=m"(r.st0));
  else if (r.tags != FpuEmpty) fpu_setcw(CwGame);
  return r;
}

struct Job {
  const GameFn* g; MxoXFunc* f; int iterations;
  volatile LONG heartbeat, finished;
  int done, crashed, bad, stack, eaxdiff, aldiff, crashdiff, databad;
  char msg[3][200]; int nmsg;
};

// MXO_SHAPE=1 builds plausible input in the arena (g_init) before the call. MapRoutine: this = {.., +8 grid*},
// grid = {+28 minX, +38 minZ, +40 maxX, +50 maxZ, +58 cell size (double), +60 scale (int), +64/+68 columns/rows},
// arg0 = position {+0 x, +10 z}, arg1/arg2 = column/row out.
static void putd(size_t byteOff, double v) { memcpy((uint8_t*)g_init + byteOff, &v, 8); }
static double rndRange(double lo, double hi) { return lo + (hi - lo) * double(rnd32() % 1000001) / 1000000.0; }

static int g_reached = 0;   // shaped calls that got to the part their shaping is for
static bool g_betweenKeys = false;   // the last key table was asked for a time between two of its keys

static void putGlobalFloat(uint32_t rva, float v) {   // in the data both runs of this routine start from. Later routines start from the loaded image again
  const size_t off = size_t(rva) - size_t(g_data - g_base);
  if (off + 4 <= g_dataSize) memcpy(g_dataInit + off, &v, 4);
}

static float rndShapeFloat() {   // ordinary values, sometimes repeated exactly
  static float last = 0.0f;
  if (rnd32() % 8 == 0) return last;
  return last = float(int32_t(rnd32() % 200001) - 100000) / float(1 + rnd32() % 100);
}

static void putf(size_t byteOff, float v) { memcpy((uint8_t*)g_init + byteOff, &v, 4); }
static bool isKeyTable(uint32_t rva) { return rva == KeyTable || rva == KeyTableStep || rva == KeyTableBlend; }

// A key table: a 16-bit count, then from byte 2 on the keys with rising times, each a time and one value
// (KeyTable) or two (the others). arg0 = table, arg1 = time, arg2 = the weight that blends the two values.
// The floats sit two bytes into a word, so unshaped they are arbitrary bit patterns.
static void shapeKeyTable(const GameFn& g, uint32_t* args) {
  const size_t table = BlockSize * 1;                    // where arg0 points
  const size_t keySize = g.rva == KeyTable ? 8 : 12;
  // Two keys are always written, so a table of none or one has no garbage behind it
  const uint16_t count = uint16_t(rnd32() % 8 == 0 ? rnd32() % 2 : 2 + rnd32() % (MaxKeys - 1));
  const uint32_t written = count < 2 ? 2 : count, picked = rnd32() % written;
  memcpy((uint8_t*)g_init + table, &count, 2);
  float time = float(rndRange(-100, 100)), first = time, last = time, onKey = time;
  for (uint32_t k = 0; k < written; k++) {
    if (k) time += float(rndRange(0.01, 20));
    putf(table + 2 + keySize * k, time);
    for (size_t value = 4; value < keySize; value += 4) putf(table + 2 + keySize * k + value, rndShapeFloat());
    if (k < count) last = time;
    if (k == picked) onKey = time;
  }
  const uint32_t where = rnd32() % 10;
  const float asked = where == 0 ? onKey : where == 1 ? first - float(rndRange(0, 50)) : where == 2 ? last + float(rndRange(0, 50))
                    : float(rndRange(first, last));
  args[1] = fbits(asked);
  if (g.rva != KeyTable) {   // the weight
    const uint32_t end = rnd32() % 8;
    args[2] = fbits(end == 0 ? 0.0f : end == 1 ? 1.0f : float(rndRange(0, 1)));
  }
  g_betweenKeys = count >= 2 && asked >= first && asked < last;
}

// The light loop: arg0 = object {+24 low corner, +30 high corner of its box}, arg1 = {begin, end} of a list
// of pointers to lights, arg2 = the entries it writes, arg3 = the index of the first one. A light = {+0 its
// kind's table of functions, +24 a part or null, +28 position}. The part holds what those functions return:
// +1c four floats, +3c a colour, +40, +44, +48 the reach. One light in eight is of a made-up kind that keeps
// its reach in itself: the filter passes it on unseen.
static void shapeLights(uint32_t* args) {
  const uint32_t arena = uint32_t(uintptr_t(g_arena));
  const size_t object = BlockSize * 1, list = BlockSize * 2, pointers = BlockSize * 3, lights = BlockSize * LightsBlock;
  const size_t otherKind = BlockSize * 6, parts = BlockSize * PartsBlock, entries = BlockSize * 11;
  const size_t lightSize = ShapedLightSize, partSize = ShapedPartSize;

  float low[3], middle[3], extent[3];
  for (int axis = 0; axis < 3; axis++) {
    low[axis] = float(rndRange(-100, 100));
    float size = float(rndRange(0.5, 60));
    if (rnd32() % 40 == 0) size = rnd32() % 2 ? 0.0f : -size;   // an empty box, or one turned inside out
    putf(object + MxoBoxMinOffset + 4 * axis, low[axis]);
    putf(object + MxoBoxMaxOffset + 4 * axis, low[axis] + size);
    extent[axis] = ((low[axis] + size) - low[axis]) * MxoBoxScale;
    middle[axis] = extent[axis] + low[axis];
  }

  memcpy((uint8_t*)g_init + otherKind, g_base + LightKind, 4 * LightKindSlots);
  // the made-up kind has the part's reach function in the light's slot, so its reach is read from the light
  g_init[(otherKind + MxoLightReachSlot) / 4] = uint32_t(uintptr_t(g_base)) + MxoPartReachRva;

  for (uint32_t k = 0; k < ShapedLights; k++) {
    const size_t light = lights + lightSize * k, part = parts + partSize * k;
    const bool known = rnd32() % 8 != 0;
    float reach = float(rndRange(0, 150));
    const uint32_t odd = rnd32() % 40;
    if (odd == 0) reach = 0.0f;
    if (odd == 1) reach = -reach;
    if (odd == 2) reach = 30000.0f;
    // A reach whose square leaves the float range is where the translation and the original part ways
    // (docs/translator.md, Rounding), so MXO_PLAIN=1 keeps it out.
    if (odd == 3 && !g_plain) reach = float(rndf());
    g_init[light / 4] = known ? uint32_t(uintptr_t(g_base)) + LightKind : arena + uint32_t(otherKind);
    g_init[(light + MxoLightPartOffset) / 4] = rnd32() % 10 ? arena + uint32_t(part) : 0;
    putf(part + MxoPartReachOffset, reach);
    putf(light + MxoPartReachOffset, reach);   // where the made-up kind keeps it
    const uint32_t where = rnd32() % 8;
    for (int axis = 0; axis < 3; axis++) {
      float pos = middle[axis] + float(rndRange(-250, 250));
      if (where == 0) pos = middle[axis] + float(rndRange(-5000, 5000));   // far away
      if (where == 1) pos = middle[axis] + extent[axis] * float(rndRange(-1, 1));   // inside the box
      putf(light + MxoLightPosOffset + 4 * axis, pos);
    }
    // not a number on one axis: that axis counts for nothing in the loop's distance
    if (rnd32() % 40 == 0 && !g_plain) g_init[(light + MxoLightPosOffset) / 4 + rnd32() % 3] = QuietNan;
    if (where == 2) {   // as far from one side as its reach goes, the other two axes inside
      const int axis = int(rnd32() % 3);
      const float side = rnd32() % 2 ? 1.0f : -1.0f;
      for (int other = 0; other < 3; other++)
        putf(light + MxoLightPosOffset + 4 * other, middle[other] + extent[other] * float(rndRange(-1, 1)));
      putf(light + MxoLightPosOffset + 4 * axis, middle[axis] + side * (extent[axis] + reach * float(rndRange(0.98, 1.02))));
    }
  }

  // One long list in four names only lights inside the box: more in reach than the filter keeps, so it steps aside.
  uint32_t count = 1 + rnd32() % 48;
  const uint32_t length = rnd32() % 16;
  if (length == 0) count = 0;
  if (length == 1 || length == 2) count = uint32_t(MxoMaxKeptLights) + 1 + rnd32() % 200;
  const bool allInside = length == 1 && rnd32() % 2 == 0;
  if (allInside) {
    for (uint32_t k = 0; k < ShapedLights; k++)
      for (int axis = 0; axis < 3; axis++)
        putf(lights + lightSize * k + MxoLightPosOffset + 4 * axis, middle[axis] + extent[axis] * float(rndRange(-0.9, 0.9)));
  }
  for (uint32_t k = 0; k < count; k++)
    g_init[pointers / 4 + k] = arena + uint32_t(lights + lightSize * (rnd32() % ShapedLights));
  g_init[list / 4] = arena + uint32_t(pointers);
  g_init[list / 4 + 1] = arena + uint32_t(pointers) + 4 * count;
  args[1] = arena + uint32_t(list);
  args[2] = arena + uint32_t(entries);
  args[3] = rnd32() % (LightEntries + 1);
}

// The light loop's translation behind the filter, as the DLL installs the two
static void* g_lightLoop = nullptr;
static bool g_lightLeftOut = false;   // the filter left a light out in the last call

static uint32_t __stdcall lightsThroughFilter(const uint8_t* object, const MxoLightList* lights, void* entries, uint32_t first) {
  MxoLightCount count;
  const uint32_t taken = MxoRunLightLoop(MxoLightLoop(uintptr_t(g_lightLoop)), uint32_t(uintptr_t(g_base)), object, lights, entries, first, &count);
  g_lightLeftOut = count.kept < count.seen;
  return taken;
}

// Writes what the first calls that differ were given and what each version made of it. The arena still holds
// the lights as they went in.
static const char* LightsDetailFile = "lights-detail.txt";
static const int LightsDetailCases = 4;
static int g_lightsDetailed = 0, g_lightsAloneDiffer = 0, g_lightsFilteredDiffer = 0, g_lightsCompared = 0;

static void describeLights(int iteration, const uint32_t* args, uint32_t countOriginal, uint32_t countAlone, uint32_t countFiltered) {
  FILE* out = fopen(LightsDetailFile, "a");
  if (!out) return;
  const uint8_t* arena = (const uint8_t*)g_arena;
  const uint8_t* object = (const uint8_t*)uintptr_t(args[0]);
  const MxoLightList* list = (const MxoLightList*)uintptr_t(args[1]);
  const size_t count = size_t(list->end - list->begin);
  const MxoLightBox box = MxoLightBoxOf(object);
  fpu_setcw(Cw53);   // printf rounds the digits of a double with FPU arithmetic
  fprintf(out, "== iteration %d: %u lights, first entry %u, lights taken: original %u, translation alone %u, with the filter %u\n",
    iteration, unsigned(count), unsigned(args[3]), unsigned(countOriginal), unsigned(countAlone), unsigned(countFiltered));
  fprintf(out, "   box middle %g %g %g, extent %g %g %g\n", box.middle[0], box.middle[1], box.middle[2], box.extent[0], box.extent[1], box.extent[2]);
  for (size_t k = 0; k < count && k < 60; k++) {
    const uint8_t* light = list->begin[k];
    const bool known = MxoWordAt((const uint8_t*)uintptr_t(MxoWordAt(light)) + MxoLightReachSlot) == uint32_t(uintptr_t(g_base)) + MxoLightReachRva;
    const uint8_t* part = (const uint8_t*)uintptr_t(MxoWordAt(light + MxoLightPartOffset));
    const float reach = known ? (part ? MxoFloatAt(part + MxoPartReachOffset) : 0.0f) : MxoFloatAt(light + MxoPartReachOffset);
    float distance = 0.0f;
    for (int axis = 0; axis < 3; axis++) {
      const float offset = MxoFloatAt(light + MxoLightPosOffset + 4 * axis) - box.middle[axis];
      if (offset < -box.extent[axis]) distance += (offset + box.extent[axis]) * (offset + box.extent[axis]);
      else if (offset > box.extent[axis]) distance += (offset - box.extent[axis]) * (offset - box.extent[axis]);
    }
    fprintf(out, "   %2u light %2u %s %s reach %g squared %g, distance squared %g: %s by this reading, filter %s\n", unsigned(k),
      unsigned((light - arena - BlockSize * LightsBlock) / ShapedLightSize), known ? "known" : "other", part ? "part" : "none", reach, double(reach) * reach, distance,
      double(reach) * reach < double(distance) ? "dropped" : "taken", MxoLightOutOfReach(box, light, uint32_t(uintptr_t(g_base))) ? "leaves it out" : "passes it on");
  }
  const size_t entries = size_t((const uint8_t*)uintptr_t(args[2]) - arena);
  for (uint32_t k = 0; k <= LightEntries + 1; k++) {
    const size_t at = (entries + LightEntrySize * k) / 4;
    if (g_resA[at] == g_init[at] && g_arena[at] == g_init[at] && g_resA[at + 1] == g_arena[at + 1]) continue;
    float a, b; memcpy(&a, &g_resA[at + 1], 4); memcpy(&b, &g_arena[at + 1], 4);
    fprintf(out, "   entry %u: original kind %08x x %g, tested kind %08x x %g, before the call %08x\n", unsigned(k), g_resA[at], a, g_arena[at], b, g_init[at]);
  }
  fclose(out);
  fpu_setcw(CwGame);
}

static void shapeInput(const GameFn& g, uint32_t* args) {
  if (g.rva == MxoLightLoopRva) { shapeLights(args); return; }
  if (isKeyTable(g.rva)) { shapeKeyTable(g, args); return; }
  if (g.rva == SortComparator) {
    // two pointers to element pointers. Each element has a box at +24..+2c (min) and +30..+38
    // (max), compared along the direction held in the globals at SortDirection
    const size_t objA = BlockSize * 9, objB = BlockSize * 10;
    g_init[BlockSize * 1 / 4] = uint32_t(uintptr_t(g_arena)) + objA;
    g_init[BlockSize * 2 / 4] = uint32_t(uintptr_t(g_arena)) + (rnd32() % 16 ? objB : objA);
    for (size_t o = 0x24; o <= 0x38; o += 4) {
      float a = rndShapeFloat(), b = rnd32() % 6 ? rndShapeFloat() : a;
      memcpy((uint8_t*)g_init + objA + o, &a, 4);
      memcpy((uint8_t*)g_init + objB + o, &b, 4);
    }
    for (uint32_t r = SortDirection; r < SortDirection + 12; r += 4)
      putGlobalFloat(r, rnd32() % 5 ? rndShapeFloat() / 1000.0f : 0.0f);
    return;
  }
  if (g.rva != MapRoutine) return;
  const size_t grid = BlockSize * 8, pos = BlockSize * 1;
  g_init[2] = uint32_t(uintptr_t(g_arena)) + grid;
  double minX = rndRange(-5000, 5000), minZ = rndRange(-5000, 5000);
  double maxX = minX + rndRange(1, 8000), maxZ = minZ + rndRange(1, 8000);
  putd(grid + 0x28, minX); putd(grid + 0x38, minZ); putd(grid + 0x40, maxX); putd(grid + 0x50, maxZ);
  uint32_t pick = rnd32() % 16;
  uint32_t cols = pick == 3 ? 0 : 1 + rnd32() % 512, rows = pick == 4 ? 0 : 1 + rnd32() % 512;
  int32_t scale = pick == 2 ? -int32_t(rnd32() % 100000) : pick == 7 ? 0 : 1 + int32_t(rnd32() % 255);
  // cell size times scale near the map width divided by the columns, so the results spread over the grid
  double cell = (maxX - minX) / double(cols ? cols : 1) / double(scale > 0 ? scale : 1) * rndRange(0.3, 1.5);
  putd(grid + 0x58, pick == 0 ? 0.0 : pick == 1 ? -rndRange(0, 10) : cell);
  memcpy((uint8_t*)g_init + grid + 0x60, &scale, 4);
  memcpy((uint8_t*)g_init + grid + 0x64, &cols, 4);
  memcpy((uint8_t*)g_init + grid + 0x68, &rows, 4);
  bool inside = rnd32() % 10 != 0;
  putd(pos + 0x00, inside ? rndRange(minX, maxX) : rndRange(-20000, 20000));
  putd(pos + 0x10, inside ? rndRange(minZ, maxZ) : rndRange(-20000, 20000));
  if (pick == 5) putd(pos + 0x00, minX);   // exactly on the edges
  if (pick == 6) putd(pos + 0x10, maxZ);
}

static DWORD WINAPI gameWorker(void* param) {
  Job& j = *(Job*)param;
  const GameFn& g = *j.g;
  fpu_setcw(CwGame);
  MxoX_tid = GetCurrentThreadId();
  for (int it = 0; it < j.iterations && g_timeouts < MaxTimeouts; it++) {
    InterlockedIncrement(&j.heartbeat);
    g_specials = !g_plain && (it & 3) == 3;
    for (size_t k = 0; k < BlockSize * Blocks / 4; k++) {
      uint32_t r = g_plain ? 0 : rnd32() % 64;
      // a few small integers and in-arena pointers, so counts and links are sometimes sane
      g_init[k] = r < 56 ? fbits(rndf()) : r < 61 ? rnd32() % 5 : uint32_t(uintptr_t(g_arena)) + (rnd32() % (BlockSize * (Blocks - 1) / 4)) * 4;
    }
    uint32_t args[PassedArgs];
    for (int a = 0; a < PassedArgs; a++)
      args[a] = (a < g.nargs && g.kinds[a] == 'f') ? fbits(rndf()) : uint32_t(uintptr_t(g_arena)) + uint32_t(BlockSize * (a + 1));
    g_betweenKeys = false;
    if (getenv("MXO_SHAPE") && *getenv("MXO_SHAPE")) shapeInput(g, args);
    memcpy(g_data, g_dataInit, g_dataSize);
    memcpy(g_arena, g_init, BlockSize * Blocks);
    Result ra = runOne(g_base + g.rva, g, args);
    memcpy(g_resA, g_arena, BlockSize * Blocks);
    if (g.rva == MapRoutine && g_resA[BlockSize * 2 / 4] != 0xffffffffu && !ra.crashed) g_reached++;
    if (g.rva == SortComparator && !ra.crashed) g_reached++;
    if (g_betweenKeys && !ra.crashed) g_reached++;
    memcpy(g_dataA, g_data, g_dataSize);
    memcpy(g_data, g_dataInit, g_dataSize);
    memcpy(g_arena, g_init, BlockSize * Blocks);
    // The light loop runs behind the filter, as the DLL installs it, unless MXO_LIGHT_FILTER=0. The translation
    // alone runs first either way, so a difference can be told apart.
    void* second = j.f->replacement;
    g_lightLeftOut = false;
    const bool lightLoop = g.rva == MxoLightLoopRva && MxoLightFilterFits(g_base, g_imageSize);
    Result alone = {};
    bool aloneDiffers = false;
    if (lightLoop) {
      alone = runOne(j.f->replacement, g, args);
      size_t at = 0;
      aloneDiffers = !ra.crashed && !alone.crashed && (ra.eax != alone.eax || diff(g_resA, g_arena, BlockSize * Blocks, &at));
      memcpy(g_data, g_dataInit, g_dataSize);
      memcpy(g_arena, g_init, BlockSize * Blocks);
      g_lightLoop = j.f->replacement;
      if (!(getenv("MXO_LIGHT_FILTER") && *getenv("MXO_LIGHT_FILTER") == '0')) second = (void*)&lightsThroughFilter;
    }
    Result rb = runOne(second, g, args);
    if (g_lightLeftOut && !ra.crashed && !rb.crashed) g_reached++;
    if (lightLoop && !ra.crashed && !rb.crashed && !alone.crashed) {
      size_t at = 0;
      const bool differs = ra.eax != rb.eax || diff(g_resA, g_arena, BlockSize * Blocks, &at);
      g_lightsCompared++;
      g_lightsAloneDiffer += aloneDiffers;
      g_lightsFilteredDiffer += differs;
      if ((differs || aloneDiffers) && g_lightsDetailed < LightsDetailCases) { g_lightsDetailed++; describeLights(it, args, ra.eax, alone.eax, rb.eax); }
    }
    if (ra.crashed || rb.crashed) { j.crashed++; if (ra.crashed != rb.crashed) j.crashdiff++; continue; }
    j.done++;
    size_t where = 0;
    if (diff(g_dataA, g_data, g_dataSize, &where)) {
      if (!j.databad++ && j.nmsg < 3) snprintf(j.msg[j.nmsg++], 200, "global data differs at .data+%x: orig %08x xlat %08x", unsigned(where), *(uint32_t*)(g_dataA + where), *(uint32_t*)(g_data + where));
    }
    if (ra.tags != rb.tags) { if (!j.stack++ && j.nmsg < 3) snprintf(j.msg[j.nmsg++], 200, "FPU stack differs: orig %04x xlat %04x", ra.tags, rb.tags); }
    if ((ra.eax ^ rb.eax) & 0xffffff00) { if (!j.eaxdiff++ && j.nmsg < 3) snprintf(j.msg[j.nmsg++], 200, "eax orig %08x xlat %08x", ra.eax, rb.eax); }
    if (g.alResult && ((ra.eax ^ rb.eax) & 0xff)) {
      if (!j.aldiff++ && j.nmsg < 3) snprintf(j.msg[j.nmsg++], 200, "al differs: orig %02x xlat %02x (iteration %d)", ra.eax & 0xff, rb.eax & 0xff, it);
    }
    if (diff(&ra.st0, &rb.st0, 8, &where) && !diff(g_resA, g_arena, BlockSize * Blocks, &where)) {
      uint64_t a, b; memcpy(&a, &ra.st0, 8); memcpy(&b, &rb.st0, 8);
      if (!j.bad++ && j.nmsg < 3) snprintf(j.msg[j.nmsg++], 200, "st0 differs: orig %016llx xlat %016llx (iteration %d)", (unsigned long long)a, (unsigned long long)b, it);
    } else if (diff(g_resA, g_arena, BlockSize * Blocks, &where) || diff(&ra.st0, &rb.st0, 8, &where)) {
      if (!j.bad++ && j.nmsg < 3) snprintf(j.msg[j.nmsg++], 200, "result differs at arena+%u: orig %08x xlat %08x (iteration %d)", unsigned(where), g_resA[where / 4], g_arena[where / 4], it);
    }
  }
  if (g.rva == MxoLightLoopRva) {
    if (FILE* out = fopen(LightsDetailFile, "a")) {
      fprintf(out, "== %d calls compared: the translation alone differs from the original in %d, the tested version in %d\n",
        g_lightsCompared, g_lightsAloneDiffer, g_lightsFilteredDiffer);
      fclose(out);
    }
  }
  j.finished = 1;
  return 0;
}

static const char* FuzzFile = "fuzz.txt";

// The image is loaded without its imports, so originals that call msvcr71's floor or ceil would crash where
// their translations compute the result in place. Each slot in the translator's table gets the real function,
// if the unresolved slot names it: the table belongs to the client.dll the translation was made from.
static void ResolveMathImports(uint8_t* base, uint32_t imageSize) {
  HMODULE crt = LoadLibraryA("msvcr71.dll");
  if (!crt)
    return;
  static const char* const names[] = { "floor", "ceil" };
  for (const uint32_t* e = MxoX_crtslots; e[0]; e += 2) {
    if (e[1] > 1 || e[0] > imageSize || imageSize - e[0] < 4)
      continue;
    uint32_t* slot = (uint32_t*)(base + e[0]);
    const uint32_t nameRva = *slot;   // unresolved: the address of the import's hint and name
    if (nameRva > imageSize - 16 || strcmp((const char*)(base + nameRva + 2), names[e[1]]))
      continue;
    DWORD old;
    VirtualProtect(slot, 4, PAGE_READWRITE, &old);
    *slot = (uint32_t)(uintptr_t)GetProcAddress(crt, names[e[1]]);
    VirtualProtect(slot, 4, old, &old);
  }
}

// Child: tests routines [first, first + count), one line each. A routine that blocks for good ends the
// process: whatever it holds would block everything after it too.
static int runGameChild(int iterations, int first, int count) {
  HMODULE mod = LoadLibraryExA(clientPath(), nullptr, DONT_RESOLVE_DLL_REFERENCES);
  if (!mod) return 2;
  uint8_t* base = g_base = (uint8_t*)mod;
  auto nt = (const IMAGE_NT_HEADERS32*)(base + ((const IMAGE_DOS_HEADER*)base)->e_lfanew);
  uint32_t imageSize = nt->OptionalHeader.SizeOfImage;
  if (!MxoXFixups(base, MxoX_imagebase, MxoX_absfix, MxoX_relfix, MxoX_code_begin, MxoX_code_end)) return 2;
  g_imageSize = imageSize;
  ResolveMathImports(base, imageSize);
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
  g_dataPristine = (uint8_t*)malloc(g_dataSize);
  memcpy(g_dataPristine, g_data, g_dataSize);
  memcpy(g_dataInit, g_data, g_dataSize);
  g_seed ^= uint64_t(first + 2) * 0x9E3779B97F4A7C15ull;   // first + 1 would cancel the start value for routine 0 and leave the generator at zero
  FILE* out = fopen(FuzzFile, "a");
  const int total = int(sizeof(g_gameFns) / sizeof(g_gameFns[0]));
  for (int idx = first; idx < first + count && idx < total; idx++) {
    const GameFn& g = g_gameFns[idx];
    MxoXFunc* f = findFunc(MxoX_funcs, g.rva);
    if (!f || !MxoXMatches(base, imageSize, MxoX_imagebase, *f)) { fprintf(out, "%d %06x NOMATCH\n", idx, g.rva); fflush(out); continue; }
    static Job j; memset(&j, 0, sizeof(j)); g_reached = 0;
    memcpy(g_dataInit, g_dataPristine, g_dataSize);   // shaped input of an earlier routine does not carry over
    j.g = &g; j.f = f; j.iterations = iterations;
    g_timeouts = 0; g_guard = 0;
    HANDLE th = CreateThread(nullptr, 0, gameWorker, &j, 0, nullptr);
    g_worker = th;
    LONG lastBeat = -1; DWORD lastChange = GetTickCount();
    bool killed = false;
    while (WaitForSingleObject(th, 100) == WAIT_TIMEOUT) {
      if (j.heartbeat != lastBeat) { lastBeat = j.heartbeat; lastChange = GetTickCount(); }
      else if (GetTickCount() - lastChange > BlockedAfterMs) { killed = true; break; }
    }
    fprintf(out, "%d %06x %s ran=%d crashed=%d crashdiff=%d timeouts=%ld result=%d data=%d eax=%d stack=%d al=%d reached=%d sig=%s%s\n", idx, g.rva,
      killed ? "BLOCKED" : "DONE", j.done, j.crashed, j.crashdiff, long(g_timeouts), j.bad, j.databad, j.eaxdiff, j.stack, g.alResult ? j.aldiff : -1,
      g_reached, g.thisPtr ? "this," : "", g.kinds);
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

// The float-to-integer helper is the one dependency with a replacement. The other rows are jump tables.
static MxoXFunc* findHelper() {
  for (const MxoXFunc* dep = (const MxoXFunc*)MxoX_deps; dep->size; dep++)
    if (MxoXFunc* f = findFunc(MxoX_funcs, dep->rva)) return f;
  return nullptr;
}

static int runGame(int iterations) {
  int problems = 0;
  DeleteFileA(FuzzFile);
  DeleteFileA(LightsDetailFile);
  const int total = int(sizeof(g_gameFns) / sizeof(g_gameFns[0]));
  printf("== game routines: %d translations, each compared with the original in client.dll\n", total);
  {
    // the float-to-integer helper against the inline fast path used by the translations
    HMODULE mod = LoadLibraryExA(clientPath(), nullptr, DONT_RESOLVE_DLL_REFERENCES);
    if (!mod) {   // or every routine would be listed as lost and the total would still be 0
      printf("cannot load %s. Set MXO_CLIENT_DLL to the game's client.dll\n", clientPath());
      return 1;
    }
    MxoXFunc* helper = findHelper();
    if (helper) {
      void* ftol = (uint8_t*)mod + helper->rva;
      int badf = 0, fast = 0;
      for (int it = 0; it < HelperCases; it++) {
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
      // the helper's replacement, over the whole range with huge values, infinities and NaN
      {
        MxoXFixups((uint8_t*)mod, MxoX_imagebase, MxoX_absfix, MxoX_relfix, MxoX_code_begin, MxoX_code_end);
        int badr = 0, stackr = 0;
        for (int it = 0; it < HelperCases; it++) {
          g_specials = it & 1;
          double v = (it % 6 == 0) ? double(int32_t(rnd32())) * 0.5 : (it % 6 == 1) ? double(rndf()) * 1000.0
                   : (it % 6 == 2) ? double(int64_t(uint64_t(rnd32()) << 32 | rnd32())) : (it % 6 == 3) ? double(rndf()) * 4.0e9 : double(rndf());
          uint32_t lo1, hi1, lo2, hi2;
          __asm__ __volatile__("fldl %2\n call *%3\n" : "=a"(lo1), "=d"(hi1) : "m"(v), "r"(ftol) : "ecx", "st");
          uint32_t tagsOriginal = fpu_tags();
          __asm__ __volatile__("fldl %2\n call *%3\n" : "=a"(lo2), "=d"(hi2) : "m"(v), "r"(helper->replacement) : "ecx", "st");
          uint32_t tagsReplacement = fpu_tags();
          if (tagsOriginal != FpuEmpty || tagsReplacement != FpuEmpty) { stackr++; fpu_setcw(CwGame); }
          if (lo1 != lo2 || hi1 != hi2) { if (badr++ < 4) printf("helper replacement MISMATCH v=%g original %08x:%08x replacement %08x:%08x\n", v, hi1, lo1, hi2, lo2); }
        }
        printf("float-to-integer helper replacement: %d cases, %d mismatches, %d FPU stack errors\n", HelperCases, badr, stackr);
        problems += badr + stackr;
      }
    }
  }
  char self[MAX_PATH]; GetModuleFileNameA(nullptr, self, MAX_PATH);
  int next = 0;
  while (next < total) {
    char cmd[600]; snprintf(cmd, sizeof(cmd), "\"%s\" %d child %d %d", self, iterations, next, BatchSize);
    STARTUPINFOA si = {}; si.cb = sizeof(si); PROCESS_INFORMATION pi = {};
    if (!CreateProcessA(nullptr, cmd, nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi)) { printf("cannot start child\n"); return problems + 1; }
    int before = lastIndexDone(); DWORD lastChange = GetTickCount();
    while (WaitForSingleObject(pi.hProcess, 500) == WAIT_TIMEOUT) {
      int now = lastIndexDone();
      if (now != before) { before = now; lastChange = GetTickCount(); }
      else if (GetTickCount() - lastChange > ChildSilentMs) { TerminateProcess(pi.hProcess, 4); break; }
    }
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
    int done = lastIndexDone();
    if (done < next) { FILE* out = fopen(FuzzFile, "a"); fprintf(out, "%d %06x LOST\n", next, g_gameFns[next].rva); fclose(out); done = next; }
    next = done + 1;
    printf("... %d of %d\n", next, total);
  }
  FILE* in = fopen(FuzzFile, "r");
  char line[512]; int tested = 0, exercised = 0, clean = 0, blocked = 0, unmatched = 0, alCompared = 0, eaxRoutines = 0; long runs = 0, eaxCases = 0;
  while (in && fgets(line, sizeof(line), in)) {
    if (line[0] == '#') { printf("   %s", line); continue; }
    int idx, ran = 0, crashed = 0, crashdiff = 0, result = 0, data = 0, eax = 0, stack = 0, al = -1; long timeouts = 0; unsigned rva; char status[32] = "";
    if (sscanf(line, "%d %x %31s ran=%d crashed=%d crashdiff=%d timeouts=%ld result=%d data=%d eax=%d stack=%d al=%d", &idx, &rva, status, &ran, &crashed, &crashdiff, &timeouts, &result, &data, &eax, &stack, &al) < 3) continue;
    tested++; runs += ran; if (ran) exercised++;
    if (!strcmp(status, "BLOCKED") || !strcmp(status, "LOST")) blocked++;
    if (!strcmp(status, "NOMATCH")) unmatched++;
    if (al >= 0) alCompared++;
    const int alDiffs = al > 0 ? al : 0;
    if (eax) { eaxRoutines++; eaxCases += eax; }
    if (result || data || eax || stack || crashdiff || alDiffs || strcmp(status, "DONE")) printf("%s", line);
    else if (ran) clean++;
    problems += result + data + stack + crashdiff + alDiffs;
  }
  if (in) fclose(in);
  printf("game routines: %d tested, %d ran to completion at least once (%ld comparisons), %d of those identical in every run, %d blocked or lost, %d not in this client.dll\n",
    tested, exercised, runs, clean, blocked, unmatched);
  if (tested > 0 && exercised == 0) {   // another build of the client, or children that all died: not a pass
    printf("no routine ran. Is MXO_CLIENT_DLL the client.dll the translation was made from?\n");
    problems++;
  }
  printf("al was compared for %d routines. Differences in the rest of eax, reported above and not counted: %ld cases in %d routines\n",
    alCompared, eaxCases, eaxRoutines);
  return problems;
}
