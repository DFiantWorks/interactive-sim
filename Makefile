# interactive-sim -- viewer-driven controls + design-driven flags, placed
# anywhere in a design and funnelled to ONE viewer over ONE socket.
#
# The same C++ backend (backend/interactive.cpp) is reached by three thin shims:
# DPI (sv/), VPI (v/), VHPIDIRECT (vhdl/). Start the viewer first (it listens),
# then run a demo (the sim connects as a client):
#
#   make viewer                       # terminal viewer, listens on PORT
#   make demo-vpi                     # Icarus  : button gates a counter -> flags
#   make demo-dpi                     # Verilator (needs --timing)
#   make demo-vhpi    / make demo-nvc # GHDL / NVC
#   make dist && make dist-vpi        # portable backend libraries + VPI module
#   make e2e          / make e2e-dist # end-to-end test (source / PREBUILT libs)
#   make clean

BACKEND := backend/interactive.cpp
BUILD   := build
HOST    ?= 127.0.0.1
PORT    ?= 7777
STREAM  ?= $(HOST):$(PORT)
SIM     ?= all
# C++ compiler for the backend/shims. On Windows, oss-cad-suite's libvpi.a is
# built with MinGW-w64, so it MUST be linked with a MinGW-w64 g++ -- the
# MSYS/Cygwin gcc (x86_64-pc-msys) fails with `undefined reference to
# __imp__assert`. make's built-in default (g++) resolves to that wrong gcc in an
# MSYS shell, so auto-pick a MinGW-w64 g++ here. Override anytime with CXX=...
ifeq ($(origin CXX),default)
  CXX := $(shell command -v x86_64-w64-mingw32-g++ 2>/dev/null \
            || ([ -x /mingw64/bin/g++ ]            && echo /mingw64/bin/g++) \
            || ([ -x /c/msys64/mingw64/bin/g++ ]   && echo /c/msys64/mingw64/bin/g++) \
            || command -v c++ 2>/dev/null \
            || echo g++)
endif
# A path-qualified MinGW-w64 g++ needs its own bin dir on PATH so its cc1plus can
# load its DLLs (otherwise it fails silently with no diagnostic). Scope that to
# the compiler command only -- prepending it globally would let MinGW's bundled
# (older) iverilog/vvp shadow oss-cad-suite's. Empty for a bare-name compiler.
ifneq (,$(findstring /,$(CXX)))
  CXXENV := PATH="$(dir $(CXX)):$$PATH"
endif
DIST    ?= $(BUILD)/dist
PYTHON  ?= python3        # GUI viewers need a Python with tkinter (use PYTHON=python on Windows)

.PHONY: viewer lint-dpi demo-dpi demo-vpi demo-vhpi demo-nvc \
        demo-dpi-dist demo-vhpi-dist demo-nvc-dist demo-vpi-dist demo-mcode-dist \
        dist dist-vpi e2e e2e-dist clean

# ---- Reference viewer ------------------------------------------------------
viewer:
	$(PYTHON) viewer/interactive_viewer.py --host 0.0.0.0 --port $(PORT)

# ---- DPI / Verilator (built WITH --timing for the ctrl #-delays) -----------
lint-dpi:
	verilator --lint-only -Wno-WIDTH --timing --top-module tb_demo \
		examples/tb_demo.sv sv/interactive_ctrl.sv sv/interactive_flag.sv

demo-dpi:
	mkdir -p $(BUILD)/demo-dpi
	verilator --cc --exe --build -j 0 -Wno-WIDTH --timing --timescale 1ns/1ps \
		--top-module tb_demo --Mdir $(BUILD)/demo-dpi -o tb_demo \
		--main examples/tb_demo.sv sv/interactive_ctrl.sv sv/interactive_flag.sv $(abspath $(BACKEND)) \
		-LDFLAGS "-pthread"
	INTERACTIVE_STREAM=$(STREAM) ./$(BUILD)/demo-dpi/tb_demo

