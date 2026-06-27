# interactive-sim

Drop **viewer-driven controls** and **design-driven flags** anywhere in an HDL
design — at any hierarchy, unconnected to each other — and funnel them all
to/from a **single dedicated viewer over one TCP socket**. Each component is
completely asynchronous to the others.

Two components, one simulator-agnostic C++ backend, three foreign-interface
shims (DPI / VPI / VHPIDIRECT) — the same layering as
[vga-monitor-sim](../vga-monitor-sim).

| Component | Direction | Models | HDL trigger |
|-----------|-----------|--------|-------------|
| `interactive_ctrl` | viewer → design | buttons, switches, toggles | none (self-paced `POLL_US` timer, default 1 ms) |
| `interactive_flag` | design → viewer | LEDs, 7-segments, status words | on `value` change |

## How unconnected components share one socket

The backend (`backend/interactive.cpp`) is compiled once and linked into the
simulation process, so its **process-global singleton** — one socket, one
background reader thread, one registry — is shared by every instance regardless
of where it sits in the hierarchy. That shared singleton, **not any HDL wiring**,
is what lets unrelated components meet on one socket.

- **Outputs** (`flag`): on each `value` change the HDL calls the backend, which
  sends a framed message to the viewer.
- **Inputs** (`ctrl`): a single **background reader thread** owns the receive
  side of the socket and demultiplexes inbound messages into a `name → value`
  map. Each `ctrl` reads its latest value from that map on its own `POLL_NS`
  tick. A value set in the viewer is therefore visible to every clock domain on
  its next sample, with **no coupling between domains**.

> Why `ctrl` has no clock: DPI/VPI give a foreign thread no portable way to force
> a signal value into the simulator asynchronously — the simulator owns all
> signal scheduling. So `ctrl` self-paces on its own internal `#`-delay timer,
> which keeps it asynchronous to everything else and controls input latency.

## Identity

Each component is identified by a **user-supplied `NAME`**, which is both its
channel id on the wire and its label in the viewer. **Names must be unique**
across the whole simulation; a collision is reported and the duplicate instance
is dropped.

## Wire protocol

Newline-delimited JSON, one message per line:

```
sim    -> viewer   {"ev":"reg",  "name":"btn_run","kind":"ctrl","width":1}
                   {"ev":"flag", "t":1234.567,"name":"led_count","val":42}
                   {"ev":"close","name":"btn_run"}
viewer -> sim      {"name":"btn_run","val":1}
```

Plain JSON lines, so any GUI can speak it — the bundled
`viewer/interactive_viewer.py` is just a reference terminal viewer.

**Time and resolution.** This is a human-interaction interface (buttons, LEDs),
so the time base is the **microsecond**: the flag `t` tag is in µs and
`interactive_ctrl` polls on a µs-scale `POLL_US` period (default 1 ms — well below
human perception). 1 ns precision is still preserved, so the one place finer
timing matters — a fast-toggled flag dimmed by PWM duty cycle — a viewer can
still reconstruct its perceived brightness from the µs `t` stamps. The HDL
components carry a `1us/1ns` timescale (Verilog/SV) or use `us`/`ns` time
literals (VHDL); nothing in the design is forced to a finer base.

## Update model

Updates are **per-component and change-driven** — only the component that changed
is transmitted, identified by its `NAME`. There is no full-state snapshot and no
broadcast of all components.

- **Controls (viewer → sim):** the viewer sends one message for the control the
  user actually touched; the backend updates only that entry, and each
  `interactive_ctrl` reads only its own `NAME`. Touching one control says nothing
  about any other.
- **Flags (sim → viewer):** each `interactive_flag` is sensitive to its own
  `value`, so it emits only when *that* instance changes, carrying only its own
  `{name, val}`. Other flags stay silent.

Consequences:

- **No redundant sends.** `@(value)` / `process(value)` wake on an actual change
  event, so reassigning the same value emits nothing.
- **Whole-component granularity.** An 8-bit flag that changes one bit sends its
  full 8-bit `val`, but still only for that one component — there is no per-bit
  delta within a component.
- **Traffic scales with activity, not instance count.** A design with 200 idle
  LEDs and one blinking one sends one message per blink, not 200.
- **Late joiners.** Because state is sent only on change, a viewer that connects
  mid-run learns a flag's value only on its next change. (An initial state replay
  or periodic snapshot would be a deliberate add-on, not the default.)

## Quick start

Start the viewer first (it listens; the sim connects as a client):

```sh
make viewer                 # listens on 127.0.0.1:7777 by default (PORT=...)
```

In another terminal, run a demo (button gates a counter, surfaced as flags):

```sh
make demo-vpi               # Icarus Verilog
make demo-dpi               # Verilator (built with --timing)
make demo-vhpi              # GHDL
make demo-nvc               # NVC
```

