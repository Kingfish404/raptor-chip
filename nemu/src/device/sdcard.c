/***************************************************************************************
* Copyright (c) 2014-2022 Zihao Yu, Nanjing University
*
* NEMU is licensed under Mulan PSL v2.
* You can use this software according to the terms and conditions of the Mulan PSL v2.
* You may obtain a copy of Mulan PSL v2 at:
*          http://license.coscl.org.cn/MulanPSL2
*
* THIS SOFTWARE IS PROVIDED ON AN "AS IS" BASIS, WITHOUT WARRANTIES OF ANY KIND,
* EITHER EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO NON-INFRINGEMENT,
* MERCHANTABILITY OR FIT FOR A PARTICULAR PURPOSE.
*
* See the Mulan PSL v2 for more details.
***************************************************************************************/

#include <common.h>
#include <device/map.h>
#include <memory/paddr.h>

#define QEMU_SDHCI_PCI_ECAM_BASE 0x30008000u
#define QEMU_SDHCI_PCI_ECAM_SIZE 0x1000u

#define SDHCI_SIZE 0x100u
#define SDHCI_DMA_ADDRESS 0x00u
#define SDHCI_ARGUMENT 0x08u
#define SDHCI_CMD_AND_MODE 0x0cu
#define SDHCI_RESPONSE0 0x10u
#define SDHCI_PRESENT_STATE 0x24u
#define SDHCI_SOFTWARE_RESET 0x2fu
#define SDHCI_INT_STAT 0x30u

#define SDHCI_CMD_READ_SINGLE_BLOCK 17u
#define SDHCI_BLOCK_SIZE 512u

static const char *sdcard_runtime_img = NULL;
static uint8_t *sdhci_space = NULL;
static uint8_t *pci_ecam_space = NULL;
static uint8_t *sdcard_image = NULL;
static size_t sdcard_image_size = 0;
static uint32_t sdhci_int_stat = 0;
static bool warned_no_image = false;

static uint32_t load32(uint32_t offset)
{
  return (uint32_t)sdhci_space[offset] |
         ((uint32_t)sdhci_space[offset + 1] << 8) |
         ((uint32_t)sdhci_space[offset + 2] << 16) |
         ((uint32_t)sdhci_space[offset + 3] << 24);
}

static void store32(uint32_t offset, uint32_t value)
{
  sdhci_space[offset] = (uint8_t)value;
  sdhci_space[offset + 1] = (uint8_t)(value >> 8);
  sdhci_space[offset + 2] = (uint8_t)(value >> 16);
  sdhci_space[offset + 3] = (uint8_t)(value >> 24);
}

static bool overlaps(uint32_t offset, int len, uint32_t reg, uint32_t size)
{
  return offset < reg + size && offset + (uint32_t)len > reg;
}

static void dma_read_block()
{
  uint8_t block[SDHCI_BLOCK_SIZE];
  memset(block, 0, sizeof(block));

  uint32_t disk_offset = load32(SDHCI_ARGUMENT);
  if (sdcard_image == NULL)
  {
    if (!warned_no_image)
    {
      Log("sdhci: no SD card image attached; reads return zeroes");
      warned_no_image = true;
    }
  }
  else if (disk_offset < sdcard_image_size)
  {
    size_t remain = sdcard_image_size - disk_offset;
    size_t ncopy = remain < sizeof(block) ? remain : sizeof(block);
    memcpy(block, sdcard_image + disk_offset, ncopy);
  }

  uint32_t dma_addr = load32(SDHCI_DMA_ADDRESS);
  memcpy(guest_to_host(dma_addr), block, sizeof(block));
}

static void complete_command()
{
  sdhci_int_stat |= 0x1u;
  store32(SDHCI_INT_STAT, sdhci_int_stat);
}