# ---- VPI / Icarus ----------------------------------------------------------
IVL_INC := $(shell dirname $(shell command -v iverilog))/../include/iverilog
UNAME_S := $(shell uname -s)
ifneq (,$(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)))
  VPI_LINK := -shared -static $(dir $(IVL_INC))../lib/libvpi.a -lws2_32
else
  VPI_LINK := -shared -pthread
endif

demo-vpi:
	mkdir -p $(BUILD)/demo-vpi
	$(CXXENV) $(CXX) -O2 -fPIC -I$(IVL_INC) v/interactive_vpi.cpp $(BACKEND) $(VPI_LINK) \
		-o $(BUILD)/demo-vpi/interactive.vpi
	iverilog -g2012 -o $(BUILD)/demo-vpi/tb_demo.vvp -s tb_demo \
		examples/tb_demo.v v/interactive_ctrl.v v/interactive_flag.v
	INTERACTIVE_STREAM=$(STREAM) \
		vvp -M$(BUILD)/demo-vpi -m interactive $(BUILD)/demo-vpi/tb_demo.vvp

# ---- VHPIDIRECT / GHDL -----------------------------------------------------
GHDL ?= ghdl
$(BUILD)/demo-vhpi/backend.o: $(BACKEND)
	mkdir -p $(BUILD)/demo-vhpi
	$(CXXENV) $(CXX) -O2 -fPIC -c $(BACKEND) -o $@
$(BUILD)/demo-vhpi/vhpi.o: vhdl/interactive_vhpi.cpp
	mkdir -p $(BUILD)/demo-vhpi
	$(CXXENV) $(CXX) -O2 -fPIC -c $< -o $@

demo-vhpi: $(BUILD)/demo-vhpi/backend.o $(BUILD)/demo-vhpi/vhpi.o
	$(GHDL) -a --std=08 --workdir=$(BUILD)/demo-vhpi \
		vhdl/interactive_pkg.vhdl vhdl/interactive_ctrl.vhdl vhdl/interactive_flag.vhdl examples/tb_demo.vhdl
	$(GHDL) -e --std=08 --workdir=$(BUILD)/demo-vhpi -o $(BUILD)/demo-vhpi/tb_demo \
		-Wl,$(BUILD)/demo-vhpi/backend.o -Wl,$(BUILD)/demo-vhpi/vhpi.o \
		-Wl,-lstdc++ -Wl,-pthread tb_demo
	INTERACTIVE_STREAM=$(STREAM) ./$(BUILD)/demo-vhpi/tb_demo --stop-time=5ms

# ---- VHPIDIRECT / NVC ------------------------------------------------------
demo-nvc:
	mkdir -p $(BUILD)/demo-nvc
	$(CXXENV) $(CXX) -O2 -fPIC -shared $(BACKEND) vhdl/interactive_vhpi.cpp -lstdc++ -pthread \
		-o $(BUILD)/demo-nvc/libinteractive_vhpi.so
	nvc --std=2008 --work=$(BUILD)/demo-nvc/work -a \
		vhdl/interactive_pkg.vhdl vhdl/interactive_ctrl.vhdl vhdl/interactive_flag.vhdl examples/tb_demo.vhdl
	nvc --std=2008 --work=$(BUILD)/demo-nvc/work -e tb_demo
	INTERACTIVE_STREAM=$(STREAM) \
		nvc --std=2008 --work=$(BUILD)/demo-nvc/work -r tb_demo \
		--load $(BUILD)/demo-nvc/libinteractive_vhpi.so --stop-time=5ms

