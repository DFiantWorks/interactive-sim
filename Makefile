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
# The verilator command. Override to `verilator_bin` (with VERILATOR_ROOT set)
# when the perl `verilator` wrapper isn't usable -- e.g. oss-cad-suite's wrapper
# needs Pod::Usage, absent in some MSYS2/CI perls; verilator_bin needs neither.
VERILATOR ?= verilator

.PHONY: viewer lint-dpi demo-dpi demo-vpi demo-vhpi demo-nvc \
        demo-dpi-dist demo-vhpi-dist demo-nvc-dist demo-vpi-dist demo-mcode-dist \
        dist dist-vpi dist-xsim e2e e2e-dist clean

# ---- Reference viewer ------------------------------------------------------
viewer:
	$(PYTHON) viewer/interactive_viewer.py --host 0.0.0.0 --port $(PORT)

# ---- DPI / Verilator (built WITH --timing for the ctrl #-delays) -----------
lint-dpi:
	$(VERILATOR) --lint-only -Wno-WIDTH --timing --top-module tb_demo \
		examples/tb_demo.sv sv/interactive_ctrl.sv sv/interactive_flag.sv

demo-dpi:
	mkdir -p $(BUILD)/demo-dpi
	$(VERILATOR) --cc --exe --build -j 0 -Wno-WIDTH --timing --timescale 1ns/1ps \
		--top-module tb_demo --Mdir $(BUILD)/demo-dpi -o tb_demo \
		--main examples/tb_demo.sv sv/interactive_ctrl.sv sv/interactive_flag.sv $(abspath $(BACKEND)) \
		$(VERILATED_OPT) -LDFLAGS "-pthread $(SOCK_LIB) $(STATIC_CXX)"
	INTERACTIVE_STREAM=$(STREAM) ./$(BUILD)/demo-dpi/tb_demo

# ---- VPI / Icarus ----------------------------------------------------------
IVL_INC := $(shell dirname $(shell command -v iverilog))/../include/iverilog
UNAME_S := $(shell uname -s)
# Sockets: Winsock on Windows (the #pragma comment(lib) in the source is MSVC-only,
# so MinGW must link -lws2_32 explicitly); in libc on Linux/macOS.
ifneq (,$(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)))
  SOCK_LIB := -lws2_32
  # Statically fold libstdc++/libgcc into the Verilator exe on MinGW, so it does
  # not depend on libstdc++-6.dll being on PATH at run time. Harmless across the
  # DPI boundary -- it is extern "C", so no C++ objects cross between the exe and
  # interactive_dpi.dll.
  STATIC_CXX := -static-libstdc++ -static-libgcc
  # Build the Verilator runtime at -O2, not Verilator's default -Os, on MinGW. The
  # rolling MSYS2 gcc 16 makes std::string's move ctor inline-only (no out-of-line
  # definition in its libstdc++ DLL or static .a), yet at -Os it declines to inline
  # it at some call sites in verilated.cpp and emits an out-of-line *call* -- which
  # then has nothing to resolve to (`undefined reference to ...
  # basic_string(basic_string&&)`). -O2 inlines it, so no external reference is
  # emitted. Passed via -CFLAGS, which lands last in CPPFLAGS and so overrides the
  # earlier OPT_GLOBAL/OPT_FAST=-Os on every runtime + model object.
  VERILATED_OPT := -CFLAGS -O2
  # The native MinGW-w64 g++ needs a Windows-style TMP. make's recipe shell
  # (sh.exe) leaves TMP/TEMP as a POSIX path (/tmp) or empty -- neither of which
  # the native compiler can resolve, so it falls back to the unwritable C:\WINDOWS
  # ("cannot create temporary file" -- breaks `dist` and the -shared/-static
  # links). Point both at build/ in Windows form, computed once here; every CXXENV
  # recipe creates build/ before it compiles. Skipped if cygpath isn't available.
  WINTMP := $(shell cygpath -w "$(abspath $(BUILD))" 2>/dev/null)
  ifneq (,$(WINTMP))
    CXXENV += TMP="$(WINTMP)" TEMP="$(WINTMP)"
  endif
else
  SOCK_LIB :=
  STATIC_CXX :=
  VERILATED_OPT :=
