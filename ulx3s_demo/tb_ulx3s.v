// tb_ulx3s.v
//
// A ULX3S-board GUI demo for interactive-sim, end-to-end on the VPI/Icarus flow.
// It models the 8 user LEDs and the board's push-buttons as interactive-sim
// components, all funnelled to the graphical viewer over one socket. The viewer
// is fpga-isv (https://github.com/DFiantWorks/interactive-sim-viewer), which
// ships this board as its bundled `ulx3s` example; the LED/button names below
// match that example's panel map:
//
//   * interactive_ctrl "btn_pwr"               -- lights the whole LED bar while held
//   * interactive_ctrl "btn_left"/"btn_right"  -- sweep direction of a "Larson scanner"
//   * interactive_ctrl "btn_up"/"btn_down"     -- scanner faster / slower
//   * interactive_ctrl "btn_fire1"             -- pause / resume the scanner
//   * interactive_ctrl "btn_fire2"             -- reset the scanner to LED0
//   * interactive_flag  "leds" (8-bit)         -- the 8 user LEDs (bit i -> LEDi)
//
// The buttons are momentary: the GUI sends 1 on mouse-down and 0 on mouse-up, so
// the design edge-detects a press. A single always-process drives all state, so
// every register has exactly one driver.
//
// Run (from this ulx3s_demo/ folder). Start the GUI viewer first, then click the
// buttons on the board and watch the LEDs sweep:
//   make viewer              # in one terminal (fpga-isv, ULX3S example; it listens)
//   make demo                # in another  (the sim; it connects)
//
// NOTE: this testbench calls $rt_sync (realtime_vpi.cpp), a demo-only
// VPI helper that paces the simulation to the wall clock so the animation runs
// at human speed. It must be loaded alongside the framework's `interactive`
// module (the Makefile target does this with `-m interactive -m realtime`).

`timescale 1us/1ns

module tb_ulx3s;
    // ---- viewer-driven momentary push-buttons (ULX3S: PWR + a 6-way pad) ----
    localparam POLL = 4000;          // control poll period: 4 ms
    wire pwr, fire1, fire2, up, down, left, right;
    interactive_ctrl #(.NAME("btn_pwr"),   .WIDTH(1), .POLL_US(POLL)) u_pwr (.value(pwr));
    interactive_ctrl #(.NAME("btn_fire1"), .WIDTH(1), .POLL_US(POLL)) u_f1  (.value(fire1));
    interactive_ctrl #(.NAME("btn_fire2"), .WIDTH(1), .POLL_US(POLL)) u_f2  (.value(fire2));
    interactive_ctrl #(.NAME("btn_up"),    .WIDTH(1), .POLL_US(POLL)) u_up  (.value(up));
    interactive_ctrl #(.NAME("btn_down"),  .WIDTH(1), .POLL_US(POLL)) u_dn  (.value(down));
    interactive_ctrl #(.NAME("btn_left"),  .WIDTH(1), .POLL_US(POLL)) u_lf  (.value(left));
    interactive_ctrl #(.NAME("btn_right"), .WIDTH(1), .POLL_US(POLL)) u_rt  (.value(right));

    // ---- the 8 user LEDs, surfaced as one 8-bit flag (bit i -> LEDi) ----
    reg [7:0] leds = 8'b0000_0001;
    interactive_flag #(.NAME("leds"), .WIDTH(8)) u_leds (.value(leds));

    // ---- animation + control state (single process => single driver each) ----
    localparam BASE = 15000;         // 15 ms wall-clock-paced base tick
    integer steps = 8;               // scanner advances every `steps` base ticks
    integer cnt   = 0;
    reg [2:0] pos = 3'd0;            // lit LED position
    reg       dir = 1'b1;            // 1: sweep toward LED7, 0: toward LED0
    reg       run = 1'b1;            // running / paused
    reg pf1=0, pf2=0, pu=0, pd=0, pl=0, pr=0;   // previous button samples

    initial begin
        forever begin
            #(BASE);
            $rt_sync($realtime);     // pace the sim to the wall clock (demo VPI)

            // rising-edge actions on the momentary buttons
            if (fire1 & ~pf1) run   = ~run;                                // pause/resume
            if (fire2 & ~pf2) pos   = 3'd0;                                // reset to LED0
            if (left  & ~pl)  dir   = 1'b1;                                // sweep left
            if (right & ~pr)  dir   = 1'b0;                                // sweep right
            if (up    & ~pu)  steps = (steps > 2)  ? steps - 1 : steps;    // faster
            if (down  & ~pd)  steps = (steps < 40) ? steps + 1 : steps;    // slower
            pf1=fire1; pf2=fire2; pu=up; pd=down; pl=left; pr=right;

            // advance the Larson scanner
            if (run) begin
                cnt = cnt + 1;
                if (cnt >= steps) begin
                    cnt = 0;
                    if (dir) pos = (pos == 3'd7) ? 3'd0 : pos + 3'd1;
                    else     pos = (pos == 3'd0) ? 3'd7 : pos - 3'd1;
                end
            end

            // PWR lights the whole bar; otherwise show the single scanner dot.
            // Same value => no @(value) event => nothing sent (change-driven).
            leds = pwr ? 8'hFF : (8'b1 << pos);
        end
    end
endmodule
