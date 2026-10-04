#!/usr/bin/env bash
# Qt 6 lifecycle checks. No compositor, backend plugin or desktop config needed.
set -euo pipefail
cd "$(dirname "$0")/../.."
runner="${QMLTESTRUNNER:-/usr/lib/qt6/bin/qmltestrunner}"
if [[ ! -x "$runner" ]]; then
  echo "Set QMLTESTRUNNER to the Qt 6 qmltestrunner executable" >&2
  exit 2
fi
QT_QPA_PLATFORM=offscreen QT_QPA_PLATFORMTHEME= QT_STYLE_OVERRIDE=Fusion \
  "$runner" -input tests/qml/tst_restore_hosts.qml -o -,txt
python3 tests/qml/service_lifecycle.py
