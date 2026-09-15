#pragma once

// The Grabbar title strip: a reserved top decoration with a window-menu
// target, an ellipsized title, and Minimize / Maximize-Restore / Close.
//
// Derived from Hyprbars' CHyprBar (BSD-3-Clause, Hypr Development). Grabbar
// changes: buttons act on release inside the same target with the window
// identity captured at press; actions go through typed backend calls instead
// of `exec`; dragging respects the drag threshold and detaches tiled windows;
// the strip is suspended while no shell service is connected.

#define WLR_USE_UNSTABLE

#include <hyprland/src/render/decorations/IHyprWindowDecoration.hpp>
#include <hyprland/src/render/OpenGL.hpp>
#include <hyprland/src/render/gl/GLTexture.hpp>
#include <hyprland/src/devices/IPointer.hpp>
#include <hyprland/src/desktop/rule/windowRule/WindowRule.hpp>
#include <hyprland/src/helpers/AnimatedVariable.hpp>
#include <hyprland/src/helpers/time/Time.hpp>
#include <hyprland/src/helpers/signal/Signal.hpp>

#include "globals.hpp"

#define private public
#include <hyprland/src/managers/input/InputManager.hpp>
#undef private

namespace Event {
    struct SCallbackInfo;
}

enum eGrabbarButton : int8_t {
    BTN_NONE = -1,
    BTN_MENU = 0,
    BTN_MINIMIZE,
    BTN_MAXIMIZE,
    BTN_CLOSE,
};

struct SButtonSlot {
    eGrabbarButton id = BTN_NONE;
    CBox           box; // logical pixels, relative to the strip's top-left
};

class CGrabbarDeco : public IHyprWindowDecoration {
  public:
    CGrabbarDeco(PHLWINDOW);
    virtual ~CGrabbarDeco();

    virtual SDecorationPositioningInfo getPositioningInfo();
    virtual void                       onPositioningReply(const SDecorationPositioningReply& reply);
    virtual void                       draw(PHLMONITOR, float const& a);
    virtual eDecorationType            getDecorationType();
    virtual void                       updateWindow(PHLWINDOW);
    virtual void                       damageEntire();
    virtual eDecorationLayer           getDecorationLayer();
    virtual uint64_t                   getDecorationFlags();
    virtual std::string                getDisplayName();

    PHLWINDOW                          getOwner();
    void                               updateRules();
    void                               onConfigReloaded();
    void                               onBackendStateChanged();
    void                               renderPass(PHLMONITOR, float const& a);
    CBox                               assignedBoxGlobal();

    WP<CGrabbarDeco>                   m_self;

  private:
    PHLWINDOWREF               m_window;
    CBox                       m_assignedBox;
    SP<Render::ITexture>       m_textTex;
    std::string                m_lastTitle;
    int                        m_lastTitleWidth = -1;
    bool                       m_windowSizeChanged = false;
    bool                       m_hidden            = false; // rule grabbar:no_bar
    bool                       m_lastEffectiveEnabled = false;
    bool                       m_windowHasFocus       = false;
    int                        m_lastHeight           = 0;

    // input state
    eGrabbarButton             m_pressedButton = BTN_NONE;
    eGrabbarButton             m_hoverButton   = BTN_NONE;
    std::string                m_pressToken;
    Vector2D                   m_pressPos;      // global coords at press
    Vector2D                   m_pressOffset;   // press position relative to the strip
    Time::steady_tp            m_lastTitlePress = Time::steadyNow();
    bool                       m_lastPressWasTitle = false;
    bool                       m_dragPending  = false;
    bool                       m_dragging     = false;
    bool                       m_cancelledDown = false;

    PHLANIMVAR<CHyprColor>     m_realBarColor;

    CHyprSignalListener        m_mouseButtonCallback;
    CHyprSignalListener        m_mouseMoveCallback;

    bool                       effectiveEnabled();
    bool                       inputIsValid();
    Vector2D                   cursorRelativeToBar();
    std::vector<SButtonSlot>   layoutButtons(double barW, double barH);
    eGrabbarButton             buttonAt(const Vector2D& rel);
    void                       onMouseButton(Event::SCallbackInfo& info, IPointer::SButtonEvent e);
    void                       onMouseMove(Vector2D coords);
    void                       handleDownEvent(Event::SCallbackInfo& info);
    void                       handleUpEvent(Event::SCallbackInfo& info);
    void                       startDrag();
    void                       endDrag();
    void                       activate(eGrabbarButton b, const std::string& token);
    void                       renderTitle(const Vector2D& bufferSize, float scale, int maxWidth);
    SP<Render::ITexture>       glyph(eGrabbarButton b, bool maximized, int size, const CHyprColor& color);

    friend class CGrabbarPassElement;
};
