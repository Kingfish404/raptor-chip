#include <common.h>
#include <device_write.h>
#include <memory.h>

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Supports both legacy bare-metal SDHCI base (0x40000000) and the platform
// Linux SDHCI window (0x42000000, IRQ 4) with SDMA + ADMA2 R/W DMA.
#define QEMU_SDHCI_PCI_ECAM_BASE 0x30008000u
#define QEMU_SDHCI_PCI_ECAM_SIZE 0x1000u
#define QEMU_SDHCI_BASE 0x40000000u
#define SDHCI_PLTFM_BASE 0x42000000u
#define SDHCI_IRQ 4u

#define SDHCI_DMA_ADDRESS 0x00u
#define SDHCI_BLOCK_SIZE_REG 0x04u
#define SDHCI_BLOCK_COUNT_REG 0x06u
#define SDHCI_ARGUMENT 0x08u
#define SDHCI_TRANSFER_MODE 0x0cu
#define SDHCI_RESPONSE0 0x10u
#define SDHCI_PRESENT_STATE 0x24u
#define SDHCI_HOST_CONTROL 0x28u
#define SDHCI_CLOCK_CONTROL 0x2cu
#define SDHCI_SOFTWARE_RESET 0x2fu
#define SDHCI_INT_STAT 0x30u
#define SDHCI_INT_ENABLE 0x34u
#define SDHCI_SIGNAL_ENABLE 0x38u
#define SDHCI_CAPABILITIES 0x40u
#define SDHCI_ADMA_ADDRESS 0x58u
#define SDHCI_HOST_VERSION 0xfcu

#define SDHCI_SECTOR_BYTES 512u

void nsim_plic_raise(uint32_t irq);

static struct
{
    const char *path;
    uint8_t *image;
    size_t image_size;
    uint8_t regs[0x100];
    uint8_t pci_ecam[QEMU_SDHCI_PCI_ECAM_SIZE];
    bool app_cmd;
    bool warned_no_image;
    bool legacy_byte_addr;
} sdhci;

static uint16_t load16(uint32_t off)
{
    return (uint16_t)sdhci.regs[off] | ((uint16_t)sdhci.regs[off + 1] << 8);
}

static uint32_t load32(uint32_t off)
{
    return (uint32_t)sdhci.regs[off] |
           ((uint32_t)sdhci.regs[off + 1] << 8) |
           ((uint32_t)sdhci.regs[off + 2] << 16) |
           ((uint32_t)sdhci.regs[off + 3] << 24);
}

static uint64_t load64(uint32_t off)
{
    return (uint64_t)load32(off) | ((uint64_t)load32(off + 4) << 32);
}

static void store16(uint32_t off, uint16_t val)
{
    sdhci.regs[off] = (uint8_t)val;
    sdhci.regs[off + 1] = (uint8_t)(val >> 8);
}

static void store32(uint32_t off, uint32_t val)
{
    sdhci.regs[off] = (uint8_t)val;
    sdhci.regs[off + 1] = (uint8_t)(val >> 8);
    sdhci.regs[off + 2] = (uint8_t)(val >> 16);
    sdhci.regs[off + 3] = (uint8_t)(val >> 24);
}

static void reset_controller(uint8_t mask)
{
    if (mask & 0x01u)
    {
        memset(sdhci.regs, 0, sizeof(sdhci.regs));
        // Card inserted + card state stable + write-protect switch off (writable)
        store32(SDHCI_PRESENT_STATE, 0x01ff0000u);
        // ADMA2 + High-Speed + SDMA + suspend/resume + 3.3V/1.8V, 52 MHz base clock
        store32(SDHCI_CAPABILITIES, 0x05e834b4u);
        // SD Host Specification Version 3.00
        store16(SDHCI_HOST_VERSION + 2, 0x0002u);
        sdhci.app_cmd = false;
        sdhci.legacy_byte_addr = true;
    }
    else
    {
        if (mask & 0x02u)
            store32(SDHCI_INT_STAT, load32(SDHCI_INT_STAT) & ~0x00ff0001u);
        if (mask & 0x04u)
            store32(SDHCI_INT_STAT, load32(SDHCI_INT_STAT) & ~0xff000002u);
    }
    sdhci.regs[SDHCI_SOFTWARE_RESET] = 0;
}

