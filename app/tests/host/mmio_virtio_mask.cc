// Exercise production register updates with full and sparse transaction masks.
#include "../../../sim/csrc/mem/mmio-virtio-blk.cc"
uint8_t *guest_to_host(paddr_t) { return nullptr; }
void nsim_plic_raise(uint32_t) {}
void (*ref_difftest_memcpy)(paddr_t, void *, size_t, bool) = nullptr;
int main() {
    reset_regs();
    blk.desc_addr = 0x11223344deadbeefull;
    mmio_virtio_blk_handle(0x80, 0x44332211, 0x0a, true, nullptr);
    assert(blk.desc_addr == 0x1122334444ad22efull);
    mmio_virtio_blk_handle(0x84, 0x88776655, 0x0f, true, nullptr);
    assert(blk.desc_addr == 0x8877665544ad22efull);
    mmio_virtio_blk_handle(0x81, 0x6655, 0x03, true, nullptr);
    assert(blk.desc_addr == 0x88776655446655efull);
    mmio_virtio_blk_handle(0x80, 0, 0, true, nullptr);
    assert(blk.desc_addr == 0x88776655446655efull);
    blk.interrupt_status = 0x01010101;
    mmio_virtio_blk_handle(0x64, 0x01010101, 0x05, true, nullptr);
    assert(blk.interrupt_status == 0x01000100);
    mmio_virtio_blk_handle(0x38, 0x100, 0x0f, true, nullptr);
    assert(blk.queue_num == 8);
    blk.status = 4;
    mmio_virtio_blk_handle(0x71, 0, 0x07, true, nullptr);
    assert(blk.status == 4 && blk.desc_addr == 0x88776655446655efull);
    mmio_virtio_blk_handle(0x70, 0, 0x0f, true, nullptr);
    assert(blk.status == 0 && blk.desc_addr == 0 && blk.queue_num == 0);
    puts("PASS: virtio register masks, split 64-bit address halves, W1C, clamp and reset");
}
