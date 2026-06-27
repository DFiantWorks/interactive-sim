// tb_demo.sv
//
// SystemVerilog twin of examples/tb_demo.v for the DPI/Verilator flow. Two
// unconnected component kinds funnelled to one viewer over one socket:
//   * interactive_ctrl "btn_run"   -- viewer-driven gate for a counter.
//   * interactive_flag "led_count" -- the 8-bit counter.
//   * interactive_flag "led_hb"    -- a heartbeat blinker.
//
// Build with Verilator --timing (interactive_ctrl uses #-delays). See the
// `demo-dpi` Makefile target.

`timescale 1ns/1ps

module tb_demo;
    logic clk = 0;
    always #5 clk = ~clk;            // 100 MHz

    logic enable;
    interactive_ctrl #(.NAME("btn_run"), .WIDTH(1), .POLL_US(1000)) u_btn (
        .value (enable)
    );

    logic [7:0] count = 0;
    always_ff @(posedge clk)
        if (enable)
            count <= count + 8'd1;

    interactive_flag #(.NAME("led_count"), .WIDTH(8)) u_led (.value(count));

    logic hb = 0;
    always #200000 hb = ~hb;         // toggle every 200 us
    interactive_flag #(.NAME("led_hb"), .WIDTH(1)) u_hb (.value(hb));

    initial begin
        #5000000;                    // run 5 ms then stop
        $finish;
    end
endmodule
