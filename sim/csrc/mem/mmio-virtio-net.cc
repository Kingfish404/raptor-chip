#include <common.h>
#include <device_write.h>
#include <memory.h>

#include <stdint.h>
#include <string.h>
#include <deque>
#include <vector>

// Standard OASIS VirtIO 1.2 Modern (VERSION=2, DEVICE_ID=1) virtio-mmio NIC at
// 0x10002000 (PLIC IRQ 2). Advertises VIRTIO_F_VERSION_1 (bit 32),
// VIRTIO_F_ACCESS_PLATFORM (bit 33), VIRTIO_NET_F_MAC (bit 5), and
// VIRTIO_NET_F_STATUS (bit 16), with built-in gateway (10.0.2.2) ARP + ICMP
// echo responder for self-contained mainline Linux networking verification.
#define VIRTIO_NET_IRQ 2u
#define VIRTIO_NET_QUEUE_MAX 256u
#define VIRTIO_NET_HDR_LEN 12u

#define VNET_FEAT_LOW  ((1u << 5) | (1u << 16))
#define VNET_FEAT_HIGH ((1u << 0) | (1u << 1))

void nsim_plic_raise(uint32_t irq);

struct vnet_desc_t
{
    uint64_t addr;
    uint32_t len;
    uint16_t flags;
    uint16_t next;
} __attribute__((packed));

struct vnet_queue_t
{
    uint32_t num;
    uint32_t ready;
    uint64_t desc;
    uint64_t driver;
    uint64_t device;
    uint16_t last_avail;
    uint16_t used_idx;
};

static struct
{
    bool enabled;
    uint8_t mac[6];
    uint32_t dev_feat_sel;
    uint32_t drv_feat_sel;
    uint32_t drv_feat[2];
    uint32_t queue_sel;
    uint32_t status;
    uint32_t int_status;
    vnet_queue_t q[2];  // 0 = RX, 1 = TX
    std::deque<std::vector<uint8_t>> rx_frames;
} vnet;

void virtio_net_set_enabled(bool en)
{
    vnet.enabled = en;
}

static void reset_vnet_regs()
{
    vnet.dev_feat_sel = 0;
    vnet.drv_feat_sel = 0;
    vnet.drv_feat[0] = 0;
    vnet.drv_feat[1] = 0;
    vnet.queue_sel = 0;
    vnet.status = 0;
    vnet.int_status = 0;
    memset(vnet.q, 0, sizeof(vnet.q));
    vnet.rx_frames.clear();
}

void init_virtio_net()
{
    static const uint8_t default_mac[6] = {0x02, 0x52, 0x41, 0x50, 0x05, 0x02};
    memcpy(vnet.mac, default_mac, 6);
    reset_vnet_regs();
}

static bool vnet_push_used(vnet_queue_t *q, uint16_t head, uint32_t len)
{
    uint16_t qnum = q->num ? (uint16_t)q->num : (uint16_t)VIRTIO_NET_QUEUE_MAX;
    uint16_t used_idx = 0;
    if (!dma_guest_read(q->device + 2, &used_idx, sizeof(used_idx)))
        return false;
    uint64_t elem_pa = q->device + 4 + (uint64_t)(used_idx % qnum) * 8;
    uint32_t id32 = head;
    if (!dma_guest_write(elem_pa, &id32, 4) || !dma_guest_write(elem_pa + 4, &len, 4))
        return false;
    used_idx++;
    return dma_guest_write(q->device + 2, &used_idx, sizeof(used_idx));
}

