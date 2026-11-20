#include <common.h>
#include <device_write.h>
#include <memory.h>

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <map>

// Standard PCIe Host Bridge (pci-host-ecam-generic at 0x41000000) + NVM Express
// 1.4 Controller (BDF 00:01.0, BAR0 default 0x50000000, INTA -> PLIC IRQ 11).
// Supports Admin + I/O Submission/Completion Queues and PRP1/PRP2/PRP-List DMA.
#define PCIE_ECAM_BASE 0x41000000u
#define PCIE_ECAM_SIZE 0x01000000u
#define NVME_DEFAULT_BAR0 0x50000000u
#define NVME_SC_DATA_XFER_ERROR 0x0004u
#define NVME_SC_INVALID_OPCODE 0x0001u
#define NVME_SC_LBA_RANGE 0x0080u  // Generic status: LBA Out of Range
#define NVME_BAR_BYTES 0x4000u
#define NVME_IRQ 11u
#define NVME_SECTOR_SIZE 512u
#define NVME_PAGE_SIZE 4096u

void nsim_plic_raise(uint32_t irq);

struct nvme_sq_t
{
    uint64_t addr;
    uint16_t size;
    uint16_t head;
    uint16_t cqid;
};

struct nvme_cq_t
{
    uint64_t addr;
    uint16_t size;
    uint16_t tail;
    uint8_t phase;
    bool irq_en;
};

static struct
{
    const char *path;
    uint8_t *image;
    size_t image_size;

    uint32_t bar0;
    bool bar0_sizing;
    uint16_t pci_cmd;
    uint8_t int_line;

    uint32_t cc;
    uint32_t csts;
    uint32_t intms;
    uint32_t aqa;
    uint64_t asq;
    uint64_t acq;
    bool irq_asserted;

    std::map<uint16_t, nvme_sq_t> sqs;
    std::map<uint16_t, nvme_cq_t> cqs;
} nvme_dev;

void nvme_set_image(const char *path)
{
    nvme_dev.path = path;
}

static void reset_nvme_ctrl()
{
    nvme_dev.cc = 0;
    nvme_dev.csts = 0;
    nvme_dev.intms = 0;
    nvme_dev.irq_asserted = false;
    nvme_dev.sqs.clear();
    nvme_dev.cqs.clear();
}

void init_pcie_nvme()
{
    free(nvme_dev.image);
    nvme_dev.image = NULL;
    nvme_dev.image_size = 0;
    nvme_dev.bar0 = NVME_DEFAULT_BAR0;
    nvme_dev.bar0_sizing = false;
    nvme_dev.pci_cmd = 0x0006u;
    nvme_dev.int_line = NVME_IRQ;
    nvme_dev.aqa = 0;
    nvme_dev.asq = 0;
    nvme_dev.acq = 0;
    reset_nvme_ctrl();

    if (nvme_dev.path == NULL || nvme_dev.path[0] == '\0')
        return;

    FILE *fp = fopen(nvme_dev.path, "rb");
    if (fp == NULL)
    {
        fprintf(stderr, "[nvme] cannot open %s: %s\n", nvme_dev.path, strerror(errno));
        exit(1);
    }
    if (fseek(fp, 0, SEEK_END) != 0)
    {
        fprintf(stderr, "[nvme] cannot seek %s\n", nvme_dev.path);
        exit(1);
    }
    long sz = ftell(fp);
    if (sz <= 0)
    {
        fprintf(stderr, "[nvme] empty image: %s\n", nvme_dev.path);
        exit(1);
    }
    rewind(fp);

    nvme_dev.image = (uint8_t *)malloc((size_t)sz);
    if (nvme_dev.image == NULL)
    {
        fprintf(stderr, "[nvme] out of memory loading %s\n", nvme_dev.path);
        exit(1);
    }
    if (fread(nvme_dev.image, 1, (size_t)sz, fp) != (size_t)sz)
    {
        fprintf(stderr, "[nvme] short read loading %s\n", nvme_dev.path);
        exit(1);
    }
    fclose(fp);
    nvme_dev.image_size = (size_t)sz;
    Log("nvme: loaded %s (%zu bytes, PCIe 00:01.0 BAR0=0x%08x)",
        nvme_dev.path, nvme_dev.image_size, nvme_dev.bar0);
}

