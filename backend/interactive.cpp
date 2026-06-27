// interactive.cpp
//
// Simulator-agnostic backend for interactive-sim. It is reached through three
// thin foreign-interface shims that all call the same functions:
//   - SystemVerilog + Verilator -> DPI-C       (sv/interactive_{ctrl,flag}.sv)
//   - VHDL + GHDL/NVC           -> VHPIDIRECT  (vhdl/interactive_vhpi.cpp)
//   - Verilog + Icarus          -> VPI         (v/interactive_vpi.cpp)
//
// Two component kinds, placed anywhere in the design hierarchy and NOT wired to
// each other in any way:
//   - interactive_ctrl : a viewer-driven input  (button / switch / toggle).
//                        The HDL samples its current value; the value is set
//                        from the viewer over the socket, asynchronously.
//   - interactive_flag : a design-driven output (LED / 7-seg / status word).
//                        The HDL writes a value on change; it is pushed to the
//                        viewer over the socket.
//
// Everything funnels through ONE shared TCP socket to a single dedicated viewer.
// The backend is compiled once and linked into the simulation process, so its
// process-global state below is shared by every component instance regardless of
// where it sits in the hierarchy -- that shared singleton, not any HDL wiring,
// is what lets unconnected components meet on one socket.
//
// Each component is identified by a user-supplied NAME, which is both its channel
// id in the wire protocol and its label in the viewer. Names must be unique
// across the whole simulation (a collision is reported and the later instance is
// dropped from the registry).
//
// Wire protocol -- newline-delimited JSON, one message per line:
//   sim  -> viewer  {"ev":"reg",  "name":"...","kind":"ctrl|flag","width":N}
//                   {"ev":"flag", "t":<us>,"name":"...","val":N}
//                   {"ev":"close","name":"..."}
// Times are in microseconds: this is a human-interaction interface (buttons,
// LEDs), so us resolution is ample -- still fine enough that a viewer can
// integrate a fast-toggled flag's duty cycle into a perceived brightness.
//   viewer -> sim   {"name":"...","val":N}
// Inbound control messages are demultiplexed by a single background reader thread
// into a name->value map; interactive_ctrl_read just looks up the latest value,
// so a control set in the viewer is visible to every clock domain on its next
// sample, with no coupling between domains.
//
// Environment variables:
//   INTERACTIVE_STREAM=host:port   connect (TCP) to the viewer at startup. If
//                                  unset or the connect fails, the simulation
//                                  still runs: flags are dropped and controls
//                                  read 0 (their default).

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <map>
#include <mutex>
#include <string>
#include <thread>

// --- Cross-platform TCP socket layer (POSIX + Windows/Winsock) --------------
#ifdef _WIN32
  #include <winsock2.h>
  #include <ws2tcpip.h>
  #pragma comment(lib, "ws2_32.lib")
  using sock_t = SOCKET;
  static const sock_t kBadSock = INVALID_SOCKET;
  static int  sock_close(sock_t s)                   { return ::closesocket(s); }
  static int  sock_send(sock_t s, const char* b, size_t n) { return ::send(s, b, (int)n, 0); }
  static int  sock_recv(sock_t s, char* b, size_t n) { return ::recv(s, b, (int)n, 0); }
  static void sock_shutdown(sock_t s)                { ::shutdown(s, SD_BOTH); }
  static void sock_startup()                         { WSADATA w; WSAStartup(MAKEWORD(2, 2), &w); }
  #define IA_EXPORT extern "C" __declspec(dllexport)
#else
  #include <unistd.h>
  #include <sys/socket.h>
  #include <netdb.h>
  using sock_t = int;
  static const sock_t kBadSock = -1;
  static int     sock_close(sock_t s)                   { return ::close(s); }
  static ssize_t sock_send(sock_t s, const char* b, size_t n) { return ::send(s, b, n, 0); }
  static ssize_t sock_recv(sock_t s, char* b, size_t n) { return ::recv(s, b, n, 0); }
  static void    sock_shutdown(sock_t s)                { ::shutdown(s, SHUT_RDWR); }
  static void    sock_startup()                         {}
  #define IA_EXPORT extern "C"
#endif

