#pragma once

// Grabbar native backend — G0 feasibility prototype.
//
// Derived from Hyprbars (hyprland-plugins @ 7644cecdb947060682891a0db2a0cdc5c0b9e704,
// BSD-3-Clause, Copyright (c) 2023 Hypr Development). See docs/UPSTREAM.md and
// THIRD_PARTY_NOTICES for the retained notice and the list of changes.

#include <hyprland/src/plugins/PluginAPI.hpp>
#include <hyprland/src/render/Texture.hpp>
#include <hyprland/src/config/values/types/BoolValue.hpp>
#include <hyprland/src/config/values/types/IntValue.hpp>
#include <hyprland/src/config/values/types/StringValue.hpp>
#include <hyprland/src/config/values/types/ColorValue.hpp>

#include <map>
#include <optional>
#include <string>
#include <vector>

#define GRABBAR_VERSION       "0.1.0"
#define GRABBAR_PROTOCOL      1
#define GRABBAR_WORKSPACE     "special:grabbar-minimized"
#define GRABBAR_GRACE_MS      2000
#define GRABBAR_BOOT_OK_MS    15000 // boot guard: how long the compositor must survive with Grabbar loaded
#define GRABBAR_MAX_LINE      8192
#define GRABBAR_MAX_OUTBUF    (256 * 1024)
#define GRABBAR_MAX_INBUF     (32 * 1024)
#define GRABBAR_MAX_OWNED     256

inline HANDLE PHANDLE = nullptr;

class CGrabbarDeco;
class CGrabbarBackend;

struct SGlobalState {
    std::vector<WP<CGrabbarDeco>> bars;
    uint32_t                      nobarRuleIdx = 0;

    struct {
        SP<Config::Values::CColorValue>  barColor, inactiveBarColor, textColor, hoverColor, closeHoverColor;
        SP<Config::Values::CIntValue>    barHeight, textSize, buttonSize, padding;
        SP<Config::Values::CBoolValue>   enabled, buttonsLeft;
        SP<Config::Values::CStringValue> textFont;
    } config;

    // Values pushed by the shell service (Omarchy theme and Grabbar settings).
    // They take precedence over the config values above while set, so the
    // strip follows the desktop theme without edits to hyprland.lua.
    struct {
        std::optional<uint64_t>  barColor, inactiveBarColor, textColor, hoverColor, closeHoverColor;
        std::optional<std::string> textFont;
        std::optional<bool>      buttonsLeft;
        std::optional<int>       barHeight, buttonSize;
        std::vector<std::string> excludedClasses; // exact window class matches, from Settings
    } shell;

    // glyph textures shared by every bar, keyed by glyph + scaled size + color
    std::map<std::string, SP<Render::ITexture>> glyphCache;
};

inline UP<SGlobalState>     g_pGlobalState;
inline UP<CGrabbarBackend>  g_pBackend;