static void maybe_fire_nvme_irq()
{
    if (nvme_dev.irq_asserted && (nvme_dev.intms & 1u) == 0 && (nvme_dev.pci_cmd & 0x0400u) == 0)
        nsim_plic_raise(NVME_IRQ);
}

static bool nvme_prp_transfer(uint64_t prp1, uint64_t prp2, size_t total_len,
                              bool to_guest, uint8_t *host_buf)
{
    size_t first = NVME_PAGE_SIZE - (size_t)(prp1 & (NVME_PAGE_SIZE - 1u));
    if (first > total_len)
        first = total_len;

    if (to_guest)
    {
        if (!dma_guest_write(prp1, host_buf, first))
            return false;
    }
    else
    {
        if (!dma_guest_read(prp1, host_buf, first))
            return false;
    }

    size_t pos = first;
    size_t rem = total_len - first;
    if (rem == 0)
        return true;

    if (rem <= NVME_PAGE_SIZE)
    {
        return to_guest ? dma_guest_write(prp2, host_buf + pos, rem)
                        : dma_guest_read(prp2, host_buf + pos, rem);
    }

    uint64_t list_pa = prp2;
    while (rem > 0)
    {
        // Last 8B entry of a 4 KiB PRP list page chains to the next PRP list page
        if ((list_pa & (NVME_PAGE_SIZE - 1u)) == (NVME_PAGE_SIZE - 8u) && rem > NVME_PAGE_SIZE)
        {
            uint64_t next_list = 0;
            if (!dma_guest_read(list_pa, &next_list, 8))
                return false;
            list_pa = next_list;
        }
        uint64_t page_pa = 0;
        if (!dma_guest_read(list_pa, &page_pa, 8))
            return false;
        size_t take = rem < NVME_PAGE_SIZE ? rem : NVME_PAGE_SIZE;
        bool ok = to_guest ? dma_guest_write(page_pa, host_buf + pos, take)
                           : dma_guest_read(page_pa, host_buf + pos, take);
        if (!ok)
            return false;
        pos += take;
        rem -= take;
        list_pa += 8;
    }
    return true;
}

static void nvme_post_cqe(uint16_t cqid, uint16_t sqid, uint16_t sq_head,
                          uint16_t cid, uint32_t res, uint16_t status)
{
    auto it = nvme_dev.cqs.find(cqid);
    if (it == nvme_dev.cqs.end())
        return;
    nvme_cq_t &cq = it->second;
    uint8_t cqe[16];
    memset(cqe, 0, sizeof(cqe));
    memcpy(cqe + 0, &res, 4);
    memcpy(cqe + 8, &sq_head, 2);
    memcpy(cqe + 10, &sqid, 2);
    memcpy(cqe + 12, &cid, 2);
    uint16_t sf = (uint16_t)(((status & 0x7fffu) << 1) | (cq.phase & 1u));
    memcpy(cqe + 14, &sf, 2);

    dma_guest_write(cq.addr + (uint64_t)cq.tail * 16u, cqe, 16);
    cq.tail++;
    if (cq.tail >= cq.size)
    {
        cq.tail = 0;
        cq.phase ^= 1u;
    }
    if (cq.irq_en)
    {
        nvme_dev.irq_asserted = true;
        maybe_fire_nvme_irq();
    }
}

