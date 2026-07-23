// interactive_ctrl.sv
//
// SystemVerilog (DPI-C) viewer-driven INPUT for the shared interactive-sim
// backend (../backend/interactive.cpp). Drop it in anywhere in the hierarchy,
// unconnected to anything else.
//
//   interactive_ctrl -- has NO clock: it self-paces on its own internal POLL_US
//                       timer, so it is completely asynchronous to the rest of
//                       the design. `value` tracks the latest value pushed from
//                       the viewer for this NAME.
//
// NAME is the channel id on the wire and the label in the viewer; it must be
// unique across the whole simulation. WIDTH sizes the value port.
//
//   interactive_ctrl #(.NAME("btn_start"), .WIDTH(1)) u_btn (.value(start));
//
// It uses #-delays, so under Verilator build with --timing (natively supported
// by Icarus, GHDL, NVC, Questa, etc.).
//
// Timescale is us/ns: this is a human-interaction interface, so the natural unit
// is the microsecond -- #-delays and $realtime are both in us directly (no
// scaling), while 1ns precision still captures sub-us PWM-style toggling.

`timescale 1us/1ns

module interactive_ctrl #(
    parameter string NAME    = "ctrl",
    parameter int    WIDTH   = 1,
    parameter int    POLL_US = 1000   // self-paced sample period (us); 1 ms default
) (
    output logic [WIDTH-1:0] value
);
    import "DPI-C" function chandle interactive_ctrl_open(input string name, input int width);
    import "DPI-C" function int     interactive_ctrl_read(input chandle handle);
    import "DPI-C" function void    interactive_tick(input real t);
    import "DPI-C" function int     interactive_claim_heartbeat();
    import "DPI-C" function void    interactive_close(input chandle handle);

    chandle handle;

    // No clock: poll the viewer's latest value on this instance's own timebase.
    // The backend's reader thread keeps the value fresh independently, so a value
    // set in the viewer is picked up on the next tick with no coupling to any
    // design clock or to the other components. A human-scale period (default 1 ms)
    // is imperceptible yet costs almost nothing -- lower it only for finer input
    // timing.
    initial begin
        handle = interactive_ctrl_open(NAME, WIDTH);
        value  = '0;
        forever begin
            #(POLL_US);
            value = WIDTH'(interactive_ctrl_read(handle));
        end
    end

    // Heartbeat: only the first interactive component to start claims the single
    // heartbeat slot and runs the periodic tick; every other instance stays idle.
    // One timer, one message, regardless of how many components the design has.
    localparam int HEARTBEAT_US = 1000;   // internal heartbeat period (us)
    initial
        if (interactive_claim_heartbeat() != 0)
            forever begin
                #(HEARTBEAT_US);
                interactive_tick($realtime);
            end

    final interactive_close(handle);
endmodule
