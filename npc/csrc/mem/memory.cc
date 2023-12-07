#include "common.h"

static uint8_t pmem[MSIZE] = {};

uint8_t *guest_to_host(paddr_t addr)
{
    return pmem + addr - MBASE;
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

extern "C" void pmem_read(word_t addr, word_t *data)
{
    if (addr >= MBASE && addr < MBASE + MSIZE)
    {
        *data = host_read(pmem + addr - MBASE, 4);
    }
    // printf("pmem_read addr: " FMT_WORD_NO_PREFIX ", ", addr);
    // printf("data: " FMT_WORD_NO_PREFIX "\n", *data);
}

extern "C" void pmem_write(word_t waddr, word_t wdata, char wmask)
{
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
    // printf("pmem_write: waddr = 0x%x, wdata = 0x%x, wmask = 0x%x\n",
    //        waddr, wdata, wmask);
}