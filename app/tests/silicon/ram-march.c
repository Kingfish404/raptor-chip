#include <stdint.h>

/* March C- over an isolated BSS buffer, never over executing code or the stack.
 */
static volatile uint32_t memory[128];

int main(void) {
  for (unsigned i = 0; i < 128; ++i)
    memory[i] = 0;
  for (unsigned pass = 0; pass < 4; ++pass) {
    const uint32_t expected = (pass & 1) ? UINT32_MAX : 0;
    for (unsigned j = 0; j < 128; ++j) {
      unsigned i = pass < 2 ? j : 127 - j;
      if (memory[i] != expected)
        return 1;
      memory[i] = ~expected;
    }
  }
  for (unsigned i = 0; i < 128; ++i)
    if (memory[i] != 0)
      return 2;
  return 0;
}
