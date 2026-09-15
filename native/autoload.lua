-- Grabbar native autoload for Hyprland's Lua config.
--
-- Called from ~/.config/hypr/hyprland.lua as
--   pcall(dofile, os.getenv("HOME") .. "/.config/omarchy/plugins/tech.greyforge.grabbar/native/autoload.lua")
--
-- Two rules keep this safe (see docs/AUTOLOAD.md for the 2026-09-15 incident):
--
-- 1. hl.plugin.load() only DECLARES the plugin for this evaluation of the
--    config. Hyprland diffs the declared set against loaded plugins after every
--    reload and unloads anything no longer declared; unloading and loading each
--    trigger further reloads. So the declaration must be identical on every
--    evaluation: never make it depend on whether the plugin is already loaded.
--
-- 2. Boot guard. Each compositor instance that declares the plugin records its
--    signature in <state>/autoload/last-attempt. The native plugin writes the
--    same signature to <state>/autoload/last-ok once it has run for a while.
--    If, at startup, the previous attempt never reached ok, this file declares
--    nothing and records the skip, so a bad boot cannot repeat itself. Clear it
--    with `grabbar autoload retry`.
do
  local home  = os.getenv("HOME") or ""
  local so    = os.getenv("GRABBAR_SO") or (home .. "/.config/omarchy/plugins/tech.greyforge.grabbar/native/grabbar/grabbar.so")
  local state = os.getenv("GRABBAR_STATE_DIR") or ((os.getenv("XDG_STATE_HOME") or (home .. "/.local/state")) .. "/grabbar")
  local dir   = state .. "/autoload"
  local his   = os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or ""

  local function read(path)
    local f = io.open(path, "r"); if not f then return nil end
    local s = f:read("*l"); f:close(); return s
  end
  local function write(path, s)
    local f = io.open(path, "w"); if not f then return false end
    f:write(s or "", "\n"); f:close(); return true
  end
  local function exists(path)
    local f = io.open(path, "r"); if f then f:close(); return true end; return false
  end

  if exists(so) and exists(dir .. "/enabled") then
    local last_attempt = read(dir .. "/last-attempt")
    local last_ok      = read(dir .. "/last-ok")
    local previous_failed = last_attempt ~= nil and last_attempt ~= "" and last_attempt ~= his and last_attempt ~= last_ok
    if previous_failed then
      -- Idempotent across reloads: the marker holds the failed signature and
      -- the declared plugin set is empty on every evaluation until `retry`.
      write(dir .. "/skipped", last_attempt)
      pcall(function()
        hl.notification.create({ text = "Grabbar: native controls stayed off because the last start with them did not finish. Run: grabbar autoload retry", timeout = 12000 })
      end)
    else
      -- Record this instance before declaring, so a start that never gets far
      -- enough for the plugin to confirm health leaves the attempt on record.
      if his ~= "" and last_attempt ~= his then write(dir .. "/last-attempt", his) end
      hl.plugin.load(so)
    end
  end
end
