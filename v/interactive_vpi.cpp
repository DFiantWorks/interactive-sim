// interactive_vpi.cpp
//
// VPI shim that lets a Verilog simulator (e.g. Icarus, which has no DPI support)
// drive the shared interactive-sim backend in ../backend/interactive.cpp -- the
// same core used by the Verilator/DPI and GHDL/VHPI flows.
//
// VPI calls the backend through registered system tasks/functions. As with the
// VHDL/VHPI shim, each component instance is an integer id into a registry (no
// pointer types cross the boundary):
//
//   handle = $interactive_ctrl_open(name, width);          // function -> id
//   value  = $interactive_ctrl_read(handle);               // function -> int
//   handle = $interactive_flag_open(name, width);          // function -> id
//   $interactive_flag_write(handle, $realtime, value);     // task
//   $interactive_close(handle);                            // task
//
// Build into a loadable VPI module and run with:
//   vvp -M<dir> -m interactive sim.vvp

#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include <vpi_user.h>

// Core API (defined in ../backend/interactive.cpp).
extern "C" {
void* interactive_ctrl_open(const char* name, int width);
int   interactive_ctrl_read(void* handle);
void* interactive_flag_open(const char* name, int width);
void  interactive_flag_write(void* handle, double t, int value);
void  interactive_tick(double t);
int   interactive_claim_heartbeat(void);
void  interactive_close(void* handle);
}

namespace {

std::vector<void*> g_handles;   // id -> core handle

int collect_args(vpiHandle systf, vpiHandle* out, int maxn) {
    vpiHandle it = vpi_iterate(vpiArgument, systf);
    if (!it) return 0;
    int n = 0;
    vpiHandle a;
    while ((a = vpi_scan(it)) != nullptr) {
        if (n < maxn) out[n] = a;
        ++n;
    }
    return n;
}

int as_int(vpiHandle a) {
    s_vpi_value v; v.format = vpiIntVal;
    vpi_get_value(a, &v);
    return v.value.integer;
}

double as_real(vpiHandle a) {
    s_vpi_value v; v.format = vpiRealVal;
    vpi_get_value(a, &v);
    return v.value.real;
}

// vpi_get_value's string buffer is only valid until the next call, so copy it.
std::string as_str(vpiHandle a) {
    s_vpi_value v; v.format = vpiStringVal;
    vpi_get_value(a, &v);
    return v.value.str ? std::string(v.value.str) : std::string();
}

void put_int_return(vpiHandle systf, int value) {
    s_vpi_value rv; rv.format = vpiIntVal; rv.value.integer = value;
    vpi_put_value(systf, &rv, nullptr, vpiNoDelay);
}

PLI_INT32 ctrl_open_calltf(PLI_BYTE8*) {
    vpiHandle systf = vpi_handle(vpiSysTfCall, nullptr);
    vpiHandle a[2];
    int n = collect_args(systf, a, 2);
    std::string name = (n >= 1) ? as_str(a[0]) : "ctrl";
    int width = (n >= 2) ? as_int(a[1]) : 1;
    g_handles.push_back(interactive_ctrl_open(name.c_str(), width));
    put_int_return(systf, static_cast<int>(g_handles.size()) - 1);
    return 0;
}

PLI_INT32 ctrl_read_calltf(PLI_BYTE8*) {
    vpiHandle systf = vpi_handle(vpiSysTfCall, nullptr);
    vpiHandle a[1];
    if (collect_args(systf, a, 1) < 1) { put_int_return(systf, 0); return 0; }
    put_int_return(systf, interactive_ctrl_read(g_handles[as_int(a[0])]));
    return 0;
}

PLI_INT32 flag_open_calltf(PLI_BYTE8*) {
    vpiHandle systf = vpi_handle(vpiSysTfCall, nullptr);
    vpiHandle a[2];
    int n = collect_args(systf, a, 2);
    std::string name = (n >= 1) ? as_str(a[0]) : "flag";
    int width = (n >= 2) ? as_int(a[1]) : 1;
    g_handles.push_back(interactive_flag_open(name.c_str(), width));
    put_int_return(systf, static_cast<int>(g_handles.size()) - 1);
    return 0;
}

PLI_INT32 flag_write_calltf(PLI_BYTE8*) {
    vpiHandle systf = vpi_handle(vpiSysTfCall, nullptr);
    vpiHandle a[3];
    if (collect_args(systf, a, 3) < 3) return 0;
    interactive_flag_write(g_handles[as_int(a[0])], as_real(a[1]), as_int(a[2]));
    return 0;
}

PLI_INT32 tick_calltf(PLI_BYTE8*) {
    vpiHandle systf = vpi_handle(vpiSysTfCall, nullptr);
    vpiHandle a[1];
    if (collect_args(systf, a, 1) < 1) return 0;
    interactive_tick(as_real(a[0]));
    return 0;
}

PLI_INT32 claim_heartbeat_calltf(PLI_BYTE8*) {
    vpiHandle systf = vpi_handle(vpiSysTfCall, nullptr);
    put_int_return(systf, interactive_claim_heartbeat());
    return 0;
}

PLI_INT32 close_calltf(PLI_BYTE8*) {
    vpiHandle systf = vpi_handle(vpiSysTfCall, nullptr);
    vpiHandle a[1];
    if (collect_args(systf, a, 1) < 1) return 0;
    interactive_close(g_handles[as_int(a[0])]);
    return 0;
}

void reg_func(const char* name, PLI_INT32 (*calltf)(PLI_BYTE8*)) {
    s_vpi_systf_data d; std::memset(&d, 0, sizeof(d));
    d.type = vpiSysFunc; d.sysfunctype = vpiIntFunc;
    d.tfname = const_cast<PLI_BYTE8*>(name); d.calltf = calltf;
    vpi_register_systf(&d);
}

void reg_task(const char* name, PLI_INT32 (*calltf)(PLI_BYTE8*)) {
    s_vpi_systf_data d; std::memset(&d, 0, sizeof(d));
    d.type = vpiSysTask;
    d.tfname = const_cast<PLI_BYTE8*>(name); d.calltf = calltf;
    vpi_register_systf(&d);
}

void register_tf() {
    reg_func("$interactive_ctrl_open",  ctrl_open_calltf);
    reg_func("$interactive_ctrl_read",  ctrl_read_calltf);
    reg_func("$interactive_flag_open",  flag_open_calltf);
    reg_task("$interactive_flag_write", flag_write_calltf);
    reg_task("$interactive_tick",       tick_calltf);
    reg_func("$interactive_claim_heartbeat", claim_heartbeat_calltf);
    reg_task("$interactive_close",      close_calltf);
}

}  // namespace

extern "C" {
void (*vlog_startup_routines[])() = { register_tf, nullptr };
}
