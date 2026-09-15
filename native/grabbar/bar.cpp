#include "bar.hpp"

#include <hyprland/src/Compositor.hpp>
#include <hyprland/src/desktop/state/FocusState.hpp>
#include <hyprland/src/desktop/state/WindowState.hpp>
#include <hyprland/src/desktop/state/LayerState.hpp>
#include <hyprland/src/desktop/state/ViewHitTester.hpp>
#include <hyprland/src/desktop/view/Window.hpp>
#include <hyprland/src/desktop/view/LayerSurface.hpp>
#include <hyprland/src/helpers/MiscFunctions.hpp>
#include <hyprland/src/managers/SeatManager.hpp>
#include <hyprland/src/managers/KeybindManager.hpp>
#include <hyprland/src/managers/input/InputManager.hpp>
#include <hyprland/src/render/Renderer.hpp>
#include <hyprland/src/config/ConfigManager.hpp>
#include <hyprland/src/config/ConfigValue.hpp>
#include <hyprland/src/config/shared/animation/AnimationTree.hpp>
#include <hyprland/src/config/shared/parserUtils/ParserUtils.hpp>
#include <hyprland/src/config/shared/actions/ConfigActions.hpp>
#include <hyprland/src/animation/AnimationManager.hpp>
#include <hyprland/src/protocols/LayerShell.hpp>
#include <hyprland/src/event/EventBus.hpp>
#include <hyprland/src/layout/LayoutManager.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/state/MonitorState.hpp>
#include <hyprland/src/debug/log/Logger.hpp>

#include "backend.hpp"
#include "pass.hpp"

#include <cairo/cairo.h>

#include <climits>
#include <cmath>
#include <format>

using namespace Render::GL;

static CHyprColor configColor(Config::INTEGER color) {
    return CHyprColor{static_cast<uint64_t>(color)};
}

// Appearance values: what the shell pushed (Omarchy theme / Settings) wins
// over the plugin:grabbar:* config values.
namespace {
    CHyprColor colorOf(const std::optional<uint64_t>& pushed, const SP<Config::Values::CColorValue>& cfg) {
        return pushed ? CHyprColor{*pushed} : configColor(cfg->value());
    }
    int barHeightValue() {
        const auto& S = g_pGlobalState->shell;
        return std::clamp<int>(S.barHeight.value_or(g_pGlobalState->config.barHeight->value()), 0, 200);
    }
    int buttonSizeValue() {
        const auto& S = g_pGlobalState->shell;
        return std::clamp<int>(S.buttonSize.value_or(g_pGlobalState->config.buttonSize->value()), 24, 64);
    }
    bool buttonsLeftValue() {
        const auto& S = g_pGlobalState->shell;
        return S.buttonsLeft.value_or(g_pGlobalState->config.buttonsLeft->value());
    }
    std::string textFontValue() {
        const auto& S = g_pGlobalState->shell;
        return S.textFont.value_or(g_pGlobalState->config.textFont->value());
    }
}

// Control glyphs are drawn as paths (spec §3.3): no icon font is needed and
// they stay crisp at every output scale. `px` is the glyph box in buffer
// pixels; strokes are ~1/8 of it with round caps.
static SP<Render::ITexture> drawGlyph(eGrabbarButton b, bool maximized, int px, const CHyprColor& color) {
    px = std::max(px, 4);
    auto* surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, px, px);
    auto* cr      = cairo_create(surface);
    cairo_set_operator(cr, CAIRO_OPERATOR_CLEAR);
    cairo_paint(cr);
    cairo_set_operator(cr, CAIRO_OPERATOR_OVER);
    cairo_set_source_rgba(cr, color.r, color.g, color.b, color.a);
    const double S = px;
    const double W = std::max(1.0, std::round(S / 8.0));
    cairo_set_line_width(cr, W);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    const double m = std::round(S * 0.18) + 0.5; // margin
    const double e = S - m;                       // far edge
    switch (b) {
        case BTN_MENU:
            cairo_set_line_width(cr, std::max(1.0, std::round(S / 10.0)));
            for (double y : {S * 0.24, S * 0.5, S * 0.76}) {
                cairo_move_to(cr, m, std::round(y) + 0.5);
                cairo_line_to(cr, e, std::round(y) + 0.5);
            }
            cairo_stroke(cr);
            break;
        case BTN_MINIMIZE:
            cairo_move_to(cr, m, std::round(S * 0.58) + 0.5);
            cairo_line_to(cr, e, std::round(S * 0.58) + 0.5);
            cairo_stroke(cr);
            break;
        case BTN_MAXIMIZE:
            if (!maximized) {
                cairo_rectangle(cr, m, m, e - m, e - m);
                cairo_stroke(cr);
            } else {
                // Restore size: two offset squares, the front one complete.
                const double off = std::round(S * 0.16);
                cairo_rectangle(cr, m, m + off, e - m - off, e - m - off);
                cairo_stroke(cr);
                cairo_move_to(cr, m + off, m + off);
                cairo_line_to(cr, m + off, m);
                cairo_line_to(cr, e, m);
                cairo_line_to(cr, e, e - off);
                cairo_line_to(cr, e - off, e - off);
                cairo_stroke(cr);
            }
            break;
        case BTN_CLOSE:
            cairo_move_to(cr, m, m);
            cairo_line_to(cr, e, e);
            cairo_move_to(cr, e, m);
            cairo_line_to(cr, m, e);
            cairo_stroke(cr);
            break;
        default: break;
    }
    cairo_surface_flush(surface);
    auto tex = g_pHyprRenderer->createTexture(surface);
    cairo_destroy(cr);
    cairo_surface_destroy(surface);
    return tex;
}

