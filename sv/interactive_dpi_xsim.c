/* interactive_dpi_xsim.c -- DPI trampoline for Vivado XSim (Windows).
 *
 * XSim links DPI through its own bundled GCC and rejects a foreign-built library
 * (it wants a .a static archive, and a MinGW .a of the real backend fails on the
 * libstdc++/UCRT/winsock ABI). This shim avoids all of that: it uses ONLY
 * kernel32 (LoadLibrary/GetProcAddress + GetEnvironmentVariable/lstrcpy), so a
 * prebuilt MinGW interactive_dpi.a links cleanly under XSim's gcc. On first DPI
 * call it loads the self-contained interactive_dpi.dll and forwards.
 *
 * The DLL name defaults to "interactive_dpi.dll"; override with the
 * INTERACTIVE_DLL environment variable (e.g. a versioned release filename).
 *
 * Build: gcc -O2 -c interactive_dpi_xsim.c && ar rcs interactive_dpi.a *.o
 * Use:   xelab my_tb -sv_root <dir> -sv_lib interactive_dpi   (DLL on PATH)
 */
#include <windows.h>

typedef void* (*ctrl_open_fn)(const char*, int);
typedef int   (*ctrl_read_fn)(void*);
typedef void* (*flag_open_fn)(const char*, int);
typedef void  (*flag_write_fn)(void*, double, int);
typedef void  (*close_fn)(void*);

static ctrl_open_fn  p_ctrl_open;
static ctrl_read_fn  p_ctrl_read;
static flag_open_fn  p_flag_open;
static flag_write_fn p_flag_write;
static close_fn      p_close;
static int           tried;

static void ensure(void) {
    if (tried) return;
    tried = 1;
    char dll[MAX_PATH];
    if (GetEnvironmentVariableA("INTERACTIVE_DLL", dll, sizeof dll) == 0)
        lstrcpyA(dll, "interactive_dpi.dll");
    HMODULE h = LoadLibraryA(dll);
    if (!h) return;
    p_ctrl_open  = (ctrl_open_fn)  (void*)GetProcAddress(h, "interactive_ctrl_open");
    p_ctrl_read  = (ctrl_read_fn)  (void*)GetProcAddress(h, "interactive_ctrl_read");
    p_flag_open  = (flag_open_fn)  (void*)GetProcAddress(h, "interactive_flag_open");
    p_flag_write = (flag_write_fn) (void*)GetProcAddress(h, "interactive_flag_write");
    p_close      = (close_fn)      (void*)GetProcAddress(h, "interactive_close");
}

void* interactive_ctrl_open(const char* name, int width) {
    ensure(); return p_ctrl_open ? p_ctrl_open(name, width) : 0;
}
int interactive_ctrl_read(void* h) {
    ensure(); return p_ctrl_read ? p_ctrl_read(h) : 0;
}
void* interactive_flag_open(const char* name, int width) {
    ensure(); return p_flag_open ? p_flag_open(name, width) : 0;
}
void interactive_flag_write(void* h, double t, int value) {
    ensure(); if (p_flag_write) p_flag_write(h, t, value);
}
void interactive_close(void* h) {
    ensure(); if (p_close) p_close(h);
}
