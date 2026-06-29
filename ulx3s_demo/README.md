# ULX3S GUI demo

The **simulation half** of a worked graphical example of [interactive-sim](../)
(the framework in the parent folder): a **photo of the
[ULX3S](https://github.com/ulx3s/ulx3s) board** where you **click the buttons
with the mouse** and watch the **8 user LEDs light up at their position on the
board**.

The graphical panel itself is **[fpga-isv](https://github.com/DFiantWorks/interactive-sim-viewer)**,
the standalone interactive-sim panel viewer. It ships the ULX3S board as its
bundled `ulx3s` example (the board photo + LED/button pixel map), so this folder
no longer carries its own viewer — it only holds the demo design and a wall-clock
pacing helper:

| File | Role |
|------|------|
| `tb_ulx3s.v` | the demo design: a "Larson scanner" driven by the buttons |
| `realtime_vpi.cpp` | demo-only `$rt_sync` VPI helper that paces the sim to the wall clock |

Everything else — the `interactive_ctrl` / `interactive_flag` components, the C++
backend, and the VPI shim — is reused unchanged from [`../`](../).

## Run it

Install the viewer once (a prebuilt binary, `pipx install fpga-isv`, or Homebrew —
see the [fpga-isv README](https://github.com/DFiantWorks/interactive-sim-viewer#install)).
Then start the GUI first (it listens), and the simulation second (it connects):

```sh
make viewer                  # 1) the fpga-isv GUI window, ULX3S example
make demo                    # 2) the simulation, paced to the wall clock
```

`make viewer` is just a convenience wrapper for `fpga-isv --example ulx3s`.

Controls (mouse, or the mirrored keys): **◀ / ▶** set the scanner sweep
direction, **▲ / ▼** change speed, **F1** (space) pauses/resumes, **F2** (enter)
resets to LED0, and **PWR** (p) lights the whole bar while held. Each board
button is *momentary*: the GUI sends `1` on press and `0` on release, and the
design edge-detects it.

## How it maps to the framework

- **Buttons → `interactive_ctrl`.** A click is hit-tested against the button
  regions in fpga-isv's panel map; the matched button's `NAME` is sent over the
  socket. `tb_ulx3s.v` instantiates one `interactive_ctrl` per button.
- **LEDs → `interactive_flag`.** The 8 LEDs are one 8-bit `leds` flag; LED item
  *i* lights when bit *i* is 1, in the configured `on_color`.

The names in `tb_ulx3s.v` (`leds`, `btn_pwr`, `btn_fire1`, `btn_fire2`, `btn_up`,
`btn_down`, `btn_left`, `btn_right`) match the `ulx3s` example's panel map. fpga-isv
is a pure client of the same wire protocol as the framework's reference terminal
viewer ([`../viewer/interactive_viewer.py`](../viewer/interactive_viewer.py)), so
anything that speaks the protocol works here.

## The panel config (now in fpga-isv)

The board photo, the LED/button pixel map, and the `--calibrate` workflow for
mapping a different photo all live in fpga-isv now. See its
[Config](https://github.com/DFiantWorks/interactive-sim-viewer#config) section
for the JSON format and how to tune coordinates.

## Wall-clock pacing

A Verilog simulator advances *simulation* time as fast as the CPU allows, so a
free-running "blink every 100 ms" would emit thousands of updates per real second
and the viewer would only ever see the final state. So the demo's top-level loop
throttles itself to the wall clock via `$rt_sync`, a **demo-only** VPI helper
(`realtime_vpi.cpp`) loaded alongside the framework's `interactive` module
(`-m interactive -m realtime`). The framework itself is untouched; pacing is
purely a property of this demo. (Measured: ~5 LED updates per real second at the
default speed, human rate, not a flood.)
