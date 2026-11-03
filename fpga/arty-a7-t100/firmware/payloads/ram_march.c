#include "board.h"

int main(void) {
  volatile uint32_t *first = (volatile uint32_t *)0x80004000u;
  volatile uint32_t *end = (volatile uint32_t *)0x8003e000u;
  // March C- over every word outside firmware and stack. This includes the
  // flasher's descriptor/staging area, which this standalone payload does not use.
  for (volatile uint32_t *p = first; p < end; p++) *p = 0;
  for (volatile uint32_t *p = first; p < end; p++) {
    if (*p != 0) return 1;
    *p = 0xffffffffu;
  }
  for (volatile uint32_t *p = first; p < end; p++) {
    if (*p != 0xffffffffu) return 2;
    *p = 0;
  }
  for (volatile uint32_t *p = end; p != first;) {
    p--;
    if (*p != 0) return 3;
    *p = 0xffffffffu;
  }
  for (volatile uint32_t *p = end; p != first;) {
    p--;
    if (*p != 0xffffffffu) return 4;
    *p = 0;
  }
  for (volatile uint32_t *p = first; p < end; p++)
    if (*p != 0) return 5;
  console("RAM March C-: PASS 0x80004000..0x8003dfff\n");
  return 0;
}
