#include <difftest-isa.h>
#include <difftest-multi.h>
#include <difftest-vector.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

static const NemuDiffAPI *reference;
static NemuDiffAPI proxy;
static const NemuDiffVectorAPI *vector_reference;
static NemuDiffVectorAPI vector_proxy;
static int fired;

static void *reference_handle(void)
{
  static void *handle;
  if (!handle) {
    const char *path = getenv("NEMU_TEST_REFERENCE");
    if (path) handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  }
  return handle;
}

static int corrupt_step(uint32_t hart, uint64_t sequence, NemuDiffFrame *frame)
{
  const char *fault = getenv("NEMU_TEST_FAULT");
  if (fault && !strcmp(fault, "route") && hart == 1 && !fired) {
    fired = 1;
    return reference->step(0, sequence, frame);
  }
  int result = reference->step(hart, sequence, frame);
  if (result || fired || sequence < 30) return result;
  if (!fault) return result;
  if (!strcmp(fault, "gpr")) frame->state.gpr[5] ^= 1;
  else if (!strcmp(fault, "fpr")) frame->state.fpr[5] ^= 1;
  else if (!strcmp(fault, "csr")) frame->state.csr[0x340] ^= 1;
  else if (!strcmp(fault, "hart")) frame->state.csr[0xf14] ^= 1;
  else if (!strcmp(fault, "trap")) frame->trapped ^= 1;
  else if (!strcmp(fault, "drop")) frame->count = 0;
  else {
    for (unsigned index = 0; index < frame->count; index++) {
      NemuDiffMemory *event = &frame->memory[index];
      if (!strcmp(fault, "address")) event->address ^= 8;
      else if (!strcmp(fault, "load") && !event->write) event->data ^= 1;
      else if (!strcmp(fault, "store") && event->write) event->data ^= 1;
      else continue;
      fired = 1;
      return result;
    }
    return result;
  }
  fired = 1;
  return result;
}

__attribute__((visibility("default")))
const NemuDiffAPI *nemu_difftest_query(uint32_t version, uint32_t size)
{
  void *handle = reference_handle();
  if (!handle) return NULL;
  NemuDiffQuery query = (NemuDiffQuery)dlsym(handle, "nemu_difftest_query");
  if (!query) return NULL;
  reference = query(version, size);
  if (!reference) return NULL;
  proxy = *reference;
  proxy.step = corrupt_step;
  if (getenv("NEMU_TEST_BAD_ABI")) proxy.version++;
  if (getenv("NEMU_TEST_BAD_CAP")) proxy.capabilities = 0;
  return &proxy;
}

__attribute__((visibility("default")))
const NemuISAAPI *nemu_difftest_isa_query(uint32_t version, uint32_t size)
{
  void *handle = reference_handle();
  if (!handle) return NULL;
  NemuISAQuery query = (NemuISAQuery)dlsym(handle, "nemu_difftest_isa_query");
  return query ? query(version, size) : NULL;
}

static int corrupt_vector_state(uint32_t hart, NemuDiffVectorState *state)
{
  int result = vector_reference->get_state(hart, state);
  const char *fault = getenv("NEMU_TEST_FAULT");
  if (result || !fault) return result;
  if (!strcmp(fault, "vreg-init")) {
    state->reg[0][0] ^= 1;
    return result;
  }
  if (strcmp(fault, "vreg")) return result;
  for (unsigned reg = 0; reg < 32; reg++)
    for (unsigned byte = 0; byte < NEMU_DIFF_VECTOR_VLENB; byte++)
      if (state->reg[reg][byte]) {
        state->reg[reg][byte] ^= 1;
        return result;
      }
  return result;
}

__attribute__((visibility("default")))
const NemuDiffVectorAPI *nemu_difftest_vector_query(uint32_t version, uint32_t size)
{
  void *handle = reference_handle();
  if (!handle) return NULL;
  NemuDiffVectorQuery query = (NemuDiffVectorQuery)dlsym(handle, "nemu_difftest_vector_query");
  vector_reference = query ? query(version, size) : NULL;
  if (!vector_reference) return NULL;
  vector_proxy = *vector_reference;
  vector_proxy.get_state = corrupt_vector_state;
  return &vector_proxy;
}
