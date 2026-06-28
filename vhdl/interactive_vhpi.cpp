// interactive_vhpi.cpp
//
// VHPIDIRECT shim that lets GHDL/NVC drive the shared interactive-sim backend in
// ../backend/interactive.cpp (the same core the DPI and VPI flows use).
// VHPIDIRECT marshals scalars (integer/real), not pointers, so each component
// instance is an integer id into a small registry here; `out integer` handles
// arrive as int*.
//
// The component NAME arrives as (char* base, int namelen): the VHDL side passes a
// BOUNDED string(1 to 255) (a constrained array), which GHDL and NVC both pass as
// a pointer to its first character, so we rebuild it with std::string(name,
// namelen). A constrained array is required: GHDL does not implement marshaling
// an unconstrained `string` to a foreign subprogram.

#include <cstdint>
#include <string>
#include <vector>

#ifdef _WIN32
  #define VHPI_EXPORT extern "C" __declspec(dllexport)
#else
  #define VHPI_EXPORT extern "C"
#endif

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
const int          kMaxName = 255;   // not NAME_MAX: that's a POSIX macro (limits.h)
std::vector<void*> g_handles;        // id -> core handle

std::string name_of(const char* name, int namelen) {
    if (namelen < 0)        namelen = 0;
    if (namelen > kMaxName) namelen = kMaxName;   // matches the VHDL name_t bound
    return std::string(name, name + namelen);
}
}

VHPI_EXPORT void vhpi_ctrl_open(int* handle, char* name, int namelen, int width) {
    g_handles.push_back(interactive_ctrl_open(name_of(name, namelen).c_str(), width));
    *handle = static_cast<int>(g_handles.size()) - 1;
}

VHPI_EXPORT void vhpi_ctrl_read(int handle, int* result) {
    *result = interactive_ctrl_read(g_handles[handle]);
}

VHPI_EXPORT void vhpi_flag_open(int* handle, char* name, int namelen, int width) {
    g_handles.push_back(interactive_flag_open(name_of(name, namelen).c_str(), width));
    *handle = static_cast<int>(g_handles.size()) - 1;
}

VHPI_EXPORT void vhpi_flag_write(int handle, double t, int value) {
    interactive_flag_write(g_handles[handle], t, value);
}

VHPI_EXPORT void vhpi_tick(double t) {
    interactive_tick(t);
}

VHPI_EXPORT void vhpi_claim_heartbeat(int* result) {
    *result = interactive_claim_heartbeat();
}

VHPI_EXPORT void vhpi_close(int handle) {
    interactive_close(g_handles[handle]);
}
