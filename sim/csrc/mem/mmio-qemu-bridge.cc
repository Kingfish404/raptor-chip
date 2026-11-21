#include <common.h>
#include <device_write.h>
#include <memory.h>

#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <vector>

// Verilator RQIO v1 client (`--qemu-io-socket=PATH`): connects Verilator SoC
// I/O apertures (0x10001000..0x10008fff and 0x41000000..0x5fffffff) directly
// to `tools/qemu_io_bridge/raptor_qemu_bridge.py` (`qemu-system-riscv64` or
// builtin backend), servicing DMA_READ_REQ / DMA_WRITE_REQ and PLIC IRQs.
void nsim_plic_raise(uint32_t irq);

static struct
{
    const char *socket_path;
    int fd;
    uint16_t seq;
    uint32_t prev_irq_mask;
} qbridge = {NULL, -1, 1, 0};

void qemu_io_bridge_set_socket(const char *path)
{
    qbridge.socket_path = path;
}

bool qemu_io_bridge_active()
{
    return qbridge.fd >= 0;
}

static bool write_all(int fd, const void *buf, size_t len)
{
    const uint8_t *p = (const uint8_t *)buf;
    size_t sent = 0;
    while (sent < len)
    {
        ssize_t n = write(fd, p + sent, len - sent);
        if (n <= 0)
            return false;
        sent += (size_t)n;
    }
    return true;
}

static bool read_all(int fd, void *buf, size_t len)
{
    uint8_t *p = (uint8_t *)buf;
    size_t got = 0;
    while (got < len)
    {
        ssize_t n = read(fd, p + got, len - got);
        if (n <= 0)
            return false;
        got += (size_t)n;
    }
    return true;
}

static bool send_rqio_pkt(const void *payload, uint16_t len)
{
    uint8_t hdr[2] = {(uint8_t)(len & 0xffu), (uint8_t)(len >> 8)};
    return write_all(qbridge.fd, hdr, 2) && write_all(qbridge.fd, payload, len);
}

static bool recv_rqio_pkt(std::vector<uint8_t> &out)
{
    uint8_t hdr[2];
    if (!read_all(qbridge.fd, hdr, 2))
        return false;
    uint16_t len = (uint16_t)hdr[0] | ((uint16_t)hdr[1] << 8);
    out.resize(len);
    return len == 0 || read_all(qbridge.fd, out.data(), len);
}

static void update_irqs(uint32_t mask)
{
    uint32_t rising = mask & ~qbridge.prev_irq_mask;
    qbridge.prev_irq_mask = mask;
    for (uint32_t irq = 1; irq < 32; irq++)
    {
        if (rising & (1u << irq))
            nsim_plic_raise(irq);
    }
}

void init_qemu_io_bridge()
{
    if (qbridge.fd >= 0)
    {
        close(qbridge.fd);
        qbridge.fd = -1;
    }
    qbridge.seq = 1;
    qbridge.prev_irq_mask = 0;

    if (qbridge.socket_path == NULL || qbridge.socket_path[0] == '\0')
        return;

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0)
    {
        fprintf(stderr, "[qemu-io] socket() failed: %s\n", strerror(errno));
        exit(1);
    }
    struct sockaddr_un sun;
    memset(&sun, 0, sizeof(sun));
    sun.sun_family = AF_UNIX;
    strncpy(sun.sun_path, qbridge.socket_path, sizeof(sun.sun_path) - 1);
    if (connect(fd, (struct sockaddr *)&sun, sizeof(sun)) != 0)
    {
        fprintf(stderr, "[qemu-io] connect(%s) failed: %s\n",
                qbridge.socket_path, strerror(errno));
        exit(1);
    }
    qbridge.fd = fd;
    Log("qemu-io: connected RQIO bridge socket %s", qbridge.socket_path);
}

