# ULX3S GUI demo

A worked example of [interactive-sim](../) (the framework in the parent folder):
a **photo of the [ULX3S](https://github.com/ulx3s/ulx3s) board** where you
**click the buttons with the mouse** and watch the **8 user LEDs light up at
their position on the board**.

![The ULX3S GUI demo running: the simulation drives the LEDs and mouse clicks on
the board buttons feed back into the design.](ulx3s_demo.gif)

It reuses the framework unchanged (the same `interactive_ctrl` / `interactive_flag`
components, the same C++ backend and VPI shim from `../`) and adds only:

| File | Role |
|------|------|
| `ulx3s_viewer.py` | config-driven graphical viewer (stdlib `tkinter`) |
| `ulx3s.json` | board config: photo URL + LED/button pixel map + LED colour |
| `tb_ulx3s.v` | the demo design: a "Larson scanner" driven by the buttons |
| `realtime_vpi.cpp` | demo-only `$rt_sync` VPI helper that paces the sim to the wall clock |

## Run it

Start the GUI first (it listens), then the simulation (it connects):

```sh
make viewer PYTHON=python    # 1) the GUI window; needs a tkinter Python
make demo                    # 2) the simulation, paced to the wall clock
```

JPEG/cropped photos need [Pillow](https://pypi.org/project/pillow/)
(`pip install pillow`); the default config uses a PNG that is downloaded and
cached next to `ulx3s.json` on first run.

Controls (mouse, or the mirrored keys): **◀ / ▶** set the scanner sweep
direction, **▲ / ▼** change speed, **F1** (space) pauses/resumes, **F2** (enter)
resets to LED0, and **PWR** (p) lights the whole bar while held. Each board
button is *momentary*: the GUI sends `1` on press and `0` on release, and the
design edge-detects it.

## How it maps to the framework

- **Buttons → `interactive_ctrl`.** A click is hit-tested against the button
  regions in the map; the matched button's `NAME` is sent over the socket.
- **LEDs → `interactive_flag`.** The 8 LEDs are one 8-bit `leds` flag; LED item
  *i* lights when bit *i* is 1, in the configured `on_color`.

The viewer is just another viewer on the same wire protocol as the framework's
reference terminal viewer (`../viewer/interactive_viewer.py`), so anything that
speaks the protocol works here.

## The config

All coordinates are in **original-image pixels**; `image.crop` trims the photo to
the board and `image.scale` scales it for display, but the map stays in
original-image pixels so it is independent of crop and window size.

```jsonc
{
  "image":  { "url": "https://github.com/ulx3s/ulx3s/blob/master/pic/ULX3S_v303_top.png?raw=true",
              "cache": "ULX3S_v303_top.png", "crop": [160, 195, 1650, 1010], "scale": 0.72 },
  "leds":   { "on_color": "#ff5a36", "shape": "rect", "w": 26, "h": 32,
              "items": [ { "name": "leds", "bit": 0, "x": 632, "y": 462 }, ... ] },
  "buttons":[ { "name": "btn_pwr", "shape": "circle", "x": 1375, "y": 408,
                "r": 42, "key": "p" }, ... ]
}
```

To map a **different photo** (or retune the coordinates), point `image.url` at it
and run the viewer with `--calibrate`: clicking the photo prints each click's
original-image pixel coordinate, so you can read off the x/y for every LED and
button.

```sh
python ulx3s_viewer.py --calibrate
```

## Wall-clock pacing

A Verilog simulator advances *simulation* time as fast as the CPU allows, so a
free-running "blink every 100 ms" would emit thousands of updates per real second
and the viewer would only ever see the final state. So the demo's top-level loop
throttles itself to the wall clock via `$rt_sync`, a **demo-only** VPI helper
(`realtime_vpi.cpp`) loaded alongside the framework's `interactive` module
(`-m interactive -m realtime`). The framework itself is untouched; pacing is
purely a property of this demo. (Measured: ~5 LED updates per real second at the
default speed, human rate, not a flood.)
