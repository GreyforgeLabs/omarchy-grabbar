#pragma once

// The Grabbar backend: live window identities, typed window actions, the
// owned hidden workspace, the private shell socket, and disconnect recovery.
//
// Nothing in here builds a shell command or resolves an action against the
// focused window. Every action takes a token, and a token that no longer maps
// to the same live window produces ACTION_STALE.

#include "globals.hpp"

#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/helpers/math/Math.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>

#include <wayland-server-core.h>

#include <deque>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

enum eActionStatus : uint8_t {
    ACTION_OK = 0,
    ACTION_STALE,   // token expired, reused, or the window is gone
    ACTION_REFUSED, // valid target, but the operation is not allowed right now (explained)
    ACTION_FAILED,  // compositor did not end up in the requested state
};

struct SWindowOrigin {
    std::string workspaceName;
    WORKSPACEID workspaceId = WORKSPACE_INVALID;
    std::string monitorName;
    MONITORID   monitorId = MONITOR_INVALID;
    bool        floating  = false;
    bool        pinned    = false;
    bool        maximized = false;
    CBox        floatBox; // goal geometry when floating
};

struct STrackedWindow {
    std::string   token;
    PHLWINDOWREF  window;
    uint64_t      stableId = 0;
    pid_t         pid      = 0;
    bool          owned    = false; // currently hidden on Grabbar's workspace by Grabbar
    std::string   ownerRequest;     // requestId of the minimize that hid it
    std::string   pendingRequest;   // minimize request awaiting the shell's commit
    bool          transitioning = false; // Grabbar itself is moving it right now
    SWindowOrigin origin;
};

using Fields = std::vector<std::pair<std::string, std::string>>;

struct SGrabbarClient {
    int              fd     = -1;
    wl_event_source* source = nullptr;
    std::string      inbuf;
    std::string      outbuf;
    bool             isShell = false;
    bool             dead    = false;
};

class CGrabbarBackend {
  public:
    CGrabbarBackend();
    ~CGrabbarBackend();

    bool                start();
    void                stop(bool restoreOwned, const char* reason);

    // identity
    std::string         tokenFor(PHLWINDOW w); // registers on first sight
    PHLWINDOW           resolve(const std::string& token);
    STrackedWindow*     tracked(const std::string& token);

    // readiness
    bool                shellConnected() const;
    bool                minimizeEnabled() const;
    bool                suspended() const; // no shell after the grace period: decorations off
    bool                paused() const;    // Disable requested by the shell
    uint64_t            epoch() const;
    const std::string&  socketPath() const;

    // actions (deco + protocol share these)
    void                requestMinimize(const std::string& token, const std::string& source);
    eActionStatus       minimizeCommit(const std::string& token, const std::string& requestId, std::string& err);
    eActionStatus       restore(const std::string& token, const std::string& destination, const std::string& monitorName, bool focus, std::string& err);
    eActionStatus       setMaximized(const std::string& token, std::optional<bool> on, std::string& err);
    eActionStatus       closeWindow(const std::string& token, std::string& err);
    eActionStatus       setFloating(const std::string& token, std::optional<bool> on, std::string& err);
    void                menuRequest(const std::string& token, const Vector2D& at);
    size_t              restoreAllOwned(const char* reason);
    size_t              ownedCount() const;
    bool                isMaximized(PHLWINDOW w) const;
    bool                isMinimizable(PHLWINDOW w, std::string& why) const;

    std::string         statusText(bool json) const;

    // compositor events
    void                onWindowOpen(PHLWINDOW w);
    void                onWindowClose(PHLWINDOW w);
    void                onWindowChanged(PHLWINDOW w, const char* what);
    // Another tool (a taskbar, a window switcher, `focuswindow`) focused a
    // hidden window or opened Grabbar's workspace: treat it as a restore.
    void                onOwnedWindowActivated(PHLWINDOW w);
    void                onOwnedWorkspaceRevealed(PHLMONITOR mon);

    // called from the wayland event loop
    void                acceptClient();
    void                clientEvent(SGrabbarClient* c, uint32_t mask);
    void                onGraceExpired();

  private:
    std::string                            m_socketPath;
    std::string                            m_sessionId;
    uint64_t                               m_epoch      = 0;
    uint64_t                               m_generation = 0;
    uint64_t                               m_requestSeq = 0;
    int                                    m_listenFd   = -1;
    wl_event_source*                       m_listenSource = nullptr;
    std::vector<UP<SGrabbarClient>>        m_clients;
    SGrabbarClient*                        m_shell = nullptr;
    bool                                   m_ready = false;     // shell confirmed restore access
    bool                                   m_suspended = true;  // no handshake yet, or grace expired
    bool                                   m_stopping  = false;
    bool                                   m_paused    = false; // shell asked for Disable: no controls, no new minimize
    SP<CEventLoopTimer>                    m_graceTimer;
    bool                                   m_revealPending = false;
    void                                   handleReveal();
    std::unordered_map<std::string, STrackedWindow> m_windows; // token -> tracked
    std::unordered_map<uintptr_t, std::string>      m_tokenByWindow;

    PHLWORKSPACE                           ownedWorkspace(PHLMONITOR mon, bool create);
    bool                                   onOwnedWorkspace(PHLWINDOW w) const;
    PHLWORKSPACE                           destinationWorkspace(const STrackedWindow& t, const std::string& destination, const std::string& monitorName, std::string& note);
    bool                                   returnWindow(STrackedWindow& t, PHLWORKSPACE dest, bool focus, std::string& err);
    SWindowOrigin                          captureOrigin(PHLWINDOW w) const;
    void                                   forgetWindow(const std::string& token);

    // protocol
    void                                   send(SGrabbarClient* c, const std::string& type, const Fields& fields);
    void                                   broadcastShell(const std::string& type, const Fields& fields);
    void                                   flush(SGrabbarClient* c);
    void                                   dropClient(SGrabbarClient* c, const char* why);
    void                                   handleLine(SGrabbarClient* c, const std::string& line);
    Fields                                 windowFields(const STrackedWindow& t) const;
    void                                   sendWindow(SGrabbarClient* c, const STrackedWindow& t, const char* kind);
    void                                   sendState(SGrabbarClient* c);
    void                                   onShellLost(const char* why);
    void                                   setSuspended(bool suspended);
    void                                   applyTheme(const Fields& f);
    void                                   applySettings(const Fields& f);
    void                                   refreshBars();
};

// protocol helpers (also used by tests)
std::string grabbarEncode(const std::string& v);
std::string grabbarDecode(const std::string& v);
