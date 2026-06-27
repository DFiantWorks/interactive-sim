// tb_demo.v
//
// A tiny end-to-end demo for the VPI/Icarus flow. It shows the two component
// kinds living in one design, completely unconnected to each other yet funnelled
// to a single viewer over one socket:
//
//   * interactive_ctrl "btn_run"  -- a viewer-driven button that gates a counter.
//   * interactive_flag "led_count" -- the 8-bit counter, pushed to the viewer.
//   * interactive_flag "led_hb"    -- a slow heartbeat blinker.
//
// Run (see the Makefile `demo-vpi` target). Start the viewer first, then:
//   set btn_run=1 in the viewer to make the counter run; btn_run=0 to freeze it.

`timescale 1ns/1ps

module tb_demo;
    reg clk = 0;
    always #5 clk = ~clk;            // 100 MHz

    // Viewer-driven input: gate for the counter (no clock on the component).
    wire enable;
    interactive_ctrl #(.NAME("btn_run"), .WIDTH(1), .POLL_US(1000)) u_btn (
        .value (enable)
    );

    // Counter, gated by the button, surfaced as an 8-bit flag.
    reg [7:0] count = 0;
    always @(posedge clk)
        if (enable)
            count <= count + 8'd1;

    interactive_flag #(.NAME("led_count"), .WIDTH(8)) u_led (.value(count));

    // A free-running heartbeat, independent of everything else.
    reg hb = 0;
    always #200000 hb = ~hb;         // toggle every 200 us
    interactive_flag #(.NAME("led_hb"), .WIDTH(1)) u_hb (.value(hb));

    initial begin
        #5000000;                    // run 5 ms then stop
        $finish;
    end
endmodule
