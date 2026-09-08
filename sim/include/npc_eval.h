#pragma once
#include <device_write.h>

// Call once for each clock half-cycle, after setting the new clock level.
// Device callbacks may append events during eval; consume only the front
// presented before a rising edge, leaving newly queued writes for the next one.
template<class Top> inline void npc_eval(Top *dut)
{
#if !defined(RAPT_SOC) && !defined(CONFIG_wrapBus)
  uint64_t first = 0, last = 0;
  if (dut->reset) device_write_reset();
  const bool valid = !dut->reset && device_write_front(&first, &last);
  dut->external_write_valid_i = valid;
  dut->external_write_pending_i = valid;
  dut->external_write_first_i = first;
  dut->external_write_last_i = last;
  dut->eval();
  if (dut->clock && valid) device_write_consume();
#else
  dut->eval();
#endif
}
