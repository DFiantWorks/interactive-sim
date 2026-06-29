# ULX3S GUI demo for interactive-sim.
#
# The simulation half of a graphical ULX3S board demo: a photo of the board where
# you click the buttons and watch the 8 user LEDs light up at their position. This
# folder holds only the demo *design* (tb_ulx3s.v) plus a wall-clock pacing VPI
# helper (realtime_vpi.cpp); it reuses the framework's VPI shim + backend from ../
#
# The graphical panel is the standalone viewer fpga-isv, which ships the ULX3S
# board as a bundled example (see https://github.com/DFiantWorks/interactive-sim-viewer
# for install). Start the GUI first (it listens), then run the simulation (it connects):
#   make viewer                  # 1) the fpga-isv GUI window, ULX3S example
#   make demo                    # 2) the simulation, paced to the wall clock
#   make clean

ROOT    := ..
BACKEND := $(ROOT)/backend/interactive.cpp
BUILD   := build
HOST    ?= 127.0.0.1
PORT    ?= 7777
STREAM  ?= $(HOST):$(PORT)

# C++ compiler for the VPI modules. On Windows, oss-cad-suite's libvpi.a is built
# with MinGW-w64, so it MUST be linked with a MinGW-w64 g++ -- the MSYS/Cygwin gcc
# fails with `undefined reference to __imp__assert`. make's built-in default (g++)
# resolves to that wrong gcc in an MSYS shell, so auto-pick a MinGW-w64 g++ here.
# Override anytime with CXX=...
ifeq ($(origin CXX),default)
  CXX := $(shell command -v x86_64-w64-mingw32-g++ 2>/dev/null \
            || ([ -x /mingw64/bin/g++ ]            && echo /mingw64/bin/g++) \
            || ([ -x /c/msys64/mingw64/bin/g++ ]   && echo /c/msys64/mingw64/bin/g++) \
            || command -v c++ 2>/dev/null \
            || echo g++)
endif
# A path-qualified MinGW-w64 g++ needs its own bin dir on PATH so its cc1plus can
# load its DLLs. Scope that to the compiler command only.
ifneq (,$(findstring /,$(CXX)))
  CXXENV := PATH="$(dir $(CXX)):$$PATH"
endif

IVL_INC := $(shell dirname $(shell command -v iverilog))/../include/iverilog
UNAME_S := $(shell uname -s)
ifneq (,$(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)))
  VPI_LINK := -shared -static $(dir $(IVL_INC))../lib/libvpi.a -lws2_32
else
  VPI_LINK := -shared -pthread
endif

.PHONY: viewer demo clean

# ---- Graphical board viewer (fpga-isv, ULX3S example) ----------------------
# fpga-isv is the standalone interactive-sim panel viewer; install it from
# https://github.com/DFiantWorks/interactive-sim-viewer (pipx install fpga-isv,
# Homebrew, or a prebuilt binary). The ULX3S board ships as a bundled example.
viewer:
	fpga-isv --example ulx3s --host 0.0.0.0 --port $(PORT)

# ---- ULX3S design / Icarus, paced to the wall clock for live animation -----
# Builds the framework `interactive` VPI module (from ../) AND a demo-only
# `realtime` VPI module that throttles the sim to real time, then loads both.
demo:
	mkdir -p $(BUILD)
	$(CXXENV) $(CXX) -O2 -fPIC -I$(IVL_INC) $(ROOT)/v/interactive_vpi.cpp $(BACKEND) $(VPI_LINK) \
		-o $(BUILD)/interactive.vpi
	$(CXXENV) $(CXX) -O2 -fPIC -I$(IVL_INC) realtime_vpi.cpp $(VPI_LINK) \
		-o $(BUILD)/realtime.vpi
	iverilog -g2012 -o $(BUILD)/tb_ulx3s.vvp -s tb_ulx3s \
		tb_ulx3s.v $(ROOT)/v/interactive_ctrl.v $(ROOT)/v/interactive_flag.v
	INTERACTIVE_STREAM=$(STREAM) \
		vvp -M$(BUILD) -m interactive -m realtime $(BUILD)/tb_ulx3s.vvp

clean:
	rm -rf $(BUILD) __pycache__
