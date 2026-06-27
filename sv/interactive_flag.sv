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
    import "DPI-C" function void    interactive_close(input chandle handle);

    chandle handle;

    initial handle = interactive_flag_open(NAME, WIDTH);

    // Push every change (and the first settled value) to the viewer, tagged with
    // the sim time in us ($realtime is us at this module's us/ns timescale).
    always @(value)
        interactive_flag_write(handle, $realtime, int'(value));

    final interactive_close(handle);
endmodule