static void raise_sdhci_irq(uint32_t status_bits)
{
    uint32_t en = load32(SDHCI_INT_ENABLE);
    // Legacy bare-metal tests may not program INT_ENABLE before polling INT_STAT.
    if (en == 0)
        en = 0xffffffffu;
    uint32_t next_stat = load32(SDHCI_INT_STAT) | (status_bits & en);
    // Bit 15 (Error Interrupt) summarizes the error half and is not maskable.
    if (next_stat & 0xffff0000u)
        next_stat |= 0x00008000u;
    store32(SDHCI_INT_STAT, next_stat);
    if ((next_stat & load32(SDHCI_SIGNAL_ENABLE)) != 0)
        nsim_plic_raise(SDHCI_IRQ);
}

static void card_read_bytes(uint64_t disk_off, uint8_t *dst, size_t len)
{
    memset(dst, 0, len);
    if (sdhci.image == NULL)
    {
        if (!sdhci.warned_no_image)
        {
            Log("sdhci: no SD card image attached; reads return zeroes");
            sdhci.warned_no_image = true;
        }
        return;
    }
    if (disk_off < sdhci.image_size)
    {
        size_t avail = sdhci.image_size - (size_t)disk_off;
        size_t n = avail < len ? avail : len;
        memcpy(dst, sdhci.image + disk_off, n);
    }
}

static bool card_write_bytes(uint64_t disk_off, const uint8_t *src, size_t len)
{
    if (sdhci.image == NULL || disk_off + len > sdhci.image_size)
        return false;
    memcpy(sdhci.image + disk_off, src, len);
    return true;
}

static bool execute_dma_transfer(bool to_card, uint64_t disk_off, size_t total_bytes)
{
    uint8_t dma_sel = (sdhci.regs[SDHCI_HOST_CONTROL] >> 3) & 0x3u;
    uint8_t bounce[4096];

    if (dma_sel >= 2u)
    {
        // ADMA2 scatter-gather descriptor table (32-bit or 64-bit)
        uint64_t desc_pa = load64(SDHCI_ADMA_ADDRESS);
        size_t rem = total_bytes;
        uint64_t cur_disk = disk_off;
        for (unsigned guard = 0; guard < 4096 && rem > 0; guard++)
        {
            uint8_t entry[12];
            size_t entry_sz = (dma_sel == 3u) ? 12u : 8u;
            if (!dma_guest_read(desc_pa, entry, entry_sz))
                return false;
            uint16_t attr = (uint16_t)entry[0] | ((uint16_t)entry[1] << 8);
            uint16_t seg_raw = (uint16_t)entry[2] | ((uint16_t)entry[3] << 8);
            uint64_t buf_pa = (uint32_t)entry[4] | ((uint32_t)entry[5] << 8) |
                              ((uint32_t)entry[6] << 16) | ((uint32_t)entry[7] << 24);
            if (dma_sel == 3u)
            {
                uint64_t hi = (uint32_t)entry[8] | ((uint32_t)entry[9] << 8) |
                              ((uint32_t)entry[10] << 16) | ((uint32_t)entry[11] << 24);
                buf_pa |= hi << 32;
            }
            if (!(attr & 0x1u))
                break;
            size_t seg_len = (seg_raw == 0) ? 65536u : (size_t)seg_raw;
            uint8_t act = (attr >> 4) & 0x3u;
            if (act == 2u)
            {
                size_t take = seg_len < rem ? seg_len : rem;
                size_t pos = 0;
                while (pos < take)
                {
                    size_t chunk = (take - pos) < sizeof(bounce) ? (take - pos) : sizeof(bounce);
                    if (to_card)
                    {
                        if (!dma_guest_read(buf_pa + pos, bounce, chunk) ||
                            !card_write_bytes(cur_disk + pos, bounce, chunk))
                            return false;
                    }
                    else
                    {
                        card_read_bytes(cur_disk + pos, bounce, chunk);
                        if (!dma_guest_write(buf_pa + pos, bounce, chunk))
                            return false;
                    }
                    pos += chunk;
                }
                cur_disk += take;
                rem -= take;
            }
            else if (act == 3u)
            {
                desc_pa = buf_pa;
                continue;
            }
            if (attr & 0x2u)
                break;
            desc_pa += entry_sz;
        }
        return rem == 0;
    }

    // SDMA contiguous transfer
    uint64_t dma_pa = load32(SDHCI_DMA_ADDRESS);
    size_t pos = 0;
    while (pos < total_bytes)
    {
        size_t chunk = (total_bytes - pos) < sizeof(bounce) ? (total_bytes - pos) : sizeof(bounce);
        if (to_card)
        {
            if (!dma_guest_read(dma_pa + pos, bounce, chunk) ||
                !card_write_bytes(disk_off + pos, bounce, chunk))
                return false;
        }
        else
        {
            card_read_bytes(disk_off + pos, bounce, chunk);
            if (!dma_guest_write(dma_pa + pos, bounce, chunk))
                return false;
        }
        pos += chunk;
    }
    store32(SDHCI_DMA_ADDRESS, (uint32_t)(dma_pa + total_bytes));
    return true;
}

