#pragma once

#include <cstddef>
#include <cstdint>
#include <cstring>

// Include after mxo_x87_apply.h: the game code is recognised with its MxoXCodeHash.
//
// The client's routine at MxoLightLoopRva chooses the projector lights for one object, with four
// calls per light of the scene: 27 to 31% of the main thread among many characters at night
// (docs/translator.md). This runs in front of it and leaves out the lights clearly out of reach.
// The routine still decides every light it is given, and every close case is given to it.

const uint32_t MxoLightLoopRva      = 0x48fa40;
const uint32_t MxoLightBoxScaleAt[] = { 142, 162, 196 };   // in the loop's code: the addresses of the factor it scales the box by
const float    MxoBoxScale          = 0.75f;      // what that factor has to be
const uint32_t MxoBoxMinOffset      = 0x24;       // in the object: the low corner of its box, three floats
const uint32_t MxoBoxMaxOffset      = 0x30;       // the high corner

const uint32_t MxoLightReachSlot    = 0x24;       // in a light's table of functions: returns its reach
const uint32_t MxoLightPartOffset   = 0x24;       // in a light: the part that holds the reach, or null
const uint32_t MxoLightPosOffset    = 0x28;       // in a light: its position, three floats
const uint32_t MxoPartReachOffset   = 0x48;       // in that part: the reach, a float

// What the one known kind of light has at MxoLightReachSlot: the reach of the light's part, and
// without a part the float at the address in its code, which has to be 0
const uint32_t MxoLightReachRva     = 0x4b3fe0;
const uint32_t MxoLightReachSize    = 19;
const uint64_t MxoLightReachHash    = 0xfbda6d8eae75e52eull;
const uint32_t MxoLightReachZeroAt  = 14;

// Where that function jumps with a part: returns the float at MxoPartReachOffset of what it is called on
const uint32_t MxoPartReachRva      = 0x4a98c0;
const uint32_t MxoPartReachSize     = 4;
const uint64_t MxoPartReachHash     = 0xdabfbd814307a612ull;

const float    MxoLightMargin       = 1.01f;      // a light this close to reaching the box is left to the routine
const size_t   MxoMaxKeptLights     = 256;        // with more lights in reach than this the routine gets the whole list
const uint32_t MxoLightEntryCount   = 8;          // the routine fills at most this many entries

// The list the routine is handed: pointers to the lights
struct MxoLightList {
  const uint8_t* const* begin;
  const uint8_t* const* end;
};

// The routine, as the game calls it and as its translation is called. Returns how many lights it took.
typedef uint32_t (__stdcall* MxoLightLoop)(const uint8_t* object, const MxoLightList* lights, void* entries, uint32_t first);

// One call of the filter: the length of the list, and how many of its lights the routine got
struct MxoLightCount {
  uint32_t seen;
  uint32_t kept;
};

static inline float MxoFloatAt(const uint8_t* address) {
  float value;
  std::memcpy(&value, address, sizeof(value));
  return value;
}

static inline uint32_t MxoWordAt(const uint8_t* address) {
  uint32_t value;
  std::memcpy(&value, address, sizeof(value));
  return value;
}

// The box of the routine: for each axis the middle it uses and the distance it allows from there
struct MxoLightBox {
  float middle[3];
  float extent[3];
};

static inline MxoLightBox MxoLightBoxOf(const uint8_t* object) {
  MxoLightBox box;
  for (uint32_t axis = 0; axis < 3; axis++) {
    const float low = MxoFloatAt(object + MxoBoxMinOffset + 4 * axis);
    box.extent[axis] = (MxoFloatAt(object + MxoBoxMaxOffset + 4 * axis) - low) * MxoBoxScale;
    box.middle[axis] = box.extent[axis] + low;
  }
  return box;
}

