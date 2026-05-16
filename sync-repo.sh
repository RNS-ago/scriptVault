#!/bin/bash
set -euo pipefail

ADD_FLAG="-u"
GIT_DIR_NAME=".git"
TARGET_DIR=""

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] /path/to/repo

Options:
  -a, --all              Stage all changes (git add --all)
  -u, --update           Stage tracked file changes only (git add -u) [default]
  -g, --git-dir NAME     Name of the git metadata directory (default: .git)
  -h, --help             Show this help

Examples:
  $(basename "$0") ~/notes
  $(basename "$0") --all ~/notes
  $(basename "$0") --git-dir .bare ~/dotfiles
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|-A|--all)       ADD_FLAG="--all"; shift ;;
        -u|--update)       ADD_FLAG="-u";    shift ;;
        -g|--git-dir)
            [[ $# -ge 2 ]] || { echo "Error: $1 requires an argument" >&2; exit 1; }
            GIT_DIR_NAME="$2"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
        --)                shift; break ;;
        -*)                echo "Error: unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)
            [[ -z "$TARGET_DIR" ]] || { echo "Error: only one directory allowed" >&2; exit 1; }
            TARGET_DIR="${1%/}"; shift ;;
    esac
done

[[ -n "$TARGET_DIR" ]] || { echo "Error: no directory provided" >&2; usage >&2; exit 1; }
[[ -d "$TARGET_DIR" ]] || { echo "Error: '$TARGET_DIR' does not exist" >&2; exit 1; }

GIT_DIR="$TARGET_DIR/$GIT_DIR_NAME"
[[ -d "$GIT_DIR" ]] || { echo "Error: '$GIT_DIR' not found — not a Git repository?" >&2; exit 1; }

vargit() {
    /usr/bin/git --git-dir="$GIT_DIR" --work-tree="$TARGET_DIR" "$@"
}

gstatus=$(vargit status --porcelain)
if [[ -n "$gstatus" ]]; then
    vargit add "$ADD_FLAG"
    vargit commit -m "Automated snapshot" -m "$gstatus"
    vargit pull --rebase
    vargit push
fi