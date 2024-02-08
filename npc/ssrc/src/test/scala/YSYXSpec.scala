// See README.md for license details.

import npc.NPC

import chisel3._
import chisel3.experimental.BundleLiterals._
import chisel3.simulator.EphemeralSimulator._
import org.scalatest.freespec.AnyFreeSpec
import org.scalatest.matchers.must.Matchers

class NPCSpec extends AnyFreeSpec with Matchers {

  "NPC Testing" in {
    simulate(new NPC()) { dut =>
      dut.reset.poke(true.B)
      dut.clock.step()
      dut.reset.poke(false.B)
      dut.clock.step()
    }
  }
}
