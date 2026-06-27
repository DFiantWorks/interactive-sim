// interactive_flag.v
//
// Verilog (VPI) design-driven OUTPUT for the shared interactive-sim backend, the
// twin of sv/interactive_flag.sv. It reaches the backend through the system
// tasks/functions registered by v/interactive_vpi.cpp.
//
//   interactive_flag -- pushes `value` to the viewer on every change
//                       (LED / 7-seg / status word).
//
// NAME (channel id + viewer label) must be unique across the simulation.
//
// Timescale is us/ns: a human-interaction interface, so $realtime is in us
// directly, with 1ns precision for sub-us PWM-style toggling.

`timescale 1us/1ns

module interactive_flag #(
    parameter NAME  = "flag",
    parameter WIDTH = 1
) (
    input [WIDTH-1:0] value
);
    integer handle;

    initial handle = $interactive_flag_open(NAME, WIDTH);

    always @(value)
        $interactive_flag_write(handle, $realtime, value);  // us (us/ns timescale)

    final $interactive_close(handle);
endmodule
