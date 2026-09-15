#!/usr/bin/env bash
# Offline test suite: pure model, recovery journal helper, backend protocol
# client, syntax checks, and the Omarchy manifest validator when available.
# Needs node and python3. The native backend and the nested-compositor
# scenarios (tests/integration) are run separately; see docs/QUALIFICATION.md.
set -euo pipefail
cd "$(dirname "$0")/.."
node tests/unit/test_model.js
python3 tests/unit/test_journal.py
python3 tests/unit/test_autoload.py
python3 tests/unit/test_protocol.py
python3 -m py_compile helpers/grabbar-journal helpers/grabbar_backend.py
bash -n bin/grabbar tests/integration/*.sh
if command -v qmllint >/dev/null 2>&1; then
  # Host modules (qs.Commons, qs.Ui, Quickshell.*) are not resolvable offline;
  # only syntax-level problems are reported.
  for f in Service.qml BarWidget.qml Panel.qml; do
    if qmllint "$f" 2>&1 | grep -E '^Error' | grep -viE 'import|module' | grep -q .; then
      echo "qmllint: $f has syntax problems"; qmllint "$f" 2>&1 | grep -E '^Error' | head -20; exit 1
    fi
  done
fi
if command -v omarchy >/dev/null 2>&1; then
  omarchy plugin validate .
fi
echo "ok"
