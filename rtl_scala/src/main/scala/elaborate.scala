object Elaborate extends App {
  val firtoolOptions = Array(
    "--lowering-options=" + List(
      // make yosys happy
      // see https://github.com/llvm/circt/blob/main/docs/VerilogGeneration.md
      "disallowLocalVariables",
      "disallowPackedArrays",
      "locationInfoStyle=wrapInAtSquareBracket"
    ).reduce(_ + "," + _),
    "--disable-layers=Verification"
  )
  circt.stage.ChiselStage.emitSystemVerilogFile(new npc.ysyx_idu_decoder(), args, firtoolOptions)
  circt.stage.ChiselStage.emitSystemVerilogFile(new npc.ysyx_idu_decoder_c(), args, firtoolOptions)
}
