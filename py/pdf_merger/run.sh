#!/usr/bin/env bash
# Launch the merge_to_pdf TUI. Ensures the venv is set up first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/setup.sh" --quiet

VENV_PY="$SCRIPT_DIR/.venv/bin/python"
exec "$VENV_PY" "$SCRIPT_DIR/merge_to_pdf_tui.py" "$@"