static void synthesize_gateway_reply(const uint8_t *frame, size_t len)
{
    if (len < 14)
        return;
    static const uint8_t gw_mac[6] = {0x52, 0x55, 0x0a, 0x00, 0x02, 0x02};
    uint16_t etype = ((uint16_t)frame[12] << 8) | frame[13];

    // ARP Request -> ARP Reply
    if (etype == 0x0806 && len >= 42)
    {
        uint16_t oper = ((uint16_t)frame[20] << 8) | frame[21];
        if (oper == 1)
        {
            std::vector<uint8_t> reply(42, 0);
            memcpy(&reply[0], &frame[6], 6);
            memcpy(&reply[6], gw_mac, 6);
            reply[12] = 0x08;
            reply[13] = 0x06;
            reply[15] = 0x01;
            reply[16] = 0x08;
            reply[18] = 6;
            reply[19] = 4;
            reply[21] = 2;  // ARP reply
            memcpy(&reply[22], gw_mac, 6);
            memcpy(&reply[28], &frame[38], 4);
            memcpy(&reply[32], &frame[22], 6);
            memcpy(&reply[38], &frame[28], 4);
            vnet.rx_frames.push_back(std::move(reply));
        }
        return;
    }

    // IPv4 ICMP Echo Request -> ICMP Echo Reply
    if (etype == 0x0800 && len >= 42)
    {
        size_t ihl = (size_t)(frame[14] & 0x0fu) * 4u;
        if (ihl >= 20 && len >= 14 + ihl + 8 && frame[14 + 9] == 1 && frame[14 + ihl] == 8)
        {
            std::vector<uint8_t> reply(frame, frame + len);
            memcpy(&reply[0], &frame[6], 6);
            memcpy(&reply[6], gw_mac, 6);
            memcpy(&reply[14 + 12], &frame[14 + 16], 4);
            memcpy(&reply[14 + 16], &frame[14 + 12], 4);
            reply[14 + 10] = 0;
            reply[14 + 11] = 0;
            uint32_t csum = 0;
            for (size_t i = 0; i < ihl; i += 2)
                csum += ((uint32_t)reply[14 + i] << 8) | reply[14 + i + 1];
            while (csum >> 16)
                csum = (csum & 0xffffu) + (csum >> 16);
            uint16_t ip_hc = (uint16_t)~csum;
            reply[14 + 10] = (uint8_t)(ip_hc >> 8);
            reply[14 + 11] = (uint8_t)ip_hc;

            reply[14 + ihl] = 0;  // Echo Reply
            uint32_t ic = (((uint32_t)reply[14 + ihl + 2] << 8) | reply[14 + ihl + 3]) + 0x0800u;
            ic = (ic & 0xffffu) + (ic >> 16);
            reply[14 + ihl + 2] = (uint8_t)(ic >> 8);
            reply[14 + ihl + 3] = (uint8_t)ic;
            vnet.rx_frames.push_back(std::move(reply));
        }
    }
}

static void deliver_rx_queue()
{
    vnet_queue_t *q = &vnet.q[0];
    if (!vnet.enabled || !q->ready || !(vnet.status & 4u) || vnet.rx_frames.empty())
        return;

    uint16_t qnum = q->num ? (uint16_t)q->num : (uint16_t)VIRTIO_NET_QUEUE_MAX;
    uint16_t avail_idx = 0;
    if (!dma_guest_read(q->driver + 2, &avail_idx, sizeof(avail_idx)))
        return;

    while (!vnet.rx_frames.empty() && q->last_avail != avail_idx)
    {
        uint16_t head = 0;
        uint64_t ring_pa = q->driver + 4 + (uint64_t)(q->last_avail % qnum) * 2;
        if (!dma_guest_read(ring_pa, &head, sizeof(head)))
            break;
        q->last_avail++;

        const std::vector<uint8_t> &frame = vnet.rx_frames.front();
        std::vector<uint8_t> full(VIRTIO_NET_HDR_LEN + frame.size(), 0);
        full[10] = 1;  // num_buffers = 1
        memcpy(full.data() + VIRTIO_NET_HDR_LEN, frame.data(), frame.size());

        size_t pos = 0;
        uint16_t idx = head;
        for (unsigned guard = 0; guard < VIRTIO_NET_QUEUE_MAX && pos < full.size(); guard++)
        {
            vnet_desc_t d;
            if (!dma_guest_read(q->desc + (uint64_t)idx * sizeof(d), &d, sizeof(d)))
                break;
            if (d.flags & 2u)
            {
                size_t take = d.len < (full.size() - pos) ? d.len : (full.size() - pos);
                if (take > 0)
                    dma_guest_write(d.addr, full.data() + pos, take);
                pos += take;
            }
            if (!(d.flags & 1u))
                break;
            idx = d.next;
        }
        vnet.rx_frames.pop_front();
        if (vnet_push_used(q, head, (uint32_t)pos))
        {
            vnet.int_status |= 1u;
            nsim_plic_raise(VIRTIO_NET_IRQ);
        }
    }
}

static void service_tx_queue()
{
    vnet_queue_t *q = &vnet.q[1];
    if (!vnet.enabled || !q->ready || !(vnet.status & 4u))
        return;

    uint16_t qnum = q->num ? (uint16_t)q->num : (uint16_t)VIRTIO_NET_QUEUE_MAX;
    uint16_t avail_idx = 0;
    if (!dma_guest_read(q->driver + 2, &avail_idx, sizeof(avail_idx)))
        return;

    while (q->last_avail != avail_idx)
    {
        uint16_t head = 0;
        uint64_t ring_pa = q->driver + 4 + (uint64_t)(q->last_avail % qnum) * 2;
        if (!dma_guest_read(ring_pa, &head, sizeof(head)))
            break;
        q->last_avail++;

        std::vector<uint8_t> raw;
        uint16_t idx = head;
        for (unsigned guard = 0; guard < VIRTIO_NET_QUEUE_MAX; guard++)
        {
            vnet_desc_t d;
            if (!dma_guest_read(q->desc + (uint64_t)idx * sizeof(d), &d, sizeof(d)))
                break;
            if (d.len > 0 && d.len <= 65536)
            {
                size_t old_sz = raw.size();
                raw.resize(old_sz + d.len);
                dma_guest_read(d.addr, raw.data() + old_sz, d.len);
            }
            if (!(d.flags & 1u))
                break;
            idx = d.next;
        }
        if (vnet_push_used(q, head, 0))
        {
            vnet.int_status |= 1u;
            nsim_plic_raise(VIRTIO_NET_IRQ);
        }
        if (raw.size() > VIRTIO_NET_HDR_LEN)
            synthesize_gateway_reply(raw.data() + VIRTIO_NET_HDR_LEN,
                                     raw.size() - VIRTIO_NET_HDR_LEN);
    }
    deliver_rx_queue();
}