CGrabbarDeco::CGrabbarDeco(PHLWINDOW pWindow) : IHyprWindowDecoration(pWindow) {
    m_window = pWindow;

    if (const auto PMONITOR = pWindow->m_monitor.lock(); PMONITOR)
        PMONITOR->m_scheduledRecalc = true;

    m_mouseButtonCallback = Event::bus()->m_events.input.mouse.button.listen([this](IPointer::SButtonEvent e, Event::SCallbackInfo& info) { onMouseButton(info, e); });
    m_mouseMoveCallback   = Event::bus()->m_events.input.mouse.move.listen([this](Vector2D c, Event::SCallbackInfo& info) { onMouseMove(c); });

    Animation::mgr()->createAnimation(colorOf(g_pGlobalState->shell.barColor, g_pGlobalState->config.barColor), m_realBarColor,
                                      Config::animationTree()->getAnimationPropertyConfig("border"), pWindow, AVARDAMAGE_NONE);
    m_realBarColor->setUpdateCallback([this](auto) { damageEntire(); });
}

CGrabbarDeco::~CGrabbarDeco() {
    std::erase(g_pGlobalState->bars, m_self);
}

bool CGrabbarDeco::effectiveEnabled() {
    if (!g_pGlobalState->config.enabled->value() || m_hidden || !g_pBackend || g_pBackend->suspended() || g_pBackend->paused())
        return false;
    // A `nodecoration` window rule means no strip and no reserved space.
    const auto PWINDOW = m_window.lock();
    if (PWINDOW && !PWINDOW->m_ruleApplicator->decorate().valueOrDefault())
        return false;
    return true;
}

SDecorationPositioningInfo CGrabbarDeco::getPositioningInfo() {
    const auto                 HEIGHT  = barHeightValue();
    const bool                 ENABLED = effectiveEnabled();

    SDecorationPositioningInfo info;
    info.policy         = ENABLED ? DECORATION_POSITION_STICKY : DECORATION_POSITION_ABSOLUTE;
    info.edges          = DECORATION_EDGE_TOP;
    info.priority       = 5000;
    info.reserved       = true;
    info.desiredExtents = {{0, ENABLED ? HEIGHT : 0}, {0, 0}};
    return info;
}

void CGrabbarDeco::onPositioningReply(const SDecorationPositioningReply& reply) {
    if (reply.assignedGeometry.size() != m_assignedBox.size())
        m_windowSizeChanged = true;

    m_assignedBox = reply.assignedGeometry;
}

std::string CGrabbarDeco::getDisplayName() {
    return "Grabbar";
}

// ----------------------------------------------------------------- layout

