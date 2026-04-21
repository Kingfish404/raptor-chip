`ifndef RAPT_CONFIG_SVH
`define RAPT_CONFIG_SVH
/**
 * Architecture (arch) Parameters
 * @param RAPT_XLEN: Width of an integer register in bits
 * @param RAPT_I_EXTENSION: I Extension
 * @param RAPT_M_EXTENSION: M Extension
 */
`ifdef RAPT_RV64
`define RAPT_XLEN 64
`define RAPT_MISA 'h8000000000141107
`else
`define RAPT_XLEN 32
`define RAPT_MISA 'h40141107
`endif
// `define RAPT_I_EXTENSION 'h1
// `define RAPT_M_EXTENSION 'h1

/**
 * Microarchitecture (uarch) Parameters
 * @param RAPT_M_FAST: M Extension Fast Mode (one cycle)
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

// `define RAPT_M_FAST 'h1
`define RAPT_L1I_LINE_LEN 1
`define RAPT_L1I_LEN 2

`define RAPT_PHT_SIZE 2
`define RAPT_BTB_SIZE 2
`define RAPT_RSB_SIZE 2

`define RAPT_RIQ_SIZE 2
`define RAPT_IIQ_SIZE 2
`define RAPT_ROB_SIZE 2

`define RAPT_RS_SIZE 2
`define RAPT_IOQ_SIZE 2

`define RAPT_SQ_SIZE 2
`define RAPT_L1D_LEN 2

`ifdef RAPT_I_EXTENSION
`define RAPT_REG_SIZE 32 // 32 registers
`else
`define RAPT_REG_SIZE 16 // 16 registers
`endif

`define RAPT_REG_LEN $clog2(`RAPT_REG_SIZE) // Register Length

`define RAPT_PHY_SIZE 32 // physical register number
`define RAPT_PHY_LEN $clog2(`RAPT_PHY_SIZE)

`endif
