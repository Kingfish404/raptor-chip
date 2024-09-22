package gcd

import chisel3._
import chisel3.util.{switch, is}
import chisel3.util.BitPat
import chisel3.util.Cat
import chisel3.util.experimental.decode._

class CSRDecoder extends Module {

  def ECALL_ = BitPat("b0000000 00000 00000 000 00000 1110011")
  def EBREAK = BitPat("b0011000 00010 00000 000 00000 1110011")
  def MRET__ = BitPat("b0011000 00010 00000 000 00000 1110011")

  def FENCEI = BitPat("b??????? ????? ????? 001 ????? 0001111")

  def CSRRW_ = BitPat("b??????? ????? ????? 001 ????? 1110011")
  def CSRRS_ = BitPat("b??????? ????? ????? 010 ????? 1110011")
  def CSRRC_ = BitPat("b??????? ????? ????? 011 ????? 1110011")
  def CSRRWI = BitPat("b??????? ????? ????? 101 ????? 1110011")
  def CSRRSI = BitPat("b??????? ????? ????? 110 ????? 1110011")
  def CSRRCI = BitPat("b??????? ????? ????? 111 ????? 1110011")
  val table = TruthTable(
    Map(
      ECALL_ -> BitPat("b0111"),
      EBREAK -> BitPat("b1111"),
      MRET__ -> BitPat("b0111"),
      FENCEI -> BitPat("b0001"),
      CSRRW_ -> BitPat("b0011"),
      CSRRS_ -> BitPat("b0011"),
      CSRRC_ -> BitPat("b0011"),
      CSRRWI -> BitPat("b0011"),
      CSRRSI -> BitPat("b0011"),
      CSRRCI -> BitPat("b0011")
    ),
    BitPat("b000")
  )
  val instruction = IO(Input(UInt(32.W)))
  var ebreak_o = IO(Output(UInt(1.W)))
  val system_func3_zero_o = IO(Output(UInt(1.W)))
  val csr_wen_o = IO(Output(UInt(1.W)))
  val system_o = IO(Output(UInt(1.W)))

  val decoded = decoder(instruction, table)
  ebreak_o := decoded(3)
  system_func3_zero_o := decoded(2)
  csr_wen_o := decoded(1)
  system_o := decoded(0)
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

  io.outputGCD := x
  io.outputValid := y === 0.U
}