std::vector<SButtonSlot> CGrabbarDeco::layoutButtons(double barW, double barH) {
    const int  SIZE = buttonSizeValue();
    const int  PAD  = std::clamp<int>(g_pGlobalState->config.padding->value(), 0, 32);
    const bool LEFT = buttonsLeftValue();
    const double y  = std::floor((barH - SIZE) / 2.0);

    std::vector<SButtonSlot> slots;

    // Narrow window: keep only the window-menu target (spec §3.3).
    const bool NARROW = barW < PAD * 2 + SIZE * 4 + 24;

    if (!LEFT) {
        if (!NARROW) {
            double x = barW - PAD - SIZE * 3;
            for (auto b : {BTN_MINIMIZE, BTN_MAXIMIZE, BTN_CLOSE}) {
                slots.push_back({b, CBox{x, y, (double)SIZE, (double)SIZE}});
                x += SIZE;
            }
        }
        slots.push_back({BTN_MENU, CBox{(double)PAD, y, (double)SIZE, (double)SIZE}});
    } else {
        if (!NARROW) {
            double x = PAD;
            for (auto b : {BTN_CLOSE, BTN_MINIMIZE, BTN_MAXIMIZE}) {
                slots.push_back({b, CBox{x, y, (double)SIZE, (double)SIZE}});
                x += SIZE;
            }
        }
        slots.push_back({BTN_MENU, CBox{barW - PAD - SIZE, y, (double)SIZE, (double)SIZE}});
    }

    if (NARROW && barW < PAD * 2 + SIZE)
        slots.clear();

    return slots;
}

eGrabbarButton CGrabbarDeco::buttonAt(const Vector2D& rel) {
    const auto BOX = assignedBoxGlobal();
    for (const auto& s : layoutButtons(BOX.w, BOX.h)) {
        if (s.box.containsPoint(rel))
            return s.id;
    }
    return BTN_NONE;
}

// ------------------------------------------------------------------ input

bool CGrabbarDeco::inputIsValid() {
    if (!effectiveEnabled())
        return false;

    const auto PWINDOW = m_window.lock();
    if (!validMapped(PWINDOW))
        return false;

    if (g_pSeatManager->m_seatGrab && !g_pSeatManager->m_seatGrab->accepts(PWINDOW->wlSurface()->resource()))
        return false;

    const auto MOUSE    = g_pInputManager->getMouseCoordsInternal();
    auto       PMONITOR = Desktop::focusState()->monitor();

    if (!PMONITOR)
        return false;

    Desktop::CViewHitTester hitTester{*Desktop::viewState()};

    const auto WINDOWATCURSOR = hitTester.windowAt(MOUSE, Desktop::View::RESERVED_EXTENTS | Desktop::View::INPUT_EXTENTS | Desktop::View::ALLOW_FLOATING);

    if (WINDOWATCURSOR != PWINDOW && PWINDOW != Desktop::focusState()->window())
        return false;

    PHLLS    foundSurface = nullptr;
    Vector2D surfaceCoords;

    hitTester.layerSurfaceAt(MOUSE, &PMONITOR->m_layerSurfaceLayers[ZWLR_LAYER_SHELL_V1_LAYER_TOP], &surfaceCoords, &foundSurface);
    if (foundSurface)
        return false;

    hitTester.layerSurfaceAt(MOUSE, &PMONITOR->m_layerSurfaceLayers[ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY], &surfaceCoords, &foundSurface);
    if (foundSurface)
        return false;

    return true;
}

void CGrabbarDeco::onMouseButton(Event::SCallbackInfo& info, IPointer::SButtonEvent e) {
    if (e.button != BTN_LEFT) {
        // A drag in progress ends on any release so a stray button cannot
        // leave the window glued to the pointer.
        if (e.state != WL_POINTER_BUTTON_STATE_PRESSED && m_dragging)
            endDrag();
        // Secondary click anywhere on the strip opens the window menu: the
        // same text actions as the menu button (spec §3.4).
        if (e.button == BTN_RIGHT && e.state == WL_POINTER_BUTTON_STATE_PRESSED && !m_dragging && !m_dragPending && inputIsValid()) {
            const auto BOX    = assignedBoxGlobal();
            const auto COORDS = cursorRelativeToBar();
            if (VECINRECT(COORDS, 0, 0, BOX.w, BOX.h - 1)) {
                const auto PWINDOW = m_window.lock();
                if (Desktop::focusState()->window() != PWINDOW)
                    Desktop::focusState()->fullWindowFocus(PWINDOW, Desktop::FOCUS_REASON_CLICK);
                info.cancelled = true;
                g_pBackend->menuRequest(g_pBackend->tokenFor(PWINDOW), g_pInputManager->getMouseCoordsInternal());
            }
        }
        return;
    }

    if (e.state != WL_POINTER_BUTTON_STATE_PRESSED) {
        // Release is handled even when the pointer left the strip: that is
        // exactly how "press Close, drag away, release" cancels.
        if (m_pressedButton != BTN_NONE || m_dragPending || m_dragging || m_cancelledDown)
            handleUpEvent(info);
        return;
    }

    if (!inputIsValid())
        return;

    handleDownEvent(info);
}

