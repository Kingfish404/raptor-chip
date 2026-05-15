#include <common.h>
#include <memory.h>

#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Provided by difftest_dut.cc; NULL when difftest is not enabled.
extern void (*ref_difftest_memcpy)(paddr_t addr, void *buf, size_t n, bool direction);

#define VIRTIO_BLK_BASE 0x10001000u
#define VIRTIO_BLK_SIZE 0x1000u
#define VIRTIO_BLK_IRQ 1u

#define VIRTIO_MMIO_MAGIC_VALUE 0x000u
#define VIRTIO_MMIO_VERSION 0x004u
#define VIRTIO_MMIO_DEVICE_ID 0x008u
#define VIRTIO_MMIO_VENDOR_ID 0x00cu
#define VIRTIO_MMIO_DEVICE_FEATURES 0x010u
#define VIRTIO_MMIO_DEVICE_FEATURES_SEL 0x014u
#define VIRTIO_MMIO_DRIVER_FEATURES 0x020u
#define VIRTIO_MMIO_DRIVER_FEATURES_SEL 0x024u
#define VIRTIO_MMIO_QUEUE_SEL 0x030u
#define VIRTIO_MMIO_QUEUE_NUM_MAX 0x034u
#define VIRTIO_MMIO_QUEUE_NUM 0x038u
#define VIRTIO_MMIO_QUEUE_READY 0x044u
#define VIRTIO_MMIO_QUEUE_NOTIFY 0x050u
#define VIRTIO_MMIO_INTERRUPT_STATUS 0x060u
#define VIRTIO_MMIO_INTERRUPT_ACK 0x064u
#define VIRTIO_MMIO_STATUS 0x070u
#define VIRTIO_MMIO_QUEUE_DESC_LOW 0x080u
#define VIRTIO_MMIO_QUEUE_DESC_HIGH 0x084u
#define VIRTIO_MMIO_DRIVER_DESC_LOW 0x090u
#define VIRTIO_MMIO_DRIVER_DESC_HIGH 0x094u
#define VIRTIO_MMIO_DEVICE_DESC_LOW 0x0a0u
#define VIRTIO_MMIO_DEVICE_DESC_HIGH 0x0a4u
#define VIRTIO_MMIO_CONFIG_CAPACITY_LOW 0x100u
#define VIRTIO_MMIO_CONFIG_CAPACITY_HIGH 0x104u

#define VIRTIO_CONFIG_S_DRIVER_OK 4u
#define VRING_DESC_F_NEXT 1u
#define VRING_DESC_F_WRITE 2u
#define VIRTIO_BLK_T_IN 0u
#define VIRTIO_BLK_T_OUT 1u
#define VIRTIO_BLK_STATUS_OK 0u
#define VIRTIO_BLK_STATUS_IOERR 1u
#define VIRTIO_QUEUE_NUM_MAX 8u
#define VIRTIO_SECTOR_SIZE 512u

struct virtq_desc_host
{
    uint64_t addr;
    uint32_t len;
    uint16_t flags;
    uint16_t next;
} __attribute__((packed));

struct virtio_blk_req_host
{
    uint32_t type;
    uint32_t reserved;
    uint64_t sector;
} __attribute__((packed));

static struct
{
    const char *path;
    uint8_t *disk;
    size_t disk_size;

    uint32_t device_features_sel;
    uint32_t driver_features_sel;
    uint32_t driver_features[2];
    uint32_t queue_sel;
    uint32_t queue_num;
    uint32_t queue_ready;
    uint32_t status;
    uint32_t interrupt_status;
    uint64_t desc_addr;
    uint64_t driver_addr;
    uint64_t device_addr;
    uint16_t last_avail_idx;
} blk;

void nsim_plic_raise(uint32_t irq);

static bool enabled()
{
    return blk.disk != NULL;
}

static void reset_regs()
{
    blk.device_features_sel = 0;
    blk.driver_features_sel = 0;
    blk.driver_features[0] = 0;
    blk.driver_features[1] = 0;
    blk.queue_sel = 0;
    blk.queue_num = 0;
    blk.queue_ready = 0;
    blk.status = 0;
    blk.interrupt_status = 0;
    blk.desc_addr = 0;
    blk.driver_addr = 0;
    blk.device_addr = 0;
    blk.last_avail_idx = 0;
}

static bool guest_mem_read(uint64_t addr, void *buf, size_t len)
{
    uint8_t *dst = (uint8_t *)buf;
    for (size_t i = 0; i < len; i++)
    {
        uint8_t *src = guest_to_host((paddr_t)(addr + i));
        if (src == NULL)
            return false;
        dst[i] = *src;
    }
    return true;
}

