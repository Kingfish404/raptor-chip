/* Native KU5P RAM loader: polled Ethernet, ARP/IPv4 and bounded TFTP reads. */
#include <stdint.h>
#include "netboot_config.h"

#define REG(n) (*(volatile uint32_t *)(uintptr_t)(0x18000000u + (n)))
#define UART ((volatile uint8_t *)(uintptr_t)0x10000000u)
static uint8_t rx[1536], tx[1536];
static const uint8_t mac[6] = {2, 0x52, 0x41, 0x50, 5, 1};
static uint8_t peer[6];
static uint32_t crc_table[256];
extern void boot_jump(uintptr_t, uintptr_t) __attribute__((noreturn));

static void copy(uint8_t *d, const uint8_t *s, unsigned n)
{
    while (n--) *d++ = *s++;
}
static int equal(const uint8_t *a, const uint8_t *b, unsigned n)
{
    while (n--) if (*a++ != *b++) return 0;
    return 1;
}
static void say(const char *s)
{
    while (*s) {
        while (!(UART[5] & 0x20)) {}
        UART[0] = *s++;
    }
}
static void hex(uint32_t v)
{
    char s[9];
    for (unsigned i = 0; i < 8; i++) s[i] = "0123456789abcdef"[(v >> (28 - 4*i)) & 15];
    s[8] = 0;
    say(s);
}
static void fail(const char *s) __attribute__((noreturn));
static void fail(const char *s)
{
    say("NETBOOT ERROR: "); say(s); say("\r\n");
    say("Returning to native ROM\r\n");
    REG(8) = 0;
    while (!(UART[5] & 0x40)) {}
    boot_jump(0x20000000u, 0);
}
void boot_trap(unsigned long cause, unsigned long pc, unsigned long address)
{
    say("NETBOOT TRAP "); hex(cause); say(" pc="); hex(pc); say(" addr="); hex(address);
    fail("trap");
}
static uint32_t ticks(void)
{
    unsigned long v;
    __asm__ volatile ("rdtime %0" : "=r"(v));
    return v;
}
static void delay(unsigned us)
{
    uint32_t t = ticks();
    while ((uint32_t)(ticks() - t) < us) {}
}
static unsigned get16(const uint8_t *p) { return (unsigned)p[0] << 8 | p[1]; }
static uint32_t get32(const uint8_t *p)
{
    return (uint32_t)get16(p) << 16 | get16(p + 2);
}
static void set16(uint8_t *p, unsigned v) { p[0] = v >> 8; p[1] = v; }
static void set32(uint8_t *p, uint32_t v) { set16(p, v >> 16); set16(p + 2, v); }
static unsigned checksum(const uint8_t *p, unsigned n)
{
    unsigned s = 0;
    while (n > 1) { s += get16(p); p += 2; n -= 2; }
    if (n) s += (unsigned)*p << 8;
    while (s >> 16) s = (s & 65535) + (s >> 16);
    return (~s) & 65535;
}
static void mdio_bit(unsigned b)
{
    REG(0x40) = 2 | (b ? 4 : 0); delay(1);
    REG(0x40) = 3 | (b ? 4 : 0); delay(1);
    REG(0x40) = 2 | (b ? 4 : 0);
}
static void mdio_send(unsigned value, unsigned bits)
{
    while (bits--) mdio_bit((value >> bits) & 1);
}
static unsigned mdio_get(void)
{
    REG(0x40) = 0; delay(1); REG(0x40) = 1; delay(1);
    /* Sample while MDC is high; a falling-edge sample can see the next bit. */
    unsigned value = REG(0x44) & 1;
    REG(0x40) = 0;
    return value;
}
static void mdio_header(unsigned op, unsigned reg)
{
    mdio_send(0xffffffffu, 32); mdio_send(1, 2); mdio_send(op, 2);
    mdio_send(1, 5); mdio_send(reg, 5);
}
static void phy_write(unsigned reg, unsigned v)
{
    mdio_header(1, reg); mdio_send(2, 2); mdio_send(v, 16); REG(0x40) = 0;
}
static unsigned phy_read(unsigned reg)
{
    mdio_header(2, reg);
    unsigned bad = mdio_get(), v = 0;
    for (unsigned i = 0; i < 16; i++) v = (v << 1) | mdio_get();
    mdio_get(); REG(0x40) = 0;
    return bad ? 65535 : v;
}
static void transmit(unsigned n)
{
    uint32_t t = ticks();
    while (!(REG(0x0c) & 2))
        if ((uint32_t)(ticks() - t) > 2000000) fail("TX timeout");
    for (unsigned i = 0; i < n; i += 4) {
        uint32_t v = 0;
        for (unsigned j = 0; j < 4 && i+j < n; j++) v |= (uint32_t)tx[i+j] << (8*j);
        REG(0x2000 + i) = v;
    }
    __asm__ volatile ("fence rw,rw" ::: "memory");
    REG(0x20) = n;
}
static unsigned receive(void)
{
    unsigned d = REG(0x18), n = d & 65535, slot = (d >> 16) & 7;
    if (!n) return 0;
    if (n <= sizeof(rx)) {
        for (unsigned i = 0; i < n; i += 4) {
            uint32_t v = REG(0x4000 + slot * 2048 + i);
            for (unsigned j = 0; j < 4 && i+j < n; j++) rx[i+j] = v >> (8*j);
        }
    }
    __asm__ volatile ("fence rw,rw" ::: "memory");
    REG(0x1c) = 1;
    return n <= sizeof(rx) ? n : 0;
}
static void ethernet(const uint8_t *dest, unsigned type)
{
    copy(tx, dest, 6); copy(tx + 6, mac, 6); set16(tx + 12, type);
}
static void arp(unsigned op, const uint8_t *dest)
{
    ethernet(dest, 0x806); set16(tx + 14, 1); set16(tx + 16, 0x800);
    tx[18] = 6; tx[19] = 4; set16(tx + 20, op);
    copy(tx + 22, mac, 6); set32(tx + 28, CLIENT_IP);
    copy(tx + 32, dest, 6); set32(tx + 38, SERVER_IP);
    transmit(42);
}
/* Service ARP while receiving TFTP; only accept our configured peer. */
static unsigned poll(void)
{
    unsigned n = receive();
    if (n >= 42 && get16(rx + 12) == 0x806 && get16(rx + 14) == 1 &&
        get16(rx + 16) == 0x800 && rx[18] == 6 && rx[19] == 4 &&
        get32(rx + 28) == SERVER_IP && get32(rx + 38) == CLIENT_IP) {
        if (get16(rx + 20) == 1 || get16(rx + 20) == 2) copy(peer, rx + 22, 6);
        if (get16(rx + 20) == 1) arp(2, peer);
        return 0;
    }
    return n;
}
static void udp(unsigned source, unsigned dest, unsigned bytes)
{
    ethernet(peer, 0x800);
    for (unsigned i = 14; i < 42; i++) tx[i] = 0;
    tx[14] = 0x45; set16(tx + 16, 28 + bytes); tx[22] = 64; tx[23] = 17;
    set32(tx + 26, CLIENT_IP); set32(tx + 30, SERVER_IP);
    set16(tx + 24, checksum(tx + 14, 20));
    set16(tx + 34, source); set16(tx + 36, dest); set16(tx + 38, 8 + bytes);
    transmit(42 + bytes);
}
static unsigned string(uint8_t *d, const char *s)
{
    unsigned n = 0;
    do { d[n] = s[n]; } while (s[n++]);
    return n;
}
static void request(const char *name, unsigned local)
{
    set16(tx + 42, 1);
    unsigned n = 2;
    n += string(tx + 42 + n, name); n += string(tx + 42 + n, "octet");
    n += string(tx + 42 + n, "blksize"); n += string(tx + 42 + n, "1024");
    udp(local, SERVER_PORT, n);
}
static void ack_block(unsigned local, unsigned remote, unsigned block)
{
    set16(tx + 42, 4); set16(tx + 44, block); udp(local, remote, 4);
}
static void download(const char *name, uintptr_t address, unsigned size, uint32_t expected,
                     unsigned local)
{
    unsigned remote = 0, block = 0, offset = 0, retries = 0, blocksize = 512;
    uint32_t crc = ~0u, start = ticks(), last = start;
    say("TFTP "); say(name); say("\r\n"); request(name, local);
    for (;;) {
        unsigned n = poll();
        if ((uint32_t)(ticks() - last) > 1000000) {
            if (++retries > 20) fail("TFTP timeout");
            if (remote) ack_block(local, remote, block); else request(name, local);
            last = ticks();
        }
        if (n < 46 || !equal(rx, mac, 6) || !equal(rx + 6, peer, 6) ||
            get16(rx + 12) != 0x800 || rx[14] != 0x45 || rx[23] != 17 ||
            (get16(rx + 20) & 0x3fff) || checksum(rx + 14, 20) ||
            get32(rx + 26) != SERVER_IP || get32(rx + 30) != CLIENT_IP ||
            get16(rx + 36) != local) continue;
        unsigned total = get16(rx + 16), len = get16(rx + 38), port = get16(rx + 34);
        if (total < 32 || total + 14 > n || len < 12 || len + 20 != total ||
            (remote && remote != port)) continue;
        unsigned op = get16(rx + 42), seq = get16(rx + 44);
        if (op == 5) fail("TFTP server rejected request");
        if (op == 6 && !offset && !block) {
            static const uint8_t option[] = "blksize\0001024";
            if (len != 8 + 2 + sizeof(option) || !equal(rx + 44, option, sizeof(option)))
                fail("unsupported TFTP option reply");
            remote = port; blocksize = 1024; ack_block(local, remote, 0);
            last = ticks(); retries = 0; continue;
        }
        if (op != 3 || len - 12 > blocksize) continue;
        if (seq == block && remote) { ack_block(local, remote, block); continue; }
        if (seq != (unsigned)(uint16_t)(block + 1)) continue;
        unsigned bytes = len - 12;
        if (bytes > size - offset) fail("file exceeds expected size");
        remote = port;
        uint8_t *dst = (uint8_t *)(address + offset);
        for (unsigned i = 0; i < bytes; i++) {
            uint8_t v = rx[46+i]; dst[i] = v;
            crc = (crc >> 8) ^ crc_table[(crc ^ v) & 255];
        }
        offset += bytes; block = seq; retries = 0; last = ticks();
        ack_block(local, remote, block);
        if (offset && !(offset & 0xfffff)) { say("Loaded 0x"); hex(offset); say("\r\n"); }
        if (bytes < blocksize) {
            if (offset != size || ~crc != expected) fail("file size/CRC mismatch");
            say("Verified bytes=0x"); hex(offset); say(" elapsed_us=0x"); hex(ticks() - start); say("\r\n");
            /* Dally for a lost final ACK before advancing to the next transfer. */
            uint32_t end = ticks();
            while ((uint32_t)(ticks() - end) < 1100000) {
                n = poll();
                if (n >= 46 && get16(rx + 12) == 0x800 && rx[14] == 0x45 &&
                    get32(rx + 26) == SERVER_IP && get16(rx + 34) == remote &&
                    get16(rx + 36) == local && get16(rx + 42) == 3 && get16(rx + 44) == block)
                    ack_block(local, remote, block);
            }
            return;
        }
    }
}
void boot_main(void)
{
    say("\r\nRaptor native TFTP loader\r\n");
    if (REG(0) != 0x524e4554 || REG(4) != 1) fail("Ethernet ABI");
    REG(0x10) = 0; REG(8) = 0;
    phy_write(31, 0);
    uint32_t phy_id = (uint32_t)phy_read(2) << 16 | phy_read(3);
    say("PHY ID "); hex(phy_id); say("\r\n");
    if (phy_id != 0x001cc916u) fail("unexpected PHY ID");
    /* RTL8211F: internal TX delay, no RX delay (RX phase is in FPGA). */
    phy_write(31, 0xd08); phy_write(0x11, phy_read(0x11) | 0x100);
    phy_write(0x15, phy_read(0x15) & ~8u);
    unsigned txcr = phy_read(0x11), rxcr = phy_read(0x15);
    if (!(txcr & 0x100) || (rxcr & 8)) fail("PHY delay configuration");
    say("RGMII TXCR="); hex(txcr); say(" RXCR="); hex(rxcr); say("\r\n");
    phy_write(31, 0xa43); phy_write(0x19, phy_read(0x19) & ~0x20u);
    phy_write(31, 0);
    phy_write(4, 1); phy_write(9, 0x200); phy_write(0, 0x1200);
    delay(200000);
    uint32_t start = ticks();
    while ((phy_read(1) & 0x24) != 0x24) {
        if ((uint32_t)(ticks() - start) > 15000000) fail("PHY link timeout");
        delay(10000);
    }
    REG(8) = 1;
    while (!(REG(0x0c) & 4))
        if ((uint32_t)(ticks() - start) > 16000000) fail("MAC clock timeout");
    say("Link ready; BMCR="); hex(phy_read(0)); say(" ANAR="); hex(phy_read(4));
    say(" CTRL1000="); hex(phy_read(9)); say(" BMSR="); hex(phy_read(1)); say("\r\n");
    say("ARP\r\n");
    static const uint8_t broadcast[6] = {255,255,255,255,255,255};
    for (unsigned attempt = 0; !peer[0] && !peer[1] && !peer[2] && !peer[3] && !peer[4] && !peer[5]; attempt++) {
        if (attempt == 20) {
            say("MAC status="); hex(REG(0x0c)); say(" rx="); hex(REG(0x28));
            say(" errors="); hex(REG(0x2c)); say(" tx="); hex(REG(0x34));
            say(" phy="); hex(phy_read(1)); say("\r\n");
            fail("ARP timeout");
        }
        arp(1, broadcast);
        start = ticks();
        while ((uint32_t)(ticks() - start) < 1000000) poll();
    }
    for (unsigned i = 0; i < 256; i++) {
        uint32_t c = i;
        for (unsigned j = 0; j < 8; j++) c = (c >> 1) ^ (0xedb88320u & (0u - (c & 1)));
        crc_table[i] = c;
    }
    download("fw_payload.bin", 0x80000000u, FIRMWARE_SIZE, FIRMWARE_CRC, 49152);
    download("runtime.dtb", 0x8fff0000u, DTB_SIZE, DTB_CRC, 49153);
    REG(8) = 0;
    say("Starting OpenSBI/Linux\r\n");
    while (!(UART[5] & 0x40)) {}
    boot_jump(0x80000000u, 0x8fff0000u);
}
