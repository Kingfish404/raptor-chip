#!/usr/bin/env bash

set -euo pipefail

processor_header=repo/riscv/processor.h
if ! grep -q 'void take_trap_public' "$processor_header"; then
  sed -i.bak -e '/} halt_request;/a\
\
  void take_trap_public(trap_t \&t, reg_t epc) { take_trap(t, epc); }' "$processor_header"
  rm -f "${processor_header}.bak"
fi