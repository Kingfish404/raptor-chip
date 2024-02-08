import circt.stage._
import npc._

object Elaborate extends App {
  def ysyx = new NPC()
  val generator = Seq(chisel3.stage.ChiselGeneratorAnnotation(() => ysyx))
  (new ChiselStage)
    .execute(args, generator :+ CIRCTTargetAnnotation(CIRCTTarget.Verilog))
}
