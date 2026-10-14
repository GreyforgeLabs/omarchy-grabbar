#pragma once

// Grabbar wire codec and small pure helpers (docs/PROTOCOL.md).
//
// Standard library only, so tests/native builds and runs it under
// AddressSanitizer/UBSan without Hyprland headers. The same format is
// implemented by GrabbarModel.js (encodeField/decodeField/buildLine/parseLine)
// and helpers/grabbar_backend.py (encode/decode/build/parse).

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <utility>
#include <vector>

using Fields = std::vector<std::pair<std::string, std::string>>;

namespace grabbar {

    inline bool isHex(unsigned char c) {
        return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
    }

    inline int hexValue(unsigned char c) {
        return c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10;
    }

    // Control characters, DEL, '%', tab and newline become %XX.
    inline void appendEncoded(std::string& out, const std::string& v) {
        static constexpr char HEX[] = "0123456789ABCDEF";
        for (unsigned char c : v) {
            if (c < 0x20 || c == 0x7f || c == '%') { // tab and newline are < 0x20
                out += '%';
                out += HEX[c >> 4];
                out += HEX[c & 15];
            } else
                out += (char)c;
        }
    }

    inline std::string encode(const std::string& v) {
        std::string out;
        out.reserve(v.size());
        appendEncoded(out, v);
        return out;
    }

    inline std::string decode(const std::string& v) {
        std::string out;
        out.reserve(v.size());
        for (size_t i = 0; i < v.size(); ++i) {
            if (v[i] == '%' && i + 2 < v.size() && isHex(v[i + 1]) && isHex(v[i + 2])) {
                out += (char)((hexValue(v[i + 1]) << 4) | hexValue(v[i + 2]));
                i += 2;
            } else
                out += v[i];
        }
        return out;
    }

    // One message: type, then key=value fields, tab-separated, newline-terminated.
    // Appends to `out` directly so a send costs no temporary strings.
    inline void appendLine(std::string& out, const std::string& type, const Fields& fields) {
        out += type;
        for (const auto& [k, v] : fields) {
            out += '\t';
            out += k;
            out += '=';
            appendEncoded(out, v);
        }
        out += '\n';
    }

    inline std::string buildLine(const std::string& type, const Fields& fields) {
        std::string line;
        appendLine(line, type, fields);
        return line;
    }

    inline Fields parseLine(const std::string& line, std::string& type) {
        Fields fields;
        size_t start = 0;
        bool   first = true;
        while (true) {
            const size_t tab = line.find('\t', start);
            const size_t end = tab == std::string::npos ? line.size() : tab;
            if (first) {
                type.assign(line, start, end - start);
                first = false;
            } else if (end > start) {
                const size_t eq = line.find('=', start);
                if (eq == std::string::npos || eq >= end)
                    fields.emplace_back(line.substr(start, end - start), "");
                else
                    fields.emplace_back(line.substr(start, eq - start), decode(line.substr(eq + 1, end - eq - 1)));
            }
            if (tab == std::string::npos)
                break;
            start = tab + 1;
        }
        return fields;
    }

    inline std::string field(const Fields& f, const char* key, const char* def = "") {
        for (const auto& [k, v] : f)
            if (k == key)
                return v;
        return def;
    }

    // "#rrggbb", "#aarrggbb", "rrggbb" or "aarrggbb"; anything else is rejected.
    inline std::optional<uint64_t> parseArgb(const std::string& v) {
        size_t start = !v.empty() && v[0] == '#' ? 1 : 0;
        size_t len   = v.size() - start;
        if (len != 6 && len != 8)
            return std::nullopt;
        uint64_t val = 0;
        for (size_t i = start; i < v.size(); ++i) {
            if (!isHex(v[i]))
                return std::nullopt;
            val = (val << 4) | (uint64_t)hexValue(v[i]);
        }
        if (len == 6)
            val |= 0xff000000ull;
        return val;
    }

    // Settings → excluded classes: '|'-separated, empty parts dropped, each
    // bounded to 128 bytes, at most 256 entries.
    inline std::vector<std::string> splitClasses(const std::string& v) {
        std::vector<std::string> out;
        size_t                   start = 0;
        while (start <= v.size() && out.size() < 256) {
            const auto bar = v.find('|', start);
            const auto end = bar == std::string::npos ? v.size() : bar;
            if (end > start)
                out.emplace_back(v, start, std::min<size_t>(end - start, 128));
            if (bar == std::string::npos)
                break;
            start = bar + 1;
        }
        return out;
    }

    // ------------------------------------------------------- strip layout

    enum eButton : int8_t {
        BUTTON_NONE = -1,
        BUTTON_MENU = 0,
        BUTTON_MINIMIZE,
        BUTTON_MAXIMIZE,
        BUTTON_CLOSE,
    };

    struct SSlot {
        eButton id = BUTTON_NONE;
        double  x = 0, y = 0, w = 0, h = 0; // logical px, relative to the strip's top-left

        bool    contains(double px, double py) const {
            return px >= x && px < x + w && py >= y && py < y + h;
        }
    };

    // At most four targets; fixed storage, so layout costs no allocation on
    // the per-frame and per-pointer-motion paths.
    struct SSlots {
        std::array<SSlot, 4> slot{};
        size_t               count = 0;

        void                 push(eButton id, double x, double y, double s) {
            slot[count++] = SSlot{id, x, y, s, s};
        }
        const SSlot* begin() const {
            return slot.data();
        }
        const SSlot* end() const {
            return slot.data() + count;
        }
    };

    // Window menu target on the leading edge (trailing when the controls are
    // on the left), Minimize / Maximize / Close on the other. A narrow strip
    // keeps only the menu target (spec §3.3); a strip narrower than one target
    // has none.
    inline SSlots layoutSlots(double barW, double barH, int size, int pad, bool left) {
        SSlots       s;
        const double y      = std::floor((barH - size) / 2.0);
        const bool   NARROW = barW < pad * 2 + size * 4 + 24;
        if (NARROW && barW < pad * 2 + size)
            return s;

        if (!left) {
            if (!NARROW) {
                double x = barW - pad - size * 3;
                for (auto b : {BUTTON_MINIMIZE, BUTTON_MAXIMIZE, BUTTON_CLOSE}) {
                    s.push(b, x, y, size);
                    x += size;
                }
            }
            s.push(BUTTON_MENU, pad, y, size);
        } else {
            if (!NARROW) {
                double x = pad;
                for (auto b : {BUTTON_CLOSE, BUTTON_MINIMIZE, BUTTON_MAXIMIZE}) {
                    s.push(b, x, y, size);
                    x += size;
                }
            }
            s.push(BUTTON_MENU, barW - pad - size, y, size);
        }
        return s;
    }

    inline eButton buttonAt(const SSlots& slots, double px, double py) {
        for (const auto& s : slots)
            if (s.contains(px, py))
                return s.id;
        return BUTTON_NONE;
    }

    // Glyph texture cache key: button, maximized flag, pixel size and RGBA.
    inline uint64_t glyphKey(int button, bool maximized, int px, uint32_t rgba) {
        return ((uint64_t)rgba << 32) | ((uint64_t)(uint16_t)px << 8) | ((uint64_t)(maximized ? 1 : 0) << 7) | (uint64_t)(uint8_t)(button & 0x7f);
    }
}
