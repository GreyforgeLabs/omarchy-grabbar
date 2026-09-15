-- Minimal nested-compositor config shared by the startup tests. No Omarchy
-- bootstrap: the compositor under test is a Wayland client of the live one.
hl.monitor({ output = "", mode = "1280x800", position = "auto", scale = 1 })
hl.config({ misc = { disable_hyprland_logo = true, disable_splash_rendering = true } })
-- Hyprland's own log lines are needed to count plugin loads and reloads.
hl.config({ debug = { disable_logs = false } })
