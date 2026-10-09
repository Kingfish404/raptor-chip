#!/usr/bin/env python3
"""Verify posted-write diagnostics across actual NPC save/exit/load runs.

Build bus_write_error.S with RAPT_CKPT_ERROR, then pass its ELF and binary.
The two milestones check pending+overflow and acknowledged diagnostic data.
"""
import checkpoint_milestones

STATUS = {'checkpoint_pending': 0xf03, 'checkpoint_acknowledged': 0xf00}


def check_save(label, state, text, log):
    assert int(state['csr_mberr_status'], 0) == STATUS[label], state
    assert int(state['csr_mberr_addr'], 0) == 0x21100000, state
    assert text.count('AXI write decode error') == 2, log


def check_load(label, text, log):
    assert text.count('AXI write decode error') == 3, log


if __name__ == '__main__':
    raise SystemExit(checkpoint_milestones.run(__doc__, STATUS, check_save, check_load))
