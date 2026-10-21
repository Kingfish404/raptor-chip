# Differential unit test for the pipelined rapt_fpu_addsub vs. host IEEE-754
# FPU. See tb_host_diff.cpp for the checking policy.
#
# Usage:  make -C verify/xsim/fpu/addsub run [N=200000]

UNITS := addsub
EXTRA_SOURCES = $(ROOT)/hdl/backend/feu/fpu/rapt_fpu_fp_addsub.sv
include ../host-diff.mk