// Deliver a short read-data block (SCR, SD status, switch status) to the
// first ADMA2 descriptor buffer or to the SDMA address.
static void dma_write_small(uint32_t xfer_cmd, const uint8_t *buf, size_t len)
{
    if (!(xfer_cmd & 0x1u))
        return;
    uint64_t pa = load32(SDHCI_DMA_ADDRESS);
    if (((sdhci.regs[SDHCI_HOST_CONTROL] >> 3) & 0x3u) >= 2u)
    {
        uint8_t desc[8];
        if (!dma_guest_read(load64(SDHCI_ADMA_ADDRESS), desc, sizeof(desc)))
            return;
        pa = (uint32_t)desc[4] | ((uint32_t)desc[5] << 8) |
             ((uint32_t)desc[6] << 16) | ((uint32_t)desc[7] << 24);
    }
    dma_guest_write(pa, buf, len);
}

static void process_command()
{
    uint32_t xfer_cmd = load32(SDHCI_TRANSFER_MODE);
    uint32_t cmd_idx = (xfer_cmd >> 24) & 0x3fu;
    uint32_t arg = load32(SDHCI_ARGUMENT);
    uint16_t blk_sz = load16(SDHCI_BLOCK_SIZE_REG) & 0x0fffu;
    if (blk_sz == 0)
        blk_sz = SDHCI_SECTOR_BYTES;
    uint16_t blk_cnt = load16(SDHCI_BLOCK_COUNT_REG);
    if (!(xfer_cmd & 0x2u) || blk_cnt == 0)
        blk_cnt = 1;

    uint32_t irq_bits = 0x00000001u;  // Command Complete

    if (sdhci.app_cmd)
    {
        sdhci.app_cmd = false;
        switch (cmd_idx)
        {
        case 41:  // ACMD41: SD_SEND_OP_COND -> ready, CCS=1 (block addressed)
            sdhci.legacy_byte_addr = false;
            store32(SDHCI_RESPONSE0, 0xc0ff8000u);
            break;
        case 51:  // ACMD51: SEND_SCR (8 bytes big-endian)
        {
            static const uint8_t scr[8] = {0x02, 0x35, 0x80, 0x03, 0x00, 0x00, 0x00, 0x00};
            store32(SDHCI_RESPONSE0, 0x00000920u);
            dma_write_small(xfer_cmd, scr, sizeof(scr));
            irq_bits |= 0x00000002u;
            break;
        }
        case 13:  // ACMD13: SD_STATUS (64 bytes)
        {
            uint8_t sd_stat[64];
            memset(sd_stat, 0, sizeof(sd_stat));
            store32(SDHCI_RESPONSE0, 0x00000920u);
            dma_write_small(xfer_cmd, sd_stat, sizeof(sd_stat));
            irq_bits |= 0x00000002u;
            break;
        }
        default:
            store32(SDHCI_RESPONSE0, 0x00000920u);
            break;
        }
        raise_sdhci_irq(irq_bits);
        return;
    }

    switch (cmd_idx)
    {
    case 0:  // GO_IDLE_STATE
        store32(SDHCI_RESPONSE0, 0);
        break;
    case 2:  // ALL_SEND_CID (SDHCI shifts 136-bit R2 right by 8 bits into 0x10..0x1f)
        store32(SDHCI_RESPONSE0 + 0,  0x00015241u);
        store32(SDHCI_RESPONSE0 + 4,  0x50543031u);
        store32(SDHCI_RESPONSE0 + 8,  0x30525054u);
        store32(SDHCI_RESPONSE0 + 12, 0x001b5344u);
        break;
    case 3:  // SEND_RELATIVE_ADDR
        store32(SDHCI_RESPONSE0, 0x00010500u);
        break;
    case 6:  // SWITCH_FUNC (64-byte status block)
    {
        uint8_t sw_buf[64];
        memset(sw_buf, 0, sizeof(sw_buf));
        sw_buf[13] = 0x02;  // High-Speed supported
        store32(SDHCI_RESPONSE0, 0x00000900u);
        dma_write_small(xfer_cmd, sw_buf, sizeof(sw_buf));
        irq_bits |= 0x00000002u;
        break;
    }
    case 7:   // SELECT_CARD
    case 12:  // STOP_TRANSMISSION
    case 13:  // SEND_STATUS
    case 16:  // SET_BLOCKLEN
    case 23:  // SET_BLOCK_COUNT
        store32(SDHCI_RESPONSE0, 0x00000900u);
        break;
    case 8:   // SEND_IF_COND
        store32(SDHCI_RESPONSE0, arg);
        break;
    case 9:   // SEND_CSD (CSD v2.0 SDHC, shifted right by 8 bits per SDHCI R2 convention)
    {
        size_t sz = sdhci.image_size ? sdhci.image_size : (64ull * 1024ull * 1024ull);
        uint32_t c_size = (sz > 512 * 1024) ? (uint32_t)((sz / (512 * 1024)) - 1) : 0u;
        // Raw 128-bit CSD[127:0] with CRC stripped -> SDHCI stores CSD[127:8] in 0x1f..0x10:
        //   CSD[127:126]=01 (CSD v2.0), TAAC=0x0e, NSAC=0x00, TRAN_SPEED=0x32,
        //   CCC=0x5b5, READ_BL_LEN=9, C_SIZE[69:48]=c_size, ERASE_BLK_EN=1, SECTOR_SIZE=0x7f,
        //   WRITE_BL_LEN=9.
        uint64_t hi64 = (0x400e00325b590000ull) | ((uint64_t)(c_size >> 16) & 0x3full);
        uint64_t lo64 = ((uint64_t)(c_size & 0xffffu) << 48) | 0x00007fc009004000ull;
        // Shift 128-bit value right by 8 bits into RESPONSE[0..3]
        uint64_t r_lo = (lo64 >> 8) | (hi64 << 56);
        uint64_t r_hi = (hi64 >> 8);
        store32(SDHCI_RESPONSE0 + 0,  (uint32_t)r_lo);
        store32(SDHCI_RESPONSE0 + 4,  (uint32_t)(r_lo >> 32));
        store32(SDHCI_RESPONSE0 + 8,  (uint32_t)r_hi);
        store32(SDHCI_RESPONSE0 + 12, (uint32_t)(r_hi >> 32));
        break;
    }
    case 55:  // APP_CMD
        sdhci.app_cmd = true;
        store32(SDHCI_RESPONSE0, 0x00000920u);
        break;
    case 17:
    case 18:
    {
        uint64_t disk_off = sdhci.legacy_byte_addr ? (uint64_t)arg
                                                   : (uint64_t)arg * SDHCI_SECTOR_BYTES;
        size_t nblocks = (cmd_idx == 17) ? 1u : (size_t)blk_cnt;
        if (!execute_dma_transfer(false, disk_off, nblocks * blk_sz))
            irq_bits |= 0x00208000u;
        else
            irq_bits |= 0x00000002u;
        store32(SDHCI_RESPONSE0, 0x00000900u);
        break;
    }
    case 24:
    case 25:
    {
        uint64_t disk_off = sdhci.legacy_byte_addr ? (uint64_t)arg
                                                   : (uint64_t)arg * SDHCI_SECTOR_BYTES;
        size_t nblocks = (cmd_idx == 24) ? 1u : (size_t)blk_cnt;
        if (!execute_dma_transfer(true, disk_off, nblocks * blk_sz))
            irq_bits |= 0x00208000u;
        else
            irq_bits |= 0x00000002u;
        store32(SDHCI_RESPONSE0, 0x00000900u);
        break;
    }
    default:
        // Unimplemented optional MMC/SDIO probe command (CMD1, CMD5, CMD52): Command Timeout
        irq_bits = 0x00018000u;
        break;
    }

    raise_sdhci_irq(irq_bits);
}

