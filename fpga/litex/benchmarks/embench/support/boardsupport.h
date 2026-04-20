/* ============================================================================
 * boardsupport.h: Embench-IoT board support for Raptor LiteX SoC
 *
 * Freestanding port — no newlib/picolibc required. Mirrors the structure of
 * the CoreMark LiteX port in ../coremark/portme/.
 *
 * Timing: RISC-V rdcycle + rdtime (Zicntr, 1 MHz timebase).
 * Output: minimal printf via LiteX UART CSR (see minilib.c).
 * ============================================================================ */

#ifndef BOARDSUPPORT_H
#define BOARDSUPPORT_H

/* Used by embench-iot's main() (upstream support/main.c) — we provide our
 * own main.c which also honours this, to match our NPC port. */
#define WARMUP_HEAT 1

#endif /* BOARDSUPPORT_H */
