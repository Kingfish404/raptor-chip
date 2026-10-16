#include <device/map.h>
#include <device/block-image.h>
#include <memory/paddr.h>
#include "../../../nemu/src/device/disk.c"

FILE *log_fp;
static uint8_t memory[16384];
static unsigned interrupts;

bool log_enable(void) { return false; }
void assert_fail_msg(void) { abort(); }

uint8_t *new_space(int size)
{
  assert(size > 0);
  return calloc(1, size);
}

void add_mmio_map(const char *name, paddr_t address, void *space, uint32_t size, io_callback_t callback)
{
  assert(name && address == 0x10001000 && space && size == 4096 && callback);
}

bool paddr_dma_read(paddr_t address, void *buffer, size_t size)
{
  if (address < 0x80000000 || address - 0x80000000 > sizeof(memory) ||
      size > sizeof(memory) - (address - 0x80000000)) return false;
  memcpy(buffer, memory + (address - 0x80000000), size);
  return true;
}

bool paddr_dma_write(paddr_t address, const void *buffer, size_t size)
{
  if (address < 0x80000000 || address - 0x80000000 > sizeof(memory) ||
      size > sizeof(memory) - (address - 0x80000000)) return false;
  memcpy(memory + (address - 0x80000000), buffer, size);
  return true;
}

void plic_raise_block_irq(int source)
{
  assert(source == 1);
  interrupts++;
}

void storage_test_attach(const char *path, int mode)
{
  free(virtio_blk_base);
  virtio_blk_base = NULL;
  memset(memory, 0, sizeof(memory));
  interrupts = 0;
  virtio_blk_set_disk_image(path);
  virtio_blk_set_disk_mode(mode);
  init_disk();
}

void storage_test_close(void)
{
  close_disk();
}

uint8_t *storage_test_memory(void) { return memory; }
unsigned storage_test_interrupts(void) { return interrupts; }

uint32_t storage_test_read(unsigned offset)
{
  virtio_blk_io_handler(offset, 4, false);
  return io_read_value(offset, 4);
}

void storage_test_write(unsigned offset, uint32_t value)
{
  io_write_value(offset, 4, value);
  virtio_blk_io_handler(offset, 4, true);
}