static void nvme_process_sq(uint16_t sqid, uint16_t new_tail)
{
    auto it = nvme_dev.sqs.find(sqid);
    if (it == nvme_dev.sqs.end())
        return;
    nvme_sq_t &sq = it->second;

    while (sq.head != new_tail && sq.size > 0)
    {
        uint8_t cmd[64];
        if (!dma_guest_read(sq.addr + (uint64_t)sq.head * 64u, cmd, 64))
            break;
        sq.head = (uint16_t)((sq.head + 1u) % sq.size);

        uint32_t cdw0 = 0, nsid = 0, cdw10 = 0, cdw11 = 0, cdw12 = 0;
        uint64_t prp1 = 0, prp2 = 0;
        memcpy(&cdw0, cmd + 0, 4);
        memcpy(&nsid, cmd + 4, 4);
        memcpy(&prp1, cmd + 24, 8);
        memcpy(&prp2, cmd + 32, 8);
        memcpy(&cdw10, cmd + 40, 4);
        memcpy(&cdw11, cmd + 44, 4);
        memcpy(&cdw12, cmd + 48, 4);

        uint8_t opc = (uint8_t)(cdw0 & 0xffu);
        uint16_t cid = (uint16_t)(cdw0 >> 16);
        uint32_t result = 0;
        uint16_t status = 0;

        if (sqid == 0)
        {
            if (opc == 0x0cu)  // Async Event Request: hold without completion
                continue;
            if (opc == 0x06u)  // Identify
            {
                uint8_t id[4096];
                memset(id, 0, sizeof(id));
                uint8_t cns = (uint8_t)(cdw10 & 0xffu);
                if (cns == 0x01u)  // Controller
                {
                    uint16_t vid = 0x1b36u;
                    memcpy(id + 0, &vid, 2);
                    memcpy(id + 2, &vid, 2);
                    memcpy(id + 4, "RAPTORNVME0000000001", 20);
                    memcpy(id + 24, "Raptor RVA23 NVMe 1.4 Controller        ", 40);
                    memcpy(id + 64, "1.4     ", 8);
                    id[77] = 8;  // MDTS = 1 MiB
                    uint32_t ver = 0x00010400u;
                    memcpy(id + 80, &ver, 4);
                    id[512] = 0x66;  // SQES 64B
                    id[513] = 0x44;  // CQES 16B
                    uint32_t nn = 1u;
                    memcpy(id + 516, &nn, 4);
                    id[525] = 1;  // VWC: volatile write cache present
                }
                else if (cns == 0x00u && nsid == 1u)  // Namespace 1
                {
                    uint64_t blocks = nvme_dev.image_size / NVME_SECTOR_SIZE;
                    memcpy(id + 0, &blocks, 8);
                    memcpy(id + 8, &blocks, 8);
                    memcpy(id + 16, &blocks, 8);
                    uint32_t lbaf0 = 0x00090000u;  // LBADS = 9 (512B)
                    memcpy(id + 128, &lbaf0, 4);
                }
                else if (cns == 0x02u)  // Active Namespace ID List
                {
                    uint32_t ns1 = 1u;
                    memcpy(id + 0, &ns1, 4);
                }
                else if (cns == 0x03u && nsid == 1u)  // NS Descriptor List
                {
                    id[0] = 3;
                    id[1] = 16;
                    memcpy(id + 4, "RAPTOR-NVME-NS01", 16);
                }
                if (!nvme_prp_transfer(prp1, prp2, sizeof(id), true, id))
                    status = NVME_SC_DATA_XFER_ERROR;
            }
            else if (opc == 0x05u)  // Create I/O CQ
            {
                uint16_t cqid = (uint16_t)(cdw10 & 0xffffu);
                uint16_t qsz = (uint16_t)((cdw10 >> 16) + 1u);
                bool ien = (cdw11 & 0x2u) != 0;
                nvme_dev.cqs[cqid] = {prp1, qsz, 0, 1, ien};
            }
            else if (opc == 0x01u)  // Create I/O SQ
            {
                uint16_t iosq = (uint16_t)(cdw10 & 0xffffu);
                uint16_t qsz = (uint16_t)((cdw10 >> 16) + 1u);
                uint16_t cqid = (uint16_t)(cdw11 >> 16);
                nvme_dev.sqs[iosq] = {prp1, qsz, 0, cqid};
            }
            else if (opc == 0x00u)  // Delete I/O SQ
            {
                nvme_dev.sqs.erase((uint16_t)(cdw10 & 0xffffu));
            }
            else if (opc == 0x04u)  // Delete I/O CQ
            {
                nvme_dev.cqs.erase((uint16_t)(cdw10 & 0xffffu));
            }
            else if (opc == 0x09u || opc == 0x0au)  // Set / Get Features
            {
                if ((cdw10 & 0xffu) == 0x07u)
                    result = (7u << 16) | 7u;
            }
            nvme_post_cqe(0, 0, sq.head, cid, result, status);
        }
        else
        {
            uint64_t slba = (uint64_t)cdw10 | ((uint64_t)cdw11 << 32);
            size_t nlb = (size_t)(cdw12 & 0xffffu) + 1u;
            size_t nbytes = nlb * NVME_SECTOR_SIZE;
            uint64_t disk_off = slba * NVME_SECTOR_SIZE;

            if (opc == 0x02u)  // Read
            {
                if (disk_off + nbytes > nvme_dev.image_size)
                    status = NVME_SC_LBA_RANGE;
                else if (!nvme_prp_transfer(prp1, prp2, nbytes, true, nvme_dev.image + disk_off))
                    status = NVME_SC_DATA_XFER_ERROR;
            }
            else if (opc == 0x01u)  // Write
            {
                if (disk_off + nbytes > nvme_dev.image_size)
                    status = NVME_SC_LBA_RANGE;
                else if (!nvme_prp_transfer(prp1, prp2, nbytes, false, nvme_dev.image + disk_off))
                    status = NVME_SC_DATA_XFER_ERROR;
            }
            else if (opc == 0x08u)  // Write Zeroes
            {
                if (disk_off + nbytes <= nvme_dev.image_size)
                    memset(nvme_dev.image + disk_off, 0, nbytes);
                else
                    status = NVME_SC_LBA_RANGE;
            }
            else if (opc != 0x00u && opc != 0x09u)
            {
                status = NVME_SC_INVALID_OPCODE;
            }
            nvme_post_cqe(sq.cqid, sqid, sq.head, cid, result, status);
        }
    }
}

