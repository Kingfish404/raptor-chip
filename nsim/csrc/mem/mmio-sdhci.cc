#include <common.h>
#include <memory.h>

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define QEMU_SDHCI_PCI_ECAM_BASE 0x30008000u
#define QEMU_SDHCI_PCI_ECAM_SIZE 0x1000u
#define QEMU_SDHCI_BASE 0x40000000u
#define QEMU_SDHCI_SIZE 0x100u

#define SDHCI_DMA_ADDRESS 0x00u
#define SDHCI_ARGUMENT 0x08u
#define SDHCI_CMD_AND_MODE 0x0cu
#define SDHCI_RESPONSE0 0x10u
#define SDHCI_PRESENT_STATE 0x24u
#define SDHCI_SOFTWARE_RESET 0x2fu
#define SDHCI_INT_STAT 0x30u

#define SDHCI_CMD_READ_SINGLE_BLOCK 17u
#define SDHCI_BLOCK_SIZE 512u

static struct
{
    const char *path;
    uint8_t *image;
    size_t image_size;
    uint8_t regs[QEMU_SDHCI_SIZE];
    uint8_t pci_ecam[QEMU_SDHCI_PCI_ECAM_SIZE];
    bool warned_no_image;
} sdhci;

static uint32_t load32(uint32_t offset)
{
    return (uint32_t)sdhci.regs[offset] |
           ((uint32_t)sdhci.regs[offset + 1] << 8) |
           ((uint32_t)sdhci.regs[offset + 2] << 16) |
           ((uint32_t)sdhci.regs[offset + 3] << 24);
}

static void store32(uint32_t offset, uint32_t value)
{
    sdhci.regs[offset] = (uint8_t)value;
    sdhci.regs[offset + 1] = (uint8_t)(value >> 8);
    sdhci.regs[offset + 2] = (uint8_t)(value >> 16);
    sdhci.regs[offset + 3] = (uint8_t)(value >> 24);
}

static bool guest_write_bytes(uint32_t addr, const uint8_t *src, size_t len)
{
    for (size_t i = 0; i < len; i++)
    {
        uint8_t *dst = guest_to_host((paddr_t)(addr + i));
        if (dst == NULL)
            return false;
        *dst = src[i];
    }
    return true;
}

static void dma_read_block()
{
    uint8_t block[SDHCI_BLOCK_SIZE];
    memset(block, 0, sizeof(block));

    uint32_t disk_offset = load32(SDHCI_ARGUMENT);
    if (sdhci.image == NULL)
    {
        if (!sdhci.warned_no_image)
        {
            Log("sdhci: no SD card image attached; reads return zeroes");
            sdhci.warned_no_image = true;
        }
    }
    else if (disk_offset < sdhci.image_size)
    {
        size_t remain = sdhci.image_size - disk_offset;
        size_t ncopy = remain < sizeof(block) ? remain : sizeof(block);
        memcpy(block, sdhci.image + disk_offset, ncopy);
    }

    uint32_t dma_addr = load32(SDHCI_DMA_ADDRESS);
    if (!guest_write_bytes(dma_addr, block, sizeof(block)))
        Log("sdhci: DMA target is unmapped: 0x%08x", dma_addr);
}