namespace {

enum { KIND_CTRL = 0, KIND_FLAG = 1 };

struct Comp {
    std::string name;
    int         kind;
    int         width;
};

// --- Process-global singleton. The whole point: one socket + one reader thread
//     shared by every component instance, anywhere in the hierarchy. g_mu guards
//     the socket sends, the value map, and the connection lifecycle. The reader
//     thread does NOT hold g_mu while blocked in recv (only when it updates the
//     map), so a slow/absent viewer never stalls the simulation. ---
std::mutex                 g_mu;
sock_t                     g_sock = kBadSock;
bool                       g_inited = false;
bool                       g_connect_tried = false;
std::string                g_target;
std::map<std::string, long> g_values;        // latest viewer->sim control values
std::map<std::string, int>  g_registered;     // name -> kind, for collision checks
std::thread                g_reader;
std::atomic<bool>          g_stop{false};
bool                       g_reader_started = false;
int                        g_open_count = 0;

// JSON-quote a string (only the escapes a component name could plausibly hit).
std::string jstr(const std::string& s) {
    std::string o = "\"";
    for (char ch : s) {
        if (ch == '"' || ch == '\\') { o += '\\'; o += ch; }
        else if (ch == '\n')         { o += "\\n"; }
        else                          { o += ch; }
    }
    o += '"';
    return o;
}

// Minimal, forgiving scanners for the inbound viewer->sim line. We only need a
// string field ("name") and an integer field ("val"); anything else is ignored.
std::string find_str(const std::string& s, const char* key) {
    std::string pat = std::string("\"") + key + "\"";
    size_t k = s.find(pat);
    if (k == std::string::npos) return "";
    k = s.find(':', k + pat.size());
    if (k == std::string::npos) return "";
    k = s.find('"', k);
    if (k == std::string::npos) return "";
    size_t end = ++k;
    std::string out;
    while (end < s.size() && s[end] != '"') {
        if (s[end] == '\\' && end + 1 < s.size()) ++end;  // skip escape
        out += s[end++];
    }
    return out;
}

long find_int(const std::string& s, const char* key, bool* ok) {
    *ok = false;
    std::string pat = std::string("\"") + key + "\"";
    size_t k = s.find(pat);
    if (k == std::string::npos) return 0;
    k = s.find(':', k + pat.size());
    if (k == std::string::npos) return 0;
    ++k;
    while (k < s.size() && (s[k] == ' ' || s[k] == '\t')) ++k;
    size_t start = k;
    if (k < s.size() && (s[k] == '-' || s[k] == '+')) ++k;
    size_t digits = k;
    while (k < s.size() && s[k] >= '0' && s[k] <= '9') ++k;
    if (k == digits) return 0;                 // no digits
    *ok = true;
    return std::strtol(s.c_str() + start, nullptr, 10);
}

// Send a whole line under g_mu (caller holds it). On any error the link is
// considered down: close the socket and signal the reader to stop. We do NOT
// join the reader here -- closing the fd unblocks its recv and it exits on its
// own; joining is done once, at shutdown.
bool send_line_locked(const std::string& s) {
    if (g_sock == kBadSock) return false;
    const char* p = s.data();
    size_t n = s.size();
    while (n) {
        auto k = sock_send(g_sock, p, n);
        if (k <= 0) {
#ifndef _WIN32
            if (k < 0 && errno == EINTR) continue;
#endif
            std::fprintf(stderr, "[interactive] viewer gone, link closed\n");
            g_stop.store(true);
            sock_shutdown(g_sock);
            sock_close(g_sock);
            g_sock = kBadSock;
            return false;
        }
        p += k;
        n -= static_cast<size_t>(k);
    }
    return true;
}

void process_incoming(const std::string& line) {
    std::string name = find_str(line, "name");
    if (name.empty()) return;
    bool ok = false;
    long v = find_int(line, "val", &ok);
    if (!ok) return;
    std::lock_guard<std::mutex> lk(g_mu);
    g_values[name] = v;
}

// The single background reader. Owns the recv side of the shared socket and
// demultiplexes inbound control messages into g_values. Runs until the socket is
// shut down (at process exit or when the viewer disconnects).
void reader_loop() {
    sock_t fd = g_sock;                 // fixed for this thread's lifetime
    std::string buf;
    char tmp[1024];
    while (!g_stop.load()) {
        auto k = sock_recv(fd, tmp, sizeof(tmp));
        if (k <= 0) break;              // viewer closed, or socket shut down
        buf.append(tmp, tmp + k);
        size_t nl;
        while ((nl = buf.find('\n')) != std::string::npos) {
            process_incoming(buf.substr(0, nl));
            buf.erase(0, nl + 1);
        }
    }
}

// Connect once to INTERACTIVE_STREAM and start the reader thread. Caller holds
// g_mu. Returns false (and the simulation runs viewer-less) if unset or the
// connect fails.
bool ensure_connected_locked() {
    if (g_sock != kBadSock) return true;
    if (g_connect_tried)    return false;
    g_connect_tried = true;
    if (g_target.empty())   return false;

    size_t colon = g_target.find_last_of(':');
    std::string host = (colon == std::string::npos) ? "127.0.0.1" : g_target.substr(0, colon);
    std::string port = (colon == std::string::npos) ? g_target : g_target.substr(colon + 1);
    if (host.empty()) host = "127.0.0.1";

    struct addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host.c_str(), port.c_str(), &hints, &res) != 0) {
        std::fprintf(stderr, "[interactive] cannot resolve %s:%s\n", host.c_str(), port.c_str());
        return false;
    }
    sock_t fd = kBadSock;
    for (auto p = res; p; p = p->ai_next) {
        fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (fd == kBadSock) continue;
        if (connect(fd, p->ai_addr, static_cast<int>(p->ai_addrlen)) == 0) break;
        sock_close(fd); fd = kBadSock;
    }
    freeaddrinfo(res);
    if (fd == kBadSock) {
        std::fprintf(stderr, "[interactive] connect to %s:%s failed (running viewer-less)\n",
                     host.c_str(), port.c_str());
        return false;
    }
    g_sock = fd;
    g_stop.store(false);
    g_reader = std::thread(reader_loop);
    g_reader_started = true;
    std::fprintf(stderr, "[interactive] connected to %s:%s\n", host.c_str(), port.c_str());
    return true;
}