static bool guest_mem_write(uint64_t addr, const void *buf, size_t len)
{
    const uint8_t *src = (const uint8_t *)buf;
    for (size_t i = 0; i < len; i++)
    {
        uint8_t *dst = guest_to_host((paddr_t)(addr + i));
        if (dst == NULL)
            return false;
        *dst = src[i];
    }
    // Mirror DMA writes into the difftest reference so subsequent CPU loads
    // observe matching data on both sides.
    if (ref_difftest_memcpy != NULL && len > 0)
    {
        uint8_t *host = guest_to_host((paddr_t)addr);
        if (host != NULL)
            ref_difftest_memcpy((paddr_t)addr, host, len, DIFFTEST_TO_REF);
    }
    return true;
}

static bool read_desc(uint16_t idx, struct virtq_desc_host *desc)
{
    if (idx >= VIRTIO_QUEUE_NUM_MAX)
        return false;
    return guest_mem_read(blk.desc_addr + idx * sizeof(*desc), desc, sizeof(*desc));
}

static void write_reg32(uint32_t *reg, paddr_t offset, word_t wdata)
{
    uint32_t shift = (uint32_t)(offset & 0x3u) * 8u;
    uint32_t mask = 0xffu << shift;
    *reg = (*reg & ~mask) | (((uint32_t)wdata & 0xffu) << shift);
}

static void write_reg64(uint64_t *reg, paddr_t offset, word_t wdata)
{
    uint32_t shift = (uint32_t)(offset & 0x3u) * 8u;
    uint64_t mask = 0xffull << shift;
    uint64_t low = (*reg & ~0xffffffffull) | (((*reg & 0xffffffffull) & ~mask) |
                   (((uint64_t)wdata & 0xffull) << shift));
    uint64_t high = ((*reg >> 32) & ~mask) | (((uint64_t)wdata & 0xffull) << shift);
    if ((offset & ~0x3u) == VIRTIO_MMIO_QUEUE_DESC_HIGH ||
        (offset & ~0x3u) == VIRTIO_MMIO_DRIVER_DESC_HIGH ||
        (offset & ~0x3u) == VIRTIO_MMIO_DEVICE_DESC_HIGH)
        *reg = (*reg & 0xffffffffull) | (high << 32);
    else
        *reg = low;
}

static bool write_used_elem(uint16_t id, uint32_t len)
{
    uint16_t qnum = blk.queue_num ? (uint16_t)blk.queue_num : (uint16_t)VIRTIO_QUEUE_NUM_MAX;
    uint16_t used_idx = 0;
    uint32_t elem_id = id;
    uint32_t elem_len = len;
    if (!guest_mem_read(blk.device_addr + 2, &used_idx, sizeof(used_idx)))
        return false;

    uint64_t elem_addr = blk.device_addr + 4 + (uint64_t)(used_idx % qnum) * 8;
    if (!guest_mem_write(elem_addr, &elem_id, sizeof(elem_id)))
        return false;
    if (!guest_mem_write(elem_addr + 4, &elem_len, sizeof(elem_len)))
        return false;

    used_idx++;
    return guest_mem_write(blk.device_addr + 2, &used_idx, sizeof(used_idx));
}

static void complete_request(uint16_t head, uint32_t used_len, uint8_t status)
{
    struct virtq_desc_host desc0, desc1, desc2;
    if (!read_desc(head, &desc0))
        return;
    if (!(desc0.flags & VRING_DESC_F_NEXT) || !read_desc(desc0.next, &desc1))
        return;
    if (!(desc1.flags & VRING_DESC_F_NEXT) || !read_desc(desc1.next, &desc2))
        return;

    guest_mem_write(desc2.addr, &status, 1);
    if (write_used_elem(head, used_len))
    {
        blk.interrupt_status |= 1u;
        nsim_plic_raise(VIRTIO_BLK_IRQ);
    }
}

