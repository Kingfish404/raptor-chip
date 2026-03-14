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

#include <isa.h>
#include <device/map.h>

// ---------------------------------------------------------------------------
// RISC-V PLIC (Platform-Level Interrupt Controller)
// Reference: https://github.com/riscv/riscv-plic-spec/blob/master/riscv-plic-1.0.0.pdf
//            https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/plic.cc
// ---------------------------------------------------------------------------

// Number of external interrupt sources (1-based; source 0 is reserved/unused)
#define PLIC_NDEV 32
// Number of contexts: context 0 = M-mode hart 0, context 1 = S-mode hart 0
#define PLIC_NCTX 2
#define PLIC_NWORDS ((PLIC_NDEV + 31) / 32)

// PLIC register-map offsets
#define PLIC_PRIORITY_BASE 0x000000 // 4 bytes per source (0..NDEV)
#define PLIC_PENDING_BASE 0x001000  // 4 bytes per 32-source word
#define PLIC_ENABLE_BASE 0x002000   // per-context enable bits
#define PLIC_ENABLE_STRIDE 0x80
#define PLIC_CONTEXT_BASE 0x200000 // per-context threshold + claim/complete
#define PLIC_CONTEXT_STRIDE 0x1000

static uint8_t *plic_base = NULL;

// PLIC internal state
static uint32_t plic_priority[PLIC_NDEV + 1];
static uint32_t plic_pending[PLIC_NWORDS];
static uint32_t plic_enable[PLIC_NCTX][PLIC_NWORDS];
static uint32_t plic_threshold[PLIC_NCTX];
static uint32_t plic_claimed[PLIC_NCTX];

// Update MIP.MEIP / MIP.SEIP (and SIP.SEIP) based on current PLIC state.
static void plic_update_mip(void)
{
    for (int ctx = 0; ctx < PLIC_NCTX; ctx++)
    {
        bool has_irq = false;
        for (int i = 1; i <= PLIC_NDEV; i++)
        {
            int w = i / 32, b = i % 32;
            if ((plic_pending[w] & (1u << b)) &&
                (plic_enable[ctx][w] & (1u << b)) &&
                plic_priority[i] > plic_threshold[ctx])
            {
                has_irq = true;
                break;
            }
        }
        if (ctx == 0)
        {
            // Context 0 → MEIP (bit 11 of MIP)
            if (has_irq)
                cpu.sr[CSR_MIP] |= (1u << 11);
            else
                cpu.sr[CSR_MIP] &= ~(1u << 11);
        }
        else
        {
            // Context 1 → SEIP (bit 9 of MIP and SIP)
            if (has_irq)
            {
                cpu.sr[CSR_MIP] |= (1u << 9);
                cpu.sr[CSR_SIP] |= (1u << 9);
            }
            else
            {
                cpu.sr[CSR_MIP] &= ~(1u << 9);
                cpu.sr[CSR_SIP] &= ~(1u << 9);
            }
        }
    }
}

// Claim: return highest-priority pending+enabled IRQ for a context
// and clear its pending bit.
static uint32_t plic_claim(int ctx)
{
    uint32_t best_id = 0;
    uint32_t best_prio = plic_threshold[ctx];
    for (int i = 1; i <= PLIC_NDEV; i++)
    {
        int w = i / 32, b = i % 32;
        if ((plic_pending[w] & (1u << b)) &&
            (plic_enable[ctx][w] & (1u << b)) &&
            plic_priority[i] > best_prio)
        {
            best_prio = plic_priority[i];
            best_id = i;
        }
    }
    if (best_id > 0)
    {
        int w = best_id / 32, b = best_id % 32;
        plic_pending[w] &= ~(1u << b);
        plic_claimed[ctx] = best_id;
    }
    return best_id;
}

// Public: raise an external interrupt at source `irq` (1-based).
void plic_raise_irq(int irq)
{
    if (irq < 1 || irq > PLIC_NDEV)
        return;
    int w = irq / 32, b = irq % 32;
    plic_pending[w] |= (1u << b);
    plic_update_mip();
}