void shutdown_all();   // fwd

void lazy_init_locked() {
    if (g_inited) return;
    g_inited = true;
    sock_startup();
    if (const char* s = std::getenv("INTERACTIVE_STREAM"))
        if (s[0]) g_target = s;
    std::atexit(shutdown_all);   // backstop: join the reader before static dtors
}

// Stop the reader thread and close the socket. Idempotent: after the first run
// there is no socket and no thread, so later calls return immediately. Never
// called while holding g_mu (it joins, and the reader may take g_mu).
void shutdown_all() {
    std::thread reaper;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        if (!g_reader_started && g_sock == kBadSock) return;
        g_stop.store(true);
        if (g_sock != kBadSock) sock_shutdown(g_sock);   // unblock recv
        if (g_reader_started) {
            reaper = std::move(g_reader);
            g_reader_started = false;
        }
    }
    if (reaper.joinable()) reaper.join();
    std::lock_guard<std::mutex> lk(g_mu);
    if (g_sock != kBadSock) { sock_close(g_sock); g_sock = kBadSock; }
}

// Announce a component to the viewer, after a uniqueness check on its name.
Comp* open_comp(const char* name, int kind, int width) {
    std::lock_guard<std::mutex> lk(g_mu);
    lazy_init_locked();
    std::string nm = (name && name[0]) ? name : (kind == KIND_CTRL ? "ctrl" : "flag");
    int w = (width > 0) ? width : 1;

    if (g_registered.count(nm)) {
        std::fprintf(stderr,
            "[interactive] duplicate name '%s' -- instance dropped (names must be unique)\n",
            nm.c_str());
        return nullptr;
    }
    g_registered[nm] = kind;

    Comp* c = new Comp{nm, kind, w};
    g_open_count++;
    ensure_connected_locked();
    send_line_locked(std::string("{\"ev\":\"reg\",\"name\":") + jstr(nm) +
                     ",\"kind\":\"" + (kind == KIND_CTRL ? "ctrl" : "flag") +
                     "\",\"width\":" + std::to_string(w) + "}\n");
    std::fprintf(stderr, "[interactive] %s '%s' (%d-bit) open\n",
                 kind == KIND_CTRL ? "ctrl" : "flag", nm.c_str(), w);
    return c;
}

}  // namespace


// ---- Public, simulator-agnostic API ----------------------------------------

IA_EXPORT void* interactive_ctrl_open(const char* name, int width) {
    return open_comp(name, KIND_CTRL, width);
}

// Latest viewer-set value for this control (0 until the viewer first sets it).
IA_EXPORT int interactive_ctrl_read(void* handle) {
    Comp* c = static_cast<Comp*>(handle);
    if (!c) return 0;
    std::lock_guard<std::mutex> lk(g_mu);
    auto it = g_values.find(c->name);
    return (it == g_values.end()) ? 0 : static_cast<int>(it->second);
}

IA_EXPORT void* interactive_flag_open(const char* name, int width) {
    return open_comp(name, KIND_FLAG, width);
}

// Push a new flag value to the viewer, tagged with the current sim time (us).
IA_EXPORT void interactive_flag_write(void* handle, double t, int value) {
    Comp* c = static_cast<Comp*>(handle);
    if (!c) return;
    std::lock_guard<std::mutex> lk(g_mu);
    char num[64];
    std::snprintf(num, sizeof(num), "{\"ev\":\"flag\",\"t\":%.3f,\"name\":", t);
    send_line_locked(std::string(num) + jstr(c->name) +
                     ",\"val\":" + std::to_string(value) + "}\n");
}

IA_EXPORT void interactive_close(void* handle) {
    Comp* c = static_cast<Comp*>(handle);
    if (!c) return;
    bool last = false;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        send_line_locked(std::string("{\"ev\":\"close\",\"name\":") + jstr(c->name) + "}\n");
        g_registered.erase(c->name);
        if (--g_open_count <= 0) last = true;
    }
    delete c;
    if (last) shutdown_all();   // last component out: tear down the link cleanly
}