void CGrabbarDeco::handleDownEvent(Event::SCallbackInfo& info) {
    const auto PWINDOW = m_window.lock();
    if (!validMapped(PWINDOW))
        return;

    const auto BOX    = assignedBoxGlobal();
    const auto COORDS = cursorRelativeToBar();

    if (!VECINRECT(COORDS, 0, 0, BOX.w, BOX.h - 1)) {
        if (m_dragging)
            endDrag();
        m_dragPending   = false;
        m_pressedButton = BTN_NONE;
        return;
    }

    if (Desktop::focusState()->window() != PWINDOW)
        Desktop::focusState()->fullWindowFocus(PWINDOW, Desktop::FOCUS_REASON_CLICK);

    if (PWINDOW->m_isFloating)
        Desktop::windowState()->raise(PWINDOW);

    info.cancelled  = true;
    m_cancelledDown = true;

    const auto TOKEN = g_pBackend->tokenFor(PWINDOW);
    const auto BTN   = buttonAt(COORDS);

    if (BTN != BTN_NONE) {
        m_pressedButton     = BTN;
        m_pressToken        = TOKEN;
        m_lastPressWasTitle = false;
        m_dragPending       = false;
        damageEntire();
        return;
    }

    // Title region: double-click toggles Maximize / Restore size, otherwise a
    // drag may start once the pointer travels past the threshold.
    const auto NOW = Time::steadyNow();
    const bool DOUBLE =
        m_lastPressWasTitle && std::chrono::duration_cast<std::chrono::milliseconds>(NOW - m_lastTitlePress).count() < 400;

    m_lastTitlePress    = NOW;
    m_lastPressWasTitle = true;
    m_pressedButton     = BTN_NONE;
    m_pressToken        = TOKEN;

    if (DOUBLE) {
        m_lastPressWasTitle = false;
        m_dragPending       = false;
        std::string err;
        g_pBackend->setMaximized(TOKEN, std::nullopt, err);
        return;
    }

    m_pressPos    = g_pInputManager->getMouseCoordsInternal();
    m_pressOffset = COORDS;
    m_dragPending = true;
}

void CGrabbarDeco::handleUpEvent(Event::SCallbackInfo& info) {
    if (m_cancelledDown)
        info.cancelled = true;
    m_cancelledDown = false;

    if (m_pressedButton != BTN_NONE) {
        const auto BTN   = m_pressedButton;
        const auto TOKEN = m_pressToken;
        m_pressedButton  = BTN_NONE;
        m_pressToken.clear();
        damageEntire();

        // Act only when released inside the same target on the same window.
        if (buttonAt(cursorRelativeToBar()) == BTN && inputIsValid()) {
            if (g_pBackend->resolve(TOKEN))
                activate(BTN, TOKEN);
            else
                Log::logger->log(Log::DEBUG, "[grabbar] release ignored: stale target {}", TOKEN);
        } else
            Log::logger->log(Log::DEBUG, "[grabbar] release outside target: cancelled");
    }

    if (m_dragging)
        endDrag();

    m_dragPending = false;
}

void CGrabbarDeco::onMouseMove(Vector2D coords) {
    if (!validMapped(m_window))
        return;

    // Hover feedback, only when this strip is what the pointer is really over
    // (an overlapping floating window or a layer surface must not light it up).
    auto HB = effectiveEnabled() ? buttonAt(cursorRelativeToBar()) : BTN_NONE;
    if (HB != BTN_NONE && !inputIsValid())
        HB = BTN_NONE;
    if (HB != m_hoverButton) {
        m_hoverButton = HB;
        damageEntire();
    }

    if (!m_dragPending || m_dragging)
        return;

    static auto PDRAGTHRESHOLD = CConfigValue<Config::INTEGER>("binds:drag_threshold");
    const double THRESHOLD     = *PDRAGTHRESHOLD > 0 ? (double)*PDRAGTHRESHOLD : 6.0;

    const auto MOUSE = g_pInputManager->getMouseCoordsInternal();
    if ((MOUSE - m_pressPos).size() < THRESHOLD)
        return;

    m_dragPending = false;
    startDrag();
}

