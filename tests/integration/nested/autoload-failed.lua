dofile(os.getenv("GRABBAR_NESTED_BASE"))
-- The block that broke the desktop on 2026-09-15, verbatim except for the
-- path (GRABBAR_SO instead of the installed plugin). Kept only to reproduce
-- the failure in an isolated compositor. NEVER install this.
do
  local so = os.getenv("GRABBAR_SO")
  local loaded = false
  for _, p in ipairs(hl.get_loaded_plugins() or {}) do
    if p.name == "grabbar" then loaded = true end
  end
  local f = io.open(so, "r")
  if f then f:close() end
  if not loaded and f then hl.plugin.load(so) end
end
