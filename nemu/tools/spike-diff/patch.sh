#!/bin/bash
grep -q 'void take_trap_public' repo/riscv/processor.h || sed -i '' -e '/} halt_request;/a\
\
  void take_trap_public(trap_t &t, reg_t epc) { take_trap(t, epc); }' repo/riscv/processor.h