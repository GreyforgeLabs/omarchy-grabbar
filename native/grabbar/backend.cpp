#include "backend.hpp"
#include "bar.hpp"

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/Workspace.hpp>
#include <hyprland/src/state/WorkspaceState.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/output/Monitor.hpp>
#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/managers/fullscreen/FullscreenController.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/debug/log/Logger.hpp>

#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <chrono>
#include <format>
#include <algorithm>

using namespace Config::Actions;

// ------------------------------------------------------------- encoding

std::string grabbarEncode(const std::string& v) {
    static const char* HEX = "0123456789ABCDEF";
    std::string        out;
    out.reserve(v.size());
    for (unsigned char c : v) {
        if (c < 0x20 || c == 0x7f || c == '%' || c == '\t' || c == '\n') {
            out += '%';
            out += HEX[c >> 4];
            out += HEX[c & 15];
        } else
            out += (char)c;
    }
    return out;
}

std::string grabbarDecode(const std::string& v) {
    std::string out;
    out.reserve(v.size());
    for (size_t i = 0; i < v.size(); ++i) {
        if (v[i] == '%' && i + 2 < v.size() && std::isxdigit((unsigned char)v[i + 1]) && std::isxdigit((unsigned char)v[i + 2])) {
            out += (char)std::stoi(v.substr(i + 1, 2), nullptr, 16);
            i += 2;
        } else
            out += v[i];
    }
    return out;
}

static std::string buildLine(const std::string& type, const Fields& fields) {
    std::string line = type;
    for (const auto& [k, v] : fields) {
        line += '\t';
        line += k;
        line += '=';
        line += grabbarEncode(v);
    }
    line += '\n';
    return line;
}

static Fields parseLine(const std::string& line, std::string& type) {
    Fields fields;
    size_t start = 0;
    bool   first = true;
    while (start <= line.size()) {
        size_t tab  = line.find('\t', start);
        auto   part = line.substr(start, tab == std::string::npos ? std::string::npos : tab - start);
        if (first) {
            type  = part;
            first = false;
        } else if (!part.empty()) {
            auto eq = part.find('=');
            if (eq == std::string::npos)
                fields.emplace_back(part, "");
            else
                fields.emplace_back(part.substr(0, eq), grabbarDecode(part.substr(eq + 1)));
        }
        if (tab == std::string::npos)
            break;
        start = tab + 1;
    }
    return fields;
}

static std::string field(const Fields& f, const char* key, const std::string& def = "") {
    for (const auto& [k, v] : f)
        if (k == key)
            return v;
    return def;
}

static const char* statusName(eActionStatus s) {
    switch (s) {
        case ACTION_OK: return "ok";
        case ACTION_STALE: return "stale";
        case ACTION_REFUSED: return "refused";
        case ACTION_FAILED: return "failed";
    }
    return "failed";
}

// ------------------------------------------------------------ lifecycle

static int onListenReadable(int, uint32_t, void* data) {
    static_cast<CGrabbarBackend*>(data)->acceptClient();
    return 0;
}

static int onClientReadable(int, uint32_t mask, void* data) {
    auto c = static_cast<SGrabbarClient*>(data);
    g_pBackend->clientEvent(c, mask);
    return 0;
}

CGrabbarBackend::CGrabbarBackend() = default;

CGrabbarBackend::~CGrabbarBackend() {
    if (m_listenFd >= 0)
        stop(false, "destroy");
}