static void process_one(uint16_t head)
{
    struct virtq_desc_host desc0, desc1, desc2;
    struct virtio_blk_req_host req;
    uint8_t status = VIRTIO_BLK_STATUS_OK;
    uint32_t used_len = 0;

    if (!read_desc(head, &desc0) || !(desc0.flags & VRING_DESC_F_NEXT) ||
        !read_desc(desc0.next, &desc1) || !(desc1.flags & VRING_DESC_F_NEXT) ||
        !read_desc(desc1.next, &desc2) ||
        desc0.len < sizeof(req) || !guest_mem_read(desc0.addr, &req, sizeof(req)))
    {
        complete_request(head, 0, VIRTIO_BLK_STATUS_IOERR);
        return;
    }

    uint64_t disk_off = req.sector * VIRTIO_SECTOR_SIZE;
    if (disk_off >= blk.disk_size)
    {
        status = VIRTIO_BLK_STATUS_IOERR;
    }
    else
    {
        size_t avail = blk.disk_size - (size_t)disk_off;
        size_t len = desc1.len <= avail ? desc1.len : avail;
        if (req.type == VIRTIO_BLK_T_IN)
        {
            if (!guest_mem_write(desc1.addr, blk.disk + disk_off, len))
                status = VIRTIO_BLK_STATUS_IOERR;
            if (status == VIRTIO_BLK_STATUS_OK && len < desc1.len)
            {
                uint8_t zero = 0;
                for (uint32_t i = (uint32_t)len; i < desc1.len; i++)
                    if (!guest_mem_write(desc1.addr + i, &zero, 1))
                        status = VIRTIO_BLK_STATUS_IOERR;
            }
            used_len = desc1.len;
        }
        else if (req.type == VIRTIO_BLK_T_OUT)
        {
            if (len != desc1.len || !guest_mem_read(desc1.addr, blk.disk + disk_off, len))
                status = VIRTIO_BLK_STATUS_IOERR;
            used_len = 0;
        }
        else
        {
            status = VIRTIO_BLK_STATUS_IOERR;
        }
    }

    guest_mem_write(desc2.addr, &status, 1);
    if (write_used_elem(head, used_len))
    {
        blk.interrupt_status |= 1u;
        nsim_plic_raise(VIRTIO_BLK_IRQ);
    }
}

static void service_queue()
{
    if (!enabled() || blk.queue_sel != 0 || blk.queue_ready == 0 ||
        !(blk.status & VIRTIO_CONFIG_S_DRIVER_OK) || blk.desc_addr == 0 ||
        blk.driver_addr == 0 || blk.device_addr == 0)
        return;

    uint16_t qnum = blk.queue_num ? (uint16_t)blk.queue_num : (uint16_t)VIRTIO_QUEUE_NUM_MAX;
    if (qnum > VIRTIO_QUEUE_NUM_MAX)
        qnum = VIRTIO_QUEUE_NUM_MAX;

    uint16_t avail_idx = 0;
    if (!guest_mem_read(blk.driver_addr + 2, &avail_idx, sizeof(avail_idx)))
        return;

    while (blk.last_avail_idx != avail_idx)
    {
        uint16_t head = 0;
        uint64_t ring_addr = blk.driver_addr + 4 + (uint64_t)(blk.last_avail_idx % qnum) * 2;
        if (!guest_mem_read(ring_addr, &head, sizeof(head)))
            return;
        if (head < qnum)
            process_one(head);
        blk.last_avail_idx++;
    }
}

static uint32_t read_reg32(paddr_t offset)
{
    uint32_t base = (uint32_t)offset & ~0x3u;
    if (!enabled())
    {
        if (base == VIRTIO_MMIO_MAGIC_VALUE)
            return 0x74726976u;
        if (base == VIRTIO_MMIO_VERSION)
            return 2u;
        if (base == VIRTIO_MMIO_VENDOR_ID)
            return 0x554d4551u;
        return 0;
    }

    switch (base)
    {
    case VIRTIO_MMIO_MAGIC_VALUE:
        return 0x74726976u;
    case VIRTIO_MMIO_VERSION:
        return 2u;
    case VIRTIO_MMIO_DEVICE_ID:
        return 2u;
    case VIRTIO_MMIO_VENDOR_ID:
        return 0x554d4551u;
    case VIRTIO_MMIO_DEVICE_FEATURES:
        return blk.device_features_sel == 0 ? 0u : 0u;
    case VIRTIO_MMIO_QUEUE_NUM_MAX:
        return blk.queue_sel == 0 ? VIRTIO_QUEUE_NUM_MAX : 0u;
    case VIRTIO_MMIO_QUEUE_READY:
        return blk.queue_ready;
    case VIRTIO_MMIO_INTERRUPT_STATUS:
        return blk.interrupt_status;
    case VIRTIO_MMIO_STATUS:
        return blk.status;
    case VIRTIO_MMIO_CONFIG_CAPACITY_LOW:
        return (uint32_t)(blk.disk_size / VIRTIO_SECTOR_SIZE);
    case VIRTIO_MMIO_CONFIG_CAPACITY_HIGH:
        return (uint32_t)((blk.disk_size / VIRTIO_SECTOR_SIZE) >> 32);
    default:
        return 0;
    }
}