In the viewer, type `btn_run=1` to start the counter and watch `led_count`
update; `btn_run=0` freezes it. The `led_hb` heartbeat blinks independently.

For a graphical example — a photo of the ULX3S board where you click the buttons
with the mouse and watch the LEDs light up at their position — see the
self-contained [`ulx3s_demo/`](ulx3s_demo/) (its own README + Makefile):

![The ULX3S GUI demo running](ulx3s_demo/ulx3s_demo.gif)

## Usage in your own design

```systemverilog
interactive_ctrl #(.NAME("sw_mode"), .WIDTH(2)) u_sw  (.value(mode));
interactive_flag #(.NAME("led_err"), .WIDTH(1)) u_err (.value(error));
```

```vhdl
u_sw  : entity work.interactive_ctrl
    generic map (NAME => "sw_mode", WIDTH => 2) port map (value => mode);
u_err : entity work.interactive_flag
    generic map (NAME => "led_err", WIDTH => 1) port map (value => error);
```

Set `INTERACTIVE_STREAM=host:port` for the simulation. If it is unset or the
connect fails, the simulation still runs: flags are dropped and controls read
their default (0).

## Prebuilt libraries

Each tagged release publishes a per-platform archive of the **portable,
self-contained backend libraries** — no build step, no simulator headers needed
to consume them. Download the bundle for your platform from the
[Releases](../../releases) page and point your simulator at it:

```
interactive-sim-<ver>-<platform>/
  interactive_dpi.<so|dylib|dll>     DPI-C library  (Verilator / Questa / Vivado XSim)
  interactive_vhpi.<so|dylib|dll>    VHPIDIRECT library (NVC; GHDL experimental)
  interactive.vpi                    VPI module (Icarus)         [not in the MSVC bundle]
  interactive_ctrl.{sv,v,vhdl}       per-component HDL shims
  interactive_flag.{sv,v,vhdl}
  interactive_pkg.vhdl               VHDL foreign bindings
  interactive_pkg_mcode.vhdl         GHDL-mcode variant (names the library to load)
  libinteractive_*.dll.a             import libraries        [MinGW bundle only]
```

Platforms: `linux-x86_64`, `linux-arm64`, `macos-arm64`, `macos-x86_64`,
`windows-x86_64` (MSVC ABI), `windows-x86_64-mingw` (MinGW ABI). Build them
yourself with `make dist && make dist-vpi` (output in `build/dist/`).

## CI / tests

`make e2e` runs the end-to-end test from source for every installed simulator;
`make e2e-dist DIST=build/dist` runs the same checks against the **prebuilt**
libraries. Each demo connects over TCP to a listener and the test asserts the
protocol handshake (every component announces itself; the heartbeat flag streams
values). CI (`.github/workflows/`) gates **DPI (Verilator), VPI (Icarus), and
VHPIDIRECT (NVC)** on every push and PR across Linux x86_64/arm64, macOS, and
Windows — from source and against the prebuilt artifacts — and gates each `v*`
tag on the same checks before publishing the release archives.

## Layout

```
backend/interactive.cpp      shared core: socket, reader thread, protocol, registry
sv/interactive_ctrl.sv       DPI-C viewer-driven input   (Verilator/Questa/...)
sv/interactive_flag.sv       DPI-C design-driven output
v/interactive_ctrl.v         VPI viewer-driven input     (Icarus)
v/interactive_flag.v         VPI design-driven output
v/interactive_vpi.cpp        VPI shim
vhdl/interactive_ctrl.vhdl   VHPIDIRECT viewer-driven input (GHDL/NVC)
vhdl/interactive_flag.vhdl   VHPIDIRECT design-driven output
vhdl/interactive_pkg.vhdl    foreign bindings
vhdl/interactive_vhpi.cpp    VHPIDIRECT shim
viewer/interactive_viewer.py reference terminal viewer
examples/tb_demo.{v,sv,vhdl} per-flow demo testbenches
tests/e2e.py                 end-to-end protocol test (source + prebuilt artifacts)
ci/package-release.sh        pack per-platform release archives (CI, v* tags)
.github/workflows/           CI + multi-platform artifact build + release
ulx3s_demo/                  standalone graphical ULX3S board demo (own README + Makefile)
```

## Status

DPI/Verilator, VPI/Icarus, and VHPIDIRECT/NVC are exercised end-to-end in CI from
source and against the prebuilt artifacts, on Linux (x86_64/arm64), macOS, and
Windows.

**GHDL/VHPIDIRECT is experimental** and not yet gated. The VHPIDIRECT shim passes
each component's `NAME` as an `in string` to a foreign procedure with an `out
integer` handle; NVC marshals this per the documented convention (pointer to the
first character), but recent GHDL emits "NOT IMPLEMENTED" for it, so the name does
not pass through. NVC drives the identical VHDL + shim, so the VHPIDIRECT path
itself is covered — see the comments in `vhdl/interactive_pkg.vhdl`.