void CGrabbarDeco::startDrag() {
    const auto PWINDOW = m_window.lock();
    if (!validMapped(PWINDOW))
        return;

    if (!g_pBackend->resolve(m_pressToken))
        return;

    std::string err;
    const auto  OLDSIZE   = PWINDOW->size(Desktop::View::IGeometric::GEOMETRIC_GOAL);
    bool        reposition = false;

    // Dragging a maximized window first gives it a usable size (spec §4.4).
    if (g_pBackend->isMaximized(PWINDOW)) {
        g_pBackend->setMaximized(m_pressToken, false, err);
        reposition = PWINDOW->m_isFloating;
    }

    // Dragging a tiled window detaches it into floating mode, then follows
    // the pointer (spec §4.4).
    if (!PWINDOW->m_isFloating) {
        (void)Config::Actions::floatWindow(Config::Actions::TOGGLE_ACTION_ENABLE, PWINDOW);
        reposition = true;
    }

    if (reposition) {
        // Keep the strip under the pointer so the native move grabs this
        // window and not whatever the layout put there, keep the pointer over
        // the same proportional point of the strip, and keep the strip inside
        // the work area.
        const auto MOUSE = g_pInputManager->getMouseCoordsInternal();
        auto       size  = PWINDOW->size(Desktop::View::IGeometric::GEOMETRIC_GOAL);
        CBox       area  = {0, 0, 0, 0};
        if (const auto MON = PWINDOW->m_monitor.lock(); MON) {
            area = MON->logicalBoxMinusReserved();
            if (area.w <= 0 || area.h <= 0)
                area = MON->logicalBox();
        }

        // A window that filled its layout slot gets a usable floating size.
        if (area.w > 0 && area.h > 0 && (size.x > area.w * 0.8 || size.y > area.h * 0.8)) {
            size = Vector2D{std::round(area.w * 0.6), std::round(area.h * 0.6)};
            (void)Config::Actions::resize(size, false, PWINDOW);
        }

        const double ratio  = OLDSIZE.x > 0 ? std::clamp(m_pressOffset.x / OLDSIZE.x, 0.0, 1.0) : 0.5;
        Vector2D     target = {MOUSE.x - ratio * size.x, MOUSE.y - m_pressOffset.y};
        if (area.w > 0 && area.h > 0) {
            target.x = std::clamp(target.x, area.x, std::max(area.x, area.x + area.w - size.x));
            target.y = std::clamp(target.y, area.y, std::max(area.y, area.y + area.h - 40.0));
        }
        (void)Config::Actions::move(target, false, PWINDOW);
    }

    g_pKeybindManager->changeMouseBindMode(MBIND_MOVE);
    m_dragging = true;
    Log::logger->log(Log::DEBUG, "[grabbar] drag started on {}", m_pressToken);
}

void CGrabbarDeco::endDrag() {
    g_pKeybindManager->changeMouseBindMode(MBIND_INVALID);
    m_dragging = false;
    Log::logger->log(Log::DEBUG, "[grabbar] drag ended");
}

// `token` was captured at press and re-validated at release: the action
// targets that window even if focus moved meanwhile (spec §4.1, test F02).
void CGrabbarDeco::activate(eGrabbarButton b, const std::string& token) {
    std::string err;
    eActionStatus st = ACTION_OK;
    switch (b) {
        case BTN_MINIMIZE: g_pBackend->requestMinimize(token, "bar"); break;
        case BTN_MAXIMIZE: st = g_pBackend->setMaximized(token, std::nullopt, err); break;
        case BTN_CLOSE: st = g_pBackend->closeWindow(token, err); break;
        case BTN_MENU: g_pBackend->menuRequest(token, g_pInputManager->getMouseCoordsInternal()); break;
        default: break;
    }
    if (st != ACTION_OK)
        Log::logger->log(Log::WARN, "[grabbar] action {} failed: {} ({})", (int)b, err, (int)st);
}

// -------------------------------------------------------------- rendering

SP<Render::ITexture> CGrabbarDeco::glyph(eGrabbarButton b, bool maximized, int size, const CHyprColor& color) {
    const auto KEY  = std::format("{}:{}:{}:{:x}", (int)b, maximized ? 1 : 0, size, color.getAsHex());
    auto&      slot = g_pGlobalState->glyphCache[KEY];
    if (!slot || slot->m_texID == 0)
        slot = drawGlyph(b, maximized, size, color);
    return slot;
}

