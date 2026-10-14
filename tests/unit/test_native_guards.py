#!/usr/bin/env python3
"""Source guards for the native plugin's startup-safety and release rules.

These keep the 2026-09-15 incident class (SYSTEM-BREAKING-BUG.md,
docs/AUTOLOAD.md) closed without loading anything into a compositor.
"""
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
NATIVE = os.path.join(ROOT, "native", "grabbar")


def code(path):
    """Source text with // and /* */ comments and string literals removed."""
    text = open(path).read()
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', text)


sources = {f: code(os.path.join(NATIVE, f)) for f in os.listdir(NATIVE) if f.endswith((".cpp", ".hpp"))}

# 1. No config reload from the plugin itself. PLUGIN_INIT used to call
#    HyprlandAPI::reloadConfig() (inherited from Hyprbars); with config-time
#    declaration every extra reload re-runs the plugin diff.
for name, text in sources.items():
    assert not re.search(r"\breloadConfig\s*\(", text), f"{name} reloads the compositor config"
    assert "hl.plugin" not in text and "get_loaded_plugins" not in text, name

# 2. The boot-guard health marker is written once, from a timer, after the
#    configured delay; never during PLUGIN_INIT.
main = sources["main.cpp"]
calls = [m.start() for m in re.finditer(r"\bwriteBootOk\(\);", main)]
timer = re.search(r"makeShared<CEventLoopTimer>\(std::chrono::milliseconds\(GRABBAR_BOOT_OK_MS\).*?addTimer\(g_bootOkTimer\)", main, flags=re.S)
assert timer and len(calls) == 1 and timer.start() < calls[0] < timer.end(), \
    "the health marker must only be written by the boot-ok timer"
assert re.search(r"GRABBAR_BOOT_OK_MS\s+\d{4,}", open(os.path.join(NATIVE, "globals.hpp")).read()), \
    "boot-ok delay must stay seconds long"

# 3. Hyprland's globals (g_pCompositor, g_pKeybindManager, ...) are C++ inline
#    variables. With -fvisibility=hidden the plugin would bind private, null
#    copies of them instead of the compositor's, and crash at load.
makefile = open(os.path.join(NATIVE, "Makefile")).read()
assert "visibility=hidden" not in makefile and "visibility-inlines-hidden" not in makefile, makefile
assert "--no-gnu-unique" in makefile, "g++ builds must stay unloadable"

# 4. The shipped loader declares the plugin with a single call whose only
#    conditions are per-instance stable (tests/unit/test_loader.py runs it).
lua = open(os.path.join(ROOT, "native", "autoload.lua")).read()
lua_code = "\n".join(line.split("--", 1)[0] for line in lua.splitlines())
assert lua_code.count("hl.plugin.load(") == 1, "exactly one declaration"
assert "get_loaded_plugins" not in lua_code and "hl.plugin.unload" not in lua_code

# 4b. Decoration destructors run inside CWindow::updateWindowDecos() while
#     Hyprland erases from the window's decoration list. Calling back into the
#     compositor there (ending a drag refocuses, re-lays out and runs other
#     decorations' input hooks) re-enters that list mid-erase. Drag cleanup on
#     unload belongs at the start of PLUGIN_EXIT, before decorations go away.
bar = sources["bar.cpp"]
dtor = re.search(r"CGrabbarDeco::~CGrabbarDeco\(\)\s*\{(.*?)\n\}", bar, flags=re.S)
assert dtor, "strip destructor not found"
for call in ("endDrag", "cancelDrag", "changeMouseBindMode", "g_pKeybindManager", "g_layoutManager", "focusState", "g_pBackend"):
    assert call not in dtor.group(1), f"strip destructor calls into the compositor ({call})"
exit_body = re.search(r"void PLUGIN_EXIT\(\)\s*\{(.*?)\n\}", main, flags=re.S).group(1)
assert "cancelDrag()" in exit_body and exit_body.index("cancelDrag()") < exit_body.index("stop(true"), \
    "PLUGIN_EXIT must end strip drags before returning windows and before decorations are removed"

# 5. One version everywhere: manifest, native GRABBAR_VERSION, changelog.
manifest = json.load(open(os.path.join(ROOT, "manifest.json")))
native_version = re.search(r'#define GRABBAR_VERSION\s+"([^"]+)"', open(os.path.join(NATIVE, "globals.hpp")).read()).group(1)
assert native_version == manifest["version"], (native_version, manifest["version"])
changelog = open(os.path.join(ROOT, "CHANGELOG.md")).read()
assert re.search(r"^## " + re.escape(manifest["version"]) + r"\b", changelog, flags=re.M), "CHANGELOG has no section for " + manifest["version"]

print("test_native_guards: ok")
