dofile(os.getenv("GRABBAR_NESTED_BASE"))
-- Exactly the hook `grabbar autoload enable` installs, pointed at this checkout
-- through GRABBAR_SO / GRABBAR_STATE_DIR (both honoured by native/autoload.lua).
pcall(dofile, os.getenv("GRABBAR_AUTOLOAD_LUA"))
