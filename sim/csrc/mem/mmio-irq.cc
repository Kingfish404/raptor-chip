#include <common.h>

#include <atomic>

extern NPCState npc;

// ---------------------------------------------------------------------------
// PLIC IRQ delivery via the synthesizable `ext_irq_i[]` port (rapt.sv:147).
// ---------------------------------------------------------------------------
// `g_ext_irq_pending` accumulates "pulse" bits: each MMIO callback that wants
// to fire IRQ N sets bit N. The TB wrapper (sim/rtl/) calls
// `npc_consume_ext_irq_vector()` once per `posedge clock`, atomically reading
// and clearing the bitmap, then drives `ext_irq_i[]` for one cycle. The PLIC
// edge-detect FSM (rtl/uncore/irq/rapt_plic.sv) latches the rising edge as
// pending, exactly as a real device line would.
//
// This replaces the legacy backdoor `*npc.plic_pending |= ...` write into
// rtl/ state, removing the cross-hierarchy poke and making the IRQ
// path synthesizable end-to-end (the TB drives a real port).
//
// Bit indexing matches the PLIC: bit `i` <-> source `i` (1..NDEV); bit 0 is
// reserved and ignored.
static std::atomic<uint32_t> g_ext_irq_pending{0};

void nsim_plic_raise(uint32_t irq)
{
    if (irq == 0 || irq > NPC_PLIC_NDEV)
        return;
    g_ext_irq_pending.fetch_or(1u << irq, std::memory_order_relaxed);
}

bool qemu_io_bridge_active();
void qemu_io_bridge_poll();
void goldfish_rtc_poll();

extern "C" void npc_consume_ext_irq_vector(int *rdata)
{
    static uint32_t poll_div = 0;
    if ((++poll_div & 0xffu) == 0)
    {
        if (qemu_io_bridge_active())
            qemu_io_bridge_poll();
        else
            goldfish_rtc_poll();
    }
    if (rdata == nullptr)
        return;
    *rdata = (int)g_ext_irq_pending.exchange(0, std::memory_order_relaxed);
}