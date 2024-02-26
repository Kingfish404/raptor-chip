#include <stdint.h>
#include <common.h>
#include <utils.h>

void difftest_skip_ref();
void npc_abort();

static uint8_t sram[SRAM_SIZE] = {};
static uint8_t mrom[MROM_SIZE] = {};
static uint8_t pmem[MSIZE] = {};
#ifdef CONFIG_SOFT_MMIO
static uint32_t rtc_port_base[2] = {0x0, 0x0};
#endif

uint8_t *guest_to_host(paddr_t addr)
{
    if (addr >= MBASE && addr <= MBASE + MSIZE)
    {
        return pmem + addr - MBASE;
    }
    if (addr >= MROM_BASE && addr < MROM_BASE + MROM_SIZE)
    {
        return mrom + addr - MROM_BASE;
    }
    if (addr >= SRAM_BASE && addr < SRAM_BASE + SRAM_SIZE)
    {
        return sram + addr - SRAM_BASE;
    }
    Assert(0, "Invalid guest address: " FMT_WORD, addr);
}

paddr_t host_to_guest(uint8_t *addr)
{
    return addr + MBASE - pmem;
}

static inline word_t host_read(void *addr, int len)
{
    switch (len)
    {
    case 1:
        return *(uint8_t *)addr;
    case 2:
        return *(uint16_t *)addr;
    case 4:
        return *(uint32_t *)addr;
    case 8:
        return *(uint64_t *)addr;
    default:
        assert(0);
    }
}

static inline void host_write(void *addr, word_t data, int len)
{
    switch (len)
    {
    case 1:
        *(uint8_t *)addr = data;
        break;
    case 2:
        *(uint16_t *)addr = data;
        break;
    case 4:
        *(uint32_t *)addr = data;
        break;
    case 8:
        *(uint64_t *)addr = data;
        break;
    default:
        assert(0);
    }
}

extern "C" void pmem_read(word_t raddr, word_t *data)
{
#ifdef CONFIG_SOFT_MMIO
    if (raddr == RTC_ADDR + 4)
    {
        uint64_t t = get_time();
        rtc_port_base[0] = (uint32_t)(t >> 32);
        *data = rtc_port_base[0];
        difftest_skip_ref();
        return;
    }
    else if (raddr == RTC_ADDR)
    {
        uint64_t t = get_time();
        rtc_port_base[1] = (uint32_t)(t);
        *data = rtc_port_base[1];
        difftest_skip_ref();
        return;
    }
#endif
    if (raddr >= MBASE && raddr < MBASE + MSIZE)
    {
        *data = host_read(pmem + raddr - MBASE, 4);
        // Log("raddr: " FMT_WORD_NO_PREFIX ", data: " FMT_WORD_NO_PREFIX,
        //        raddr, *data);
        return;
    }
    npc_abort();
    assert(0);
}

extern "C" void pmem_write(word_t waddr, word_t wdata, char wmask)
{
    // Log("waddr: 0x%x, wdata: 0x%x, wmask = 0x%x",
    //        waddr, wdata, wmask);
#ifdef CONFIG_SOFT_MMIO
    // SERIAL_MMIO: hex "MMIO address of the serial controller"
    if (waddr == SERIAL_PORT)
    {
        putchar(wdata);
        difftest_skip_ref();
        return;
    }
#endif
    if (waddr < MBASE || waddr > MBASE + MSIZE)
    {
        Log("Invalid write: addr = " FMT_WORD ", data = " FMT_WORD ", mask = %x",
            waddr, wdata, wmask);
        npc_abort();
        return;
    }
    switch (wmask)
    {
    case 0x1:
        host_write(pmem + waddr - MBASE, wdata, 1);
        break;
    case 0x3:
        host_write(pmem + waddr - MBASE, wdata, 2);
        break;
    case 0xf:
        host_write(pmem + waddr - MBASE, wdata, 4);
        break;
    case 0xff:
        host_write(pmem + waddr - MBASE, wdata, 8);
        break;
    default:
        break;
    }
}

extern "C" void flash_read(uint32_t addr, uint32_t *data) { assert(0); }

extern "C" void mrom_read(uint32_t addr, uint32_t *data)
{
    uint32_t offset = addr - MROM_BASE;
    *data = *((uint32_t *)(mrom + offset));
    Log("mrom raddr: 0x%x, rdata: 0x%x", addr, *data);
}