static void write_sdhci(paddr_t offset, word_t wdata, char wmask)
{
    bool command_written = false;
    uint32_t int_clear = 0;
    uint8_t sw_rst = 0;

    for (uint32_t i = 0; i < sizeof(word_t); i++)
    {
        if (((uint8_t)wmask & (1u << i)) == 0)
            continue;
        uint32_t reg = (uint32_t)offset + i;
        if (reg >= sizeof(sdhci.regs))
            continue;

        uint8_t byte = (uint8_t)(wdata >> (i * 8));
        if (reg >= SDHCI_INT_STAT && reg < SDHCI_INT_STAT + 4)
        {
            int_clear |= (uint32_t)byte << ((reg - SDHCI_INT_STAT) * 8);
            continue;
        }
        if (reg == SDHCI_SOFTWARE_RESET)
        {
            sw_rst = byte;
            continue;
        }
        // Preserve read-only present-state, capabilities and version registers
        if ((reg >= SDHCI_PRESENT_STATE && reg < SDHCI_PRESENT_STATE + 4) ||
            (reg >= SDHCI_CAPABILITIES && reg < SDHCI_CAPABILITIES + 8) ||
            reg >= SDHCI_HOST_VERSION)
            continue;

        sdhci.regs[reg] = byte;
        if (reg == SDHCI_CLOCK_CONTROL && (byte & 0x1u))
            sdhci.regs[SDHCI_CLOCK_CONTROL] |= 0x2u;  // Internal Clock Stable
        if (reg == SDHCI_TRANSFER_MODE + 3)
            command_written = true;
    }

    if (sw_rst != 0)
        reset_controller(sw_rst);

    if (int_clear != 0)
    {
        uint32_t stat = load32(SDHCI_INT_STAT) & ~int_clear;
        if (stat & 0xffff0000u)
            stat |= 0x00008000u;
        else
            stat &= ~0x00008000u;
        store32(SDHCI_INT_STAT, stat);
    }

    if (command_written)
        process_command();
}