bool CGrabbarBackend::start() {
    const char* RT = getenv("XDG_RUNTIME_DIR");
    if (!RT || !*RT) {
        Log::logger->log(Log::ERR, "[grabbar] XDG_RUNTIME_DIR unset; refusing to create a socket");
        return false;
    }

    m_sessionId = g_pCompositor->m_instanceSignature;
    m_epoch     = (uint64_t)std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();

    const std::string DIR  = std::string(RT) + "/grabbar";
    const std::string IDIR = DIR + "/" + m_sessionId;
    if (mkdir(DIR.c_str(), 0700) != 0 && errno != EEXIST)
        return false;
    chmod(DIR.c_str(), 0700);
    if (mkdir(IDIR.c_str(), 0700) != 0 && errno != EEXIST)
        return false;
    chmod(IDIR.c_str(), 0700);

    m_socketPath = IDIR + "/backend.sock";

    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    if (m_socketPath.size() >= sizeof(addr.sun_path)) {
        Log::logger->log(Log::ERR, "[grabbar] socket path too long: {}", m_socketPath);
        return false;
    }
    std::strncpy(addr.sun_path, m_socketPath.c_str(), sizeof(addr.sun_path) - 1);

    struct stat st{};
    if (lstat(m_socketPath.c_str(), &st) == 0) {
        if (!S_ISSOCK(st.st_mode)) {
            Log::logger->log(Log::ERR, "[grabbar] refusing to replace non-socket at {}", m_socketPath);
            return false;
        }
        unlink(m_socketPath.c_str());
    }

    m_listenFd = socket(AF_UNIX, SOCK_STREAM | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
    if (m_listenFd < 0)
        return false;

    if (bind(m_listenFd, (sockaddr*)&addr, sizeof(addr)) != 0 || listen(m_listenFd, 4) != 0) {
        Log::logger->log(Log::ERR, "[grabbar] bind/listen failed: {}", strerror(errno));
        close(m_listenFd);
        m_listenFd = -1;
        return false;
    }
    chmod(m_socketPath.c_str(), 0600);

    m_listenSource = wl_event_loop_add_fd(g_pCompositor->m_wlEventLoop, m_listenFd, WL_EVENT_READABLE, ::onListenReadable, this);

    m_graceTimer = makeShared<CEventLoopTimer>(std::nullopt, [](SP<CEventLoopTimer>, void* data) { static_cast<CGrabbarBackend*>(data)->onGraceExpired(); }, this);
    g_pEventLoopManager->addTimer(m_graceTimer);

    Log::logger->log(Log::INFO, "[grabbar] backend epoch {} listening on {}", m_epoch, m_socketPath);
    return true;
}

void CGrabbarBackend::stop(bool restoreOwned, const char* reason) {
    if (m_stopping)
        return;
    m_stopping = true;

    size_t restored = 0;
    if (restoreOwned)
        restored = restoreAllOwned(reason);

    broadcastShell("event", {{"kind", "backendStopping"}, {"reason", reason}, {"restored", std::to_string(restored)}});

    for (auto& c : m_clients) {
        flush(c.get());
        if (c->source)
            wl_event_source_remove(c->source);
        if (c->fd >= 0)
            close(c->fd);
        c->source = nullptr;
        c->fd     = -1;
    }
    m_clients.clear();
    m_shell = nullptr;

    if (m_listenSource) {
        wl_event_source_remove(m_listenSource);
        m_listenSource = nullptr;
    }
    if (m_listenFd >= 0) {
        close(m_listenFd);
        m_listenFd = -1;
    }
    if (!m_socketPath.empty())
        unlink(m_socketPath.c_str());

    if (m_graceTimer) {
        m_graceTimer->cancel();
        g_pEventLoopManager->removeTimer(m_graceTimer);
        m_graceTimer.reset();
    }

    m_windows.clear();
    m_tokenByWindow.clear();
    m_suspended = true;
}

// -------------------------------------------------------------- identity

std::string CGrabbarBackend::tokenFor(PHLWINDOW w) {
    if (!w)
        return "";
    const auto KEY = (uintptr_t)w.get();
    if (auto it = m_tokenByWindow.find(KEY); it != m_tokenByWindow.end()) {
        // A reused address for a different live window gets a fresh token.
        auto& t = m_windows[it->second];
        if (t.window.lock() == w && t.stableId == w->m_stableID)
            return it->second;
        m_windows.erase(it->second);
        m_tokenByWindow.erase(it);
    }

    STrackedWindow t;
    t.token    = std::format("g{}-{}", m_epoch, ++m_generation);
    t.window   = w;
    t.stableId = w->m_stableID;
    t.pid      = w->getPID();
    m_windows[t.token]  = t;
    m_tokenByWindow[KEY] = t.token;
    return t.token;
}

STrackedWindow* CGrabbarBackend::tracked(const std::string& token) {
    auto it = m_windows.find(token);
    return it == m_windows.end() ? nullptr : &it->second;
}

PHLWINDOW CGrabbarBackend::resolve(const std::string& token) {
    auto t = tracked(token);
    if (!t)
        return nullptr;
    auto w = t->window.lock();
    if (!w || !validMapped(w) || w->m_stableID != t->stableId)
        return nullptr;
    return w;
}

void CGrabbarBackend::forgetWindow(const std::string& token) {
    auto it = m_windows.find(token);
    if (it == m_windows.end())
        return;
    for (auto tb = m_tokenByWindow.begin(); tb != m_tokenByWindow.end();) {
        if (tb->second == token)
            tb = m_tokenByWindow.erase(tb);
        else
            ++tb;
    }
    m_windows.erase(it);
}

// -------------------------------------------------------------- readiness

bool CGrabbarBackend::shellConnected() const {
    return m_shell != nullptr;
}

bool CGrabbarBackend::minimizeEnabled() const {
    return m_shell != nullptr && m_ready && !m_stopping && !m_paused;
}

bool CGrabbarBackend::suspended() const {
    return m_suspended;
}

bool CGrabbarBackend::paused() const {
    return m_paused;
}

void CGrabbarBackend::refreshBars() {
    for (auto& b : g_pGlobalState->bars) {
        if (b)
            b->onBackendStateChanged();
    }
    for (auto& m : State::monitorState()->monitors())
        m->m_scheduledRecalc = true;
}

uint64_t CGrabbarBackend::epoch() const {
    return m_epoch;
}

const std::string& CGrabbarBackend::socketPath() const {
    return m_socketPath;
}

void CGrabbarBackend::setSuspended(bool suspended) {
    if (m_suspended == suspended)
        return;
    m_suspended = suspended;
    Log::logger->log(Log::INFO, "[grabbar] decorations {}", suspended ? "suspended" : "active");
    refreshBars();
}

// ---------------------------------------------------------------- state

bool CGrabbarBackend::isMaximized(PHLWINDOW w) const {
    if (!w)
        return false;
    return Fullscreen::controller()->getFullscreenModes(w).internal == Fullscreen::FSMODE_MAXIMIZED;
}

bool CGrabbarBackend::isMinimizable(PHLWINDOW w, std::string& why) const {
    if (!validMapped(w)) {
        why = "The window is gone";
        return false;
    }
    if (w->isX11OverrideRedirect()) {
        why = "This surface cannot be minimized";
        return false;
    }
    if (Fullscreen::controller()->getFullscreenModes(w).internal == Fullscreen::FSMODE_FULLSCREEN) {
        why = "Leave fullscreen before minimizing";
        return false;
    }
    if (w->isModal()) {
        why = "Dialogs are minimized together with their window";
        return false;
    }
    for (const auto& o : Desktop::windowState()->windows()) {
        if (o == w || !validMapped(o))
            continue;
        if (o->isModal() && o->parent() == w) {
            why = "This window cannot be minimized while its dialog is open";
            return false;
        }
    }
    return true;
}

SWindowOrigin CGrabbarBackend::captureOrigin(PHLWINDOW w) const {
    SWindowOrigin o;
    if (const auto WS = w->m_workspace; WS) {
        o.workspaceName = WS->m_name;
        o.workspaceId   = WS->m_id;
    }
    if (const auto MON = w->m_monitor.lock(); MON) {
        o.monitorName = MON->m_name;
        o.monitorId   = MON->m_id;
    }
    o.floating  = w->m_isFloating;
    o.pinned    = w->m_pinned;
    o.maximized = isMaximized(w);
    o.floatBox  = w->geometricBox(Desktop::View::IGeometric::GEOMETRIC_GOAL);
    return o;
}

PHLWORKSPACE CGrabbarBackend::ownedWorkspace(PHLMONITOR mon, bool create) {
    auto ws = State::workspaceState()->query().name(GRABBAR_WORKSPACE).run();
    if (ws || !create || !mon)
        return ws;

    const auto ID = State::workspaceState()->newSpecialID();
    ws            = State::workspaceState()->create(ID, mon->m_id, GRABBAR_WORKSPACE);
    if (!ws)
        Log::logger->log(Log::ERR, "[grabbar] could not create {}", GRABBAR_WORKSPACE);
    return ws;
}

bool CGrabbarBackend::onOwnedWorkspace(PHLWINDOW w) const {
    return w && w->m_workspace && w->m_workspace->m_name == GRABBAR_WORKSPACE;
}

size_t CGrabbarBackend::ownedCount() const {
    size_t n = 0;
    for (const auto& [_, t] : m_windows)
        if (t.owned)
            ++n;
    return n;
}

// --------------------------------------------------------------- actions

void CGrabbarBackend::requestMinimize(const std::string& token, const std::string& source) {
    auto t = tracked(token);
    auto w = resolve(token);
    if (!t || !w) {
        Log::logger->log(Log::DEBUG, "[grabbar] minimize request for stale token {}", token);
        return;
    }
    if (!minimizeEnabled()) {
        broadcastShell("notice", {{"text", "Minimize is unavailable until the restore drawer is ready"}, {"token", token}});
        Log::logger->log(Log::INFO, "[grabbar] minimize refused: no ready shell");
        return;
    }
    std::string why;
    if (!isMinimizable(w, why)) {
        broadcastShell("notice", {{"text", why}, {"token", token}});
        return;
    }
    if (t->owned)
        return;

    t->pendingRequest = std::format("n{}-{}", m_epoch, ++m_requestSeq);
    auto f            = windowFields(*t);
    f.emplace_back("requestId", t->pendingRequest);
    f.emplace_back("source", source);
    broadcastShell("minimizeRequest", f);
}

eActionStatus CGrabbarBackend::minimizeCommit(const std::string& token, const std::string& requestId, std::string& err) {
    auto t = tracked(token);
    auto w = resolve(token);
    if (!t || !w) {
        err = "stale target";
        return ACTION_STALE;
    }
    if (t->owned) {
        err = "already minimized";
        return ACTION_REFUSED;
    }
    if (requestId.empty() || t->pendingRequest != requestId) {
        err = "unknown or duplicate request";
        return ACTION_REFUSED;
    }
    t->pendingRequest.clear();

    if (!minimizeEnabled()) {
        err = "restore access unavailable";
        return ACTION_REFUSED;
    }
    if (!isMinimizable(w, err))
        return ACTION_REFUSED;
    if (ownedCount() >= GRABBAR_MAX_OWNED) {
        err = "Grabbar cannot keep track of more minimized windows";
        return ACTION_REFUSED;
    }

    auto mon = w->m_monitor.lock();
    if (!mon)
        mon = Desktop::focusState()->monitor();
    auto ws = ownedWorkspace(mon, true);
    if (!ws) {
        err = "could not prepare Grabbar's hidden workspace";
        return ACTION_FAILED;
    }

    // Leave maximized mode first so the captured floating geometry is the
    // window's own size, not the maximized one it currently shows.
    const bool WASMAXIMIZED = isMaximized(w);
    if (WASMAXIMIZED)
        (void)fullscreenWindow(Fullscreen::FSMODE_NONE, Fullscreen::FSMODE_NONE, false, w);

    t->origin           = captureOrigin(w);
    t->origin.maximized = WASMAXIMIZED;

    if (t->origin.pinned)
        (void)pinWindow(TOGGLE_ACTION_DISABLE, w);

    t->transitioning = true;
    auto r           = moveToWorkspace(ws, true, w);
    t->transitioning = false;
    if (!r || w->m_workspace != ws) {
        err = r ? "window did not move" : r.error().message;
        if (t->origin.maximized)
            (void)fullscreenWindow(Fullscreen::FSMODE_MAXIMIZED, Fullscreen::FSMODE_MAXIMIZED, false, w);
        if (t->origin.pinned)
            (void)pinWindow(TOGGLE_ACTION_ENABLE, w);
        return ACTION_FAILED;
    }

    t->owned        = true;
    t->ownerRequest = requestId;
    Log::logger->log(Log::INFO, "[grabbar] minimized {} ({}) from workspace {}", token, w->m_class, t->origin.workspaceName);
    return ACTION_OK;
}

PHLWORKSPACE CGrabbarBackend::destinationWorkspace(const STrackedWindow& t, const std::string& destination, const std::string& monitorName, std::string& note) {
    PHLMONITOR mon;
    for (const auto& m : State::monitorState()->monitors()) {
        if (m->m_name == monitorName)
            mon = m;
    }
    if (!mon)
        mon = Desktop::focusState()->monitor();

    if (destination == "original") {
        auto ws = State::workspaceState()->query().id(t.origin.workspaceId).run();
        if (!ws && !t.origin.workspaceName.empty())
            ws = State::workspaceState()->query().name(t.origin.workspaceName).run();
        if (ws && !ws->m_isSpecialWorkspace && !ws->inert())
            return ws;
        note = "original workspace no longer exists";
    }

    if (!mon)
        return nullptr;
    return mon->m_activeWorkspace;
}

bool CGrabbarBackend::returnWindow(STrackedWindow& t, PHLWORKSPACE dest, bool focus, std::string& err) {
    auto w = t.window.lock();
    if (!validMapped(w) || !dest) {
        err = "window or destination gone";
        return false;
    }

    t.transitioning = true;
    auto r          = moveToWorkspace(dest, true, w);
    if (!r || w->m_workspace != dest) {
        t.transitioning = false;
        err             = r ? "window did not return" : r.error().message;
        return false;
    }

    if (t.origin.floating) {
        if (!w->m_isFloating)
            (void)floatWindow(TOGGLE_ACTION_ENABLE, w);
        if (const auto MON = dest->m_monitor.lock(); MON) {
            // Clamp into the destination's work area (panel space excluded)
            // so the strip stays reachable (spec §5.3).
            CBox AREA = MON->logicalBoxMinusReserved();
            if (AREA.w <= 0 || AREA.h <= 0)
                AREA = MON->logicalBox();
            CBox       b    = t.origin.floatBox;
            if (b.w > 0 && b.h > 0 && AREA.w > 0 && AREA.h > 0) {
                b.w = std::min(b.w, AREA.w);
                b.h = std::min(b.h, AREA.h);
                b.x = std::clamp(b.x, AREA.x, AREA.x + AREA.w - b.w);
                b.y = std::clamp(b.y, AREA.y, AREA.y + AREA.h - b.h);
                (void)resize(b.size(), false, w);
                (void)move(b.pos(), false, w);
            }
        }
    } else if (w->m_isFloating)
        (void)floatWindow(TOGGLE_ACTION_DISABLE, w);

    if (t.origin.pinned)
        (void)pinWindow(TOGGLE_ACTION_ENABLE, w);
    if (t.origin.maximized)
        (void)fullscreenWindow(Fullscreen::FSMODE_MAXIMIZED, Fullscreen::FSMODE_MAXIMIZED, false, w);

    if (focus)
        (void)Config::Actions::focus(w);

    t.owned         = false;
    t.transitioning = false;
    t.ownerRequest.clear();
    // The shell clears its row only on a confirmed, visible return; tell it
    // whatever path brought the window back (drawer, CLI, grace, unload).
    sendWindow(m_shell, t, "restored");
    return true;
}

eActionStatus CGrabbarBackend::restore(const std::string& token, const std::string& destination, const std::string& monitorName, bool focus, std::string& err) {
    auto t = tracked(token);
    auto w = resolve(token);
    if (!t || !w) {
        err = "stale target";
        return ACTION_STALE;
    }
    if (!t->owned) {
        if (!onOwnedWorkspace(w)) {
            err = "window is already visible";
            return ACTION_REFUSED;
        }
        // Unrecorded window on Grabbar's workspace (spec §7.4 "Recovered"):
        // return it as an ordinary tiled window on the requested destination.
        t->origin = SWindowOrigin{};
        t->owned  = true;
    }
    std::string note;
    auto        dest = destinationWorkspace(*t, destination, monitorName, note);
    if (!dest) {
        err = "no destination workspace";
        return ACTION_FAILED;
    }
    if (!returnWindow(*t, dest, focus, err))
        return ACTION_FAILED;
    if (!note.empty())
        err = note;
    Log::logger->log(Log::INFO, "[grabbar] restored {} to {}", token, dest->m_name);
    return ACTION_OK;
}

eActionStatus CGrabbarBackend::setMaximized(const std::string& token, std::optional<bool> on, std::string& err) {
    auto t = tracked(token);
    auto w = resolve(token);
    if (!t || !w) {
        err = "stale target";
        return ACTION_STALE;
    }
    if (t->owned) {
        err = "window is minimized";
        return ACTION_REFUSED;
    }
    if (Fullscreen::controller()->getFullscreenModes(w).internal == Fullscreen::FSMODE_FULLSCREEN) {
        err = "window is fullscreen";
        return ACTION_REFUSED;
    }
    const bool CURRENT = isMaximized(w);
    const bool TARGET  = on.value_or(!CURRENT);
    if (CURRENT == TARGET)
        return ACTION_OK;

    auto r = TARGET ? fullscreenWindow(Fullscreen::FSMODE_MAXIMIZED, Fullscreen::FSMODE_MAXIMIZED, false, w) : fullscreenWindow(Fullscreen::FSMODE_NONE, Fullscreen::FSMODE_NONE, false, w);
    if (!r) {
        err = r.error().message;
        return ACTION_FAILED;
    }
    if (isMaximized(w) != TARGET) {
        err = "compositor did not apply the requested mode";
        return ACTION_FAILED;
    }
    onWindowChanged(w, "maximize");
    return ACTION_OK;
}

eActionStatus CGrabbarBackend::closeWindow(const std::string& token, std::string& err) {
    auto w = resolve(token);
    if (!w) {
        err = "stale target";
        return ACTION_STALE;
    }
    auto r = Config::Actions::closeWindow(w);
    if (!r) {
        err = r.error().message;
        return ACTION_FAILED;
    }
    // The window stays in the model until the compositor reports its destruction.
    return ACTION_OK;
}

eActionStatus CGrabbarBackend::setFloating(const std::string& token, std::optional<bool> on, std::string& err) {
    auto t = tracked(token);
    auto w = resolve(token);
    if (!t || !w) {
        err = "stale target";
        return ACTION_STALE;
    }
    if (t->owned) {
        err = "window is minimized";
        return ACTION_REFUSED;
    }
    const bool TARGET = on.value_or(!w->m_isFloating);
    if (TARGET == w->m_isFloating)
        return ACTION_OK;
    auto r = floatWindow(TARGET ? TOGGLE_ACTION_ENABLE : TOGGLE_ACTION_DISABLE, w);
    if (!r) {
        err = r.error().message;
        return ACTION_FAILED;
    }
    if (w->m_isFloating != TARGET) {
        err = "compositor did not change floating state";
        return ACTION_FAILED;
    }
    return ACTION_OK;
}

void CGrabbarBackend::menuRequest(const std::string& token, const Vector2D& at) {
    auto t = tracked(token);
    if (!t || !resolve(token))
        return;
    auto f = windowFields(*t);
    f.emplace_back("x", std::to_string((int)at.x));
    f.emplace_back("y", std::to_string((int)at.y));
    broadcastShell("menuRequest", f);
}

size_t CGrabbarBackend::restoreAllOwned(const char* reason) {
    size_t n = 0;
    // Returning a window fires compositor events that can erase entries
    // (a client may die mid-move), so walk a snapshot of the tokens.
    std::vector<std::string> tokens;
    for (const auto& [token, t] : m_windows)
        if (t.owned)
            tokens.push_back(token);
    for (const auto& token : tokens) {
        auto t = tracked(token);
        if (!t || !t->owned)
            continue;
        auto w = t->window.lock();
        if (!validMapped(w)) {
            t->owned = false;
            continue;
        }
        std::string note, err;
        auto        dest = destinationWorkspace(*t, "original", "", note);
        if (!dest || !returnWindow(*t, dest, false, err)) {
            Log::logger->log(Log::ERR, "[grabbar] could not return {}: {}", token, err);
            continue;
        }
        ++n;
    }
    if (n)
        Log::logger->log(Log::INFO, "[grabbar] returned {} hidden window(s): {}", n, reason);
    return n;
}

std::string CGrabbarBackend::statusText(bool json) const {
    const auto OWNEDWS = State::workspaceState()->query().name(GRABBAR_WORKSPACE).run();
    if (json)
        return std::format("{{\"version\":\"{}\",\"protocol\":{},\"epoch\":{},\"sessionId\":\"{}\",\"socket\":\"{}\",\"shellConnected\":{},\"minimizeEnabled\":{},"
                           "\"suspended\":{},\"paused\":{},\"tracked\":{},\"owned\":{},\"ownedWorkspace\":{},\"apiHash\":\"{}\"}}",
                           GRABBAR_VERSION, GRABBAR_PROTOCOL, m_epoch, m_sessionId, m_socketPath, shellConnected(), minimizeEnabled(), m_suspended, m_paused, m_windows.size(),
                           ownedCount(), OWNEDWS ? "true" : "false", __hyprland_api_get_hash());
    return std::format("Grabbar {} (protocol {})\nepoch: {}\nsocket: {}\nshell: {}\nminimize: {}\ndecorations: {}\ntracked windows: {}\nminimized (owned): {}\nowned workspace: {}\n",
                       GRABBAR_VERSION, GRABBAR_PROTOCOL, m_epoch, m_socketPath, shellConnected() ? "connected" : "disconnected", minimizeEnabled() ? "enabled" : "disabled",
                       m_paused ? "paused" : (m_suspended ? "suspended" : "active"), m_windows.size(), ownedCount(), OWNEDWS ? "present" : "absent");
}

// ------------------------------------------------------- window events

void CGrabbarBackend::onWindowOpen(PHLWINDOW w) {
    if (!w || m_stopping)
        return;
    const auto TOKEN = tokenFor(w);
    if (auto t = tracked(TOKEN); t)
        sendWindow(m_shell, *t, "open");
}

void CGrabbarBackend::onWindowClose(PHLWINDOW w) {
    if (!w || m_stopping)
        return;
    auto it = m_tokenByWindow.find((uintptr_t)w.get());
    if (it == m_tokenByWindow.end())
        return;
    const auto TOKEN = it->second;
    if (auto t = tracked(TOKEN); t) {
        auto f = windowFields(*t);
        f.emplace_back("kind", t->owned ? "destroyedWhileMinimized" : "closed");
        broadcastShell("window", f);
    }
    forgetWindow(TOKEN);
}

void CGrabbarBackend::onWindowChanged(PHLWINDOW w, const char* what) {
    if (!w || m_stopping)
        return;
    auto it = m_tokenByWindow.find((uintptr_t)w.get());
    if (it == m_tokenByWindow.end())
        return;
    auto t = tracked(it->second);
    if (!t)
        return;
    // Another tool moved a Grabbar-hidden window: release ownership rather
    // than dragging it back (spec §8.1).
    if (t->owned && !t->transitioning && !onOwnedWorkspace(w) && validMapped(w)) {
        t->owned = false;
        t->ownerRequest.clear();
        sendWindow(m_shell, *t, "released");
        return;
    }
    sendWindow(m_shell, *t, what);
    for (auto& b : g_pGlobalState->bars) {
        if (b && b->getOwner() == w)
            b->damageEntire();
    }
}

// --------------------------------------------------------------- protocol

Fields CGrabbarBackend::windowFields(const STrackedWindow& t) const {
    Fields f;
    auto   w = t.window.lock();
    f.emplace_back("token", t.token);
    f.emplace_back("owned", t.owned ? "1" : "0");
    if (!w) {
        f.emplace_back("alive", "0");
        return f;
    }
    f.emplace_back("alive", validMapped(w) ? "1" : "0");
    f.emplace_back("address", std::format("0x{:x}", (uintptr_t)w.get()));
    f.emplace_back("stableId", std::to_string(w->m_stableID));
    f.emplace_back("pid", std::to_string(t.pid));
    f.emplace_back("class", w->m_class.substr(0, 128));
    f.emplace_back("title", w->m_title.substr(0, 256));
    if (const auto WS = w->m_workspace; WS) {
        f.emplace_back("workspace", std::to_string(WS->m_id));
        f.emplace_back("workspaceName", WS->m_name);
    }
    if (const auto MON = w->m_monitor.lock(); MON) {
        f.emplace_back("monitor", MON->m_name);
        f.emplace_back("monitorId", std::to_string(MON->m_id));
    }
    f.emplace_back("floating", w->m_isFloating ? "1" : "0");
    f.emplace_back("pinned", w->m_pinned ? "1" : "0");
    f.emplace_back("maximized", isMaximized(w) ? "1" : "0");
    f.emplace_back("fullscreen", Fullscreen::controller()->getFullscreenModes(w).internal == Fullscreen::FSMODE_FULLSCREEN ? "1" : "0");
    f.emplace_back("hidden", onOwnedWorkspace(w) ? "1" : "0");
    f.emplace_back("modal", w->isModal() ? "1" : "0");
    const auto BOX = w->geometricBox(Desktop::View::IGeometric::GEOMETRIC_GOAL);
    f.emplace_back("x", std::to_string((int)BOX.x));
    f.emplace_back("y", std::to_string((int)BOX.y));
    f.emplace_back("w", std::to_string((int)BOX.w));
    f.emplace_back("h", std::to_string((int)BOX.h));
    if (t.owned) {
        f.emplace_back("originWorkspace", std::to_string(t.origin.workspaceId));
        f.emplace_back("originWorkspaceName", t.origin.workspaceName);
        f.emplace_back("originMonitor", t.origin.monitorName);
        f.emplace_back("originFloating", t.origin.floating ? "1" : "0");
        f.emplace_back("originPinned", t.origin.pinned ? "1" : "0");
        f.emplace_back("originMaximized", t.origin.maximized ? "1" : "0");
        f.emplace_back("request", t.ownerRequest);
    }
    return f;
}

void CGrabbarBackend::sendWindow(SGrabbarClient* c, const STrackedWindow& t, const char* kind) {
    if (!c)
        return;
    auto f = windowFields(t);
    f.emplace_back("kind", kind);
    send(c, "window", f);
}

void CGrabbarBackend::sendState(SGrabbarClient* c) {
    if (!c)
        return;
    send(c, "state",
         {{"shellConnected", shellConnected() ? "1" : "0"},
          {"minimizeEnabled", minimizeEnabled() ? "1" : "0"},
          {"suspended", m_suspended ? "1" : "0"},
          {"paused", m_paused ? "1" : "0"},
          {"owned", std::to_string(ownedCount())},
          {"tracked", std::to_string(m_windows.size())}});
}

void CGrabbarBackend::send(SGrabbarClient* c, const std::string& type, const Fields& fields) {
    if (!c || c->dead || c->fd < 0)
        return;
    c->outbuf += buildLine(type, fields);
    if (c->outbuf.size() > GRABBAR_MAX_OUTBUF) {
        dropClient(c, "output backlog");
        return;
    }
    flush(c);
}

void CGrabbarBackend::broadcastShell(const std::string& type, const Fields& fields) {
    if (m_shell)
        send(m_shell, type, fields);
}

void CGrabbarBackend::flush(SGrabbarClient* c) {
    if (!c || c->dead || c->fd < 0)
        return;
    while (!c->outbuf.empty()) {
        const auto n = ::send(c->fd, c->outbuf.data(), c->outbuf.size(), MSG_NOSIGNAL | MSG_DONTWAIT);
        if (n > 0) {
            c->outbuf.erase(0, n);
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            if (c->source)
                wl_event_source_fd_update(c->source, WL_EVENT_READABLE | WL_EVENT_WRITABLE);
            return;
        }
        dropClient(c, "write failed");
        return;
    }
    if (c->source)
        wl_event_source_fd_update(c->source, WL_EVENT_READABLE);
}

void CGrabbarBackend::dropClient(SGrabbarClient* c, const char* why) {
    if (!c || c->dead)
        return;
    c->dead = true;
    if (c->source) {
        wl_event_source_remove(c->source);
        c->source = nullptr;
    }
    if (c->fd >= 0) {
        close(c->fd);
        c->fd = -1;
    }
    Log::logger->log(Log::DEBUG, "[grabbar] client dropped: {}", why);
    if (c == m_shell)
        onShellLost(why);
}

void CGrabbarBackend::acceptClient() {
    while (true) {
        const int FD = accept4(m_listenFd, nullptr, nullptr, SOCK_NONBLOCK | SOCK_CLOEXEC);
        if (FD < 0)
            return;
        if (m_clients.size() >= 8) {
            close(FD);
            continue;
        }
        auto c    = makeUnique<SGrabbarClient>();
        c->fd     = FD;
        c->source = wl_event_loop_add_fd(g_pCompositor->m_wlEventLoop, FD, WL_EVENT_READABLE, ::onClientReadable, c.get());
        m_clients.emplace_back(std::move(c));
    }
}

void CGrabbarBackend::clientEvent(SGrabbarClient* c, uint32_t mask) {
    if (!c || c->dead)
        return;

    if (mask & (WL_EVENT_HANGUP | WL_EVENT_ERROR)) {
        dropClient(c, "hangup");
    } else {
        if (mask & WL_EVENT_WRITABLE)
            flush(c);

        if ((mask & WL_EVENT_READABLE) && !c->dead) {
            char buf[4096];
            while (true) {
                const auto n = ::recv(c->fd, buf, sizeof(buf), MSG_DONTWAIT);
                if (n > 0) {
                    c->inbuf.append(buf, n);
                    if (c->inbuf.size() > GRABBAR_MAX_INBUF) {
                        dropClient(c, "input too large");
                        break;
                    }
                    continue;
                }
                if (n == 0) {
                    dropClient(c, "closed");
                    break;
                }
                if (errno == EAGAIN || errno == EWOULDBLOCK)
                    break;
                dropClient(c, "read failed");
                break;
            }

            size_t nl;
            while (!c->dead && (nl = c->inbuf.find('\n')) != std::string::npos) {
                auto line = c->inbuf.substr(0, nl);
                c->inbuf.erase(0, nl + 1);
                if (line.size() > GRABBAR_MAX_LINE) {
                    dropClient(c, "line too long");
                    break;
                }
                if (!line.empty() && line.back() == '\r')
                    line.pop_back();
                if (!line.empty())
                    handleLine(c, line);
            }
        }
    }

    // Reap here only: pointers handed to the event loop stay valid until now.
    std::erase_if(m_clients, [](const auto& cl) { return cl->dead; });
}

void CGrabbarBackend::onShellLost(const char* why) {
    Log::logger->log(Log::INFO, "[grabbar] shell service lost ({}); minimize disabled, {} ms grace", why, GRABBAR_GRACE_MS);
    m_shell = nullptr;
    m_ready = false;
    if (m_graceTimer && !m_stopping)
        m_graceTimer->updateTimeout(std::chrono::milliseconds(GRABBAR_GRACE_MS));
    for (auto& b : g_pGlobalState->bars)
        if (b)
            b->damageEntire();
}

void CGrabbarBackend::onGraceExpired() {
    if (m_shell || m_stopping)
        return;
    const auto N = restoreAllOwned("shell service did not return");
    setSuspended(true);
    if (N > 0)
        HyprlandAPI::addNotification(PHANDLE, "Your windows were restored because Grabbar stopped.", CHyprColor{0.9, 0.7, 0.2, 1.0}, 6000);
}

void CGrabbarBackend::handleLine(SGrabbarClient* c, const std::string& line) {
    std::string type;
    const auto  F = parseLine(line, type);

    if (type == "hello") {
        if (field(F, "protocol") != std::to_string(GRABBAR_PROTOCOL)) {
            send(c, "error", {{"reason", "protocol"}, {"expected", std::to_string(GRABBAR_PROTOCOL)}});
            dropClient(c, "protocol mismatch");
            return;
        }
        if (field(F, "sessionId") != m_sessionId) {
            send(c, "error", {{"reason", "session"}, {"expected", m_sessionId}});
            dropClient(c, "session mismatch");
            return;
        }
        if (field(F, "client") == "shell") {
            if (m_shell && m_shell != c) {
                send(c, "error", {{"reason", "busy"}});
                return;
            }
            m_shell    = c;
            c->isShell = true;
            m_ready    = false;
            if (m_graceTimer)
                m_graceTimer->updateTimeout(std::nullopt);
            Log::logger->log(Log::INFO, "[grabbar] shell service connected");
        }
        send(c, "welcome",
             {{"protocol", std::to_string(GRABBAR_PROTOCOL)},
              {"backendEpoch", std::to_string(m_epoch)},
              {"sessionId", m_sessionId},
              {"grabbarVersion", GRABBAR_VERSION},
              {"apiHash", __hyprland_api_get_hash()},
              {"role", c->isShell ? "shell" : "observer"}});
        if (c->isShell) {
            for (const auto& [_, t] : m_windows)
                sendWindow(c, t, "snapshot");
            send(c, "snapshotEnd", {{"count", std::to_string(m_windows.size())}});
            sendState(c);
        }
        return;
    }

    if (type == "ping") {
        send(c, "pong", {{"epoch", std::to_string(m_epoch)}});
        return;
    }

    if (type == "status") {
        send(c, "status", {{"json", statusText(true)}});
        return;
    }

    if (type == "snapshot") {
        for (const auto& [_, t] : m_windows)
            sendWindow(c, t, "snapshot");
        send(c, "snapshotEnd", {{"count", std::to_string(m_windows.size())}});
        return;
    }

    if (type == "ready") {
        if (c != m_shell) {
            send(c, "error", {{"reason", "not-shell"}});
            return;
        }
        m_ready = field(F, "restoreAccess") == "1";
        setSuspended(false);
        sendState(c);
        for (auto& b : g_pGlobalState->bars)
            if (b)
                b->damageEntire();
        return;
    }

    if (type == "theme" || type == "settings" || type == "pause" || type == "resume") {
        if (c != m_shell) {
            send(c, "error", {{"reason", "not-shell"}});
            return;
        }
        if (type == "theme")
            applyTheme(F);
        else if (type == "settings")
            applySettings(F);
        else if (type == "pause") {
            // Disable Grabbar: return everything, then keep the strip off
            // and minimize refused until the shell resumes.
            const auto N = restoreAllOwned("disabled by the user");
            m_paused     = true;
            refreshBars();
            send(c, "result", {{"requestId", field(F, "requestId")}, {"action", "pause"}, {"status", "ok"}, {"error", std::to_string(N)}});
        } else {
            m_paused = false;
            refreshBars();
            send(c, "result", {{"requestId", field(F, "requestId")}, {"action", "resume"}, {"status", "ok"}, {"error", ""}});
        }
        sendState(c);
        return;
    }

    if (type == "action") {
        const auto ACTION    = field(F, "action");
        const auto TOKEN     = field(F, "windowToken");
        const auto REQUEST   = field(F, "requestId");
        std::string err;
        eActionStatus st = ACTION_REFUSED;

        if (ACTION == "minimizePrepare") {
            // Any local client may ask; only the shell can commit, after it
            // has written its prepared journal record.
            if (!minimizeEnabled()) {
                err = "restore access unavailable";
            } else {
                requestMinimize(TOKEN, c == m_shell ? "shell" : "client");
                st = ACTION_OK;
            }
        } else if (ACTION == "minimizeCommit") {
            st = c == m_shell ? minimizeCommit(TOKEN, REQUEST, err) : (err = "only the shell may minimize", ACTION_REFUSED);
        } else if (ACTION == "restore") {
            st = restore(TOKEN, field(F, "destination", "current"), field(F, "monitor"), field(F, "focus", "1") == "1", err);
        } else if (ACTION == "restoreAll") {
            const auto N = restoreAllOwned("restoreAll");
            err          = std::to_string(N);
            st           = ACTION_OK;
        } else if (ACTION == "maximize") {
            st = setMaximized(TOKEN, true, err);
        } else if (ACTION == "restoreSize") {
            st = setMaximized(TOKEN, false, err);
        } else if (ACTION == "toggleMaximize") {
            st = setMaximized(TOKEN, std::nullopt, err);
        } else if (ACTION == "close") {
            st = closeWindow(TOKEN, err);
        } else if (ACTION == "setFloating") {
            st = setFloating(TOKEN, field(F, "value") == "1", err);
        } else {
            err = "unknown action";
        }

        Fields out = {{"requestId", REQUEST}, {"action", ACTION}, {"windowToken", TOKEN}, {"status", statusName(st)}, {"error", err}};
        if (auto t = tracked(TOKEN); t && st == ACTION_OK) {
            for (auto& kv : windowFields(*t))
                out.push_back(kv);
        }
        send(c, "result", out);
        // Keep the shell's live map current whoever asked (the CLI or an
        // observer may act too). Restores already announced themselves.
        if (st == ACTION_OK && m_shell && ACTION != "restore" && ACTION != "restoreAll") {
            if (auto t = tracked(TOKEN); t)
                sendWindow(m_shell, *t, ACTION.c_str());
        }
        return;
    }

    send(c, "error", {{"reason", "unknown-message"}, {"type", type.substr(0, 32)}});
}

// ------------------------------------------------- shell-pushed appearance

static std::optional<uint64_t> parseArgb(const std::string& v) {
    // "#rrggbb", "#aarrggbb", "rrggbb" or "aarrggbb"; anything else is ignored.
    std::string hex = v;
    if (!hex.empty() && hex[0] == '#')
        hex.erase(0, 1);
    if (hex.size() != 6 && hex.size() != 8)
        return std::nullopt;
    for (unsigned char ch : hex)
        if (!std::isxdigit(ch))
            return std::nullopt;
    uint64_t val = std::stoull(hex, nullptr, 16);
    if (hex.size() == 6)
        val |= 0xff000000ull;
    return val;
}

void CGrabbarBackend::applyTheme(const Fields& f) {
    auto& t = g_pGlobalState->shell;
    auto  set = [&](const char* key, std::optional<uint64_t>& slot) {
        const auto V = field(f, key);
        if (V == "reset")
            slot.reset();
        else if (auto c = parseArgb(V); c)
            slot = c;
    };
    set("barColor", t.barColor);
    set("inactiveBarColor", t.inactiveBarColor);
    set("textColor", t.textColor);
    set("hoverColor", t.hoverColor);
    set("closeHoverColor", t.closeHoverColor);
    if (const auto FONT = field(f, "textFont"); !FONT.empty())
        t.textFont = FONT == "reset" ? std::optional<std::string>{} : std::optional<std::string>{FONT.substr(0, 64)};
    g_pGlobalState->glyphCache.clear();
    for (auto& b : g_pGlobalState->bars)
        if (b)
            b->onConfigReloaded();
}

void CGrabbarBackend::applySettings(const Fields& f) {
    auto& t = g_pGlobalState->shell;
    if (const auto V = field(f, "buttonsLeft"); !V.empty())
        t.buttonsLeft = V == "reset" ? std::optional<bool>{} : std::optional<bool>{V == "1"};
    if (const auto V = field(f, "controlSize"); !V.empty()) {
        // "standard" = 34 px strip / 32 px targets, "large" = 46 / 44 (spec §3.3).
        if (V == "large") {
            t.barHeight  = 46;
            t.buttonSize = 44;
        } else if (V == "standard") {
            t.barHeight  = 34;
            t.buttonSize = 32;
        } else {
            t.barHeight.reset();
            t.buttonSize.reset();
        }
    }
    if (const auto V = field(f, "excludedClasses"); true) {
        t.excludedClasses.clear();
        size_t start = 0;
        while (start <= V.size() && t.excludedClasses.size() < 256) {
            const auto bar  = V.find('|', start);
            auto       part = V.substr(start, bar == std::string::npos ? std::string::npos : bar - start);
            if (!part.empty())
                t.excludedClasses.push_back(part.substr(0, 128));
            if (bar == std::string::npos)
                break;
            start = bar + 1;
        }
    }
    g_pGlobalState->glyphCache.clear();
    for (auto& b : g_pGlobalState->bars) {
        if (!b)
            continue;
        b->updateRules();
        b->onConfigReloaded();
    }
    for (auto& m : State::monitorState()->monitors())
        m->m_scheduledRecalc = true;
}
