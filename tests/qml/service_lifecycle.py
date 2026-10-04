#!/usr/bin/env python3
"""Run the real service headlessly with a recording transport and isolated state."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="grabbar-service-lifecycle-") as directory:
    stage = Path(directory)
    for name in ("Service.qml", "BarWidget.qml", "GrabbarModel.js"):
        shutil.copy2(ROOT / name, stage / name)
    for name in ("lifecycle", "helpers"):
        shutil.copytree(ROOT / name, stage / name)
    for name in ("Commons", "Ui"):
        shutil.copytree(ROOT / "tests/qml/fixtures" / name, stage / name)
    shutil.copy2(ROOT / "tests/qml/service-lifecycle.qml", stage / "shell.qml")
    env = os.environ.copy()
    for name, suffix in {
        "HOME": "home", "XDG_CONFIG_HOME": "config", "XDG_STATE_HOME": "state",
        "XDG_CACHE_HOME": "cache", "XDG_RUNTIME_DIR": "runtime",
    }.items():
        path = stage / suffix
        path.mkdir(mode=0o700)
        env[name] = str(path)
    config = stage / "home/.config/omarchy"
    config.mkdir(parents=True)
    (config / "shell.json").write_text(
        '{"bar":{"layout":{"right":["tech.greyforge.grabbar"]}}}\n'
    )
    env.update(QT_QPA_PLATFORM="offscreen", QT_QPA_PLATFORMTHEME="",
               QT_STYLE_OVERRIDE="Fusion", HYPRLAND_INSTANCE_SIGNATURE="",
               WAYLAND_DISPLAY="", DISPLAY="")
    try:
        result = subprocess.run(["qs", "-p", str(stage / "shell.qml"), "--no-color"],
                                env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=15)
    except subprocess.TimeoutExpired as error:
        print(error.stdout.decode() if isinstance(error.stdout, bytes) else error.stdout)
        raise
    print(result.stdout)
    assert result.returncode == 0, result.returncode
    for mode in ("with", "without"):
        assert f"PASS actual Service/BarWidget {mode} service lookup: 0 -> 1 -> 0 -> 1 -> 0" in result.stdout
