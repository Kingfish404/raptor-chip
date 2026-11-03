"""Exercise the native source guard with forbidden and permitted ownership."""

from pathlib import Path
import shutil
import tempfile
import unittest

from native_sv_check import check_file


@unittest.skipUnless(shutil.which("verible-verilog-syntax"), "Verible syntax tool required")
class NativeSourceGuardTest(unittest.TestCase):
    def check(self, source):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.sv"
            path.write_text(source)
            return check_file(path, "verible-verilog-syntax")

    def test_defaults_include_multiline_and_arrays(self):
        findings = self.check("""
module fixture(input logic a = 1'b0,
               continued = 1'b0,
               input logic b[2] = '{default: '0});
  function automatic logic f(input logic x,
                             input logic y = 1'b1);
    return x | y;
  endfunction
  task automatic t(input logic x = 1'b0); endtask
endmodule
""")
        self.assertEqual(len(findings), 5)

    def test_parameter_and_local_initializers_are_permitted(self):
        self.assertEqual(self.check("""
module fixture #(parameter int N = 2)(input logic a, output logic b);
  logic x = 1'b0;
  always_comb b = a | x;
endmodule
"""), [])

    def test_disjoint_fields_still_have_shared_variable(self):
        findings = self.check("""
module fixture(input logic a, b);
  struct packed { logic lo, hi; } value;
  always_comb value.lo = a;
  always_comb value.hi = b;
endmodule
""")
        self.assertEqual(len(findings), 1)
        self.assertIn("multiple always blocks", findings[0][1])

    def test_output_port_has_one_owner(self):
        findings = self.check("""
module fixture(input logic a, b, output logic result);
  always_comb result = a;
  always_comb result = b;
endmodule
""")
        self.assertEqual(len(findings), 1)

    def test_concatenations_and_subscripts(self):
        findings = self.check("""
module fixture(input logic clock, a, index);
  logic lo, hi;
  logic [1:0] data;
  always_ff @(posedge clock) {lo, hi} <= {a, a};
  always_ff @(posedge clock) hi <= !a;
  always_ff @(posedge clock) data[index] <= a;
endmodule
""")
        self.assertEqual(len(findings), 1)
        self.assertIn("hi is written", findings[0][1])

    def test_generate_and_preprocessor_alternatives(self):
        self.assertEqual(self.check("""
module fixture #(parameter bit Mode = 0)(input logic a, output logic result);
`ifdef MODE
  always_comb result = a;
`else
  if (Mode) begin : g_a
    always_comb result = a;
  end else begin : g_b
    always_comb result = !a;
  end
`endif
endmodule
"""), [])

    def test_independent_generate_conditions_are_not_alternatives(self):
        findings = self.check("""
module fixture #(parameter bit A = 0, B = 1)(input logic x, output logic result);
  if (A) begin : g_a
    always_comb result = x;
  end
  if (B) begin : g_b
    always_comb result = !x;
  end
endmodule
""")
        self.assertEqual(len(findings), 1)

    def test_standalone_generate_blocks(self):
        findings = self.check("""
module fixture(input logic x, output wire result);
  begin : g_outer
    for (genvar i = 0; i < 1; i++) begin : g_loop
      begin : g_inner
        assign result = x;
      end
    end
  end
endmodule
""")
        self.assertEqual(len(findings), 2)
        self.assertTrue(all("standalone generate" in message for _, message in findings))

    def test_constant_generate_and_procedural_scopes(self):
        self.assertEqual(self.check("""
module fixture(input logic x, output logic result);
  if (1'b1) begin : g_outer
    always_comb begin : p_value
      result = x;
    end
  end
endmodule
"""), [])

    def test_port_assignment_patterns(self):
        findings = self.check("""
module fixture(input logic value);
  child named(.data('{value}));
  child ordered('{default: 1'b0});
endmodule
""")
        self.assertEqual(len(findings), 2)
        self.assertTrue(all("assignment pattern in port" in message for _, message in findings))

    def test_typed_array_connections(self):
        self.assertEqual(self.check("""
module fixture(input logic value);
  wire data[1];
  assign data[0] = value;
  child named(.data(data));
endmodule
"""), [])

    def test_defaults_in_both_conditional_port_lists(self):
        findings = self.check("""
module fixture(
`ifdef FEATURE
  input logic a = 1'b0
`else
  input logic b = 1'b0
`endif
);
endmodule
""")
        self.assertEqual(len(findings), 2)

    def test_conditional_shared_writers_are_checked(self):
        findings = self.check("""
module fixture(input logic a, b, output logic result);
`ifdef FEATURE
  always_comb result = a;
  always_comb result = b;
`endif
endmodule
""")
        self.assertEqual(len(findings), 1)
        self.assertIn("multiple always blocks", findings[0][1])

    def test_inline_conditional_port_punctuation(self):
        findings = self.check("""
module fixture(input logic a);
  child dut(.first(a)
`ifdef FEATURE,
    .second('{a})
`endif
  );
endmodule
""")
        self.assertEqual(len(findings), 1)
        self.assertIn("assignment pattern", findings[0][1])

    def test_onehot_logic_requires_assertion_guard(self):
        findings = self.check("""
module fixture(input logic [1:0] value);
  wire first = $onehot(value);
`ifdef FEATURE
  wire second = $onehot0(value);
`endif
endmodule
""")
        self.assertEqual(len(findings), 2)
        self.assertTrue(all("assertion guard" in message for _, message in findings))

    def test_guarded_onehot_and_assertion_macros(self):
        self.assertEqual(self.check("""
module fixture(input logic [1:0] value, input logic clock, reset);
`ifdef RAPT_SVA_ACTIVE
  wire first = $onehot(value);
`endif
`ifndef SYNTHESIS
  wire second = $onehot0(value);
`endif
  `RAPT_SVA(clock, reset, ONEHOT, $onehot(value))
endmodule
"""), [])

    def test_utf8_comments_preserve_line_numbers(self):
        findings = self.check("""// π
module fixture(input logic a = 1'b0);
endmodule
""")
        self.assertEqual(findings[0][0], 2)

    def test_interface_introspection_requires_simulation_guard(self):
        findings = self.check("""
module fixture(bus_if.slave bus);
  localparam int DataBits = $bits(bus.data);
  if (int'(bus.Width) != 2) $error("wrong width");
endmodule
""")
        self.assertEqual(len(findings), 2)
        self.assertTrue(all("interface introspection" in message for _, message in findings))

    def test_interface_data_and_simulation_shape_check(self):
        self.assertEqual(self.check("""
module fixture(bus_if.slave bus, output logic value);
`ifndef SYNTHESIS
  if (bus.Width != 2) $error("wrong width");
`endif
  assign value = bus.data[0];
endmodule
"""), [])

    def test_local_temporaries_and_interface_fields(self):
        self.assertEqual(self.check("""
interface bus_if;
  logic a, b;
  modport master(output a, b);
endinterface
module fixture(input logic x, bus_if.master bus);
  always_comb begin
    logic tmp;
    tmp = x;
    bus.a = tmp;
  end
  always_comb begin
    logic tmp;
    tmp = !x;
    bus.b = tmp;
  end
endmodule
"""), [])


if __name__ == "__main__":
    unittest.main()
