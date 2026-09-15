#define WLR_USE_UNSTABLE

#include <unistd.h>

#include <any>
#include <algorithm>
#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/config/ConfigManager.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/desktop/rule/windowRule/WindowRuleEffectContainer.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/debug/HyprCtl.hpp>

#include <hyprland/src/managers/eventLoop/EventLoopManager.hpp>
#include <hyprland/src/managers/eventLoop/EventLoopTimer.hpp>
#include <filesystem>
#include <fstream>

#include "bar.hpp"
#include "backend.hpp"
#include "globals.hpp"

// Boot guard (native/autoload.lua, docs/AUTOLOAD.md): once the compositor has
// kept running with Grabbar loaded for GRABBAR_BOOT_OK_MS, record this
// instance's signature so the next start is allowed to declare the plugin.
static SP<CEventLoopTimer> g_bootOkTimer;

static std::string autoloadStateDir() {
    const char* S = getenv("GRABBAR_STATE_DIR");
    if (S && *S)
        return std::string(S) + "/autoload";
    const char* X = getenv("XDG_STATE_HOME");
    if (X && *X)
        return std::string(X) + "/grabbar/autoload";
    const char* H = getenv("HOME");
    return std::string(H ? H : "") + "/.local/state/grabbar/autoload";
}

static void writeBootOk() {
    try {
        const auto DIR = autoloadStateDir();
        std::filesystem::create_directories(DIR);
        std::ofstream f(DIR + "/last-ok.tmp", std::ios::trunc);
        f << g_pCompositor->m_instanceSignature << "\n";
        f.close();
        std::filesystem::rename(DIR + "/last-ok.tmp", DIR + "/last-ok");
    } catch (...) { /* the guard then stays conservative: next start is skipped and reported */ }
}

// Do NOT change this function.
APICALL EXPORT std::string PLUGIN_API_VERSION() {
    return HYPRLAND_API_VERSION;
}

static void onNewWindow(PHLWINDOW window) {
    if (!window || window->m_X11DoesntWantBorders)
        return;

    g_pBackend->onWindowOpen(window);

    if (std::ranges::any_of(window->m_windowDecorations, [](const auto& d) { return d->getDisplayName() == "Grabbar"; }))
        return;

    auto bar = makeUnique<CGrabbarDeco>(window);
    g_pGlobalState->bars.emplace_back(bar);
    bar->m_self = bar;
    HyprlandAPI::addWindowDecoration(PHANDLE, window, std::move(bar));
}

static void onConfigReloaded() {
    g_pGlobalState->glyphCache.clear();
    for (auto& b : g_pGlobalState->bars) {
        if (!b)
            continue;
        b->onConfigReloaded();
    }
}

static void onUpdateWindowRules(PHLWINDOW window) {
    const auto BARIT = std::ranges::find_if(g_pGlobalState->bars, [window](const auto& bar) { return bar && bar->getOwner() == window; });

    if (BARIT == g_pGlobalState->bars.end())
        return;

    (*BARIT)->updateRules();
    window->updateWindowDecos();
}