static void process_command()
{
  uint32_t cmd_mode = load32(SDHCI_CMD_AND_MODE);
  uint32_t cmd_idx = (cmd_mode >> 24) & 0x3fu;

  switch (cmd_idx)
  {
  case 3:
    store32(SDHCI_RESPONSE0, 1u << 16);
    break;
  case SDHCI_CMD_READ_SINGLE_BLOCK:
    dma_read_block();
    break;
  default:
    break;
  }

  complete_command();
}

static void prepare_sdhci_read(void)
{
  sdhci_space[SDHCI_SOFTWARE_RESET] = 0;
  store32(SDHCI_PRESENT_STATE, 0);
  store32(SDHCI_INT_STAT, sdhci_int_stat);
}

static void sdhci_io_handler(uint32_t offset, int len, bool is_write)
{
  if (!is_write)
  {
    prepare_sdhci_read();
    return;
  }

  if (overlaps(offset, len, SDHCI_INT_STAT, 4))
  {
    uint32_t clear = load32(SDHCI_INT_STAT);
    sdhci_int_stat &= ~clear;
    store32(SDHCI_INT_STAT, sdhci_int_stat);
  }

  sdhci_space[SDHCI_SOFTWARE_RESET] = 0;
  store32(SDHCI_PRESENT_STATE, 0);

  if (overlaps(offset, len, SDHCI_CMD_AND_MODE, 4))
    process_command();
}

static void pci_ecam_io_handler(uint32_t offset, int len, bool is_write)
{
  (void)offset;
  (void)len;
  (void)is_write;
}

void sdcard_set_image(const char *path)
{
  sdcard_runtime_img = path;
}

static void load_sdcard_image(const char *path)
{
  if (path == NULL || path[0] == '\0')
    return;

  FILE *fp = fopen(path, "rb");
  Assert(fp, "Can not open SD card image '%s'", path);
  fseek(fp, 0, SEEK_END);
  long size = ftell(fp);
  Assert(size > 0, "Empty SD card image '%s'", path);
  rewind(fp);

  sdcard_image = malloc((size_t)size);
  Assert(sdcard_image, "Failed to allocate SD card image buffer");
  int ret = fread(sdcard_image, (size_t)size, 1, fp);
  assert(ret == 1);
  fclose(fp);

  sdcard_image_size = (size_t)size;
  Log("sdhci: loaded %s (%zu bytes, read-only)", path, sdcard_image_size);
}

// ---------------------------------------------------------------------------
// LiteX SPI SD-card controller (egos HARDWARE platform), at 0xF0008000.
// Mirrors nsim/csrc/mem/mmio-litex-spi.cc.  Reuses sdcard_image loaded
// above so a single --sdcard image serves both QEMU SDHCI and LiteX SPI.
// Register layout:
//   0x00 CONTROL (bit 0 starts a transfer)
//   0x04 STATUS  (bit 0 = transfer done)
//   0x08 MOSI    (TX byte)
//   0x0C MISO    (RX byte)
//   0x10 CS      (bit 0 selected)
//   0x18 CLKDIV
// ---------------------------------------------------------------------------
#define LITEX_SPI_BASE     0xF0008000u
#define LITEX_SPI_SIZE     0x100u
#define LITEX_SPI_CONTROL  0x00u
#define LITEX_SPI_STATUS   0x04u
#define LITEX_SPI_MOSI     0x08u
#define LITEX_SPI_MISO     0x0Cu
#define LITEX_SPI_CS       0x10u
#define LITEX_SPI_CLKDIV   0x18u

#define SD_BLOCK_SIZE      512u

#define SPI_RXQ_CAP        1024u

static uint8_t *spi_space = NULL;
static struct {
  uint32_t control, status, mosi, miso, cs, clkdiv;
  uint8_t  cmd_buf[6];
  uint32_t cmd_len;
  uint8_t  rxq[SPI_RXQ_CAP];
  uint32_t rxq_head, rxq_tail;
} spi;

static inline bool spi_rxq_empty(void) { return spi.rxq_head == spi.rxq_tail; }

