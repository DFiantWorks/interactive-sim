// interactive_vhpi.cpp
//
// VHPIDIRECT shim that lets GHDL/NVC drive the shared interactive-sim backend in
// ../backend/interactive.cpp (the same core the DPI and VPI flows use).
// VHPIDIRECT marshals integers, not pointers, so each component instance is an
// integer id into a small registry here; `out integer` handles arrive as int*.
//
// The component name is passed as (char* base, int namelen): GHDL and NVC pass an
// `in string` parameter as a pointer to its first character, so we rebuild it
// with std::string(name, namelen).

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
void  interactive_close(void* handle);
}

namespace {
std::vector<void*> g_handles;   // id -> core handle
}

VHPI_EXPORT void vhpi_ctrl_open(int* handle, char* name, int namelen, int width) {
    std::string nm(name, name + (namelen > 0 ? namelen : 0));
    g_handles.push_back(interactive_ctrl_open(nm.c_str(), width));
    *handle = static_cast<int>(g_handles.size()) - 1;
}

VHPI_EXPORT void vhpi_ctrl_read(int handle, int* result) {
    *result = interactive_ctrl_read(g_handles[handle]);
}

VHPI_EXPORT void vhpi_flag_open(int* handle, char* name, int namelen, int width) {
    std::string nm(name, name + (namelen > 0 ? namelen : 0));
    g_handles.push_back(interactive_flag_open(nm.c_str(), width));
    *handle = static_cast<int>(g_handles.size()) - 1;
}

VHPI_EXPORT void vhpi_flag_write(int handle, double t, int value) {
    interactive_flag_write(g_handles[handle], t, value);
}

VHPI_EXPORT void vhpi_close(int handle) {
    interactive_close(g_handles[handle]);
}
