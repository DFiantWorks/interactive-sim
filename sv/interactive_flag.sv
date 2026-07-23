// interactive_flag.sv
//
// SystemVerilog (DPI-C) design-driven OUTPUT for the shared interactive-sim
// backend (../backend/interactive.cpp). Drop it in anywhere in the hierarchy,
// unconnected to anything else.
//
//   interactive_flag -- whenever `value` changes it is pushed to the viewer
//                       under this NAME (LED / 7-seg / status word).
//
// NAME is the channel id on the wire and the label in the viewer; it must be
// unique across the whole simulation. WIDTH sizes the value port.
//
//   interactive_flag #(.NAME("led_busy"), .WIDTH(1)) u_led (.value(busy));
//
// Timescale is us/ns: this is a human-interaction interface, so the natural unit
// is the microsecond -- $realtime is in us directly, while 1ns precision still
// captures sub-us PWM-style toggling.

`timescale 1us/1ns

module interactive_flag #(
    parameter string NAME  = "flag",
    parameter int    WIDTH = 1
) (
    input logic [WIDTH-1:0] value
);
    import "DPI-C" function chandle interactive_flag_open(input string name, input int width);
    import "DPI-C" function void    interactive_flag_write(input chandle handle,
                                                           input real t, input int value);
    import "DPI-C" function void    interactive_tick(input real t);
    import "DPI-C" function int     interactive_claim_heartbeat();
    import "DPI-C" function void    interactive_close(input chandle handle);

    chandle handle;

    initial handle = interactive_flag_open(NAME, WIDTH);

    // Push every change (and the first settled value) to the viewer, tagged with
    // the sim time in us ($realtime is us at this module's us/ns timescale).
    always @(value)
        interactive_flag_write(handle, $realtime, int'(value));

    // Heartbeat: only the first interactive component to start claims the single
    // heartbeat slot and runs the periodic tick; every other instance stays idle.
    // This keeps the viewer learning sim time even while `value` is quiet, with one
    // timer and one message regardless of how many components the design has.
    localparam int HEARTBEAT_US = 1000;    // internal heartbeat period (us)
    initial
        if (interactive_claim_heartbeat() != 0)
            forever begin
                #(HEARTBEAT_US);
                interactive_tick($realtime);
            end

    final interactive_close(handle);
endmodule
