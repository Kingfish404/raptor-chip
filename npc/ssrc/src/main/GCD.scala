package gcd

import chisel3._
import chisel3.util.BitPat
import chisel3.util.Cat
import chisel3.util.experimental.decode._

class CSRDecoder extends Module {
  val instruction = IO(Input(UInt(32.W)))
  val csr_wen = IO(Output(UInt(1.W)))
  val table = TruthTable(
    Map(
      // ecall
      BitPat("b0000000 00000 00000 000 00000 1110011") -> BitPat("b1"),
      // ebreak
      BitPat("b0011000 00010 00000 000 00000 1110011") -> BitPat("b1"),
      // CSRRW
      BitPat("b??????? ????? ????? 001 ????? 1110011") -> BitPat("b1"),
      // CSRRS
      BitPat("b??????? ????? ????? 010 ????? 1110011") -> BitPat("b1"),
      // CSRRC
      BitPat("b??????? ????? ????? 011 ????? 1110011") -> BitPat("b1"),
      // CSRRWI
      BitPat("b??????? ????? ????? 101 ????? 1110011") -> BitPat("b1"),
      // CSRRSI
      BitPat("b??????? ????? ????? 110 ????? 1110011") -> BitPat("b1"),
      // CSRRCI
      BitPat("b??????? ????? ????? 111 ????? 1110011") -> BitPat("b1")
    ),
    BitPat("b0")
  )
  csr_wen := decoder(instruction, table)
}

class SimpleDecoder extends Module {
  val input = IO(Input(UInt(3.W)))
  val output = IO(Output(UInt(1.W)))

  val table = TruthTable(
    Map(
      BitPat("b001") -> BitPat("b?"),
      BitPat("b010") -> BitPat("b?"),
      BitPat("b100") -> BitPat("b1"),
      BitPat("b101") -> BitPat("b1"),
      BitPat("b111") -> BitPat("b1")
    ),
    BitPat("b0")
  )
  output := decoder(input, table)
}

/** Compute GCD using subtraction method. Subtracts the smaller from the larger
  * until register y is zero. value in register x is then the GCD
  */
class GCD extends Module {
  val io = IO(new Bundle {
    val value1 = Input(UInt(16.W))
    val value2 = Input(UInt(16.W))
    val loadingValues = Input(Bool())
    val outputGCD = Output(UInt(16.W))
    val outputValid = Output(Bool())
  })

  val x = Reg(UInt())
  val y = Reg(UInt())

  when(x > y) { x := x - y }.otherwise { y := y - x }

  when(io.loadingValues) {
    x := io.value1
    y := io.value2
  }

  // use SimpleDecoder to decode the output
  val decoder = Module(new SimpleDecoder)
  decoder.input := Cat(x(0), y(0), x > y)
  io.outputGCD := decoder.output

  io.outputValid := y === 0.U
}