# ---- Portable, self-contained backend libraries ----------------------------
# No simulator dependency. A DPI simulator loads libinteractive_dpi alongside
# sv/interactive_ctrl.sv sv/interactive_flag.sv; GHDL/NVC load libinteractive_vhpi. libstdc++/libgcc are
# folded in for portability. Output: $(DIST)/
#
# Also emits interactive_pkg_mcode.vhdl: the canonical package leaves the library
# implicit (gcc/llvm GHDL + NVC link/load it), but mcode-backend GHDL has no link
# step, so this drop-in variant names $(VHPI_LIB) in each `foreign` string.
ifeq ($(UNAME_S),Darwin)
  LIBPRE     := lib
  LIBEXT     := dylib
  DIST_FLAGS := -dynamiclib
  DIST_LIBS  :=
else ifneq (,$(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)))
  LIBPRE     :=
  LIBEXT     := dll
  DIST_FLAGS := -shared -static
  DIST_LIBS  := -lws2_32
else
  LIBPRE     := lib
  LIBEXT     := so
  DIST_FLAGS := -shared -static-libstdc++ -static-libgcc
  DIST_LIBS  := -pthread
endif
DPI_LIB  := $(LIBPRE)interactive_dpi.$(LIBEXT)
VHPI_LIB := $(LIBPRE)interactive_vhpi.$(LIBEXT)
DIST_ABS := $(abspath $(DIST))
RPATH    := -Wl,-rpath,$(DIST_ABS)
ifeq ($(UNAME_S),Darwin)
  # Make the dylibs relocatable so consumers can find them via -rpath.
  INST_DPI  := -Wl,-install_name,@rpath/$(DPI_LIB)
  INST_VHPI := -Wl,-install_name,@rpath/$(VHPI_LIB)
endif

dist:
	mkdir -p $(DIST)
	$(CXXENV) $(CXX) -O2 -fPIC $(DIST_FLAGS) $(INST_DPI)  $(BACKEND) $(DIST_LIBS) -o $(DIST)/$(DPI_LIB)
	$(CXXENV) $(CXX) -O2 -fPIC $(DIST_FLAGS) $(INST_VHPI) $(BACKEND) vhdl/interactive_vhpi.cpp $(DIST_LIBS) -o $(DIST)/$(VHPI_LIB)
	cp sv/interactive_ctrl.sv sv/interactive_flag.sv \
	   v/interactive_ctrl.v v/interactive_flag.v \
	   vhdl/interactive_ctrl.vhdl vhdl/interactive_flag.vhdl vhdl/interactive_pkg.vhdl $(DIST)/
	sed -E 's/(is "VHPIDIRECT) (vhpi_[a-z_]+")/\1 $(VHPI_LIB) \2/' \
		vhdl/interactive_pkg.vhdl > $(DIST)/interactive_pkg_mcode.vhdl
	@echo "built $(DIST)/$(DPI_LIB) and $(DIST)/$(VHPI_LIB)"

# Icarus VPI module -- needs iverilog's headers, so it's split from `dist`.
# macOS resolves vpi_* via dynamic lookup at load; Windows/MinGW links the VPI
# import library + winsock and folds in the runtime; Linux is a plain -shared.
ifeq ($(UNAME_S),Darwin)
  VPI_DIST_LINK := -bundle -undefined dynamic_lookup
else ifneq (,$(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)))
  VPI_DIST_LINK := $(VPI_LINK)
else
  VPI_DIST_LINK := -shared
endif

dist-vpi:
	mkdir -p $(DIST)
	$(CXXENV) $(CXX) -O2 -fPIC -I$(IVL_INC) v/interactive_vpi.cpp $(BACKEND) \
		$(VPI_DIST_LINK) -o $(DIST)/interactive.vpi

