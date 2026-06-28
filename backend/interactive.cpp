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
// Inbound control messages are demultiplexed by a single background thread (the
// connection manager) into a name->value map; interactive_ctrl_read looks up the
// latest value,
// so a control set in the viewer is visible to every clock domain on its next
// sample, with no coupling between domains.
//
// Environment variables:
//   INTERACTIVE_STREAM=host:port   the viewer to connect to (TCP). A background
//                                  thread keeps (re)connecting for the life of the
//                                  simulation, so the viewer may be started after
//                                  the sim and closed/reopened freely. While no
//                                  viewer is connected the simulation still runs:
//                                  flags are dropped and controls read 0 (their
//                                  default). On each (re)connect the full state is
//                                  replayed so a freshly opened viewer catches up.
//                                  If the variable is unset, everything is a no-op.

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <chrono>
#include <condition_variable>
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

// --- Process-global singleton. The whole point: one socket + one background
//     "connection manager" thread shared by every component instance, anywhere in
//     the hierarchy. g_mu guards the socket sends, the value map, the registry and
//     the connection lifecycle. The manager thread does NOT hold g_mu while
//     blocked in recv or connect (only when it updates shared state), so a
//     slow/absent viewer never stalls the simulation.
//
//     The link is order-insensitive: the manager keeps (re)connecting to the
//     viewer for as long as the simulation has open components, so the viewer can
//     be started after the sim, and closed and reopened freely. While no viewer is
//     connected every operation is a silent no-op (flags are dropped, controls
//     read their last value); on each (re)connect the manager replays the full
//     state -- a reg for every open component and the last value of every flag --
//     so a freshly opened viewer immediately shows the current board. ---
struct RegInfo { int kind; int width; };
struct FlagVal { double t; long val; };

std::mutex                     g_mu;
std::condition_variable        g_cv;          // wakes the manager's retry wait
sock_t                         g_sock = kBadSock;
bool                           g_inited = false;
std::string                    g_target;
std::map<std::string, long>    g_values;      // latest viewer->sim control values
std::map<std::string, RegInfo> g_registered;  // open components: replay + collision checks
std::map<std::string, FlagVal> g_last_flag;   // latest sim->viewer flag value, for replay
std::thread                    g_conn;        // the connection manager thread
std::atomic<bool>              g_stop{false};
bool                           g_conn_started = false;
int                            g_open_count = 0;

// How long the manager waits between connection attempts while no viewer is up.
constexpr int kReconnectMs = 500;

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
// considered down: shut down and close the socket so the connection manager's
// recv unblocks and it loops back to reconnecting (we never join here). Returns
// false -- a silent no-op -- whenever no viewer is connected.
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
            std::fprintf(stderr, "[interactive] viewer gone, will reconnect\n");
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

// Drain inbound control messages from a connected socket into g_values. Returns
// when the link drops (recv <= 0) or shutdown is requested. Holds g_mu only to
// update the value map (inside process_incoming), never while blocked in recv, so
// a slow/absent viewer never stalls the simulation.
void read_loop(sock_t fd) {
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

// One TCP connection attempt to g_target. Holds no lock (g_target is set once at
// init and never changes thereafter). Returns a connected socket, or kBadSock on
// failure. Blocking connect is fine here: this runs on the manager thread, off
// the simulation's critical path, and a refused localhost connect returns at once.
sock_t try_connect() {
    size_t colon = g_target.find_last_of(':');
    std::string host = (colon == std::string::npos) ? "127.0.0.1" : g_target.substr(0, colon);
    std::string port = (colon == std::string::npos) ? g_target : g_target.substr(colon + 1);
    if (host.empty()) host = "127.0.0.1";

    struct addrinfo hints{}, *res = nullptr;
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host.c_str(), port.c_str(), &hints, &res) != 0)
        return kBadSock;
    sock_t fd = kBadSock;
    for (auto p = res; p; p = p->ai_next) {
        fd = socket(p->ai_family, p->ai_socktype, p->ai_protocol);
        if (fd == kBadSock) continue;
        if (connect(fd, p->ai_addr, static_cast<int>(p->ai_addrlen)) == 0) break;
        sock_close(fd); fd = kBadSock;
    }
    freeaddrinfo(res);
    return fd;
}

