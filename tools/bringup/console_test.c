// Exercise UART lanes, DLAB, scratch register, and captured console through the chip.
#include <stdint.h>
int main(void) {
  volatile uint8_t *uart = (void *)0x10000000;
  uart[3] = 0x83;
  uart[0] = 12;
  uart[1] = 0;
  if (uart[0] != 12 || uart[1] != 0) return 2;
  uart[3] = 3;
  uart[7] = 0x5a;
  if (uart[7] != 0x5a || uart[2] != 1 || (uart[5] & 0x60) != 0x60) return 3;
  const char *text = "Raptor bring-up UART\n";
  while (*text) uart[0] = *text++;
  return 0;
}
