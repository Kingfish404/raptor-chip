#include <common.h>
#include <device_write.h>
#include <memory.h>

#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>
#include <vector>

// Standard OASIS VirtIO 1.2 Modern (VERSION=2, DEVICE_ID=4) virtio-mmio RNG at
// 0x10003000 (PLIC IRQ 5). Advertises VIRTIO_F_VERSION_1 (bit 32) and
// VIRTIO_F_ACCESS_PLATFORM (bit 33), filling guest DMA buffers from host
// `/dev/urandom` (with a xorshift64* fallback).
#define VIRTIO_RNG_IRQ 5u
#define VIRTIO_RNG_QUEUE_MAX 256u
#define VRNG_FEAT_HIGH ((1u << 0) | (1u << 1))

void nsim_plic_raise(uint32_t irq);

struct vrng_desc_t
{
    uint64_t addr;
    uint32_t len;
    uint16_t flags;
    uint16_t next;
} __attribute__((packed));

struct vrng_queue_t
{
    uint32_t num;
    uint32_t ready;
    uint64_t desc;
    uint64_t driver;
    uint64_t device;
    uint16_t last_avail;
};

static struct
{
    uint32_t dev_feat_sel;
    uint32_t drv_feat_sel;
    uint32_t drv_feat[2];
    uint32_t queue_sel;
    uint32_t status;
    uint32_t int_status;
    vrng_queue_t q;
    uint64_t fallback_state;
} vrng = {0, 0, {0, 0}, 0, 0, 0, {0, 0, 0, 0, 0, 0}, 0x9e3779b97f4a7c15ull};

static void fill_entropy(uint8_t *dst, size_t len)
{
    size_t got = 0;
    int fd = open("/dev/urandom", O_RDONLY);
    if (fd >= 0)
    {
        while (got < len)
        {
            ssize_t n = read(fd, dst + got, len - got);
            if (n <= 0)
                break;
            got += (size_t)n;
        }
        close(fd);
    }
    while (got < len)
    {
        uint64_t x = vrng.fallback_state;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        vrng.fallback_state = x;
        uint64_t out = x * 0x2545f4914f6cdd1dull;
        for (int b = 0; b < 8 && got < len; b++)
            dst[got++] = (uint8_t)((out >> (8 * b)) & 0xffu);
    }
}

static void reset_vrng_regs()
{
    vrng.dev_feat_sel = 0;
    vrng.drv_feat_sel = 0;
    vrng.drv_feat[0] = 0;
    vrng.drv_feat[1] = 0;
    vrng.queue_sel = 0;
    vrng.status = 0;
    vrng.int_status = 0;
    memset(&vrng.q, 0, sizeof(vrng.q));
}

static bool vrng_push_used(uint16_t head, uint32_t len)
{
    uint16_t qnum = vrng.q.num ? (uint16_t)vrng.q.num : (uint16_t)VIRTIO_RNG_QUEUE_MAX;
    uint16_t used_idx = 0;
    if (!dma_guest_read(vrng.q.device + 2, &used_idx, sizeof(used_idx)))
        return false;
    uint64_t elem_pa = vrng.q.device + 4 + (uint64_t)(used_idx % qnum) * 8;
    uint32_t id32 = head;
    if (!dma_guest_write(elem_pa, &id32, 4) || !dma_guest_write(elem_pa + 4, &len, 4))
        return false;
    used_idx++;
    return dma_guest_write(vrng.q.device + 2, &used_idx, sizeof(used_idx));
}

static void service_rng_queue()
{
    if (!vrng.q.ready || !(vrng.status & 4u))
        return;
    uint16_t qnum = vrng.q.num ? (uint16_t)vrng.q.num : (uint16_t)VIRTIO_RNG_QUEUE_MAX;
    uint16_t avail_idx = 0;
    if (!dma_guest_read(vrng.q.driver + 2, &avail_idx, sizeof(avail_idx)))
        return;

    bool completed = false;
    while (vrng.q.last_avail != avail_idx)
    {
        uint16_t head = 0;
        uint64_t ring_pa = vrng.q.driver + 4 + (uint64_t)(vrng.q.last_avail % qnum) * 2;
        if (!dma_guest_read(ring_pa, &head, sizeof(head)))
            break;
        vrng.q.last_avail++;

        uint16_t idx = head;
        uint32_t total_written = 0;
        for (unsigned hops = 0; hops < VIRTIO_RNG_QUEUE_MAX; hops++)
        {
            vrng_desc_t d;
            if (!dma_guest_read(vrng.q.desc + (uint64_t)idx * sizeof(vrng_desc_t), &d, sizeof(d)))
                break;
            if ((d.flags & 2u) && d.len > 0)
            {
                std::vector<uint8_t> buf(d.len);
                fill_entropy(buf.data(), buf.size());
                if (dma_guest_write(d.addr, buf.data(), buf.size()))
                    total_written += d.len;
            }
            if (!(d.flags & 1u))
                break;
            idx = d.next;
        }
        vrng_push_used(head, total_written);
        completed = true;
    }

    if (completed)
    {
        vrng.int_status |= 1u;
        nsim_plic_raise(VIRTIO_RNG_IRQ);
    }
}