APICALL EXPORT PLUGIN_DESCRIPTION_INFO PLUGIN_INIT(HANDLE handle) {
    PHANDLE = handle;

    const std::string HASH        = __hyprland_api_get_hash();
    const std::string CLIENT_HASH = __hyprland_api_get_client_hash();

    if (HASH != CLIENT_HASH) {
        HyprlandAPI::addNotification(PHANDLE, "[grabbar] Grabbar needs an update for this desktop version (native build does not match the running Hyprland)",
                                     CHyprColor{1.0, 0.2, 0.2, 1.0}, 8000);
        throw std::runtime_error("[grabbar] Version mismatch");
    }

    g_pGlobalState               = makeUnique<SGlobalState>();
    g_pGlobalState->nobarRuleIdx = Desktop::Rule::windowEffects()->registerEffect("grabbar:no_bar");

    auto& cfg              = g_pGlobalState->config;
    cfg.enabled            = makeShared<Config::Values::CBoolValue>("plugin:grabbar:enabled", "Whether Grabbar strips are enabled", true);
    cfg.buttonsLeft        = makeShared<Config::Values::CBoolValue>("plugin:grabbar:buttons_left", "Place the control group on the leading edge", false);
    cfg.barHeight          = makeShared<Config::Values::CIntValue>("plugin:grabbar:bar_height", "Strip height in logical pixels", 34);
    cfg.buttonSize         = makeShared<Config::Values::CIntValue>("plugin:grabbar:button_size", "Button target size in logical pixels", 32);
    cfg.padding            = makeShared<Config::Values::CIntValue>("plugin:grabbar:padding", "Horizontal padding in logical pixels", 4);
    cfg.textSize           = makeShared<Config::Values::CIntValue>("plugin:grabbar:text_size", "Title text size", 11);
    cfg.textFont           = makeShared<Config::Values::CStringValue>("plugin:grabbar:text_font", "Title font family", "Sans");
    cfg.barColor           = makeShared<Config::Values::CColorValue>("plugin:grabbar:bar_color", "Strip color for the focused window", 0xff2a2f36);
    cfg.inactiveBarColor   = makeShared<Config::Values::CColorValue>("plugin:grabbar:inactive_bar_color", "Strip color for unfocused windows", 0xff20242a);
    cfg.textColor          = makeShared<Config::Values::CColorValue>("plugin:grabbar:text_color", "Title and glyph color", 0xffe6e9ee);
    cfg.hoverColor         = makeShared<Config::Values::CColorValue>("plugin:grabbar:hover_color", "Hovered button background", 0x40ffffff);
    cfg.closeHoverColor    = makeShared<Config::Values::CColorValue>("plugin:grabbar:close_hover_color", "Hovered Close background", 0xd0c0392b);

    const std::vector<SP<Config::Values::IValue>> VALUES = {cfg.enabled,  cfg.buttonsLeft, cfg.barHeight,        cfg.buttonSize, cfg.padding,    cfg.textSize,
                                                            cfg.textFont, cfg.barColor,    cfg.inactiveBarColor, cfg.textColor,  cfg.hoverColor, cfg.closeHoverColor};
    for (const auto& v : VALUES)
        HyprlandAPI::addConfigValueV2(PHANDLE, v);

    g_pBackend = makeUnique<CGrabbarBackend>();
    if (!g_pBackend->start()) {
        HyprlandAPI::addNotification(PHANDLE, "[grabbar] could not create the private backend socket; Grabbar stays inactive", CHyprColor{1.0, 0.5, 0.2, 1.0}, 8000);
        g_pBackend.reset();
        throw std::runtime_error("[grabbar] socket setup failed");
    }

    static auto P1 = Event::bus()->m_events.window.open.listen([&](PHLWINDOW w) { onNewWindow(w); });
    static auto P2 = Event::bus()->m_events.window.updateRules.listen([&](PHLWINDOW w) { onUpdateWindowRules(w); });
    static auto P3 = Event::bus()->m_events.window.close.listen([&](PHLWINDOW w) { g_pBackend->onWindowClose(w); });
    static auto P4 = Event::bus()->m_events.window.title.listen([&](PHLWINDOW w) { g_pBackend->onWindowChanged(w, "title"); });
    static auto P5 = Event::bus()->m_events.window.fullscreen.listen([&](PHLWINDOW w) { g_pBackend->onWindowChanged(w, "fullscreen"); });
    static auto P6 = Event::bus()->m_events.window.floating.listen([&](PHLWINDOW w) { g_pBackend->onWindowChanged(w, "floating"); });
    static auto P7 = Event::bus()->m_events.window.pin.listen([&](PHLWINDOW w) { g_pBackend->onWindowChanged(w, "pin"); });
    static auto P8 = Event::bus()->m_events.window.moveToWorkspace.listen([&](PHLWINDOW w, PHLWORKSPACE) { g_pBackend->onWindowChanged(w, "workspace"); });
    static auto P9 = Event::bus()->m_events.config.reloaded.listen([&] { onConfigReloaded(); });

    static auto CMD = HyprlandAPI::registerHyprCtlCommand(PHANDLE, SHyprCtlCommand{.name = "grabbar", .exact = true, .fn = [](eHyprCtlOutputFormat fmt, std::string) {
                                                                                        return g_pBackend ? g_pBackend->statusText(fmt == FORMAT_JSON) : std::string("inactive");
                                                                                    }});

    for (auto& w : Desktop::windowState()->windows()) {
        if (w->isHidden() || !w->m_isMapped)
            continue;
        onNewWindow(w);
    }

    g_bootOkTimer = makeShared<CEventLoopTimer>(std::chrono::milliseconds(GRABBAR_BOOT_OK_MS), [](SP<CEventLoopTimer> self, void*) {
        writeBootOk();
        g_pEventLoopManager->removeTimer(self);
        g_bootOkTimer.reset();
    }, nullptr);
    g_pEventLoopManager->addTimer(g_bootOkTimer);

    // No HyprlandAPI::reloadConfig() here (Hyprbars does this): CPluginSystem::
    // loadPluginInternal already schedules a config reload after init returns,
    // and a second one only adds reload churn. Every extra reload matters when
    // the plugin is declared from the config itself (see docs/AUTOLOAD.md).

    return {"grabbar", "Familiar window controls for Omarchy.", "Greyforge Labs", GRABBAR_VERSION};
}

APICALL EXPORT void PLUGIN_EXIT() {
    if (g_bootOkTimer) {
        g_pEventLoopManager->removeTimer(g_bootOkTimer);
        g_bootOkTimer.reset();
    }
    // Return every Grabbar-hidden window before native references go away (spec §7.5).
    if (g_pBackend)
        g_pBackend->stop(true, "unload");

    for (auto& m : State::monitorState()->monitors())
        m->m_scheduledRecalc = true;

    g_pHyprRenderer->m_renderPass.removeAllOfType("CGrabbarPassElement");

    if (g_pGlobalState)
        Desktop::Rule::windowEffects()->unregisterEffect(g_pGlobalState->nobarRuleIdx);

    g_pBackend.reset();
}