void CGrabbarDeco::renderTitle(const Vector2D& bufferSize, const float scale, int maxWidth) {
    const auto COLOR = colorOf(g_pGlobalState->shell.textColor, g_pGlobalState->config.textColor);
    const auto SIZE  = std::clamp<int>(g_pGlobalState->config.textSize->value(), 6, 40);
    const auto FONT  = textFontValue();

    if (m_lastTitle.empty() || maxWidth < 8) {
        m_textTex = nullptr;
        return;
    }

    m_textTex = g_pHyprRenderer->renderText(m_lastTitle, COLOR, std::round(SIZE * scale), false, FONT, maxWidth);
}

void CGrabbarDeco::draw(PHLMONITOR pMonitor, const float& a) {
    const bool ENABLED = effectiveEnabled();

    if (m_lastEffectiveEnabled != ENABLED) {
        m_lastEffectiveEnabled = ENABLED;
        g_pDecorationPositioner->repositionDeco(this);
    }

    if (!ENABLED || !validMapped(m_window))
        return;

    auto data = CGrabbarPassElement::SBarData{this, a};
    g_pHyprRenderer->m_renderPass.add(makeUnique<CGrabbarPassElement>(data));
}

void CGrabbarDeco::renderPass(PHLMONITOR pMonitor, const float& a) {
    const auto PWINDOW = m_window.lock();
    if (!PWINDOW)
        return;

    const auto HEIGHT = barHeightValue();

    const bool FOCUSED = PWINDOW == Desktop::focusState()->window();
    m_windowHasFocus   = FOCUSED;

    const CHyprColor DEST_COLOR = FOCUSED ? colorOf(g_pGlobalState->shell.barColor, g_pGlobalState->config.barColor) :
                                            colorOf(g_pGlobalState->shell.inactiveBarColor, g_pGlobalState->config.inactiveBarColor);
    if (DEST_COLOR != m_realBarColor->goal())
        *m_realBarColor = DEST_COLOR;

    CHyprColor color = m_realBarColor->value();
    color.a *= a;

    if (HEIGHT < 1) {
        m_lastHeight = HEIGHT;
        return;
    }

    const auto PWORKSPACE      = PWINDOW->m_workspace;
    const auto WORKSPACEOFFSET = PWORKSPACE && !PWINDOW->m_pinned ? PWORKSPACE->m_renderOffset->value() : Vector2D();

    const auto ROUNDING       = PWINDOW->rounding() + PWINDOW->getRealBorderSize();
    const auto scaledRounding = ROUNDING > 0 ? ROUNDING * pMonitor->m_scale - 2 : 0;

    const auto DECOBOX = assignedBoxGlobal();
    const auto BARBUF  = DECOBOX.size() * pMonitor->m_scale;

    CBox titleBarBox = {DECOBOX.x - pMonitor->m_position.x, DECOBOX.y - pMonitor->m_position.y, DECOBOX.w, DECOBOX.h + ROUNDING * 3};
    titleBarBox.translate(PWINDOW->m_floatingOffset).scale(pMonitor->m_scale).round();

    if (titleBarBox.w < 1 || titleBarBox.h < 1)
        return;

    g_pHyprOpenGL->scissor(titleBarBox);

    if (ROUNDING) {
        CBox windowBox = {PWINDOW->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT).x + PWINDOW->m_floatingOffset.x - pMonitor->m_position.x + 1,
                          PWINDOW->position(Desktop::View::IGeometric::GEOMETRIC_CURRENT).y + PWINDOW->m_floatingOffset.y - pMonitor->m_position.y + 1,
                          PWINDOW->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT).x - 2, PWINDOW->size(Desktop::View::IGeometric::GEOMETRIC_CURRENT).y - 2};

        if (windowBox.w < 1 || windowBox.h < 1)
            return;

        glClearStencil(0);
        glClear(GL_STENCIL_BUFFER_BIT);
        g_pHyprOpenGL->setCapStatus(GL_STENCIL_TEST, true);
        glStencilFunc(GL_ALWAYS, 1, -1);
        glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
        glColorMask(GL_FALSE, GL_FALSE, GL_FALSE, GL_FALSE);

        windowBox.translate(WORKSPACEOFFSET).scale(pMonitor->m_scale).round();
        g_pHyprOpenGL->renderRect(windowBox, CHyprColor(0, 0, 0, 0), {.round = (int)scaledRounding, .roundingPower = PWINDOW->roundingPower()});
        glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);

        glStencilFunc(GL_NOTEQUAL, 1, -1);
        glStencilOp(GL_KEEP, GL_KEEP, GL_REPLACE);
    }

    g_pHyprOpenGL->renderRect(titleBarBox, color, {.round = (int)scaledRounding, .roundingPower = PWINDOW->roundingPower()});

    if (ROUNDING) {
        glClearStencil(0);
        glClear(GL_STENCIL_BUFFER_BIT);
        g_pHyprOpenGL->setCapStatus(GL_STENCIL_TEST, false);
        glStencilMask(-1);
        glStencilFunc(GL_ALWAYS, 1, 0xFF);
    }

    // buttons (logical layout, scaled at draw time)
    const auto  SLOTS      = layoutButtons(DECOBOX.w, DECOBOX.h);
    const float SCALE      = pMonitor->m_scale;
    const bool  MAXIMIZED  = g_pBackend->isMaximized(PWINDOW);
    const bool  MINENABLED = g_pBackend->minimizeEnabled();
    const auto  TEXTCOL    = colorOf(g_pGlobalState->shell.textColor, g_pGlobalState->config.textColor);
    const bool  LEFT       = buttonsLeftValue();
    // Main glyph about 14–16 px at standard size, 18–20 px at large (spec §3.3).
    const int   GLYPHSIZE  = std::round(std::clamp<int>(std::lround(buttonSizeValue() * 0.44), 12, 24) * SCALE);

    double occupiedLeft = 0, occupiedRight = 0;

    for (const auto& s : SLOTS) {
        CBox b = s.box;
        b.translate(Vector2D{titleBarBox.x / SCALE, titleBarBox.y / SCALE}).scale(SCALE).round();

        if (s.id == BTN_MENU && !LEFT)
            occupiedLeft = std::max(occupiedLeft, s.box.x + s.box.w);
        else if (s.id == BTN_MENU)
            occupiedRight = std::max(occupiedRight, DECOBOX.w - s.box.x);
        else if (LEFT)
            occupiedLeft = std::max(occupiedLeft, s.box.x + s.box.w);
        else
            occupiedRight = std::max(occupiedRight, DECOBOX.w - s.box.x);

        const bool HOVER   = m_hoverButton == s.id && m_pressedButton == BTN_NONE;
        const bool PRESSED = m_pressedButton == s.id && m_hoverButton == s.id;

        if (HOVER || PRESSED) {
            auto hc = s.id == BTN_CLOSE ? colorOf(g_pGlobalState->shell.closeHoverColor, g_pGlobalState->config.closeHoverColor) :
                                          colorOf(g_pGlobalState->shell.hoverColor, g_pGlobalState->config.hoverColor);
            hc.a *= a * (PRESSED ? 1.0 : 0.8);
            CBox inset = b;
            inset.expand(-2 * SCALE);
            g_pHyprOpenGL->renderRect(inset, hc, {.round = (int)std::round(6 * SCALE), .roundingPower = 2.F});
        }

        auto glyphColor = TEXTCOL;
        if (s.id == BTN_MINIMIZE && !MINENABLED)
            glyphColor.a *= 0.35;
        if (!FOCUSED)
            glyphColor.a *= 0.75;

        // Close keeps full contrast on its own hover treatment.
        if (s.id == BTN_CLOSE && (HOVER || PRESSED))
            glyphColor = CHyprColor{1.0F, 1.0F, 1.0F, static_cast<float>(TEXTCOL.a)};
        const auto TEX = glyph(s.id, MAXIMIZED, GLYPHSIZE, glyphColor);
        if (TEX && TEX->m_texID != 0) {
            CBox pos = {b.x + (b.w - TEX->m_size.x) / 2.0, b.y + (b.h - TEX->m_size.y) / 2.0, (double)TEX->m_size.x, (double)TEX->m_size.y};
            pos.round();
            g_pHyprOpenGL->renderTexture(TEX, pos, {.a = a});
        }
    }

    // title
    const int PAD      = g_pGlobalState->config.padding->value();
    const int maxWidth = std::max<int>(0, std::round((DECOBOX.w - occupiedLeft - occupiedRight - PAD * 2) * SCALE));

    if (m_lastTitle != PWINDOW->m_title || m_windowSizeChanged || !m_textTex || m_textTex->m_texID == 0 || m_lastTitleWidth != maxWidth) {
        m_lastTitle      = PWINDOW->m_title;
        m_lastTitleWidth = maxWidth;
        renderTitle(BARBUF, SCALE, maxWidth);
    }

    if (m_textTex && m_textTex->m_texID != 0 && maxWidth > 8) {
        const double areaX = titleBarBox.x + occupiedLeft * SCALE + PAD * SCALE;
        const double areaW = maxWidth;
        const double x     = std::round(areaX + (areaW - m_textTex->m_size.x) / 2.0);
        const double y     = std::round(titleBarBox.y + (BARBUF.y - m_textTex->m_size.y) / 2.0);
        CBox         titleBox = {x, y, (double)m_textTex->m_size.x, (double)m_textTex->m_size.y};
        auto         ta       = a;
        if (!FOCUSED)
            ta *= 0.75;
        g_pHyprOpenGL->renderTexture(m_textTex, titleBox, {.a = ta});
    }

    g_pHyprOpenGL->scissor(nullptr);

    m_windowSizeChanged = false;

    if (m_lastHeight != HEIGHT) {
        PWINDOW->layoutTarget()->recalc();
        m_lastHeight = HEIGHT;
    }
}