static word_t read_sdhci(paddr_t offset)
{
    uint32_t word_offset = (uint32_t)offset & (sizeof(word_t) - 1u);
    word_t value = 0;
    for (uint32_t i = 0; i + word_offset < sizeof(word_t); i++)
    {
        uint32_t reg = (uint32_t)offset + i;
        if (reg >= sizeof(sdhci.regs))
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
    memset(sdhci.pci_ecam, 0, sizeof(sdhci.pci_ecam));
    reset_controller(0x01u);

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
    Log("sdhci: loaded %s (%zu bytes, R/W SDMA+ADMA2)", sdhci.path, sdhci.image_size);
}

void mmio_sdhci_handle(paddr_t addr, word_t wdata, char wmask, bool is_write, word_t *data)
{
    if (addr >= QEMU_SDHCI_PCI_ECAM_BASE &&
        addr < QEMU_SDHCI_PCI_ECAM_BASE + QEMU_SDHCI_PCI_ECAM_SIZE)
    {
        paddr_t offset = addr - QEMU_SDHCI_PCI_ECAM_BASE;
        if (is_write)
            write_pci_ecam(offset, wdata, wmask);
        else if (data != NULL)
            *data = read_pci_ecam(offset);
        return;
    }

    paddr_t base = (addr >= SDHCI_PLTFM_BASE) ? SDHCI_PLTFM_BASE : QEMU_SDHCI_BASE;
    paddr_t offset = addr - base;
    if (is_write)
        write_sdhci(offset, wdata, wmask);
    else if (data != NULL)
        *data = read_sdhci(offset);
}