// Re-announce the whole world to a freshly connected viewer: a reg for every open
// component, then the last known value of every flag. Caller holds g_mu and has
// just set g_sock, so the sends land on the new link. This is what makes the
// viewer order-insensitive -- open it whenever and it catches up immediately.
void replay_state_locked() {
    for (const auto& kv : g_registered) {
        const std::string& nm  = kv.first;
        const RegInfo&      inf = kv.second;
        send_line_locked(std::string("{\"ev\":\"reg\",\"name\":") + jstr(nm) +
                         ",\"kind\":\"" + (inf.kind == KIND_CTRL ? "ctrl" : "flag") +
                         "\",\"width\":" + std::to_string(inf.width) + "}\n");
    }
    for (const auto& kv : g_last_flag) {
        char num[64];
        std::snprintf(num, sizeof(num), "{\"ev\":\"flag\",\"t\":%.3f,\"name\":", kv.second.t);
        send_line_locked(std::string(num) + jstr(kv.first) +
                         ",\"val\":" + std::to_string(kv.second.val) + "}\n");
    }
}

// The background connection manager: keep a link to the viewer up for the life of
// the simulation. While disconnected it retries every kReconnectMs; once
// connected it replays state and drains inbound control messages until the link
// drops, then loops back to reconnecting. Exits only when g_stop is set (last
// component closed, or process exit).
void conn_mgr_loop() {
    while (!g_stop.load()) {
        // -- (re)connect, retrying until we get a link or are asked to stop --
        bool announced = false;
        for (;;) {
            if (g_stop.load()) return;
            sock_t fd = try_connect();
            if (fd != kBadSock) {
                std::lock_guard<std::mutex> lk(g_mu);
                if (g_stop.load()) { sock_close(fd); return; }
                g_sock = fd;
                replay_state_locked();
                std::fprintf(stderr, "[interactive] viewer connected\n");
                break;
            }
            if (!announced) {
                std::fprintf(stderr, "[interactive] no viewer yet, retrying every "
                             "%dms (running viewer-less)\n", kReconnectMs);
                announced = true;
            }
            std::unique_lock<std::mutex> lk(g_mu);
            g_cv.wait_for(lk, std::chrono::milliseconds(kReconnectMs),
                          [] { return g_stop.load(); });
            if (g_stop.load()) return;
        }

        // -- connected: drain inbound until the link drops --
        sock_t fd;
        { std::lock_guard<std::mutex> lk(g_mu); fd = g_sock; }
        if (fd != kBadSock) read_loop(fd);

        // -- link dropped: close it (unless send already did) and loop --
        std::lock_guard<std::mutex> lk(g_mu);
        if (g_sock == fd && g_sock != kBadSock) {
            sock_close(g_sock);
            g_sock = kBadSock;
        }
    }
}

// Start the connection manager once, on first component open. Caller holds g_mu.
// With no INTERACTIVE_STREAM target the manager is never started and the whole
// backend stays a silent no-op.
void ensure_manager_started_locked() {
    if (g_conn_started || g_target.empty()) return;
    g_stop.store(false);
    g_conn = std::thread(conn_mgr_loop);
    g_conn_started = true;
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

// Stop the connection manager and close the socket. Idempotent: after the first
// run there is no socket and no thread, so later calls return immediately. Never
// called while holding g_mu (it joins, and the manager may take g_mu).
void shutdown_all() {
    std::thread reaper;
    {
        std::lock_guard<std::mutex> lk(g_mu);
        if (!g_conn_started && g_sock == kBadSock) return;
        g_stop.store(true);
        g_cv.notify_all();                               // wake a pending retry wait
        if (g_sock != kBadSock) sock_shutdown(g_sock);   // unblock recv
        if (g_conn_started) {
            reaper = std::move(g_conn);
            g_conn_started = false;
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
    g_registered[nm] = RegInfo{kind, w};

    Comp* c = new Comp{nm, kind, w};
    g_open_count++;
    // Start the (re)connecting manager; the reg below is a no-op until a viewer is
    // up, but the manager replays it (and every flag's last value) on each connect.
    ensure_manager_started_locked();
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
    g_last_flag[c->name] = FlagVal{t, value};   // remembered for replay on reconnect
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
        g_last_flag.erase(c->name);
        if (--g_open_count <= 0) last = true;
    }
    delete c;
    if (last) shutdown_all();   // last component out: tear down the link cleanly
}
