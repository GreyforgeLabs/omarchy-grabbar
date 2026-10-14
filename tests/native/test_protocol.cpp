// Native codec and strip-layout tests. Standard library only: built by
// tests/native/run.sh with AddressSanitizer and UBSan, no Hyprland needed.

#include "../../native/grabbar/protocol.hpp"

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <new>
#include <set>
#include <string>
#include <vector>

static size_t g_allocs = 0;

void* operator new(size_t n) {
    ++g_allocs;
    if (void* p = std::malloc(n ? n : 1))
        return p;
    throw std::bad_alloc();
}
void operator delete(void* p) noexcept {
    std::free(p);
}
void operator delete(void* p, size_t) noexcept {
    std::free(p);
}

static int g_passed = 0;
#define CHECK(cond)                                                                                                                                                                \
    do {                                                                                                                                                                           \
        if (!(cond)) {                                                                                                                                                             \
            std::fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);                                                                                                   \
            std::exit(1);                                                                                                                                                          \
        }                                                                                                                                                                          \
    } while (0)
#define TEST(name) static void name()
#define RUN(name)                                                                                                                                                                  \
    do {                                                                                                                                                                           \
        name();                                                                                                                                                                    \
        ++g_passed;                                                                                                                                                                \
    } while (0)

using namespace grabbar;

// Deterministic xorshift so failures reproduce.
static uint64_t g_seed = 0x9e3779b97f4a7c15ull;
static uint64_t rnd() {
    g_seed ^= g_seed << 13;
    g_seed ^= g_seed >> 7;
    g_seed ^= g_seed << 17;
    return g_seed;
}
static std::string randomBytes(size_t maxLen, const char* alphabet = nullptr) {
    std::string s(rnd() % (maxLen + 1), '\0');
    for (auto& c : s)
        c = alphabet ? alphabet[rnd() % std::char_traits<char>::length(alphabet)] : (char)(rnd() & 0xff);
    return s;
}

TEST(codec_matches_js_and_python_vectors) {
    // Same vectors as tests/unit/test_model.js and test_protocol.py.
    const std::string nasty = "a\tb\nc%deé ✕ ≡  z";
    CHECK(decode(encode(nasty)) == nasty);
    CHECK(encode(nasty).find('\t') == std::string::npos && encode(nasty).find('\n') == std::string::npos);
    const auto LINE = buildLine("action", {{"requestId", "r1"}, {"windowToken", "g1-2"}, {"action", "restore"}, {"title", "x\ty=z"}});
    CHECK(LINE == "action\trequestId=r1\twindowToken=g1-2\taction=restore\ttitle=x%09y=z\n");
    std::string type;
    auto        f = parseLine(LINE.substr(0, LINE.size() - 1), type);
    CHECK(type == "action" && f.size() == 4 && f[3].first == "title" && f[3].second == "x\ty=z");
    f = parseLine("pong\t\tflag\tepoch=7", type);
    CHECK(type == "pong" && f.size() == 2 && f[0] == std::make_pair(std::string("flag"), std::string("")) && f[1].second == "7");
    CHECK(encode("%\x7f\x01") == "%25%7F%01");
}

TEST(decode_edge_cases) {
    CHECK(decode("%") == "%");
    CHECK(decode("%4") == "%4");
    CHECK(decode("%41") == "A");
    CHECK(decode("a%4") == "a%4");
    CHECK(decode("%zz%41") == "%zzA");
    CHECK(decode("%00") == std::string(1, '\0'));
    CHECK(decode("%e9") == "\xe9");
    CHECK(decode("%%41") == "%A");
}

TEST(round_trip_every_byte_and_fuzz) {
    std::string all;
    for (int i = 0; i < 256; ++i)
        all += (char)i;
    CHECK(decode(encode(all)) == all);
    for (int i = 0; i < 20000; ++i) {
        const auto S = randomBytes(64);
        const auto E = encode(S);
        CHECK(decode(E) == S);
        CHECK(E.find('\t') == std::string::npos && E.find('\n') == std::string::npos);
        // Arbitrary input must never crash the decoder or the line parser.
        (void)decode(randomBytes(32, "%0aF\tz="));
        std::string type;
        (void)parseLine(randomBytes(96, "ab=%\t\n4F"), type);
    }
}

TEST(lines_round_trip) {
    for (int i = 0; i < 2000; ++i) {
        Fields in;
        const int N = rnd() % 6;
        for (int k = 0; k < N; ++k)
            in.emplace_back("k" + std::to_string(k), randomBytes(24));
        auto        line = buildLine("window", in);
        std::string type;
        CHECK(line.back() == '\n' && line.find('\n') == line.size() - 1);
        line.pop_back();
        const auto OUT = parseLine(line, type);
        CHECK(type == "window" && OUT == in);
        std::string appended = "prefix";
        appendLine(appended, "window", in);
        CHECK(appended == "prefix" + line + "\n");
    }
}

TEST(field_lookup) {
    const Fields F = {{"a", "1"}, {"b", ""}};
    CHECK(field(F, "a") == "1" && field(F, "b", "x").empty() && field(F, "c") == "" && field(F, "c", "current") == "current");
}

TEST(argb_parsing) {
    CHECK(parseArgb("#112233") == 0xff112233ull);
    CHECK(parseArgb("80112233") == 0x80112233ull);
    CHECK(parseArgb("#AbCdEf") == 0xffabcdefull);
    CHECK(!parseArgb(""));
    CHECK(!parseArgb("#"));
    CHECK(!parseArgb("#12345"));
    CHECK(!parseArgb("#1234567"));
    CHECK(!parseArgb("#11223g"));
    CHECK(!parseArgb("##112233"));
    CHECK(!parseArgb("reset"));
    CHECK(!parseArgb("rgba(1,2,3,4)"));
}