static inline void spi_rxq_push(uint8_t b) {
  uint32_t next = (spi.rxq_tail + 1u) % SPI_RXQ_CAP;
  if (next == spi.rxq_head) return; // drop on overflow
  spi.rxq[spi.rxq_tail] = b;
  spi.rxq_tail = next;
}

static inline uint8_t spi_rxq_pop(void) {
  uint8_t b = spi.rxq[spi.rxq_head];
  spi.rxq_head = (spi.rxq_head + 1u) % SPI_RXQ_CAP;
  return b;
}

static void spi_enqueue_cmd17_payload(uint32_t byte_addr) {
  uint8_t block[SD_BLOCK_SIZE];
  memset(block, 0, sizeof(block));

  if (sdcard_image == NULL) {
    if (!warned_no_image) {
      Log("litex-spi: no SD card image attached; reads return zeroes");
      warned_no_image = true;
    }
  } else if (byte_addr < sdcard_image_size) {
    size_t remain = sdcard_image_size - byte_addr;
    size_t ncopy  = remain < sizeof(block) ? remain : sizeof(block);
    memcpy(block, sdcard_image + byte_addr, ncopy);
  }

  spi_rxq_push(0xFE);
  for (size_t i = 0; i < sizeof(block); i++) spi_rxq_push(block[i]);
  spi_rxq_push(0xFF);
  spi_rxq_push(0xFF);
}

static void spi_handle_sd_command(const uint8_t cmd[6]) {
  uint8_t  idx = cmd[0] & 0x3Fu;
  uint32_t arg = ((uint32_t)cmd[1] << 24) | ((uint32_t)cmd[2] << 16) |
                 ((uint32_t)cmd[3] << 8)  |  (uint32_t)cmd[4];
  switch (idx) {
  case 0:  // GO_IDLE_STATE
    spi_rxq_push(0x01); break;
  case 8:  // SEND_IF_COND -> R7
    spi_rxq_push(0x01);
    spi_rxq_push(0x00); spi_rxq_push(0x00);
    spi_rxq_push(0x01); spi_rxq_push(0xAA);
    break;
  case 55: // APP_CMD
    spi_rxq_push(0x01); break;
  case 41: // ACMD41 SD_SEND_OP_COND
    spi_rxq_push(0x00); break;
  case 17: // READ_SINGLE_BLOCK (SDHC: arg is block index)
    spi_rxq_push(0x00);
    spi_enqueue_cmd17_payload(arg * SD_BLOCK_SIZE);
    break;
  default:
    spi_rxq_push(0x00); break;
  }
}

static uint8_t spi_transfer(uint8_t tx) {
  bool selected = (spi.cs & 0x1u) != 0u;
  if (!selected) {
    spi.cmd_len = 0;
    return 0xFF;
  }
  if (!spi_rxq_empty()) return spi_rxq_pop();

  if (spi.cmd_len == 0) {
    if ((tx & 0xC0u) == 0x40u) spi.cmd_buf[spi.cmd_len++] = tx;
    return 0xFF;
  }
  spi.cmd_buf[spi.cmd_len++] = tx;
  if (spi.cmd_len == 6) {
    spi_handle_sd_command(spi.cmd_buf);
    spi.cmd_len = 0;
  }
  return 0xFF;
}

static inline uint32_t spi_load_reg(uint32_t off) {
  return ((uint32_t)spi_space[off]) |
         ((uint32_t)spi_space[off + 1] << 8) |
         ((uint32_t)spi_space[off + 2] << 16) |
         ((uint32_t)spi_space[off + 3] << 24);
}
static inline void spi_store_reg(uint32_t off, uint32_t val) {
  spi_space[off]     = (uint8_t)val;
  spi_space[off + 1] = (uint8_t)(val >> 8);
  spi_space[off + 2] = (uint8_t)(val >> 16);
  spi_space[off + 3] = (uint8_t)(val >> 24);
}