# ---- Artifact demos: drive tb_demo against the PREBUILT libs in $(DIST) -----
# Same fixture as the demo-* targets, but the backend is NOT recompiled -- each
# simulator links/loads the already-built artifact (as a downstream user would).
# tests/e2e.py --dist calls these per simulator.
demo-dpi-dist:
	mkdir -p $(BUILD)/demo-dpi-dist
	verilator --cc --exe --build -j 0 -Wno-WIDTH --timing --timescale 1ns/1ps \
		--top-module tb_demo --Mdir $(BUILD)/demo-dpi-dist -o tb_demo \
		--main examples/tb_demo.sv sv/interactive_ctrl.sv sv/interactive_flag.sv \
		-LDFLAGS "-L$(DIST_ABS) -linteractive_dpi $(RPATH) -pthread"
	INTERACTIVE_STREAM=$(STREAM) ./$(BUILD)/demo-dpi-dist/tb_demo

demo-vhpi-dist:
	mkdir -p $(BUILD)/demo-vhpi-dist
	$(GHDL) -a --std=08 --workdir=$(BUILD)/demo-vhpi-dist \
		vhdl/interactive_pkg.vhdl vhdl/interactive_ctrl.vhdl vhdl/interactive_flag.vhdl examples/tb_demo.vhdl
	$(GHDL) -e --std=08 --workdir=$(BUILD)/demo-vhpi-dist -o $(BUILD)/demo-vhpi-dist/tb_demo \
		-Wl,-L$(DIST_ABS) -Wl,-linteractive_vhpi -Wl,-Wl,-rpath,$(DIST_ABS) tb_demo
	INTERACTIVE_STREAM=$(STREAM) ./$(BUILD)/demo-vhpi-dist/tb_demo --stop-time=5ms

# mcode-backend GHDL: no link step, so it LOADS the prebuilt VHPI library named
# in the generated _mcode wrapper's `foreign` strings. The library must be on the
# OS loader path -- the e2e harness adds $(DIST) to PATH/LD_LIBRARY_PATH.
demo-mcode-dist:
	mkdir -p $(BUILD)/demo-mcode-dist
	$(GHDL) -a --std=08 --workdir=$(BUILD)/demo-mcode-dist \
		$(DIST)/interactive_pkg_mcode.vhdl vhdl/interactive_ctrl.vhdl vhdl/interactive_flag.vhdl examples/tb_demo.vhdl
	INTERACTIVE_STREAM=$(STREAM) $(GHDL) --elab-run --std=08 \
		--workdir=$(BUILD)/demo-mcode-dist tb_demo --stop-time=5ms

demo-nvc-dist:
	mkdir -p $(BUILD)/demo-nvc-dist
	nvc --std=2008 --work=$(BUILD)/demo-nvc-dist/work -a \
		vhdl/interactive_pkg.vhdl vhdl/interactive_ctrl.vhdl vhdl/interactive_flag.vhdl examples/tb_demo.vhdl
	nvc --std=2008 --work=$(BUILD)/demo-nvc-dist/work -e tb_demo
	INTERACTIVE_STREAM=$(STREAM) \
		nvc --std=2008 --work=$(BUILD)/demo-nvc-dist/work -r tb_demo \
		--load $(DIST_ABS)/$(VHPI_LIB) --stop-time=5ms

demo-vpi-dist:
	mkdir -p $(BUILD)/demo-vpi-dist
	iverilog -g2012 -o $(BUILD)/demo-vpi-dist/tb_demo.vvp -s tb_demo \
		examples/tb_demo.v v/interactive_ctrl.v v/interactive_flag.v
	INTERACTIVE_STREAM=$(STREAM) \
		vvp -M$(DIST_ABS) -m interactive $(BUILD)/demo-vpi-dist/tb_demo.vvp

# ---- End-to-end test: sim -> socket -> viewer (tests/e2e.py) ----------------
# e2e builds each sim from source; e2e-dist drives the PREBUILT artifacts in
# $(DIST). Both skip simulators whose tool isn't installed.  SIM=dpi|vhpi|nvc|vpi
e2e:
	$(PYTHON) tests/e2e.py --sim $(SIM)

e2e-dist:
	$(PYTHON) tests/e2e.py --sim $(SIM) --dist $(DIST)

clean:
	rm -rf $(BUILD) obj_dir