static word_t read_pcie_ecam(paddr_t offset)
{
    uint32_t bus = ((uint32_t)offset >> 20) & 0xffu;
    uint32_t dev = ((uint32_t)offset >> 15) & 0x1fu;
    uint32_t fn = ((uint32_t)offset >> 12) & 0x07u;
    uint32_t reg = (uint32_t)offset & 0xfffu;

    if (nvme_dev.image == NULL || bus != 0 || dev != 1 || fn != 0)
        return (word_t)-1;

    uint8_t cfg[256];
    memset(cfg, 0, sizeof(cfg));
    uint16_t vid = 0x1b36u, did = 0x0010u, status = 0x0010u;
    memcpy(cfg + 0x00, &vid, 2);
    memcpy(cfg + 0x02, &did, 2);
    memcpy(cfg + 0x04, &nvme_dev.pci_cmd, 2);
    memcpy(cfg + 0x06, &status, 2);
    uint32_t class_rev = 0x01080202u;  // NVM Express 1.4
    memcpy(cfg + 0x08, &class_rev, 4);
    uint32_t bar0 = nvme_dev.bar0_sizing ? ~(NVME_BAR_BYTES - 1u)
                                         : (nvme_dev.bar0 & ~(NVME_BAR_BYTES - 1u));
    memcpy(cfg + 0x10, &bar0, 4);
    uint16_t svid = 0x1af4u, sdid = 0x1100u;
    memcpy(cfg + 0x2c, &svid, 2);
    memcpy(cfg + 0x2e, &sdid, 2);
    cfg[0x3c] = nvme_dev.int_line;
    cfg[0x3d] = 1;  // INTA

    uint32_t base = reg & ~(uint32_t)(sizeof(word_t) - 1u);
    word_t val = 0;
    for (uint32_t i = 0; i < sizeof(word_t); i++)
    {
        if (base + i < sizeof(cfg))
            val |= ((word_t)cfg[base + i]) << (8 * i);
    }
    return val;
}

