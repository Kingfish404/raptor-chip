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

#include <device/map.h>
#include <memory/paddr.h>

#include <errno.h>
#include <stdio.h>

#define VIRTIO_BLK_BASE 0x10001000u
#define VIRTIO_BLK_SIZE 0x1000u
#define VIRTIO_BLK_IRQ 1

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
#define VIRTIO_BLK_T_IN 0u
#define VIRTIO_BLK_T_OUT 1u
#define VIRTIO_BLK_STATUS_OK 0u
#define VIRTIO_BLK_STATUS_IOERR 1u
#define VIRTIO_QUEUE_NUM_MAX 8u
#define VIRTIO_SECTOR_SIZE 512u

typedef struct
{
    uint64_t addr;
    uint32_t len;
    uint16_t flags;
    uint16_t next;
} __attribute__((packed)) virtq_desc_t;

typedef struct
{
    uint32_t type;
    uint32_t reserved;
    uint64_t sector;
} __attribute__((packed)) virtio_blk_req_t;

static uint8_t *virtio_blk_base;

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

void plic_raise_irq(int irq);

void virtio_blk_set_disk_image(const char *path)
{
    blk.path = path;
}

static bool enabled(void)
{
    return blk.disk != NULL;
}

static void reset_regs(void)
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
    uint8_t *dst = buf;
    for (size_t i = 0; i < len; i++)
        dst[i] = *guest_to_host((paddr_t)(addr + i));
    return true;
}

static bool guest_mem_write(uint64_t addr, const void *buf, size_t len)
{
    const uint8_t *src = buf;
    for (size_t i = 0; i < len; i++)
        *guest_to_host((paddr_t)(addr + i)) = src[i];
    return true;
}

static bool read_desc(uint16_t idx, virtq_desc_t *desc)
{
    if (idx >= VIRTIO_QUEUE_NUM_MAX)
        return false;
    return guest_mem_read(blk.desc_addr + (uint64_t)idx * sizeof(*desc), desc, sizeof(*desc));
}

static uint64_t io_read_value(uint32_t offset, int len)
{
    uint64_t value = 0;
    for (int i = 0; i < len; i++)
        value |= (uint64_t)virtio_blk_base[offset + i] << (i * 8);
    return value;
}

static void io_write_value(uint32_t offset, int len, uint64_t value)
{
    for (int i = 0; i < len; i++)
        virtio_blk_base[offset + i] = (uint8_t)(value >> (i * 8));
}

static void write_reg32(uint32_t *reg, uint32_t offset, int len)
{
    uint32_t shift = (offset & 0x3u) * 8u;
    uint64_t mask = ((1ull << (len * 8)) - 1ull) << shift;
    uint64_t value = io_read_value(offset, len) << shift;
    *reg = (uint32_t)(((uint64_t)*reg & ~mask) | (value & mask));
}

static void write_reg64(uint64_t *reg, uint32_t offset, int len, bool high)
{
    uint32_t shift = (offset & 0x3u) * 8u;
    uint64_t mask = ((1ull << (len * 8)) - 1ull) << shift;
    uint64_t part = high ? ((*reg >> 32) & 0xffffffffull) : (*reg & 0xffffffffull);
    uint64_t value = io_read_value(offset, len) << shift;
    part = (part & ~mask) | (value & mask);
    *reg = high ? ((*reg & 0xffffffffull) | (part << 32))
                : ((*reg & ~0xffffffffull) | (part & 0xffffffffull));
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
    virtq_desc_t desc0, desc1, desc2;
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
        plic_raise_irq(VIRTIO_BLK_IRQ);
    }
}

static void process_one(uint16_t head)
{
    virtq_desc_t desc0, desc1, desc2;
    virtio_blk_req_t req;
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
        size_t count = desc1.len <= avail ? desc1.len : avail;
        if (req.type == VIRTIO_BLK_T_IN)
        {
            guest_mem_write(desc1.addr, blk.disk + disk_off, count);
            if (count < desc1.len)
            {
                uint8_t zero = 0;
                for (uint32_t i = (uint32_t)count; i < desc1.len; i++)
                    guest_mem_write(desc1.addr + i, &zero, 1);
            }
            used_len = desc1.len;
        }
        else if (req.type == VIRTIO_BLK_T_OUT)
        {
            if (count != desc1.len)
                status = VIRTIO_BLK_STATUS_IOERR;
            else
                guest_mem_read(desc1.addr, blk.disk + disk_off, count);
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
        plic_raise_irq(VIRTIO_BLK_IRQ);
    }
}

