`ifndef RAPT_FP_OPS_SVH
`define RAPT_FP_OPS_SVH

// Serializing scalar-FP bring-up operation identifiers.
`define RAPT_FP_OP_FMV_W_X 6'd1
`define RAPT_FP_OP_FMV_X_W 6'd2
`define RAPT_FP_OP_FSGNJ_S 6'd3
`define RAPT_FP_OP_FSGNJN_S 6'd4
`define RAPT_FP_OP_FSGNJX_S 6'd5
`define RAPT_FP_OP_FLW 6'd6
`define RAPT_FP_OP_FSW 6'd7
`define RAPT_FP_OP_FMV_D_X 6'd8
`define RAPT_FP_OP_FMV_X_D 6'd9
`define RAPT_FP_OP_FSGNJ_D 6'd10
`define RAPT_FP_OP_FSGNJN_D 6'd11
`define RAPT_FP_OP_FSGNJX_D 6'd12
`define RAPT_FP_OP_FLD 6'd13
`define RAPT_FP_OP_FSD 6'd14
`define RAPT_FP_OP_FADD_S 6'd15
`define RAPT_FP_OP_FSUB_S 6'd16
`define RAPT_FP_OP_FADD_D 6'd17
`define RAPT_FP_OP_FSUB_D 6'd18
`define RAPT_FP_OP_FMUL_S 6'd19
`define RAPT_FP_OP_FMUL_D 6'd20
`define RAPT_FP_OP_FMIN_S 6'd21
`define RAPT_FP_OP_FMAX_S 6'd22
`define RAPT_FP_OP_FMIN_D 6'd23
`define RAPT_FP_OP_FMAX_D 6'd24
`define RAPT_FP_OP_FLE_S 6'd25
`define RAPT_FP_OP_FLT_S 6'd26
`define RAPT_FP_OP_FEQ_S 6'd27
`define RAPT_FP_OP_FCLASS_S 6'd28
`define RAPT_FP_OP_FLE_D 6'd29
`define RAPT_FP_OP_FLT_D 6'd30
`define RAPT_FP_OP_FEQ_D 6'd31
`define RAPT_FP_OP_FCLASS_D 6'd32
`define RAPT_FP_OP_FCVT_W_S 6'd33
`define RAPT_FP_OP_FCVT_WU_S 6'd34
`define RAPT_FP_OP_FCVT_L_S 6'd35
`define RAPT_FP_OP_FCVT_LU_S 6'd36
`define RAPT_FP_OP_FCVT_S_W 6'd37
`define RAPT_FP_OP_FCVT_S_WU 6'd38
`define RAPT_FP_OP_FCVT_S_L 6'd39
`define RAPT_FP_OP_FCVT_S_LU 6'd40
`define RAPT_FP_OP_FCVT_W_D 6'd41
`define RAPT_FP_OP_FCVT_WU_D 6'd42
`define RAPT_FP_OP_FCVT_L_D 6'd43
`define RAPT_FP_OP_FCVT_LU_D 6'd44
`define RAPT_FP_OP_FCVT_D_W 6'd45
`define RAPT_FP_OP_FCVT_D_WU 6'd46
`define RAPT_FP_OP_FCVT_D_L 6'd47
`define RAPT_FP_OP_FCVT_D_LU 6'd48
`define RAPT_FP_OP_FCVT_S_D 6'd49
`define RAPT_FP_OP_FCVT_D_S 6'd50
`define RAPT_FP_OP_FMADD_S 6'd51
`define RAPT_FP_OP_FMADD_D 6'd52
`define RAPT_FP_OP_FMSUB_S 6'd53
`define RAPT_FP_OP_FMSUB_D 6'd54
`define RAPT_FP_OP_FNMSUB_S 6'd55
`define RAPT_FP_OP_FNMSUB_D 6'd56
`define RAPT_FP_OP_FNMADD_S 6'd57
`define RAPT_FP_OP_FNMADD_D 6'd58
`define RAPT_FP_OP_FDIV_S 6'd59
`define RAPT_FP_OP_FDIV_D 6'd60
`define RAPT_FP_OP_FSQRT_S 6'd61
`define RAPT_FP_OP_FSQRT_D 6'd62
// Zfhmin instructions share the final 6-bit FP operation tag.  The FEU and
// IOQ distinguish the individual operation from the architected instruction
// retained in the ROB payload (or from the memory-operation width).
`define RAPT_FP_OP_ZFHMIN 6'd63

`endif