static uint32_t vrng_read32(uint32_t aligned)
{
    switch (aligned)
    {
    case 0x000u: return 0x74726976u;  // "virt"
    case 0x004u: return 2u;           // VirtIO 1.2 Modern
    case 0x008u: return 4u;           // Device ID 4 = Entropy Source (RNG)
    case 0x00cu: return 0x52415054u;  // "RAPT"
    case 0x010u: return (vrng.dev_feat_sel == 1u) ? VRNG_FEAT_HIGH : 0u;
    case 0x034u: return (vrng.queue_sel == 0u) ? VIRTIO_RNG_QUEUE_MAX : 0u;
    case 0x044u: return (vrng.queue_sel == 0u) ? vrng.q.ready : 0u;
    case 0x060u: return vrng.int_status;
    case 0x070u: return vrng.status;
    case 0x0fcu: return 0u;
    default: return 0u;
    }
}

void mmio_virtio_rng_handle(paddr_t offset, word_t wdata, char wmask, bool is_write, word_t *data)
{
    uint32_t aligned = (uint32_t)offset & ~0x3u;
    if (!is_write)
    {
        word_t out = (word_t)vrng_read32((uint32_t)offset & ~(uint32_t)(sizeof(word_t) - 1u));
        if (sizeof(word_t) == 8)
        {
            uint32_t hi = vrng_read32(((uint32_t)offset & ~0x7u) + 4u);
            out |= (word_t)((uint64_t)hi << 32);
        }
        if (data != NULL)
            *data = out;
        return;
    }

    uint32_t val = 0;
    for (unsigned i = 0; i < 4; i++)
    {
        if ((uint8_t)wmask & (1u << i))
        {
            unsigned shift = (((unsigned)offset + i) & 3u) * 8u;
            val |= ((uint32_t)((wdata >> (8 * i)) & 0xffu)) << shift;
        }
    }

    switch (aligned)
    {
    case 0x014u: vrng.dev_feat_sel = val; break;
    case 0x020u:
        if (vrng.drv_feat_sel < 2)
            vrng.drv_feat[vrng.drv_feat_sel] = val;
        break;
    case 0x024u: vrng.drv_feat_sel = val; break;
    case 0x030u: vrng.queue_sel = val; break;
    case 0x038u: if (vrng.queue_sel == 0u) vrng.q.num = val; break;
    case 0x044u: if (vrng.queue_sel == 0u) vrng.q.ready = val & 1u; break;
    case 0x050u:
        if (val == 0u)
            service_rng_queue();
        break;
    case 0x064u: vrng.int_status &= ~val; break;
    case 0x070u:
        if (val == 0u)
            reset_vrng_regs();
        else
            vrng.status = val & 0xffu;
        break;
    case 0x080u:
        if (vrng.queue_sel == 0u)
            vrng.q.desc = (vrng.q.desc & ~0xffffffffull) | val;
        break;
    case 0x084u:
        if (vrng.queue_sel == 0u)
            vrng.q.desc = (vrng.q.desc & 0xffffffffull) | ((uint64_t)val << 32);
        break;
    case 0x090u:
        if (vrng.queue_sel == 0u)
            vrng.q.driver = (vrng.q.driver & ~0xffffffffull) | val;
        break;
    case 0x094u:
        if (vrng.queue_sel == 0u)
            vrng.q.driver = (vrng.q.driver & 0xffffffffull) | ((uint64_t)val << 32);
        break;
    case 0x0a0u:
        if (vrng.queue_sel == 0u)
            vrng.q.device = (vrng.q.device & ~0xffffffffull) | val;
        break;
    case 0x0a4u:
        if (vrng.queue_sel == 0u)
            vrng.q.device = (vrng.q.device & 0xffffffffull) | ((uint64_t)val << 32);
        break;
    default:
        break;
    }
}