static void service_queue(void)
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

static uint32_t read_reg32(uint32_t base)
{
    switch (base)
    {
    case VIRTIO_MMIO_MAGIC_VALUE:
        return 0x74726976u;
    case VIRTIO_MMIO_VERSION:
        return 2u;
    case VIRTIO_MMIO_DEVICE_ID:
        return enabled() ? 2u : 0u;
    case VIRTIO_MMIO_VENDOR_ID:
        return 0x554d4551u;
    case VIRTIO_MMIO_DEVICE_FEATURES:
        return 0u;
    case VIRTIO_MMIO_QUEUE_NUM_MAX:
        return enabled() && blk.queue_sel == 0 ? VIRTIO_QUEUE_NUM_MAX : 0u;
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

static void virtio_blk_io_handler(uint32_t offset, int len, bool is_write)
{
    uint32_t base = offset & ~0x3u;
    if (is_write)
    {
        switch (base)
        {
        case VIRTIO_MMIO_DEVICE_FEATURES_SEL:
            write_reg32(&blk.device_features_sel, offset, len);
            break;
        case VIRTIO_MMIO_DRIVER_FEATURES:
            write_reg32(&blk.driver_features[blk.driver_features_sel & 1u], offset, len);
            break;
        case VIRTIO_MMIO_DRIVER_FEATURES_SEL:
            write_reg32(&blk.driver_features_sel, offset, len);
            break;
        case VIRTIO_MMIO_QUEUE_SEL:
            write_reg32(&blk.queue_sel, offset, len);
            break;
        case VIRTIO_MMIO_QUEUE_NUM:
            write_reg32(&blk.queue_num, offset, len);
            if (blk.queue_num > VIRTIO_QUEUE_NUM_MAX)
                blk.queue_num = VIRTIO_QUEUE_NUM_MAX;
            break;
        case VIRTIO_MMIO_QUEUE_READY:
            write_reg32(&blk.queue_ready, offset, len);
            blk.queue_ready &= 1u;
            break;
        case VIRTIO_MMIO_QUEUE_NOTIFY:
            service_queue();
            break;
        case VIRTIO_MMIO_INTERRUPT_ACK:
            blk.interrupt_status &= ~(uint32_t)io_read_value(offset, len);
            break;
        case VIRTIO_MMIO_STATUS:
            write_reg32(&blk.status, offset, len);
            if (blk.status == 0)
                reset_regs();
            break;
        case VIRTIO_MMIO_QUEUE_DESC_LOW:
            write_reg64(&blk.desc_addr, offset, len, false);
            break;
        case VIRTIO_MMIO_QUEUE_DESC_HIGH:
            write_reg64(&blk.desc_addr, offset, len, true);
            break;
        case VIRTIO_MMIO_DRIVER_DESC_LOW:
            write_reg64(&blk.driver_addr, offset, len, false);
            break;
        case VIRTIO_MMIO_DRIVER_DESC_HIGH:
            write_reg64(&blk.driver_addr, offset, len, true);
            break;
        case VIRTIO_MMIO_DEVICE_DESC_LOW:
            write_reg64(&blk.device_addr, offset, len, false);
            break;
        case VIRTIO_MMIO_DEVICE_DESC_HIGH:
            write_reg64(&blk.device_addr, offset, len, true);
            break;
        default:
            break;
        }
        return;
    }

    io_write_value(base, 4, read_reg32(base));
}

void init_disk(void)
{
    reset_regs();
    free(blk.disk);
    blk.disk = NULL;
    blk.disk_size = 0;

    if (blk.path != NULL && blk.path[0] != '\0')
    {
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
        blk.disk = malloc((size_t)size);
        Assert(blk.disk != NULL, "out of memory loading disk image");
        if (fread(blk.disk, 1, (size_t)size, fp) != (size_t)size)
        {
            fprintf(stderr, "[virtio-blk] short read loading %s\n", blk.path);
            exit(1);
        }
        fclose(fp);
        blk.disk_size = (size_t)size;
        Log("virtio-blk: loaded %s (%zu bytes, writes are in-memory)", blk.path, blk.disk_size);
    }

    virtio_blk_base = new_space(VIRTIO_BLK_SIZE);
    memset(virtio_blk_base, 0, VIRTIO_BLK_SIZE);
    add_mmio_map("virtio-blk", VIRTIO_BLK_BASE, virtio_blk_base, VIRTIO_BLK_SIZE, virtio_blk_io_handler);
}