void mmio_qemu_bridge_handle(paddr_t addr, word_t wdata, char wmask, bool is_write, word_t *data)
{
    if (qbridge.fd < 0)
        return;

    // Determine aligned transfer size (0=1B, 1=2B, 2=4B, 3=8B) from active byte mask
    uint8_t m = (uint8_t)wmask;
    unsigned nbytes = 4;
    if (m == 0x01u) nbytes = 1;
    else if (m == 0x03u) nbytes = 2;
    else if (m == 0x0fu) nbytes = 4;
    else if (m == 0xffu) nbytes = 8;
    uint8_t size_log2 = (nbytes == 1) ? 0 : (nbytes == 2 ? 1 : (nbytes == 8 ? 3 : 2));

    uint32_t lane_off = (uint32_t)addr & 7u;
    uint8_t wstrb8 = is_write ? (uint8_t)(m << lane_off) : 0u;
    uint64_t wdata64 = is_write ? (((uint64_t)wdata) << (lane_off * 8u)) : 0ull;

    uint16_t seq = qbridge.seq++;
    uint8_t req[20];
    req[0] = 'R';
    req[1] = 'Q';
    req[2] = 1;
    req[3] = 0x01;  // MSG_MMIO_REQ
    memcpy(req + 4, &seq, 2);
    req[6] = (uint8_t)((size_log2 << 1) | (is_write ? 1u : 0u));
    req[7] = wstrb8;
    uint32_t addr32 = (uint32_t)addr;
    memcpy(req + 8, &addr32, 4);
    memcpy(req + 12, &wdata64, 8);

    if (!send_rqio_pkt(req, sizeof(req)))
        return;

    std::vector<uint8_t> pkt;
    while (recv_rqio_pkt(pkt))
    {
        if (pkt.size() < 8 || pkt[0] != 'R' || pkt[1] != 'Q' || pkt[2] != 1)
            continue;
        uint8_t mtype = pkt[3];
        uint16_t rseq = (uint16_t)pkt[4] | ((uint16_t)pkt[5] << 8);

        if (mtype == 0x03 && pkt.size() >= 16)  // MSG_DMA_READ_REQ
        {
            uint16_t dlen = 0;
            uint64_t daddr = 0;
            memcpy(&dlen, pkt.data() + 6, 2);
            memcpy(&daddr, pkt.data() + 8, 8);
            std::vector<uint8_t> resp(12 + dlen, 0);
            resp[0] = 'R';
            resp[1] = 'Q';
            resp[2] = 1;
            resp[3] = 0x04;  // MSG_DMA_READ_RESP
            memcpy(resp.data() + 4, &rseq, 2);
            memcpy(resp.data() + 6, &dlen, 2);
            resp[8] = dma_guest_read(daddr, resp.data() + 12, dlen) ? 0 : 1;
            send_rqio_pkt(resp.data(), (uint16_t)resp.size());
        }
        else if (mtype == 0x06 && pkt.size() >= 16)  // MSG_DMA_WRITE_REQ
        {
            uint16_t dlen = 0;
            uint64_t daddr = 0;
            memcpy(&dlen, pkt.data() + 6, 2);
            memcpy(&daddr, pkt.data() + 8, 8);
            bool ok = (pkt.size() >= (size_t)(16 + dlen)) &&
                      dma_guest_write(daddr, pkt.data() + 16, dlen);
            uint8_t resp[12];
            memset(resp, 0, sizeof(resp));
            resp[0] = 'R';
            resp[1] = 'Q';
            resp[2] = 1;
            resp[3] = 0x05;  // MSG_DMA_WRITE_RESP
            memcpy(resp + 4, &rseq, 2);
            memcpy(resp + 6, &dlen, 2);
            resp[8] = ok ? 0 : 1;
            send_rqio_pkt(resp, sizeof(resp));
        }
        else if (mtype == 0x07 && pkt.size() >= 12)  // MSG_IRQ_UPDATE
        {
            uint32_t irq_m = 0;
            memcpy(&irq_m, pkt.data() + 8, 4);
            update_irqs(irq_m);
        }
        else if (mtype == 0x02 && pkt.size() >= 20 && rseq == seq)  // MSG_MMIO_RESP
        {
            uint32_t irq_m = 0;
            uint64_t rdata64 = 0;
            memcpy(&irq_m, pkt.data() + 8, 4);
            memcpy(&rdata64, pkt.data() + 12, 8);
            update_irqs(irq_m);
            if (!is_write && data != NULL)
            {
                uint32_t word_lane = (uint32_t)addr & ~(uint32_t)(sizeof(word_t) - 1u);
                uint32_t shift = (word_lane & 7u) * 8u;
                *data = (word_t)(rdata64 >> shift);
            }
            break;
        }
    }
}

void qemu_io_bridge_poll()
{
    if (qbridge.fd < 0)
        return;

    struct pollfd pfd;
    pfd.fd = qbridge.fd;
    pfd.events = POLLIN;
    pfd.revents = 0;

    std::vector<uint8_t> pkt;
    while (poll(&pfd, 1, 0) > 0 && (pfd.revents & POLLIN) != 0)
    {
        if (!recv_rqio_pkt(pkt))
            break;
        if (pkt.size() < 8 || pkt[0] != 'R' || pkt[1] != 'Q' || pkt[2] != 1)
            continue;
        uint8_t mtype = pkt[3];
        uint16_t rseq = (uint16_t)pkt[4] | ((uint16_t)pkt[5] << 8);
        if (mtype == 0x03 && pkt.size() >= 16)
        {
            uint16_t dlen = 0;
            uint64_t daddr = 0;
            memcpy(&dlen, pkt.data() + 6, 2);
            memcpy(&daddr, pkt.data() + 8, 8);
            std::vector<uint8_t> resp(12 + dlen, 0);
            resp[0] = 'R';
            resp[1] = 'Q';
            resp[2] = 1;
            resp[3] = 0x04;
            memcpy(resp.data() + 4, &rseq, 2);
            memcpy(resp.data() + 6, &dlen, 2);
            resp[8] = dma_guest_read(daddr, resp.data() + 12, dlen) ? 0 : 1;
            send_rqio_pkt(resp.data(), (uint16_t)resp.size());
        }
        else if (mtype == 0x06 && pkt.size() >= 16)
        {
            uint16_t dlen = 0;
            uint64_t daddr = 0;
            memcpy(&dlen, pkt.data() + 6, 2);
            memcpy(&daddr, pkt.data() + 8, 8);
            bool ok = (pkt.size() >= (size_t)(16 + dlen)) &&
                      dma_guest_write(daddr, pkt.data() + 16, dlen);
            uint8_t resp[12];
            memset(resp, 0, sizeof(resp));
            resp[0] = 'R';
            resp[1] = 'Q';
            resp[2] = 1;
            resp[3] = 0x05;
            memcpy(resp + 4, &rseq, 2);
            memcpy(resp + 6, &dlen, 2);
            resp[8] = ok ? 0 : 1;
            send_rqio_pkt(resp, sizeof(resp));
        }
        else if (mtype == 0x07 && pkt.size() >= 12)
        {
            uint32_t irq_m = 0;
            memcpy(&irq_m, pkt.data() + 8, 4);
            update_irqs(irq_m);
        }
        pfd.revents = 0;
    }
}
