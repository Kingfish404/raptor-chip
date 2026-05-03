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
}