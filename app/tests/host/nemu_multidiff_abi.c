#include <difftest-multi.h>
#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
  assert(argc == 2);
  void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  assert(handle);
  NemuDiffQuery query = (NemuDiffQuery)dlsym(handle, "nemu_difftest_query");
  assert(query && !query(99, sizeof(NemuDiffAPI)) && !query(1, 0));
  const NemuDiffAPI *api = query(1, sizeof(NemuDiffAPI));
  assert(api && api->init(0) != 0 && api->init(5) != 0 && api->init(4) == 0);
  assert(api->init(2) != 0);
  NemuDiffState state;
  NemuDiffFrame frame;
  assert(api->get_state(4, &state) != 0 && api->get_state(0, NULL) != 0);
  assert(api->get_state(0, &state) == 0);
  assert(api->set_state(1, &state) != 0);
  state.gpr[0] = 1;
  assert(api->set_state(0, &state) != 0);
  state.gpr[0] = 0;
  state.pc = api->ram_base;
  state.gpr[6] = 0x100000;
  state.gpr[7] = 0x5555;
  assert(api->set_state(0, &state) == 0);
  uint32_t instruction = 0x00700293;
  assert(api->memory_copy(UINT64_MAX, &instruction, 4, 1) != 0);
  assert(api->memory_copy(api->ram_base + api->ram_size - 1, &instruction, 4, 1) != 0);
  assert(api->memory_copy(api->ram_base, &instruction, 0, 1) != 0);
  assert(api->memory_copy(api->ram_base, &instruction, 4, 2) != 0);
  assert(api->memory_copy(api->ram_base, &instruction, 4, 1) == 0);
  instruction = 0x00732023;
  assert(api->memory_copy(api->ram_base + 4, &instruction, 4, 1) == 0);
  instruction = 0;
  assert(api->memory_copy(api->ram_base, &instruction, 4, 0) == 0 && instruction == 0x00700293);
  assert(api->step(4, 0, &frame) != 0 && api->step(0, 1, &frame) != 0);
  assert(api->step(0, 0, &frame) == 0 && frame.state.gpr[5] == 7);
  assert(api->get_state(0, &state) == 0 && state.gpr[5] == 7);
  assert(api->get_state(1, &state) == 0 && state.gpr[5] == 0);
  assert(api->set_state(1, &state) != 0);
  assert(api->memory_copy(api->ram_base, &instruction, 4, 1) != 0);
  assert(api->step(0, 0, &frame) != 0);
  assert(api->step(0, 1, &frame) == 0 && frame.ended);
  assert(api->step(0, 2, &frame) != 0);
  puts("NEMU_MULTIDIFF_ABI_PASS");
  return 0;
}
