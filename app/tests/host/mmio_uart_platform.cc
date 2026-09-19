// Exercise production MMIO routing and serial models, not duplicated register logic.
#include "../../../sim/csrc/mem/memory.cc"
#include "../../../sim/csrc/mem/mmio-serial.cc"
NPCState npc{};
VerilatedContext *contextp = nullptr;
static unsigned delivered_irq;
void nsim_plic_raise(uint32_t irq) { delivered_irq = irq; }
bool sdb_is_batch_mode() { return true; }
void npc_abort() { abort(); }
void difftest_skip_ref() {}
void mmio_virtio_blk_handle(paddr_t, word_t, char, bool, word_t *) { abort(); }
void mmio_sdhci_handle(paddr_t, word_t, char, bool, word_t *) { abort(); }
void mmio_litex_spi_handle(paddr_t, word_t, char, bool, word_t *) { abort(); }
int main() {
    // A real enabled RX interrupt must use the same source as QEMU's UART.
    ier = UART_IER_RDI;
    rx_push('X');
    serial_update_irq();
    assert(delivered_irq == 10);
    init_litex_uart();
    litex_uart_inited = true; // no host terminal setup in this unit test
    word_t value = 0;
    for (paddr_t base : {paddr_t(0xf0001800u), paddr_t(0xf0001000u)}) {
        const auto *map = find_mmio_map(base);
        assert(map && map->handler);
        map->handler(base + 0x14, 3, 15, true, nullptr);
        map->handler(base + 0x14, 0, 15, false, &value);
        assert(value == (word_t(3) << ((0x14 & (sizeof(word_t)-1))*8)));
        map->handler(base, 'A', 15, true, nullptr); // one byte per CSR write
        map->handler(base, 'Z', 0, true, nullptr);  // masked write must not print
    }
    const auto *hw = find_mmio_map(0xf0001800u);
    hw->handler(0xf0001800u, 0, 15, false, &value);
    assert(value == 'X');
    hw->handler(0xf0001808u, 0, 15, false, &value);
    assert(value == 1);
    puts("PASS: UART IRQ10, CU08/egos aliases, RX and CSR lane masking");
}