static void complete_command()
{
    store32(SDHCI_INT_STAT, load32(SDHCI_INT_STAT) | 0x1u);
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

static void write_sdhci(paddr_t offset, word_t wdata, char wmask)
{
    bool command_written = false;
    uint32_t int_clear = 0;

    for (uint32_t i = 0; i < sizeof(word_t); i++)
    {
        if (((uint8_t)wmask & (1u << i)) == 0)
            continue;

        uint32_t reg = (uint32_t)offset + i;
        if (reg >= QEMU_SDHCI_SIZE)
            continue;

        uint8_t byte = (uint8_t)(wdata >> (i * 8));
        if (reg >= SDHCI_INT_STAT && reg < SDHCI_INT_STAT + 4)
        {
            int_clear |= (uint32_t)byte << ((reg - SDHCI_INT_STAT) * 8);
            continue;
        }

        sdhci.regs[reg] = byte;
        if (reg >= SDHCI_CMD_AND_MODE && reg < SDHCI_CMD_AND_MODE + 4)
            command_written = true;
    }

    if (int_clear != 0)
        store32(SDHCI_INT_STAT, load32(SDHCI_INT_STAT) & ~int_clear);

    sdhci.regs[SDHCI_SOFTWARE_RESET] = 0;
    store32(SDHCI_PRESENT_STATE, 0);

    if (command_written)
        process_command();
}

static word_t read_sdhci(paddr_t offset)
{
    sdhci.regs[SDHCI_SOFTWARE_RESET] = 0;
    store32(SDHCI_PRESENT_STATE, 0);

    uint32_t word_offset = (uint32_t)offset & (sizeof(word_t) - 1u);
    word_t value = 0;
    for (uint32_t i = 0; i + word_offset < sizeof(word_t); i++)
    {
        uint32_t reg = (uint32_t)offset + i;
        if (reg >= QEMU_SDHCI_SIZE)
            break;
        value |= (word_t)sdhci.regs[reg] << ((word_offset + i) * 8);
    }
    return value;
}

static void write_pci_ecam(paddr_t offset, word_t wdata, char wmask)
{
    for (uint32_t i = 0; i < sizeof(word_t); i++)
    {
        if (((uint8_t)wmask & (1u << i)) == 0)
            continue;
        uint32_t reg = (uint32_t)offset + i;
        if (reg < QEMU_SDHCI_PCI_ECAM_SIZE)
            sdhci.pci_ecam[reg] = (uint8_t)(wdata >> (i * 8));
    }
}

static word_t read_pci_ecam(paddr_t offset)
{
    uint32_t word_offset = (uint32_t)offset & (sizeof(word_t) - 1u);
    word_t value = 0;
    for (uint32_t i = 0; i + word_offset < sizeof(word_t); i++)
    {
        uint32_t reg = (uint32_t)offset + i;
        if (reg >= QEMU_SDHCI_PCI_ECAM_SIZE)
            break;
        value |= (word_t)sdhci.pci_ecam[reg] << ((word_offset + i) * 8);
    }
    return value;
}

void sdhci_set_image(const char *path)
{
    sdhci.path = path;
}

void init_sdhci()
{
    free(sdhci.image);
    sdhci.image = NULL;
    sdhci.image_size = 0;
    sdhci.warned_no_image = false;
    memset(sdhci.regs, 0, sizeof(sdhci.regs));
    memset(sdhci.pci_ecam, 0, sizeof(sdhci.pci_ecam));

    if (sdhci.path == NULL || sdhci.path[0] == '\0')
        return;

    FILE *fp = fopen(sdhci.path, "rb");
    if (fp == NULL)
    {
        fprintf(stderr, "[sdhci] cannot open %s: %s\n", sdhci.path, strerror(errno));
        exit(1);
    }
    if (fseek(fp, 0, SEEK_END) != 0)
    {
        fprintf(stderr, "[sdhci] cannot seek %s\n", sdhci.path);
        exit(1);
    }
    long size = ftell(fp);
    if (size <= 0)
    {
        fprintf(stderr, "[sdhci] empty SD card image: %s\n", sdhci.path);
        exit(1);
    }
    rewind(fp);

    sdhci.image = (uint8_t *)malloc((size_t)size);
    if (sdhci.image == NULL)
    {
        fprintf(stderr, "[sdhci] out of memory loading %s\n", sdhci.path);
        exit(1);
    }
    if (fread(sdhci.image, 1, (size_t)size, fp) != (size_t)size)
    {
        fprintf(stderr, "[sdhci] short read loading %s\n", sdhci.path);
        exit(1);
    }
    fclose(fp);
    sdhci.image_size = (size_t)size;
    Log("sdhci: loaded %s (%zu bytes, read-only)", sdhci.path, sdhci.image_size);
}

void mmio_sdhci_handle(paddr_t addr, word_t wdata, char wmask, bool is_write, word_t *data)
{
    if (addr >= QEMU_SDHCI_PCI_ECAM_BASE && addr < QEMU_SDHCI_PCI_ECAM_BASE + QEMU_SDHCI_PCI_ECAM_SIZE)
    {
        paddr_t offset = addr - QEMU_SDHCI_PCI_ECAM_BASE;
        if (is_write)
            write_pci_ecam(offset, wdata, wmask);
        else if (data != NULL)
            *data = read_pci_ecam(offset);
        return;
    }

    paddr_t offset = addr - QEMU_SDHCI_BASE;
    if (is_write)
        write_sdhci(offset, wdata, wmask);
    else if (data != NULL)
        *data = read_sdhci(offset);
}

bool mmio_sdhci_contains(paddr_t addr)
{
    return (addr >= QEMU_SDHCI_PCI_ECAM_BASE && addr < QEMU_SDHCI_PCI_ECAM_BASE + QEMU_SDHCI_PCI_ECAM_SIZE) ||
           (addr >= QEMU_SDHCI_BASE && addr < QEMU_SDHCI_BASE + QEMU_SDHCI_SIZE);
}