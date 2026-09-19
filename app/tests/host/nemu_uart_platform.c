// Include the production UART; the harness only supplies MMIO registration/IRQ sinks.
#include "../../../nemu/src/device/serial.c"
struct mapping { const char *name; uint32_t base; uint8_t *space; io_callback_t callback; };
static struct mapping maps[8];
static int count, delivered_irq;
uint8_t *new_space(int size) { return calloc(1, size); }
void add_mmio_map(const char *name, paddr_t base, void *space, uint32_t size, io_callback_t cb) {
  (void)size; assert(count < 8); maps[count++] = (struct mapping){name, base, space, cb};
}
void plic_raise_irq(int irq) { delivered_irq = irq; }
static struct mapping *find(uint32_t addr) {
  for (int i=0; i<count; ++i) if (maps[i].base == addr) return &maps[i];
  abort();
}
int main(void) {
  init_serial();
  ier = UART_IER_RDI;
  serial_rx_enqueue('X');
  serial_update_irq();
  assert(delivered_irq == 10);
  struct mapping *hw = find(0xf0001800u), *old = find(0xf0001000u);
  assert(hw->space == old->space && hw->callback == old->callback);
  litex_uart_store32(0x14, 3);
  hw->callback(0x14, 4, true);
  old->callback(0x14, 4, false);
  assert(litex_uart_load32(0x14) == 3);
  hw->callback(0x08, 4, false);
  assert(litex_uart_load32(0x08) == 0);
  old->callback(0, 4, false);
  assert(litex_uart_load32(0) == 'X');
  hw->callback(0x08, 4, false);
  assert(litex_uart_load32(0x08) == 1);
  litex_uart_store32(0, 'A'); hw->callback(0, 4, true);
  litex_uart_store32(0, 'A'); old->callback(0, 4, true);
  puts("PASS: NEMU IRQ10, CU08/egos shared register state and RX/TX");
}
