#!/usr/bin/env python3
"""interactive_viewer.py -- a minimal terminal viewer for interactive-sim.

It LISTENS on a TCP port; the simulation connects to it (set
INTERACTIVE_STREAM=host:port for the sim). Once connected it:

  * reads newline-delimited JSON from the sim and prints each event:
      reg   -- a component announced itself (name, kind, width)
      flag  -- a design-driven output changed value
      close -- a component went away
  * lets you drive controls by typing  NAME=VALUE  at the prompt, e.g.
      btn_run=1
    which sends {"name":"btn_run","val":1} back to the sim. The control's
    interactive_ctrl instance picks it up on its next poll tick.

Type 'q' (or Ctrl-D) to quit. This is a reference viewer -- the wire protocol is
plain JSON lines, so a real GUI can speak it just as easily.

Usage:
  python3 interactive_viewer.py [--port 7777] [--host 0.0.0.0]
"""

import argparse
import json
import socket
import sys
import threading
import time

# Heartbeats per sim/wall speed sample: measure the ratio over the span from a
# window's first heartbeat to its last, which averages out wall-clock jitter.
RATE_WINDOW = 100


def reader(conn, registry):
    """Print every inbound event line from the simulation."""
    buf = b""
    hb_anchor = None           # (sim us, wall s) of the window's first heartbeat
    hb_count = 0
    rate = None                # sim/wall ratio over the last full window
    while True:
        try:
            chunk = conn.recv(4096)
        except OSError:
            break
        if not chunk:
            break
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.strip():
                continue
            rx = time.monotonic()             # wall-clock arrival of this message
            try:
                msg = json.loads(line.decode("utf-8", "replace"))
            except json.JSONDecodeError:
                print(f"\r[?] {line!r}")
                continue
            ev = msg.get("ev")
            name = msg.get("name", "?")
            t = msg.get("t", 0.0)
            # Sim/wall speed, measured over a window of heartbeats: the ratio is
            # the sim-time span divided by the wall-clock span from the window's
            # first heartbeat to its last (RATE_WINDOW apart). Averaging over the
            # span -- not adjacent beats -- smooths out wall-clock jitter.
            if ev == "time":
                if hb_anchor is None:
                    hb_anchor, hb_count = (t, rx), 0
                else:
                    hb_count += 1
                    if hb_count >= RATE_WINDOW - 1:
                        dsim, dwall = (t - hb_anchor[0]) / 1e6, rx - hb_anchor[1]
                        if dsim > 0 and dwall > 0:
                            rate = dsim / dwall
                        hb_anchor, hb_count = (t, rx), 0
            rate_s = f" {rate:.1f}x" if rate is not None else ""
            prompt = f"\r[t={t:10.3f}us{rate_s}] > "   # every message carries the sim time
            if ev == "time":
                # Heartbeat: refresh the clock on the prompt in place, no scroll.
                sys.stdout.write(prompt)
                sys.stdout.flush()
                continue
            if ev == "reg":
                registry[name] = msg
                print(f"\r[reg]   {name:<16} kind={msg.get('kind')} "
                      f"width={msg.get('width')}")
            elif ev == "flag":
                w = registry.get(name, {}).get("width", 1)
                val = msg.get("val", 0)
                print(f"\r[flag]  {name:<16} = {val}  (0x{val & ((1 << w) - 1):x}) "
                      f"@ {t:.3f} us")
            elif ev == "close":
                print(f"\r[close] {name}")
            else:
                print(f"\r[?] {msg}")
            sys.stdout.write(prompt)
            sys.stdout.flush()
    print("\r[viewer] simulation disconnected")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=7777)
    args = ap.parse_args()

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((args.host, args.port))
    srv.listen(1)
    print(f"[viewer] listening on {args.host}:{args.port} "
          f"(set INTERACTIVE_STREAM={args.host}:{args.port} for the sim)")

    conn, peer = srv.accept()
    print(f"[viewer] simulation connected from {peer[0]}:{peer[1]}")

    registry = {}
    threading.Thread(target=reader, args=(conn, registry), daemon=True).start()

    print("Type  NAME=VALUE  to set a control (e.g. btn_run=1).  'q' to quit.")
    try:
        for raw in sys.stdin:
            line = raw.strip()
            if line in ("q", "quit", "exit"):
                break
            if "=" not in line:
                if line:
                    print(f"  ? expected NAME=VALUE, got: {line}")
                continue
            name, _, valstr = line.partition("=")
            name = name.strip()
            try:
                val = int(valstr.strip(), 0)   # accepts 1, 0x0f, 0b101
            except ValueError:
                print(f"  ? not an integer: {valstr!r}")
                continue
            msg = json.dumps({"name": name, "val": val}) + "\n"
            try:
                conn.sendall(msg.encode("utf-8"))
            except OSError:
                print("[viewer] send failed -- sim gone")
                break
    except (EOFError, KeyboardInterrupt):
        pass
    finally:
        conn.close()
        srv.close()
        print("\n[viewer] bye")


if __name__ == "__main__":
    main()