static uint32_t vnet_read32(uint32_t base)
{
    if (!vnet.enabled)
    {
        if (base == 0x000u) return 0x74726976u;
        if (base == 0x004u) return 2u;
        if (base == 0x00cu) return 0x52415054u;
        return 0u;
    }
    switch (base)
    {
    case 0x000u: return 0x74726976u;
    case 0x004u: return 2u;
    case 0x008u: return 1u;
    case 0x00cu: return 0x52415054u;
    case 0x010u:
        return vnet.dev_feat_sel == 0 ? VNET_FEAT_LOW
             : (vnet.dev_feat_sel == 1 ? VNET_FEAT_HIGH : 0u);
    case 0x034u: return vnet.queue_sel < 2 ? VIRTIO_NET_QUEUE_MAX : 0u;
    case 0x044u: return vnet.queue_sel < 2 ? vnet.q[vnet.queue_sel].ready : 0u;
    case 0x060u: return vnet.int_status;
    case 0x070u: return vnet.status;
    case 0x0fcu: return 0u;
    case 0x100u:
        return (uint32_t)vnet.mac[0] | ((uint32_t)vnet.mac[1] << 8) |
               ((uint32_t)vnet.mac[2] << 16) | ((uint32_t)vnet.mac[3] << 24);
    case 0x104u:
        return (uint32_t)vnet.mac[4] | ((uint32_t)vnet.mac[5] << 8) | (1u << 16);
    default:
        return 0u;
    }
}

void mmio_virtio_net_handle(paddr_t offset, word_t wdata, char wmask, bool is_write, word_t *data)
{
    uint32_t aligned = (uint32_t)offset & ~0x3u;
    if (!is_write)
    {
        word_t out = 0;
        uint32_t lo = vnet_read32((uint32_t)offset & ~(uint32_t)(sizeof(word_t) - 1u));
        out = (word_t)lo;
        if (sizeof(word_t) == 8)
        {
            uint32_t hi = vnet_read32(((uint32_t)offset & ~0x7u) + 4u);
            out |= (word_t)((uint64_t)hi << 32);
        }
        if (data != NULL)
            *data = out;
        return;
    }

    if (!vnet.enabled)
        return;

    uint32_t val = 0;
    for (unsigned i = 0; i < 4; i++)
    {
        if ((uint8_t)wmask & (1u << i))
        {
            unsigned shift = (((unsigned)offset + i) & 3u) * 8u;
            val |= ((uint32_t)((wdata >> (8 * i)) & 0xffu)) << shift;
        }
    }

    vnet_queue_t *q = (vnet.queue_sel < 2) ? &vnet.q[vnet.queue_sel] : NULL;
    switch (aligned)
    {
    case 0x014u: vnet.dev_feat_sel = val; break;
    case 0x020u:
        if (vnet.drv_feat_sel < 2)
            vnet.drv_feat[vnet.drv_feat_sel] = val;
        break;
    case 0x024u: vnet.drv_feat_sel = val; break;
    case 0x030u: vnet.queue_sel = val; break;
    case 0x038u: if (q) q->num = val; break;
    case 0x044u: if (q) q->ready = val & 1u; break;
    case 0x050u:
        if (val == 1u) service_tx_queue();
        else if (val == 0u) deliver_rx_queue();
        break;
    case 0x064u: vnet.int_status &= ~val; break;
    case 0x070u:
        if (val == 0u) reset_vnet_regs();
        else vnet.status = val & 0xffu;
        break;
    case 0x080u: if (q) q->desc = (q->desc & ~0xffffffffull) | val; break;
    case 0x084u: if (q) q->desc = (q->desc & 0xffffffffull) | ((uint64_t)val << 32); break;
    case 0x090u: if (q) q->driver = (q->driver & ~0xffffffffull) | val; break;
    case 0x094u: if (q) q->driver = (q->driver & 0xffffffffull) | ((uint64_t)val << 32); break;
    case 0x0a0u: if (q) q->device = (q->device & ~0xffffffffull) | val; break;
    case 0x0a4u: if (q) q->device = (q->device & 0xffffffffull) | ((uint64_t)val << 32); break;
    default: break;
    }
}
