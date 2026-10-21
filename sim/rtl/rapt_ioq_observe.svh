// Simulation-only view of immutable, banked IOQ completion metadata.
// Callers publish this payload only while the corresponding IOQ entry is valid.
rapt_pkg::rob_generation_t ioq_observe_generation[rapt_pkg::CoreConfig.ioq_entries];
for (genvar q = 0; q < rapt_pkg::CoreConfig.ioq_entries; q++) begin : g_ioq_observe
  rapt_pkg::rob_generation_t generation[rapt_pkg::CoreConfig.dispatch_width];
  for (genvar s = 0; s < rapt_pkg::CoreConfig.dispatch_width; s++) begin : g_lane
    assign generation[s] = cpu.core.backend.lsu.u_ioq.g_payload_bank[s].completion_info[q].generation;
  end
  assign ioq_observe_generation[q] = generation[cpu.core.backend.lsu.u_ioq.ioq_payload_lane[q]];
end
