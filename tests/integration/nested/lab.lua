-- Nested-compositor config for interactive / application qualification
-- (docs/QUALIFICATION.md "Nested test rig"). The compositor under test is a
-- Wayland client of the live session on a headless output; nothing here
-- touches the operator's desktop. Launch with:
--   hyprctl dispatch "hl.dsp.exec_cmd([[ [workspace <headless ws> silent] env HYPRLAND_INSTANCE_SIGNATURE= Hyprland -c <this file> ]])"
local w = os.getenv("GRABBAR_LAB_W") or "1600"
local h = os.getenv("GRABBAR_LAB_H") or "1000"
local scale = tonumber(os.getenv("GRABBAR_LAB_SCALE") or "1") or 1
hl.monitor({ output = "", mode = w .. "x" .. h, position = "auto", scale = scale })
hl.config({
  misc = { disable_hyprland_logo = true, disable_splash_rendering = true },
  debug = { disable_logs = false },
  general = { resize_on_border = true, gaps_in = 5, gaps_out = 10, border_size = 2 },
  decoration = { rounding = 8 },
  cursor = { no_warps = true },
  input = { follow_mouse = 1 },
})