static void write_pcie_ecam(paddr_t offset, word_t wdata, char wmask)
{
    uint32_t bus = ((uint32_t)offset >> 20) & 0xffu;
    uint32_t dev = ((uint32_t)offset >> 15) & 0x1fu;
    uint32_t fn = ((uint32_t)offset >> 12) & 0x07u;
    uint32_t reg = (uint32_t)offset & 0xfffu;
    if (nvme_dev.image == NULL || bus != 0 || dev != 1 || fn != 0)
        return;

    uint32_t bar0_write = 0;
    uint8_t bar0_mask = 0;

    for (uint32_t i = 0; i < sizeof(word_t); i++)
    {
        if (!((uint8_t)wmask & (1u << i)))
            continue;
        uint32_t r = reg + i;
        uint8_t b = (uint8_t)(wdata >> (8 * i));
        if (r == 0x04)
            nvme_dev.pci_cmd = (nvme_dev.pci_cmd & 0xff00u) | b;
        else if (r == 0x05)
            nvme_dev.pci_cmd = (nvme_dev.pci_cmd & 0x00ffu) | ((uint16_t)b << 8);
        else if (r >= 0x10 && r < 0x14)
        {
            bar0_write |= ((uint32_t)b) << ((r - 0x10) * 8);
            bar0_mask |= 1u << (r - 0x10);
        }
        else if (r == 0x3c)
            nvme_dev.int_line = b;
    }

    if (bar0_mask == 0x0fu)
    {
        if (bar0_write == 0xffffffffu)
            nvme_dev.bar0_sizing = true;
        else
        {
            nvme_dev.bar0_sizing = false;
            if ((bar0_write & ~(NVME_BAR_BYTES - 1u)) != 0)
                nvme_dev.bar0 = bar0_write & ~(NVME_BAR_BYTES - 1u);
        }
    }
    maybe_fire_nvme_irq();
}

static uint32_t read_nvme_reg32(uint32_t reg32)
{
    uint64_t cap = 0x00ffull | (1ull << 16) | (15ull << 24) | (1ull << 37);
    switch (reg32)
    {
    case 0x0000: return (uint32_t)cap;
    case 0x0004: return (uint32_t)(cap >> 32);
    case 0x0008: return 0x00010400u;  // NVMe 1.4
    case 0x000c: return nvme_dev.intms;
    case 0x0010: return nvme_dev.intms;
    case 0x0014: return nvme_dev.cc;
    case 0x001c: return nvme_dev.csts;
    case 0x0024: return nvme_dev.aqa;
    case 0x0028: return (uint32_t)nvme_dev.asq;
    case 0x002c: return (uint32_t)(nvme_dev.asq >> 32);
    case 0x0030: return (uint32_t)nvme_dev.acq;
    case 0x0034: return (uint32_t)(nvme_dev.acq >> 32);
    default: return 0u;
    }
}

