#!/usr/bin/env bash
# One-time setup: creates a local .venv and installs dependencies.
# Re-running it is safe — it only reinstalls when requirements.txt has changed.
#
# After it succeeds, the CLI can be called directly:
#     .venv/bin/python merge_to_pdf.py ./folder -o out.pdf
#
# Pass --quiet to suppress informational output (used by run.sh).

set -euo pipefail

QUIET=0
if [ "${1:-}" = "--quiet" ]; then
    QUIET=1
fi

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$SCRIPT_DIR/.venv"
REQ_FILE="$SCRIPT_DIR/requirements.txt"
HASH_FILE="$VENV_DIR/.req-hash"

# --- locate a usable Python ------------------------------------------------
PYTHON_BIN=""
for cmd in python3 python; do
    if command -v "$cmd" >/dev/null 2>&1; then
        PYTHON_BIN="$cmd"
        break
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    echo "Error: python3 (or python) not found in PATH." >&2
    echo "Install Python 3.9+ from https://www.python.org/downloads/" >&2
    exit 1
fi

# --- create venv if missing ------------------------------------------------
if [ ! -d "$VENV_DIR" ]; then
    log "Creating virtual environment in $VENV_DIR ..."
    "$PYTHON_BIN" -m venv "$VENV_DIR"
fi

VENV_PY="$VENV_DIR/bin/python"

# --- (re)install deps if requirements.txt changed --------------------------
hash_file_contents() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        # Fallback: mtime+size if no hashing tool is available
        stat -c '%Y-%s' "$1" 2>/dev/null || stat -f '%m-%z' "$1"
    fi
}

CURRENT_HASH=""
if [ -f "$REQ_FILE" ]; then
    CURRENT_HASH="$(hash_file_contents "$REQ_FILE")"
fi

STORED_HASH=""
if [ -f "$HASH_FILE" ]; then
    STORED_HASH="$(cat "$HASH_FILE")"
fi

if [ "$CURRENT_HASH" != "$STORED_HASH" ]; then
    log "Installing dependencies ..."
    "$VENV_PY" -m pip install --quiet --upgrade pip
    "$VENV_PY" -m pip install --quiet -r "$REQ_FILE"
    printf '%s' "$CURRENT_HASH" > "$HASH_FILE"
fi

# --- summary ---------------------------------------------------------------
if [ "$QUIET" -eq 0 ]; then
    cat <<EOF

Setup complete.

To use the CLI directly:
  $VENV_PY $SCRIPT_DIR/merge_to_pdf.py FOLDER [options]

Example:
  $VENV_PY $SCRIPT_DIR/merge_to_pdf.py ./scans -o report.pdf

Or activate the venv first and drop the long path:
  source $VENV_DIR/bin/activate
  python merge_to_pdf.py ./scans -o report.pdf

To launch the interactive TUI:
  $SCRIPT_DIR/run.sh
EOF
fi
