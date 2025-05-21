#include <stdint.h>
#include <common.h>
#include <utils.h>

void difftest_skip_ref();
void npc_abort();

static uint8_t pmem[MSIZE] = {};
static uint8_t sdram[SDRAM_SIZE] = {};
static uint8_t sram[SRAM_SIZE] = {};
static uint8_t mrom[MROM_SIZE] = {};
static uint8_t flash[FLASH_SIZE] = {};
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
    if (addr >= FLASH_BASE && addr < FLASH_BASE + FLASH_SIZE)
    {
        return flash + addr - FLASH_BASE;
    }
    if (addr >= SDRAM_BASE && addr < SDRAM_BASE + SDRAM_SIZE)
    {
        return sdram + addr - SDRAM_BASE;
    }
    // Assert(0, "Invalid guest address: " FMT_WORD, addr);
    return NULL;
}

uint8_t mmio_check_and_handle(
    paddr_t addr, word_t wdata, char wmask, bool is_write, word_t *data)
{
    // TODO: implement clint, plic, and serial
    if (addr >= 0x2000000 && addr < 0x2000000 + 0xc0000)
    {
        // clint@2000000
        return 1;
    }
    if (addr >= 0xc000000 && addr < 0xc000000 + 0x1000000)
    {
        // plic@c000000
        return 1;
    }
    if (addr >= 0x10000000 && addr < 0x10000000 + 0x100)
    {
        // ns16550@10000000
        void mmio_serial_handle(paddr_t addr, word_t wdata, bool is_write, word_t *data);
        mmio_serial_handle(addr - 0x10000000, wdata, is_write, data);
        return 1;
    }
    if (addr >= 0x10011800 && addr < 0x10011800 + 0x100)
    {
        // liteuart0: serial@10011800
        return 1;
    }
    return 0;
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

extern "C" void sdram_read(uint32_t addr, uint8_t *data)
{
    uint32_t offset = (addr - SDRAM_BASE);
    *data = sdram[offset];
    // Log(" sdram raddr: 0x%x, rdata: 0x%02x, offest: 0x%02x", addr, *data, offset);
}

extern "C" void sdram_write(uint32_t addr, uint8_t data)
{
    uint32_t offset = (addr - SDRAM_BASE);
    sdram[offset] = data;
    // Log("sdram waddr: 0x%x, wdata: 0x%02x, offest: 0x%02x", addr, data, offset);
}

extern "C" void pmem_read(word_t raddr, word_t *data)
{
    // Log("raddr: " FMT_WORD_NO_PREFIX, raddr);
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
    if (mmio_check_and_handle(raddr, 0, 0, false, data))
    {
        // Log("  MMIO read: addr = " FMT_WORD ", data = " FMT_WORD,
        //     raddr, *data);
        return;
    }
    uint8_t *host_addr = guest_to_host(raddr);
    host_addr = (uint8_t *)((size_t)host_addr & ~0x3);
    if (host_addr == NULL)
    {
        Log(FMT_RED("Invalid read: addr = " FMT_WORD), raddr);
        npc_abort();
        return;
    }
    *data = host_read(host_addr, 4);
    // Log("raddr: " FMT_WORD_NO_PREFIX ", data: " FMT_WORD_NO_PREFIX,
    //     raddr, *data);
}

extern "C" void pmem_write(word_t waddr, word_t wdata, char wmask)
{
    // Log("waddr: 0x%08x, wdata: 0x%08x, wmask = 0x%02x",
    //     waddr, wdata, wmask & 0xff);
#ifdef CONFIG_SOFT_MMIO
    // SERIAL_MMIO: hex "MMIO address of the serial controller"
    if (waddr == SERIAL_PORT)
    {
        putchar(wdata);
        difftest_skip_ref();
        return;
    }
#endif
    if (mmio_check_and_handle(waddr, wdata, wmask, true, NULL))
    {
        // Log("MMIO write: addr = " FMT_WORD ", data = " FMT_WORD ", mask = %02x",
        //     waddr, wdata, wmask & 0xff);
        return;
    }
    uint8_t *host_addr = guest_to_host(waddr);
    if (host_addr == NULL)
    {
        Log(FMT_RED("Invalid write: addr = " FMT_WORD ", data = " FMT_WORD ", mask = %02x"),
            waddr, wdata, wmask & 0xff);
        npc_abort();
        return;
    }
    switch (wmask)
    {
    case 0x1:
        host_write(host_addr, wdata, 1);
        break;
    case 0x3:
        host_write(host_addr, wdata, 2);
        break;
    case 0xf:
        host_write(host_addr, wdata, 4);
        break;
    // case 0xff:
    //     host_write(pmem + waddr - MBASE, wdata, 8);
    //     break;
    default:
        Log(FMT_RED("Invalid write: addr = " FMT_WORD ", data = " FMT_WORD ", mask = %02x"),
            waddr, wdata, wmask & 0xff);
        break;
    }
}

extern "C" void flash_read(uint32_t addr, uint32_t *data)
{
    uint32_t offset = addr;
    *data = *((uint32_t *)(flash + offset));
    // Log("flash raddr: 0x%08x, rdata: 0x%08x, offest: 0x%08x", addr, *data, offset);
}

extern "C" void mrom_read(uint32_t addr, uint32_t *data)
{
    uint32_t offset = ((addr & 0xfffffffc) - MROM_BASE);
    *data = *((uint32_t *)(mrom + offset));
    // Log("mrom raddr: 0x%x, rdata: 0x%x, offest: 0x%x", addr, *data, offset);
}

void vaddr_show(vaddr_t addr, int n)
{
    word_t data;
    word_t wsize = 4;
    for (word_t i = 0; i < (n / 4 + 1); i++)
    {
        if (i % 4 == 0)
        {
            if (i != 0)
            {
                printf("| ");
                for (size_t j = 0; j < wsize; j++)
                {
                    data = host_read(guest_to_host(addr + (i - (3 - j) - 1) * wsize), 4);
                    for (size_t k = 0; k < wsize; k++)
                    {
                        uint8_t c = (data >> (((wsize)-1 - k) * 8)) & 0xff;
                        printf("%02x ", c);
                    }
                    printf(" ");
                }
                printf("\n");
            }
            printf("" FMT_WORD ": ", addr + i * wsize);
        }
        data = host_read(guest_to_host(addr + i * wsize), 4);
        printf("" FMT_WORD " ", data);
    }
    printf("\n");
}

void init_mem()
{
    void init_serial();
    init_serial();
}