void virtio_blk_set_disk_image(const char *path)
{
    blk.path = path;
}

void init_virtio_blk()
{
    reset_regs();
    free(blk.disk);
    blk.disk = NULL;
    blk.disk_size = 0;

    if (blk.path == NULL || blk.path[0] == '\0')
        return;

    FILE *fp = fopen(blk.path, "rb");
    if (fp == NULL)
    {
        fprintf(stderr, "[virtio-blk] cannot open %s: %s\n", blk.path, strerror(errno));
        exit(1);
    }
    if (fseek(fp, 0, SEEK_END) != 0)
    {
        fprintf(stderr, "[virtio-blk] cannot seek %s\n", blk.path);
        exit(1);
    }
    long size = ftell(fp);
    if (size <= 0)
    {
        fprintf(stderr, "[virtio-blk] empty disk image: %s\n", blk.path);
        exit(1);
    }
    rewind(fp);

    blk.disk = (uint8_t *)malloc((size_t)size);
    if (blk.disk == NULL)
    {
        fprintf(stderr, "[virtio-blk] out of memory loading %s\n", blk.path);
        exit(1);
    }
    if (fread(blk.disk, 1, (size_t)size, fp) != (size_t)size)
    {
        fprintf(stderr, "[virtio-blk] short read loading %s\n", blk.path);
        exit(1);
    }
    fclose(fp);
    blk.disk_size = (size_t)size;
    Log("virtio-blk: loaded %s (%zu bytes, writes are in-memory)", blk.path, blk.disk_size);
}

void mmio_virtio_blk_handle(paddr_t offset, word_t wdata, bool is_write, word_t *data)
{
    offset &= VIRTIO_BLK_SIZE - 1;
    uint32_t base = (uint32_t)offset & ~0x3u;
    if (is_write)
    {
        switch (base)
        {
        case VIRTIO_MMIO_DEVICE_FEATURES_SEL:
            write_reg32(&blk.device_features_sel, offset, wdata);
            break;
        case VIRTIO_MMIO_DRIVER_FEATURES:
            write_reg32(&blk.driver_features[blk.driver_features_sel & 1u], offset, wdata);
            break;
        case VIRTIO_MMIO_DRIVER_FEATURES_SEL:
            write_reg32(&blk.driver_features_sel, offset, wdata);
            break;
        case VIRTIO_MMIO_QUEUE_SEL:
            write_reg32(&blk.queue_sel, offset, wdata);
            break;
        case VIRTIO_MMIO_QUEUE_NUM:
            write_reg32(&blk.queue_num, offset, wdata);
            if (blk.queue_num > VIRTIO_QUEUE_NUM_MAX)
                blk.queue_num = VIRTIO_QUEUE_NUM_MAX;
            break;
        case VIRTIO_MMIO_QUEUE_READY:
            write_reg32(&blk.queue_ready, offset, wdata);
            blk.queue_ready &= 1u;
            break;
        case VIRTIO_MMIO_QUEUE_NOTIFY:
            if ((offset & 0x3u) == 0)
                service_queue();
            break;
        case VIRTIO_MMIO_INTERRUPT_ACK:
        {
            uint32_t ack = ((uint32_t)wdata & 0xffu) << ((offset & 0x3u) * 8u);
            blk.interrupt_status &= ~ack;
            break;
        }
        case VIRTIO_MMIO_STATUS:
            write_reg32(&blk.status, offset, wdata);
            if (blk.status == 0)
                reset_regs();
            break;
        case VIRTIO_MMIO_QUEUE_DESC_LOW:
        case VIRTIO_MMIO_QUEUE_DESC_HIGH:
            write_reg64(&blk.desc_addr, offset, wdata);
            break;
        case VIRTIO_MMIO_DRIVER_DESC_LOW:
        case VIRTIO_MMIO_DRIVER_DESC_HIGH:
            write_reg64(&blk.driver_addr, offset, wdata);
            break;
        case VIRTIO_MMIO_DEVICE_DESC_LOW:
        case VIRTIO_MMIO_DEVICE_DESC_HIGH:
            write_reg64(&blk.device_addr, offset, wdata);
            break;
        default:
            break;
        }
        return;
    }

    uint32_t val = read_reg32(offset);
    if (data != NULL)
        *data = word_t(val) << ((offset & (sizeof(word_t) - 1u)) * 8u);
}

bool mmio_virtio_blk_contains(paddr_t addr)
{
    return addr >= VIRTIO_BLK_BASE && addr < VIRTIO_BLK_BASE + VIRTIO_BLK_SIZE;
}
