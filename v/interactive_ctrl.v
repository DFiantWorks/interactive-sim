// interactive_ctrl.v
//
// Verilog (VPI) viewer-driven INPUT for the shared interactive-sim backend, the
// twin of sv/interactive_ctrl.sv. It reaches the backend through the system
// tasks/functions registered by v/interactive_vpi.cpp.
//
//   interactive_ctrl -- NO clock; self-paces on its own POLL_US timer (uses
//                       #-delays, native to Icarus). `value` tracks the latest
//                       value pushed from the viewer for this NAME.
//
// NAME (channel id + viewer label) must be unique across the simulation.
//
// Timescale is us/ns: a human-interaction interface, so #-delays and $realtime
// are in us directly, with 1ns precision for sub-us PWM-style toggling.

`timescale 1us/1ns

module interactive_ctrl #(
    parameter NAME    = "ctrl",
    parameter WIDTH   = 1,
    parameter POLL_US = 1000         // self-paced sample period (us); 1 ms default
) (
    output reg [WIDTH-1:0] value
);
    integer handle;

    initial begin
        handle = $interactive_ctrl_open(NAME, WIDTH);
        value  = 0;
        forever begin
            #(POLL_US);             // us, directly (us/ns timescale)
            value = $interactive_ctrl_read(handle);
        end
    end

    final $interactive_close(handle);
endmodule