TEST(excluded_classes_are_bounded) {
    CHECK(splitClasses("").empty());
    CHECK((splitClasses("a||b|") == std::vector<std::string>{"a", "b"}));
    CHECK(splitClasses(std::string(300, 'x'))[0].size() == 128);
    std::string many;
    for (int i = 0; i < 300; ++i)
        many += "c" + std::to_string(i) + "|";
    const auto V = splitClasses(many);
    CHECK(V.size() == 256 && V.front() == "c0" && V.back() == "c255");
}

// The layout before it moved into protocol.hpp, kept as the reference.
struct SRefSlot {
    eButton id;
    double  x, y, w, h;
};
static std::vector<SRefSlot> referenceLayout(double barW, double barH, int SIZE, int PAD, bool LEFT) {
    const double          y = std::floor((barH - SIZE) / 2.0);
    std::vector<SRefSlot> slots;
    const bool            NARROW = barW < PAD * 2 + SIZE * 4 + 24;
    if (!LEFT) {
        if (!NARROW) {
            double x = barW - PAD - SIZE * 3;
            for (auto b : {BUTTON_MINIMIZE, BUTTON_MAXIMIZE, BUTTON_CLOSE}) {
                slots.push_back({b, x, y, (double)SIZE, (double)SIZE});
                x += SIZE;
            }
        }
        slots.push_back({BUTTON_MENU, (double)PAD, y, (double)SIZE, (double)SIZE});
    } else {
        if (!NARROW) {
            double x = PAD;
            for (auto b : {BUTTON_CLOSE, BUTTON_MINIMIZE, BUTTON_MAXIMIZE}) {
                slots.push_back({b, x, y, (double)SIZE, (double)SIZE});
                x += SIZE;
            }
        }
        slots.push_back({BUTTON_MENU, barW - PAD - SIZE, y, (double)SIZE, (double)SIZE});
    }
    if (NARROW && barW < PAD * 2 + SIZE)
        slots.clear();
    return slots;
}

TEST(layout_matches_reference) {
    for (double w = 0; w <= 400; w += 3.5)
        for (int size : {24, 32, 44, 64})
            for (int pad : {0, 4, 32})
                for (bool left : {false, true}) {
                    const auto REF = referenceLayout(w, 34, size, pad, left);
                    const auto NEW = layoutSlots(w, 34, size, pad, left);
                    CHECK(REF.size() == NEW.count);
                    for (size_t i = 0; i < NEW.count; ++i) {
                        const auto& a = REF[i];
                        const auto& b = NEW.slot[i];
                        CHECK(a.id == b.id && a.x == b.x && a.y == b.y && a.w == b.w && a.h == b.h);
                    }
                }
    const auto R = layoutSlots(500, 34, 32, 4, false);
    CHECK(R.count == 4 && buttonAt(R, 500 - 4 - 1, 10) == BUTTON_CLOSE && buttonAt(R, 5, 10) == BUTTON_MENU && buttonAt(R, 200, 10) == BUTTON_NONE);
    CHECK(buttonAt(R, 500 - 4, 10) == BUTTON_NONE); // right edge is exclusive, like CBox::containsPoint
    const auto L = layoutSlots(500, 34, 32, 4, true);
    CHECK(buttonAt(L, 4, 1) == BUTTON_CLOSE && buttonAt(L, 499 - 4, 1) == BUTTON_MENU);
    CHECK(layoutSlots(100, 34, 32, 4, false).count == 1); // narrow: menu only
    CHECK(layoutSlots(30, 34, 32, 4, false).count == 0);  // narrower than one target
}

TEST(layout_and_hit_testing_do_not_allocate) {
    const size_t BEFORE = g_allocs;
    int          hits   = 0;
    for (int i = 0; i < 1000; ++i) {
        const auto S = layoutSlots(400 + i % 7, 34, 32, 4, i & 1);
        hits += buttonAt(S, i % 400, 17) != BUTTON_NONE;
    }
    CHECK(g_allocs == BEFORE && hits > 0);
    // The vector layout it replaces allocated on every call (1, 2, 4 slots).
    const size_t REF = g_allocs;
    (void)referenceLayout(400, 34, 32, 4, false);
    std::printf("layout allocations per call: vector reference %zu, fixed slots 0\n", g_allocs - REF);
    CHECK(g_allocs - REF >= 1);
}

TEST(glyph_keys_are_unique) {
    std::set<uint64_t> keys;
    size_t             n = 0;
    for (int b = 0; b < 4; ++b)
        for (int m = 0; m < 2; ++m)
            for (int px = 4; px <= 200; px += 7)
                for (uint32_t c : {0u, 0xffffffffu, 0x40ffffffu, 0xd0c0392bu, 0x12345678u}) {
                    keys.insert(glyphKey(b, m, px, c));
                    ++n;
                }
    CHECK(keys.size() == n);
}

int main() {
    RUN(codec_matches_js_and_python_vectors);
    RUN(decode_edge_cases);
    RUN(round_trip_every_byte_and_fuzz);
    RUN(lines_round_trip);
    RUN(field_lookup);
    RUN(argb_parsing);
    RUN(excluded_classes_are_bounded);
    RUN(layout_matches_reference);
    RUN(layout_and_hit_testing_do_not_allocate);
    RUN(glyph_keys_are_unique);
    std::printf("test_native_protocol: %d passed\n", g_passed);
    return 0;
}
