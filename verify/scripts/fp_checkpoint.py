#!/usr/bin/env python3
"""Verify FP contexts across real save/exit/load runs of fp_context.S."""
import checkpoint_milestones


def check_save(label, state, text, log):
    assert all(f'fpr{i}' in state for i in range(32)), state
    assert 'csr_fcsr' in state, state
    # The probe milestone may legally hold an all-zero initial FP state.
    if label == 'software_interrupt':
        assert any(int(state[f'fpr{i}'], 0) != 0 for i in range(32)), state


if __name__ == '__main__':
    raise SystemExit(checkpoint_milestones.run(__doc__, ('probe', 'software_interrupt'), check_save))
