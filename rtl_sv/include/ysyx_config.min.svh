`ifndef YSYX_CONFIG_SVH
`define YSYX_CONFIG_SVH
/**
 * Architecture (arch) Parameters
 * @param YSYX_XLEN: Width of an integer register in bits
 * @param YSYX_I_EXTENSION: I Extension
 * @param YSYX_M_EXTENSION: M Extension
 */
`define YSYX_XLEN 32
// `define YSYX_I_EXTENSION 'h1
`define YSYX_M_EXTENSION 'h1

`define YSYX_MISA 'h40141105

/**
 * Microarchitecture (uarch) Parameters
 * @param YSYX_M_FAST: M Extension Fast Mode (one cycle)
 *
 * @param L1I_LINE_LEN: L1I Line Length
 * @param L1I_LEN: L1I Length (Size)
 *
 * @param IQ_SIZE: Issue Queue Size
 * @param ROB_SIZE: ReOrder Buffer Size
 *
 * @param RS_SIZE: Revervation Station Size
 * @param IOQ_SIZE: In-Order Queue Size
 *
 * @param SQ_SIZE: Store Queue Size
 * @param L1D_LEN: L1D Length (Size)
 */

// `define YSYX_M_FAST 'h1
`define YSYX_L1I_LINE_LEN 1
`define YSYX_L1I_LEN 1

`define YSYX_PHT_SIZE 2
`define YSYX_BTB_SIZE 2
`define YSYX_RSB_SIZE 2

`define YSYX_IQ_SIZE 2
`define YSYX_ROB_SIZE 2

`define YSYX_RS_SIZE 2
`define YSYX_IOQ_SIZE 2

`define YSYX_SQ_SIZE 2
`define YSYX_L1D_LEN 1

`ifdef YSYX_I_EXTENSION
`define YSYX_REG_LEN 5  // 32 registers
`else
`define YSYX_REG_LEN 4  // 16 registers
`endif

`define YSYX_REG_SIZE 2**`YSYX_REG_LEN

`define YSYX_PHY_SIZE 64 // physical register number
`define YSYX_PHY_LEN $clog2(`YSYX_PHY_SIZE)

`endif
