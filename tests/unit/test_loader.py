#!/usr/bin/env python3
"""Run the shipped loader with a fake Hyprland API and isolated guard files."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
LUA = shutil.which('lua') or shutil.which('lua5.4')
assert LUA, 'Lua is required for loader safety tests (lua or lua5.4)'
HARNESS = r'''
local count = 0
hl = {
  plugin = { load = function(_) count = count + 1 end },
  get_loaded_plugins = function() error("loader must not query loaded state") end,
  notification = { create = function(_) end }
}
if os.getenv("TEST_WRITE_FAILURE") == "1" then
  local original = io.open
  io.open = function(path, mode)
    if mode == "w" then return nil, "simulated write failure" end
    return original(path, mode)
  end
end
if os.getenv("TEST_CLOSE_FAILURE") == "1" then
  local original = io.open
  io.open = function(path, mode)
    local f, err = original(path, mode)
    if not f or mode ~= "w" then return f, err end
    return {
      write = function(_, ...) return f:write(...) end,
      close = function(_) f:close(); return nil, "simulated close failure" end
    }
  end
end
if os.getenv("TEST_RENAME_FAILURE") == "1" then
  os.rename = function() return nil, "simulated rename failure" end
end
for _ = 1, 3 do dofile(arg[1]) end
print(count)
'''


def check(label, expected, *, signature='session-new', attempt=None, ok=None,
          enabled=True, write_failure=False, close_failure=False, rename_failure=False):
    with tempfile.TemporaryDirectory() as td:
        state = Path(td)
        guard = state / 'autoload'
        guard.mkdir()
        so = state / 'plugin.so'
        so.touch()  # declaration only; nothing loads this file
        if enabled:
            (guard / 'enabled').touch()
        if attempt is not None:
            (guard / 'last-attempt').write_text(attempt + '\n')
        if ok is not None:
            (guard / 'last-ok').write_text(ok + '\n')
        harness = state / 'test.lua'
        harness.write_text(HARNESS)
        env = {**os.environ, 'GRABBAR_SO': str(so), 'GRABBAR_STATE_DIR': td,
               'HYPRLAND_INSTANCE_SIGNATURE': signature,
               'TEST_WRITE_FAILURE': str(int(write_failure)),
               'TEST_CLOSE_FAILURE': str(int(close_failure)),
               'TEST_RENAME_FAILURE': str(int(rename_failure))}
        result = subprocess.run([LUA, str(harness), str(ROOT / 'native/autoload.lua')],
                                env=env, capture_output=True, text=True, timeout=5)
        assert result.returncode == 0, (label, result.stderr)
        assert result.stdout.strip() == str(expected), (label, result.stdout, expected)
        if expected:
            assert (guard / 'last-attempt').read_text().strip() == signature, label
        print('PASS', label)


check('disabled stays off', 0, enabled=False)
check('fresh start declares on every evaluation', 3)
check('same instance stays declared before health confirmation', 3, attempt='session-new')
check('healthy previous start allows next instance', 3, attempt='old', ok='old')
check('unconfirmed previous start stays off across reloads', 0, attempt='old')
check('missing instance identity stays off', 0, signature='')
check('unwritable attempt stays off', 0, write_failure=True)
check('failed close stays off', 0, close_failure=True)
check('failed atomic rename stays off', 0, rename_failure=True)
print('test_loader: ok')