static void write_nvme_reg32(uint32_t reg32, uint32_t val)
{
    switch (reg32)
    {
    case 0x000c:
        nvme_dev.intms |= val;
        break;
    case 0x0010:
        nvme_dev.intms &= ~val;
        maybe_fire_nvme_irq();
        break;
    case 0x0014:
    {
        bool was_en = (nvme_dev.cc & 1u) != 0;
        nvme_dev.cc = val;
        if ((val & 1u) && !was_en)
        {
            nvme_dev.csts = 1u;
            uint16_t asqs = (uint16_t)((nvme_dev.aqa & 0x0fffu) + 1u);
            uint16_t acqs = (uint16_t)(((nvme_dev.aqa >> 16) & 0x0fffu) + 1u);
            nvme_dev.cqs.clear();
            nvme_dev.sqs.clear();
            nvme_dev.cqs[0] = {nvme_dev.acq, acqs, 0, 1, true};
            nvme_dev.sqs[0] = {nvme_dev.asq, asqs, 0, 0};
        }
        else if (!(val & 1u))
        {
            reset_nvme_ctrl();
        }
        if (((val >> 14) & 3u) != 0)
            nvme_dev.csts = (nvme_dev.csts & ~0xcu) | (2u << 2);
        break;
    }
    case 0x0024: nvme_dev.aqa = val; break;
    case 0x0028: nvme_dev.asq = (nvme_dev.asq & ~0xffffffffull) | val; break;
    case 0x002c: nvme_dev.asq = (nvme_dev.asq & 0xffffffffull) | ((uint64_t)val << 32); break;
    case 0x0030: nvme_dev.acq = (nvme_dev.acq & ~0xffffffffull) | val; break;
    case 0x0034: nvme_dev.acq = (nvme_dev.acq & 0xffffffffull) | ((uint64_t)val << 32); break;
    default:
        if (reg32 >= 0x1000u)
        {
            uint32_t idx = (reg32 - 0x1000u) >> 2;
            uint16_t qid = (uint16_t)(idx >> 1);
            if ((idx & 1u) == 0)
            {
                nvme_process_sq(qid, (uint16_t)(val & 0xffffu));
            }
            else
            {
                auto it = nvme_dev.cqs.find(qid);
                if (it != nvme_dev.cqs.end() && (val & 0xffffu) == it->second.tail)
                    nvme_dev.irq_asserted = false;
            }
        }
        break;
    }
}

void mmio_pcie_nvme_handle(paddr_t addr, word_t wdata, char wmask, bool is_write, word_t *data)
{
    if (addr >= PCIE_ECAM_BASE && addr < PCIE_ECAM_BASE + PCIE_ECAM_SIZE)
    {
        if (is_write)
            write_pcie_ecam(addr - PCIE_ECAM_BASE, wdata, wmask);
        else if (data != NULL)
            *data = read_pcie_ecam(addr - PCIE_ECAM_BASE);
        return;
    }

    if (nvme_dev.image == NULL || !(nvme_dev.pci_cmd & 0x2u) ||
        addr < nvme_dev.bar0 || addr >= nvme_dev.bar0 + NVME_BAR_BYTES)
    {
        if (!is_write && data != NULL)
            *data = (word_t)-1;
        return;
    }

    uint32_t offset = (uint32_t)(addr - nvme_dev.bar0);
    if (!is_write)
    {
        uint32_t aligned = offset & ~(uint32_t)(sizeof(word_t) - 1u);
        word_t out = (word_t)read_nvme_reg32(aligned);
        if (sizeof(word_t) == 8)
            out |= (word_t)((uint64_t)read_nvme_reg32(aligned + 4u) << 32);
        if (data != NULL)
            *data = out;
        return;
    }

    for (unsigned i = 0; i < sizeof(word_t);)
    {
        unsigned count = 4u - ((offset + i) & 3u);
        uint8_t m = ((uint8_t)wmask >> i) & ((1u << count) - 1u);
        if (m)
        {
            uint32_t r32 = (offset + i) & ~3u;
            uint32_t cur = (r32 < 0x1000u) ? read_nvme_reg32(r32) : 0u;
            for (unsigned b = 0; b < count; b++)
            {
                if (m & (1u << b))
                {
                    unsigned sh = (((offset + i + b) & 3u) * 8u);
                    cur = (cur & ~(0xffu << sh)) |
                          (((uint32_t)((wdata >> (8 * (i + b))) & 0xffu)) << sh);
                }
            }
            write_nvme_reg32(r32, cur);
        }
        i += count;
    }
}