endif
# VPI module link: macOS resolves vpi_* via dynamic lookup at load; Windows/MinGW
# links the VPI import library + winsock and folds in the runtime; Linux is a
# plain -shared. The same recipe builds the demo module and the dist module.
ifeq ($(UNAME_S),Darwin)
  VPI_LINK := -bundle -undefined dynamic_lookup
else ifneq (,$(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)))
  VPI_LINK := -shared -static $(dir $(IVL_INC))../lib/libvpi.a -lws2_32
else
  VPI_LINK := -shared
endif
VPI_BUILD = $(CXXENV) $(CXX) -O2 -fPIC -I$(IVL_INC) v/interactive_vpi.cpp $(BACKEND) $(VPI_LINK)

demo-vpi:
	mkdir -p $(BUILD)/demo-vpi
	$(VPI_BUILD) -o $(BUILD)/demo-vpi/interactive.vpi
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
		-Wl,-lstdc++ -Wl,-pthread $(SOCK_LIB:%=-Wl,%) tb_demo
	INTERACTIVE_STREAM=$(STREAM) ./$(BUILD)/demo-vhpi/tb_demo --stop-time=5ms

# ---- VHPIDIRECT / NVC ------------------------------------------------------
demo-nvc:
	mkdir -p $(BUILD)/demo-nvc
	$(CXXENV) $(CXX) -O2 -fPIC -shared $(BACKEND) vhdl/interactive_vhpi.cpp -lstdc++ -pthread $(SOCK_LIB) \
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
# Embed the dist dir as an rpath so a linked consumer finds the .so/.dylib. On
# Windows there is no rpath -- the DLL is located via PATH (the e2e harness adds
# the dist dir) -- so leave it empty there.
ifneq (,$(filter MINGW% MSYS% CYGWIN%,$(UNAME_S)))
  RPATH  :=
else
  RPATH  := -Wl,-rpath,$(DIST_ABS)
endif
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

# Icarus VPI module -- needs iverilog's headers, so it's split from `dist`. Same
# link recipe (VPI_BUILD) as the demo module.
dist-vpi:
	mkdir -p $(DIST)
	$(VPI_BUILD) -o $(DIST)/interactive.vpi

# Vivado XSim DPI trampoline (Windows). XSim's -sv_lib wants a .a it can link with
# its own gcc, and the real C++/winsock DPI DLL's ABI can't be linked that way; so
# this kernel32-only archive forwards to interactive_dpi.dll at run time. Built
# with the C compiler paired with CXX (must be C, not C++ -- the DPI symbols need
# C linkage). Use: xelab tb -sv_root $(DIST) -sv_lib interactive_dpi (DLL on PATH)
# Derive CC from CXX (g++ -> gcc) unless the user set it; make's built-in default
# is `cc`, which `?=` would not override.
ifeq ($(origin CC),default)
  CC := $(CXX:g++=gcc)
endif
dist-xsim:
	mkdir -p $(DIST)
	$(CXXENV) $(CC) -O2 -c sv/interactive_dpi_xsim.c -o $(DIST)/interactive_dpi_xsim.o
	$(CXXENV) ar rcs $(DIST)/interactive_dpi.a $(DIST)/interactive_dpi_xsim.o
	rm -f $(DIST)/interactive_dpi_xsim.o
	@echo "built $(DIST)/interactive_dpi.a (Vivado XSim DPI trampoline)"

# ---- Artifact demos: drive tb_demo against the PREBUILT libs in $(DIST) -----
# Same fixture as the demo-* targets, but the backend is NOT recompiled -- each
# simulator links/loads the already-built artifact (as a downstream user would).
# tests/e2e.py --dist calls these per simulator.
demo-dpi-dist:
	mkdir -p $(BUILD)/demo-dpi-dist
	$(VERILATOR) --cc --exe --build -j 0 -Wno-WIDTH --timing --timescale 1ns/1ps \
		--top-module tb_demo --Mdir $(BUILD)/demo-dpi-dist -o tb_demo \
		--main examples/tb_demo.sv sv/interactive_ctrl.sv sv/interactive_flag.sv $(VERILATED_OPT) \
		-LDFLAGS "-L$(DIST_ABS) -linteractive_dpi $(RPATH) -pthread $(STATIC_CXX)"
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