eDecorationType CGrabbarDeco::getDecorationType() {
    return DECORATION_CUSTOM;
}

void CGrabbarDeco::updateWindow(PHLWINDOW pWindow) {
    damageEntire();
}

void CGrabbarDeco::onConfigReloaded() {
    m_textTex = nullptr;
    g_pDecorationPositioner->repositionDeco(this);
    damageEntire();
}

void CGrabbarDeco::onBackendStateChanged() {
    g_pDecorationPositioner->repositionDeco(this);
    if (const auto PWINDOW = m_window.lock(); validMapped(PWINDOW)) {
        if (const auto PMONITOR = PWINDOW->m_monitor.lock(); PMONITOR)
            PMONITOR->m_scheduledRecalc = true;
    }
    damageEntire();
}

void CGrabbarDeco::damageEntire() {
    g_pHyprRenderer->damageBox(assignedBoxGlobal());
}

Vector2D CGrabbarDeco::cursorRelativeToBar() {
    return g_pInputManager->getMouseCoordsInternal() - assignedBoxGlobal().pos();
}

eDecorationLayer CGrabbarDeco::getDecorationLayer() {
    return DECORATION_LAYER_UNDER;
}

uint64_t CGrabbarDeco::getDecorationFlags() {
    return DECORATION_ALLOWS_MOUSE_INPUT | DECORATION_PART_OF_MAIN_WINDOW;
}