// Whether the light is out of the box's reach by more than the margin: never for another kind of
// light than the known one, or for a reach that is not a number. An axis on which the position or
// the box is not a number adds nothing to the distance, as in the routine.
static inline bool MxoLightOutOfReach(const MxoLightBox& box, const uint8_t* light, uint32_t clientBase) {
  const uint8_t* functions = reinterpret_cast<const uint8_t*>(uintptr_t(MxoWordAt(light)));
  if (MxoWordAt(functions + MxoLightReachSlot) != clientBase + MxoLightReachRva)
    return false;

  const uint8_t* part = reinterpret_cast<const uint8_t*>(uintptr_t(MxoWordAt(light + MxoLightPartOffset)));
  const float reach = part ? MxoFloatAt(part + MxoPartReachOffset) : 0.0f;

  // the routine's own sum, branch for branch: the squared distance from the light to the box
  float distance = 0.0f;
  for (uint32_t axis = 0; axis < 3; axis++) {
    const float offset = MxoFloatAt(light + MxoLightPosOffset + 4 * axis) - box.middle[axis];
    if (offset < -box.extent[axis]) {
      const float over = offset + box.extent[axis];
      distance += over * over;
    } else if (offset > box.extent[axis]) {
      const float over = offset - box.extent[axis];
      distance += over * over;
    }
  }

  // The routine drops a light when reach * reach < distance. Rounding can differ between its
  // arithmetic and this one, so only a clear case is decided here.
  return reach * reach * MxoLightMargin < distance;
}

// Copies the lights that can reach the object into kept (room for MxoMaxKeptLights), in their
// order, and returns how many. The list can have any length. Returns MxoMaxKeptLights + 1 when more
// are in reach or the list ends before it begins: the routine then has to get the list as it is.
static inline size_t MxoLightsInReach(const uint8_t* object, const MxoLightList* lights,
    const uint8_t** kept, uint32_t clientBase) {
  if (lights->end < lights->begin)
    return MxoMaxKeptLights + 1;

  const size_t count = size_t(lights->end - lights->begin);
  const MxoLightBox box = MxoLightBoxOf(object);
  size_t keptCount = 0;
  for (size_t i = 0; i < count; i++) {
    const uint8_t* light = lights->begin[i];
    if (MxoLightOutOfReach(box, light, clientBase))
      continue;
    if (keptCount == MxoMaxKeptLights)
      return MxoMaxKeptLights + 1;
    kept[keptCount++] = light;
  }
  return keptCount;
}

// Runs the routine on the lights that can reach the object. This is all that stands in front of
// the routine: the DLL and the tests both call it.
static inline uint32_t MxoRunLightLoop(MxoLightLoop loop, uint32_t clientBase, const uint8_t* object,
    const MxoLightList* lights, void* entries, uint32_t first, MxoLightCount* count) {
  count->seen = lights->end > lights->begin ? uint32_t(lights->end - lights->begin) : 0u;
  count->kept = count->seen;

  // with no light or no free entry the routine may read nothing, so the filter reads nothing either
  if (count->seen == 0 || first >= MxoLightEntryCount)
    return loop(object, lights, entries, first);

  const uint8_t* kept[MxoMaxKeptLights];
  const size_t keptCount = MxoLightsInReach(object, lights, kept, clientBase);

  if (keptCount > MxoMaxKeptLights)
    return loop(object, lights, entries, first);

  count->kept = uint32_t(keptCount);
  const MxoLightList inReach = { kept, kept + keptCount };
  return loop(object, &inReach, entries, first);
}

static inline bool MxoImageFloatIs(const uint8_t* base, uint32_t imageSize, uint32_t address, float value) {
  const uint32_t rva = address - uint32_t(uintptr_t(base));
  return imageSize >= sizeof(float) && rva <= imageSize - sizeof(float)
      && !std::memcmp(base + rva, &value, sizeof(value));
}

// Whether the filter fits this client.dll: the two functions that give a light's reach are the
// known ones, the reach without a part is 0, and the routine scales the box by MxoBoxScale. That
// the routine itself is the known one is for the caller to check. imageSize is the size in memory.
static inline bool MxoLightFilterFits(const uint8_t* base, uint32_t imageSize) {
  if (imageSize < MxoLightReachRva + MxoLightReachSize || imageSize < MxoLightLoopRva + MxoLightBoxScaleAt[2] + sizeof(uint32_t))
    return false;

  const uint32_t zeroAt[] = { MxoLightReachZeroAt };
  if (MxoXCodeHash(base + MxoLightReachRva, MxoLightReachSize, zeroAt, 1) != MxoLightReachHash
   || MxoXCodeHash(base + MxoPartReachRva, MxoPartReachSize, nullptr, 0) != MxoPartReachHash
   || !MxoImageFloatIs(base, imageSize, MxoWordAt(base + MxoLightReachRva + MxoLightReachZeroAt), 0.0f))
    return false;

  for (uint32_t at : MxoLightBoxScaleAt) {
    if (!MxoImageFloatIs(base, imageSize, MxoWordAt(base + MxoLightLoopRva + at), MxoBoxScale))
      return false;
  }

  return true;
}
