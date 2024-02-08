package npc

import chisel3._
import chisel3.util._

class AXI4 extends Bundle {
  val aw = new Bundle {
    val addr = UInt(32.W)
    val prot = UInt(3.W)
  }
}

class NPC extends Module {
  val io = IO(new Bundle {
    val in = Input(new AXI4)
  })
}
