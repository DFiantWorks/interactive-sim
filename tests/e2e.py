#!/usr/bin/env python3
# e2e.py -- end-to-end test of the interactive-sim wire protocol.
#
# For each foreign interface this:
#   1. starts a listener on a TCP port (standing in for a viewer),
#   2. builds + runs the demo (make demo-<sim>) which connects to the listener
#      and streams newline-delimited JSON events,
#   3. asserts the protocol handshake: every component announced itself (`reg`)
#      and at least one design-driven value was pushed (`flag`).
#
# This exercises the real path -- simulator -> socket -> viewer -- across every
# foreign interface, rather than a bespoke reader. The fixture is examples/
# tb_demo.* : it registers the controls btn_run (ctrl) and the flags led_count +
# led_hb, and the free-running led_hb heartbeat guarantees flag traffic without
# any viewer input.
#
# Simulators (each maps to one `make` target):
#   dpi   -> Verilator (SystemVerilog / DPI-C)
#   vhpi  -> GHDL gcc/llvm (VHDL / VHPIDIRECT, library linked at elaboration)
#   mcode -> GHDL mcode    (VHDL / VHPIDIRECT, library loaded via _mcode wrapper;
#                           --dist only, since it loads the prebuilt library)
#   nvc   -> NVC       (VHDL / VHPIDIRECT)
#   vpi   -> Icarus    (Verilog / VPI)
# A simulator whose tool is not installed is SKIPPED, so the same run works on
# Linux/macOS/Windows, each with a different subset of FOSS simulators.
#
#   python3 tests/e2e.py                  # build from source, all sims
#   python3 tests/e2e.py --sim dpi,vpi    # a subset
#   python3 tests/e2e.py --dist build/dist
#       # link/load the PREBUILT artifacts in that dir instead of recompiling the
#       # backend -- i.e. test exactly what `make dist` / CI ship.

import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Components registered by examples/tb_demo.* (must all announce themselves).
EXPECT_REG = {"btn_run", "led_count", "led_hb"}

# sim -> (executables that must be on PATH, TCP port). Distinct ports so a
# leftover socket from one sim can't be mistaken for the next.
SIMS = {
    "dpi":   (["verilator"],       7740),
    "vhpi":  (["ghdl"],            7741),
    "vpi":   (["iverilog", "vvp"], 7742),
    "nvc":   (["nvc"],             7743),
    "mcode": (["ghdl"],            7744),
}


def which(name):
    if shutil.which(name):
        return True
    # MSYS2/MinGW ships extensionless wrapper scripts (e.g. `verilator`) that
    # Windows' PATHEXT-based shutil.which misses, even though the simulators run
    # them fine via make's shell. Scan PATH for the bare name too.
    for d in os.environ.get("PATH", "").split(os.pathsep):
        if d and os.path.isfile(os.path.join(d, name)):
            return True
    return False


def have(tools):
    return all(which(t) for t in tools)


def run_one(sim, dist, build_timeout, read_timeout):
    tools, port = SIMS[sim]
    target = f"demo-{sim}" + ("-dist" if dist else "")

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(1)
    srv.settimeout(build_timeout)             # build can be slow (Verilator)

    args = ["make", target, f"STREAM=127.0.0.1:{port}"]
    env = os.environ.copy()
    if dist:
        dabs = str(Path(dist).resolve())
        args.append(f"DIST={dist}")
        # mcode/nvc load the library by name at run time -> put DIST on the
        # OS loader path (rpath covers the linked DPI/VHPI flows).
        for var in ("PATH", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"):
            env[var] = dabs + os.pathsep + env.get(var, "")

    proc = subprocess.Popen(args, cwd=ROOT, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def fail(msg):
        try:
            proc.kill()
        except OSError:
            pass
        out = ""
        try:
            out = proc.communicate(timeout=10)[0] or ""
        except Exception:
            pass
        srv.close()
        print(f"  FAIL [{sim}] {msg}")
        tail = "\n".join(out.splitlines()[-25:])
        if tail:
            print("    --- make output (tail) ---")
            print("\n".join("    " + ln for ln in tail.splitlines()))
        return False

    try:
        conn, _ = srv.accept()
    except socket.timeout:
        return fail("simulation never connected to the viewer socket")

    regs, flags = set(), 0
    conn.settimeout(read_timeout)
    buf = b""
    deadline = time.time() + read_timeout
    try:
        while time.time() < deadline:
            try:
                chunk = conn.recv(4096)
            except OSError:
                # socket.timeout, or a connection reset on sim exit (Windows
                # sends RST rather than a clean FIN) -- end of stream either way.
                break
            if not chunk:
                break                          # sim closed the link (clean exit)
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line.decode("utf-8", "replace"))
                except json.JSONDecodeError:
                    continue
                if msg.get("ev") == "reg":
                    regs.add(msg.get("name"))
                elif msg.get("ev") == "flag":
                    flags += 1
    finally:
        conn.close()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
    srv.close()

    missing = EXPECT_REG - regs
    if missing:
        print(f"  FAIL [{sim}] missing reg events for {sorted(missing)} "
              f"(got {sorted(regs)})")
        return False
    if flags == 0:
        print(f"  FAIL [{sim}] no flag events received (expected led_hb traffic)")
        return False
    print(f"  PASS [{sim}] reg={len(regs)} ({', '.join(sorted(regs))})  flags={flags}")
    return True


def main():
    ap = argparse.ArgumentParser(description="interactive-sim end-to-end test.")
    ap.add_argument("--sim", default="all",
                    help="comma-separated subset of: " + ", ".join(SIMS) + ", or 'all'")
    ap.add_argument("--dist", default=None,
                    help="test the PREBUILT artifacts in this dir (demo-*-dist)")
    ap.add_argument("--build-timeout", type=int, default=120)
    ap.add_argument("--read-timeout", type=int, default=30)
    args = ap.parse_args()

    if args.sim == "all":
        sims = list(SIMS)
    else:
        sims = [s.strip() for s in args.sim.split(",") if s.strip()]
        unknown = [s for s in sims if s not in SIMS]
        if unknown:
            sys.exit(f"unknown sim(s): {unknown}; choose from {list(SIMS)}")

    # mcode loads a prebuilt library by name -> it only exists in --dist mode.
    if not args.dist and "mcode" in sims:
        if args.sim == "all":
            sims.remove("mcode")
        else:
            sys.exit("mcode is --dist only (it loads the prebuilt VHPI library)")

    mode = f"PREBUILT artifacts in {args.dist}" if args.dist else "from source"
    print(f"interactive-sim e2e ({mode})")

    ran = failed = 0
    for sim in sims:
        if not have(SIMS[sim][0]):
            print(f"  SKIP [{sim}] missing tool(s): {', '.join(SIMS[sim][0])}")
            continue
        ran += 1
        if not run_one(sim, args.dist, args.build_timeout, args.read_timeout):
            failed += 1

    if ran == 0:
        sys.exit("no simulators available to test")
    print(f"\n{ran - failed}/{ran} passed"
          + (f", {failed} FAILED" if failed else ""))
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