static void spi_do_control_write(uint32_t control) {
  spi.control = control;
  spi.status &= ~1u;
  if ((control & 0x1u) == 0u) return;
  uint8_t rx = spi_transfer((uint8_t)(spi.mosi & 0xFFu));
  spi.miso = (spi.miso & ~0xFFu) | (uint32_t)rx;
  spi.status |= 1u;
  spi_store_reg(LITEX_SPI_STATUS, spi.status);
  spi_store_reg(LITEX_SPI_MISO,   spi.miso);
}

static void litex_spi_io_handler(uint32_t offset, int len, bool is_write) {
  uint32_t reg = offset & ~0x3u;

  if (is_write) {
    // Snapshot the byte-aligned word that was just written by the dispatcher
    // and update our shadow state.  Only act on CONTROL when the bit-0 byte
    // (offset 0) is part of the access — matches the nsim model and avoids
    // re-triggering on each byte of a 32-bit store.
    bool ctrl_start_byte = false;
    for (int i = 0; i < len; i++) {
      uint32_t bo = offset + (uint32_t)i;
      if ((bo & ~0x3u) == LITEX_SPI_CONTROL && (bo & 0x3u) == 0u) {
        ctrl_start_byte = true;
      }
    }
    uint32_t val = spi_load_reg(reg);
    switch (reg) {
    case LITEX_SPI_CONTROL: spi.control = val; break;
    case LITEX_SPI_STATUS:  spi.status  = val; break;
    case LITEX_SPI_MOSI:    spi.mosi    = val; break;
    case LITEX_SPI_MISO:    spi.miso    = val; break;
    case LITEX_SPI_CS:      spi.cs      = val; break;
    case LITEX_SPI_CLKDIV:  spi.clkdiv  = val; break;
    default: break;
    }
    if (ctrl_start_byte) spi_do_control_write(spi.control);
    return;
  }

  uint32_t val = 0;
  switch (reg) {
  case LITEX_SPI_CONTROL: val = spi.control; break;
  case LITEX_SPI_STATUS:  val = spi.status;  break;
  case LITEX_SPI_MOSI:    val = spi.mosi;    break;
  case LITEX_SPI_MISO:    val = spi.miso;    break;
  case LITEX_SPI_CS:      val = spi.cs;      break;
  case LITEX_SPI_CLKDIV:  val = spi.clkdiv;  break;
  default:                val = 0;           break;
  }
  spi_store_reg(reg, val);
}

static void init_litex_spi_sd(void) {
  spi_space = new_space(LITEX_SPI_SIZE);
  memset(spi_space, 0, LITEX_SPI_SIZE);
  memset(&spi, 0, sizeof(spi));
  spi.status = 1u;
  spi.mosi   = 0xFFu;
  spi.miso   = 0xFFu;
  add_mmio_map("litex-spi-sd", LITEX_SPI_BASE, spi_space,
               LITEX_SPI_SIZE, litex_spi_io_handler);
}

void init_sdcard()
{
  sdhci_space = new_space(SDHCI_SIZE);
  pci_ecam_space = new_space(QEMU_SDHCI_PCI_ECAM_SIZE);
  add_mmio_map("sdhci", CONFIG_SDCARD_CTL_MMIO, sdhci_space, SDHCI_SIZE, sdhci_io_handler);
  add_mmio_map("sdhci-pci-ecam", QEMU_SDHCI_PCI_ECAM_BASE, pci_ecam_space, QEMU_SDHCI_PCI_ECAM_SIZE, pci_ecam_io_handler);

  memset(sdhci_space, 0, SDHCI_SIZE);
  memset(pci_ecam_space, 0, QEMU_SDHCI_PCI_ECAM_SIZE);
  sdhci_int_stat = 0;
  warned_no_image = false;

  const char *img = sdcard_runtime_img;
  if (img == NULL || img[0] == '\0')
    img = CONFIG_SDCARD_IMG_PATH;
  load_sdcard_image(img);

  init_litex_spi_sd();
}