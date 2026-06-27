// realtime_vpi.cpp
//
// A *demo-only* VPI helper that paces an Icarus simulation to the wall clock.
// It is NOT part of the interactive-sim framework -- the framework files
// (backend/, v/, sv/, vhdl/) are untouched. It exists solely so the ULX3S GUI
// demo (examples/tb_ulx3s.v) animates at human speed instead of completing its
// whole run in a millisecond of CPU time.
//
// Why this is needed: a Verilog simulator advances *simulation* time as fast as
// the host CPU allows. A design that toggles an LED "every 100 ms" of sim time
// would emit thousands of flag updates per real second, so the viewer would just
// see the final state. To watch LEDs blink and click buttons live, the dominant
// time-advancing loop must throttle itself to real time.
//
// Registered system task:
//   $rt_sync(realtime_us);   // realtime_us = $realtime under a us timescale
//
// On the first call it latches (sim_time, wall_time). On every later call it
// sleeps until wall-clock elapsed has caught up to sim-time elapsed, so overall
// the simulation runs at ~1x real time (jitter bounded by the caller's tick).
// If the sim ever falls behind real time it simply does not sleep.
//
// Build into a loadable VPI module and load alongside the framework module:
//   vvp -M<dir> -m interactive -m realtime sim.vvp

#include <vpi_user.h>
#include <chrono>
#include <thread>

namespace {

bool                                  g_started = false;
double                                g_sim0_us = 0.0;   // sim time at first call
std::chrono::steady_clock::time_point g_wall0;           // wall time at first call

PLI_INT32 rt_sync_calltf(PLI_BYTE8*) {
    vpiHandle systf = vpi_handle(vpiSysTfCall, nullptr);
    vpiHandle it    = vpi_iterate(vpiArgument, systf);
    if (!it) return 0;
    vpiHandle a = vpi_scan(it);
    vpi_free_object(it);               // we only need the first argument
    if (!a) return 0;

    s_vpi_value v; v.format = vpiRealVal;
    vpi_get_value(a, &v);
    const double sim_us = v.value.real;

    const auto now = std::chrono::steady_clock::now();
    if (!g_started) {
        g_started = true;
        g_sim0_us = sim_us;
        g_wall0   = now;
        return 0;
    }

    const double sim_elapsed_us  = sim_us - g_sim0_us;
    const double wall_elapsed_us =
        std::chrono::duration<double, std::micro>(now - g_wall0).count();
    const double behind_us = sim_elapsed_us - wall_elapsed_us;
    if (behind_us > 0.0)
        std::this_thread::sleep_for(
            std::chrono::microseconds(static_cast<long long>(behind_us)));
    return 0;
}

void reg_task(const char* name, PLI_INT32 (*calltf)(PLI_BYTE8*)) {
    s_vpi_systf_data d;
    for (size_t i = 0; i < sizeof(d); ++i) reinterpret_cast<char*>(&d)[i] = 0;
    d.type   = vpiSysTask;
    d.tfname = const_cast<PLI_BYTE8*>(name);
    d.calltf = calltf;
    vpi_register_systf(&d);
}

void register_tf() {
    reg_task("$rt_sync", rt_sync_calltf);
}

}  // namespace

extern "C" {
void (*vlog_startup_routines[])() = { register_tf, nullptr };
}