// Keep the old timer-interrupt API for backward compatibility.
void dev_raise_intr(void)
{
    if (!cpu.intr)
    {
        cpu.intr = true;
    }
}

// ---------------------------------------------------------------------------
// MMIO handler
// ---------------------------------------------------------------------------
static void plic_io_handler(uint32_t offset, int len, bool is_write)
{
    // Priority registers: 0x000000 .. 0x000000 + (NDEV+1)*4
    if (offset < PLIC_PRIORITY_BASE + (PLIC_NDEV + 1) * 4)
    {
        int src = (offset - PLIC_PRIORITY_BASE) / 4;
        if (src <= PLIC_NDEV)
        {
            if (is_write)
            {
                plic_priority[src] = *(uint32_t *)(plic_base + offset);
                plic_update_mip();
            }
            else
            {
                *(uint32_t *)(plic_base + offset) = plic_priority[src];
            }
        }
        return;
    }

    // Pending registers (read-only): 0x001000 .. 0x001000 + NWORDS*4
    if (offset >= PLIC_PENDING_BASE &&
        offset < PLIC_PENDING_BASE + PLIC_NWORDS * 4)
    {
        int w = (offset - PLIC_PENDING_BASE) / 4;
        if (!is_write)
        {
            *(uint32_t *)(plic_base + offset) = plic_pending[w];
        }
        return;
    }

    // Enable registers: 0x002000 + ctx * 0x80
    if (offset >= PLIC_ENABLE_BASE &&
        offset < PLIC_ENABLE_BASE + PLIC_NCTX * PLIC_ENABLE_STRIDE)
    {
        int ctx = (offset - PLIC_ENABLE_BASE) / PLIC_ENABLE_STRIDE;
        int w = ((offset - PLIC_ENABLE_BASE) % PLIC_ENABLE_STRIDE) / 4;
        if (ctx < PLIC_NCTX && w < PLIC_NWORDS)
        {
            if (is_write)
            {
                plic_enable[ctx][w] = *(uint32_t *)(plic_base + offset);
                plic_update_mip();
            }
            else
            {
                *(uint32_t *)(plic_base + offset) = plic_enable[ctx][w];
            }
        }
        return;
    }

    // Context threshold + claim/complete: 0x200000 + ctx * 0x1000
    if (offset >= PLIC_CONTEXT_BASE &&
        offset < PLIC_CONTEXT_BASE + PLIC_NCTX * PLIC_CONTEXT_STRIDE)
    {
        int ctx = (offset - PLIC_CONTEXT_BASE) / PLIC_CONTEXT_STRIDE;
        int reg = (offset - PLIC_CONTEXT_BASE) % PLIC_CONTEXT_STRIDE;
        if (ctx >= PLIC_NCTX)
            return;

        if (reg == 0x0)
        {
            // Threshold
            if (is_write)
            {
                plic_threshold[ctx] = *(uint32_t *)(plic_base + offset);
                plic_update_mip();
            }
            else
            {
                *(uint32_t *)(plic_base + offset) = plic_threshold[ctx];
            }
        }
        else if (reg == 0x4)
        {
            // Claim (read) / Complete (write)
            if (is_write)
            {
                uint32_t id = *(uint32_t *)(plic_base + offset);
                if (id >= 1 && id <= PLIC_NDEV)
                {
                    plic_claimed[ctx] = 0;
                }
                plic_update_mip();
            }
            else
            {
                uint32_t id = plic_claim(ctx);
                *(uint32_t *)(plic_base + offset) = id;
                plic_update_mip();
            }
        }
        return;
    }
}

void init_intr(void)
{
    plic_base = new_space(0x01000000);
    memset(plic_priority, 0, sizeof(plic_priority));
    memset(plic_pending, 0, sizeof(plic_pending));
    memset(plic_enable, 0, sizeof(plic_enable));
    memset(plic_threshold, 0, sizeof(plic_threshold));
    memset(plic_claimed, 0, sizeof(plic_claimed));
    // https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/platform.h
    // https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/plic.cc
    add_mmio_map("plic", CONFIG_PLIC_MMIO, plic_base, 0x01000000, plic_io_handler);
}