CBox CGrabbarDeco::assignedBoxGlobal() {
    if (!validMapped(m_window))
        return {};

    CBox box = m_assignedBox;
    box.translate(g_pDecorationPositioner->getEdgeDefinedPoint(DECORATION_EDGE_TOP, m_window.lock()));

    const auto PWORKSPACE      = m_window->m_workspace;
    const auto WORKSPACEOFFSET = PWORKSPACE && !m_window->m_pinned ? PWORKSPACE->m_renderOffset->value() : Vector2D();

    return box.translate(WORKSPACEOFFSET);
}

PHLWINDOW CGrabbarDeco::getOwner() {
    return m_window.lock();
}

void CGrabbarDeco::updateRules() {
    const auto PWINDOW    = m_window.lock();
    const auto prevHidden = m_hidden;

    m_hidden = false;

    if (!PWINDOW)
        return;

    if (PWINDOW->m_ruleApplicator->m_otherProps.props.contains(g_pGlobalState->nobarRuleIdx))
        m_hidden = truthy(PWINDOW->m_ruleApplicator->m_otherProps.props.at(g_pGlobalState->nobarRuleIdx)->effect);

    // Settings → Excluded applications: matched on the window class (never
    // on the title, spec §3.4).
    for (const auto& cls : g_pGlobalState->shell.excludedClasses) {
        if (cls == PWINDOW->m_class || cls == PWINDOW->m_initialClass) {
            m_hidden = true;
            break;
        }
    }

    if (prevHidden != m_hidden)
        g_pDecorationPositioner->repositionDeco(this);
}
