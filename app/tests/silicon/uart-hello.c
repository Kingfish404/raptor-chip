#include <am.h>

int main(void) {
  const char *text = "Hello from Raptor UART1\n";
  while (*text)
    putch(*text++);
  return 0;
}
