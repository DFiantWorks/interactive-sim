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
    localparam HEARTBEAT_US = 1000;      // internal heartbeat period (us)
    integer handle;

    initial handle = $interactive_flag_open(NAME, WIDTH);

    always @(value)
        $interactive_flag_write(handle, $realtime, value);  // us (us/ns timescale)

    // Heartbeat: only the first interactive component to start claims the single
    // heartbeat slot and runs the periodic tick; every other instance stays idle.
    // So the viewer keeps learning sim time even while `value` is quiet, with one
    // timer and one message regardless of how many components the design has.
    initial
        if ($interactive_claim_heartbeat())
            forever begin
                #(HEARTBEAT_US);
                $interactive_tick($realtime);
            end

    final $interactive_close(handle);
endmodule
