# Differential unit test for rapt_fpu_divsqrt vs. host IEEE-754 FPU.
#
# The DUT (hdl/backend/feu/fpu/rapt_fpu_divsqrt.sv) is exercised with random
# operands across both precisions, both operations, and all four rounding
# modes supported by the host fenv (RNE/RTZ/RDN/RUP), plus subnormals,
# infinities, zeros and NaNs. Numeric results must match the host bit-exactly;
# NaN results only need to be NaN with the correct exception flags (RISC-V
# permits a canonical NaN for every NaN-producing operation).
#
# Usage:  make -C verify/xsim/fpu/divsqrt run [N=300000]

UNITS := divsqrt
N ?= 300000
EXTRA_SOURCES := rapt_fpu_divsqrt_ref.sv
include ../host-diff.mk
