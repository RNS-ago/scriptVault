#!/usr/bin/env bash
# ytdlp-cli.sh — interactive wrapper around yt-dlp for music downloads
# Prompts for URL, destination, format, and metadata overrides, then runs yt-dlp.

set -euo pipefail

# ---------- colors ----------
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'
    YELLOW=$'\033[33m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'; RESET=$'\033[0m'
else
    BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; CYAN=""; RESET=""
fi

info()  { printf "%s%s%s\n" "$CYAN"   "$*" "$RESET"; }
warn()  { printf "%s%s%s\n" "$YELLOW" "$*" "$RESET" >&2; }
err()   { printf "%s%s%s\n" "$RED"    "$*" "$RESET" >&2; }
ok()    { printf "%s%s%s\n" "$GREEN"  "$*" "$RESET"; }

# If the answer is a quit sentinel, exit cleanly. Called by every input helper
# below so the user can abort from any prompt without hunting for Ctrl-C.
# The cleanup trap on EXIT still fires, so the temp dir gets removed.
maybe_quit() {
    case "$1" in
        :q|:Q|:quit|:QUIT|:exit)
            echo
            warn "Aborted."
            exit 0
            ;;
    esac
}

# Prompt helper: ask "$1" with default "$2", store in variable named "$3"
ask() {
    local prompt="$1" default="${2-}" __var="$3" answer
    if [[ -n "$default" ]]; then
        printf "%s%s%s %s[%s]%s: " "$BOLD" "$prompt" "$RESET" "$DIM" "$default" "$RESET"
    else
        printf "%s%s%s: " "$BOLD" "$prompt" "$RESET"
    fi
    IFS= read -r answer || true
    maybe_quit "$answer"
    [[ -z "$answer" ]] && answer="$default"
    printf -v "$__var" '%s' "$answer"
}

# Like ask(), but prefills the input buffer with `prefill` so the user can
# edit it directly (bash 4+, interactive TTY only). Falls back to "[default]"
# bracket convention on older bash or when stdin isn't a terminal.
ask_prefill() {
    local prompt="$1" prefill="$2" __var="$3" answer
    if (( BASH_VERSINFO[0] >= 4 )) && [[ -t 0 ]] && [[ -n "$prefill" ]]; then
        # Pass the prompt to readline via -p so backspace can't delete past it.
        # Wrap color codes in \001/\002 so readline ignores them when computing
        # prompt width (same convention as \[...\] in PS1).
        local p
        p=$'\001'"$BOLD"$'\002'"$prompt"$'\001'"$RESET"$'\002'": "
        # shellcheck disable=SC2162
        IFS= read -r -e -i "$prefill" -p "$p" answer || true
    elif [[ -n "$prefill" ]]; then
        printf "%s%s%s %s[%s]%s: " "$BOLD" "$prompt" "$RESET" "$DIM" "$prefill" "$RESET"
        IFS= read -r answer || true
        [[ -z "$answer" ]] && answer="$prefill"
    else
        printf "%s%s%s: " "$BOLD" "$prompt" "$RESET"
        IFS= read -r answer || true
    fi
    maybe_quit "$answer"
    printf -v "$__var" '%s' "$answer"
}

# Build a "(detected: X)" suffix... (kept for future use)

# ---------- artwork (iTunes Search API, à la Ben Dodson's iTunes Artwork Finder) ----------
# Globals set by the picker:
ART_URL=""        # remote URL of the chosen artwork
ART_FILE=""       # local path to the downloaded artwork
HAS_ARTWORK=0     # set to 1 in preflight if python3 + curl are available

# Hit the iTunes Search API and emit one tab-separated row per album:
#   title <TAB> artist <TAB> hires_url
itunes_search() {
    local term="$1"
    python3 - "$term" <<'PY'
import sys, json, urllib.parse, urllib.request
term = sys.argv[1]
url = "https://itunes.apple.com/search?" + urllib.parse.urlencode({
    "term": term, "country": "us", "entity": "album", "limit": 25,
})
req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
try:
    with urllib.request.urlopen(req, timeout=10) as r:
        data = json.load(r)
except Exception as e:
    sys.stderr.write(f"iTunes API error: {e}\n")
    sys.exit(1)
for entry in data.get("results", []):
    title  = entry.get("collectionName") or ""
    artist = entry.get("artistName") or ""
    art100 = entry.get("artworkUrl100") or ""
    if not (title and art100):
        continue
    # Hi-res trick from Ben Dodson's api.php: swap the size token, then
    # rewrite the host to is5-ssl.mzstatic.com so iTunes serves the largest
    # available size (the URL is canonical regardless of which CDN host
    # responded with the thumbnail).
    hires = art100.replace("100x100bb", "100000x100000-999")
    idx = hires.find("/image/thumb/")
    if idx > 0:
        hires = "https://is5-ssl.mzstatic.com" + hires[idx:]
    print(f"{title}\t{artist}\t{hires}")
PY
}

# Interactive picker. Searches iTunes using the supplied term and lets the user
# pick a result, paste a custom URL, re-search, or skip. On success, sets
# ART_URL globally and returns 0; on skip/abort, returns 1.
pick_artwork() {
    local default_term="$1" term="$1"
    while true; do
        info "Searching iTunes for: \"$term\""
        local results
        if ! results=$(itunes_search "$term" 2>/dev/null); then
            warn "Search failed (network or API issue)."
            results=""
        fi

        if [[ -z "$results" ]]; then
            warn "No results."
        else
            echo
            local i=0
            while IFS=$'\t' read -r title artist url; do
                ((i++))
                printf "  %s%2d)%s %s — %s%s%s\n" \
                    "$BOLD" "$i" "$RESET" "$title" "$DIM" "$artist" "$RESET"
                printf "      %s%s%s\n" "$DIM" "$url" "$RESET"
            done <<<"$results"
            echo
        fi

        local choice prompt_extra=""
        [[ -n "$IMAGE_PREVIEWER" ]] && prompt_extra=", [p] N to preview"
        ask "Pick a number${prompt_extra}, [u]rl, [r]e-search, or [s]kip" "s" choice
        case "$choice" in
            s|S|skip)
                return 1
                ;;
            u|U|url)
                local custom=""
                ask "Paste artwork URL" "" custom
                if [[ -n "$custom" ]]; then
                    ART_URL="$custom"
                    return 0
                fi
                ;;
            r|R|research)
                ask "New search term" "$term" term
                ;;
            p\ *|P\ *)
                local n="${choice#? }"
                # Validate it's a positive integer
                if ! [[ "$n" =~ ^[0-9]+$ ]]; then
                    warn "Usage: p N — e.g. 'p 3' to preview result 3."
                    continue
                fi
                local hires_url
                hires_url=$(awk -F'\t' -v n="$n" 'NR==n {print $3}' <<<"$results")
                if [[ -z "$hires_url" ]]; then
                    warn "Number out of range."
                    continue
                fi
                # Derive the 600x600 medium URL from the hi-res URL — same path,
                # smaller size token. Fast download, plenty for visual preview.
                local medium_url="${hires_url//100000x100000-999/600x600bb}"
                local preview_file="${TMPDIR_RUN}/preview_${n}.jpg"
                if [[ ! -f "$preview_file" ]]; then
                    info "Downloading preview…"
                    if ! download_artwork "$medium_url" "$preview_file"; then
                        warn "Couldn't download preview."
                        continue
                    fi
                fi
                echo
                preview_image "$preview_file" || true
                echo
                ;;
            ''|*[!0-9]*)
                local valid="a number, u, r, or s"
                [[ -n "$IMAGE_PREVIEWER" ]] && valid="a number, p N, u, r, or s"
                warn "Not understood — try $valid."
                ;;
            *)
                local picked
                picked=$(awk -F'\t' -v n="$choice" 'NR==n {print $3}' <<<"$results")
                if [[ -n "$picked" ]]; then
                    ART_URL="$picked"
                    return 0
                fi
                warn "Number out of range."
                ;;
        esac
    done
}

# Download $1 (URL) to $2 (path). Follows redirects.
#
# The hi-res URL we get from Ben Dodson's trick uses the magic size token
# "100000x100000-999" which asks Apple's CDN for the largest available
# variant. That works for most albums but some source images don't support
# it and Apple returns HTTP 400. When we hit that, fall back through a
# series of progressively smaller standard sizes — the 3000×3000 size is
# typically the actual maximum for modern music artwork, and 600×600 is
# guaranteed because we use it for previews.
download_artwork() {
    local url="$1" dest="$2"

    # First attempt: URL as supplied.
    if curl -fsL -A "Mozilla/5.0" -o "$dest" "$url" 2>/dev/null; then
        return 0
    fi

    # Fallback chain only applies when the URL has the magic token to swap.
    if [[ "$url" == *"100000x100000-999"* ]]; then
        local size fallback
        for size in "5000x5000bb" "3000x3000bb" "1500x1500bb" "1000x1000bb" "600x600bb"; do
            fallback="${url//100000x100000-999/$size}"
            if curl -fsL -A "Mozilla/5.0" -o "$dest" "$fallback" 2>/dev/null; then
                info "Downloaded ${size%bb} version (hi-res unavailable for this album)."
                return 0
            fi
        done
    fi

    return 1
}

# Detect an inline-image previewer. We try in this order:
#   chafa  — works in nearly every terminal, picks the best protocol available
#            (Kitty graphics, iTerm2 inline, Sixel) and falls back to Unicode
#            half-blocks on terminals without an image protocol.
#   kitty  — kitty's bundled `icat` kitten; works in kitty, ghostty, WezTerm
#            (anything that speaks the Kitty graphics protocol).
#   viu    — Rust-based viewer with Kitty/iTerm2/Sixel support.
#   imgcat — iTerm2's bundled tool; only useful on iTerm2 itself.
detect_image_previewer() {
    if command -v chafa >/dev/null 2>&1; then echo "chafa";  return; fi
    if command -v kitty >/dev/null 2>&1 && \
       [[ -n "${KITTY_WINDOW_ID-}" || "${TERM-}" == *kitty* || \
          "${TERM-}" == ghostty* || "${TERM_PROGRAM-}" == ghostty || \
          "${TERM_PROGRAM-}" == WezTerm ]]; then
        echo "kitty"; return
    fi
    if [[ "${LC_TERMINAL-}" == "iTerm2" || "${TERM_PROGRAM-}" == "iTerm.app" ]] \
       && command -v imgcat >/dev/null 2>&1; then
        echo "imgcat"; return
    fi
    if command -v viu >/dev/null 2>&1; then echo "viu"; return; fi
    echo ""
}

# Render an image file using whichever previewer was detected.
preview_image() {
    local img="$1"
    case "$IMAGE_PREVIEWER" in
        chafa)  chafa --size=40x20 --animate=off "$img" ;;
        kitty)  kitty +kitten icat --align left --transfer-mode=stream "$img" ;;
        viu)    viu -h 20 "$img" ;;
        imgcat) imgcat "$img" ;;
        *)      warn "No image previewer available."; return 1 ;;
    esac
}

# Re-embed cover art into a single audio file using ffmpeg, in place.
# Args: $1 = audio file, $2 = artwork file
embed_artwork_file() {
    local audio="$1" art="$2"
    local ext="${audio##*.}"
    local tmp="${audio%.*}.__cover_tmp__.${ext}"

    case "${ext,,}" in
        mp3)
            ffmpeg -nostdin -loglevel error -y -i "$audio" -i "$art" \
                -map 0:a -map 1:v -c copy -id3v2_version 3 \
                -metadata:s:v title="Album cover" \
                -metadata:s:v comment="Cover (front)" \
                "$tmp"
            ;;
        m4a|mp4|aac)
            ffmpeg -nostdin -loglevel error -y -i "$audio" -i "$art" \
                -map 0 -map 1 -c copy -disposition:v:0 attached_pic \
                "$tmp"
            ;;
        flac|opus|ogg)
            ffmpeg -nostdin -loglevel error -y -i "$audio" -i "$art" \
                -map 0:a -map 1:v -c copy \
                -metadata:s:v title="Album cover" \
                -metadata:s:v comment="Cover (front)" \
                -disposition:v:0 attached_pic \
                "$tmp"
            ;;
        *)
            warn "Custom artwork embed not supported for .${ext} — skipping."
            return 0
            ;;
    esac && mv "$tmp" "$audio" || {
        warn "Failed to embed artwork into ${audio##*/}"
        rm -f "$tmp"
        return 1
    }
}

confirm() {
    local prompt="$1" default="${2:-y}" answer
    local hint="[Y/n]"; [[ "$default" == "n" ]] && hint="[y/N]"
    printf "%s%s%s %s " "$BOLD" "$prompt" "$RESET" "$hint"
    IFS= read -r answer || true
    maybe_quit "$answer"
    [[ -z "$answer" ]] && answer="$default"
    [[ "$answer" =~ ^[Yy] ]]
}

# Strip yt-dlp's literal "NA" placeholder for missing fields.
clean_na() { [[ "$1" == "NA" ]] && printf "" || printf "%s" "$1"; }

# Fetch a metadata preview for the URL (first track only).
# Sets PREVIEW_* globals; on failure, leaves them empty.
PREVIEW_TITLE=""; PREVIEW_UPLOADER=""; PREVIEW_ALBUM=""
PREVIEW_ARTIST=""; PREVIEW_ALBUM_ARTIST=""
PREVIEW_GENRE="";  PREVIEW_YEAR=""
fetch_preview() {
    local url="$1" raw key value
    info "Fetching metadata preview from URL…"

    if ! raw=$(yt-dlp ${COOKIE_ARGS[@]+"${COOKIE_ARGS[@]}"} \
        --skip-download --no-warnings --ignore-no-formats-error \
        --playlist-items 1 \
        --print "TITLE=%(title)s" \
        --print "UPLOADER=%(uploader)s" \
        --print "ALBUM=%(album,playlist_title)s" \
        --print "ARTIST=%(artist,uploader)s" \
        --print "ALBUM_ARTIST=%(album_artist,uploader)s" \
        --print "GENRE=%(genre)s" \
        --print "YEAR=%(release_year,upload_date>%Y)s" \
        "$url" 2>/dev/null); then
        warn "Couldn't fetch a preview (continuing without one)."
        return 1
    fi

    while IFS='=' read -r key value; do
        value=$(clean_na "$value")
        case "$key" in
            TITLE)        PREVIEW_TITLE="$value" ;;
            UPLOADER)     PREVIEW_UPLOADER="$value" ;;
            ALBUM)        PREVIEW_ALBUM="$value" ;;
            ARTIST)       PREVIEW_ARTIST="$value" ;;
            ALBUM_ARTIST) PREVIEW_ALBUM_ARTIST="$value" ;;
            GENRE)        PREVIEW_GENRE="$value" ;;
            YEAR)         PREVIEW_YEAR="$value" ;;
        esac
    done <<<"$raw"
}

# Print one row of the preview block.
preview_row() {
    local label="$1" value="$2"
    if [[ -z "$value" ]]; then
        printf "  %-14s %s(none — yt-dlp default will be used)%s\n" "$label" "$DIM" "$RESET"
    else
        printf "  %-14s %s%s%s\n" "$label" "$GREEN" "$value" "$RESET"
    fi
}

# Force-set a metadata tag for the *current* URL's download via ffmpeg.
# Reads/writes the global FFMPEG_META array (reset to () at each iteration).
# We only emit an override when the user's value differs from what yt-dlp
# would have picked up on its own (passed in as $detected). If they match,
# yt-dlp's own metadata mapping handles it and we keep the command minimal.
add_meta_override() {
    local tag="$1" value="$2" detected="${3-}"
    [[ -z "$value" ]] && return 0
    [[ -n "$detected" && "$value" == "$detected" ]] && return 0
    FFMPEG_META+=(-metadata "${tag}=${value}")
}

# Build a yt-dlp -f format selector for video downloads.
# Args: $1 = video height ("best" or a number), $2 = audio bitrate ("best" or kbps),
#       $3 = container (mp4/mkv/webm). Prefers container-compatible codecs but
# falls back gracefully so unusual videos still download (yt-dlp transcodes the
# container if needed).
build_video_format_selector() {
    local vid_q="$1" aud_q="$2" container="$3"
    local v_h="" a_b=""
    [[ "$vid_q" != "best" ]] && v_h="[height<=${vid_q}]"
    [[ "$aud_q" != "best" ]] && a_b="[abr<=${aud_q}]"
    case "$container" in
        mp4)
            echo "bestvideo${v_h}[ext=mp4]+bestaudio${a_b}[ext=m4a]/bestvideo${v_h}+bestaudio${a_b}/best${v_h}"
            ;;
        webm)
            echo "bestvideo${v_h}[ext=webm]+bestaudio${a_b}[ext=webm]/bestvideo${v_h}+bestaudio${a_b}/best${v_h}"
            ;;
        mkv|*)
            echo "bestvideo${v_h}+bestaudio${a_b}/best${v_h}"
            ;;
    esac
}

# List subtitle tracks of the first video at $1, one row per track:
#   kind <TAB> code <TAB> name     (kind = subs for uploaded, auto for auto-generated)
# Uploaded rows come first, so row N is the number shown in the picker.
list_subs() {
    yt-dlp ${COOKIE_ARGS[@]+"${COOKIE_ARGS[@]}"} \
        -j --no-warnings --ignore-no-formats-error --playlist-items 1 "$1" \
    | python3 -c '
import sys, json
d = json.loads(sys.stdin.readline())
for kind, key in (("subs", "subtitles"), ("auto", "automatic_captions")):
    for code, tracks in (d.get(key) or {}).items():
        if code == "live_chat":
            continue
        name = next((t["name"] for t in tracks if t.get("name")), "")
        print(f"{kind}\t{code}\t{name}")
'
}

# Print the rows of one kind from list_subs output as a numbered,
# multi-column list. Args: $1 = heading, $2 = kind, $3 = rows.
print_sub_section() {
    local lines
    lines=$(awk -F'\t' -v k="$2" '$1==k {printf "%3d) %-8s %s\n", NR, $2, $3}' <<<"$3")
    [[ -z "$lines" ]] && return 0
    printf "  %s%s:%s\n" "$BOLD" "$1" "$RESET"
    column -c "$(tput cols 2>/dev/null || echo 80)" <<<"$lines" 2>/dev/null || printf "%s\n" "$lines"
    echo
}

# Interactive subtitle picker for video mode. Shows the tracks of the first
# video at $1 and lets the user pick by number or type language codes.
# On success, fills the global SUB_ARGS with yt-dlp flags and returns 0;
# on skip, or when the video has no subtitles, returns 1.
pick_subs() {
    local rows="" choice tok line kind code langs want_subs want_auto bad
    local -a toks
    info "Fetching available subtitles…"
    if ! rows=$(list_subs "$1" 2>/dev/null); then
        warn "Couldn't fetch the subtitle list. You can still type language codes."
        rows=""
    elif [[ -z "$rows" ]]; then
        warn "No subtitles available for this video."
        return 1
    else
        (( IS_PLAYLIST )) && info "(Showing tracks of the first video; codes apply to every video.)"
        echo
        print_sub_section "Uploaded subtitles"      subs "$rows"
        print_sub_section "Auto-generated captions" auto "$rows"
    fi

    while true; do
        ask "Pick numbers or language codes (e.g. 1,3 or en,de), Enter to skip" "" choice
        [[ -z "$choice" ]] && return 1
        langs=""; want_subs=0; want_auto=0; bad=0
        read -ra toks <<<"${choice//,/ }"
        for tok in "${toks[@]}"; do
            if [[ "$tok" =~ ^[0-9]+$ ]]; then
                line=$(awk -v n="$tok" 'NR==n' <<<"$rows")
                if [[ -z "$line" ]]; then
                    warn "Number out of range: $tok"
                    bad=1
                    break
                fi
                IFS=$'\t' read -r kind code _ <<<"$line"
                if [[ "$kind" == "subs" ]]; then want_subs=1; else want_auto=1; fi
            else
                # Typed code: let yt-dlp match it in either list
                # (uploaded subtitles win over auto-generated ones).
                code="$tok"; want_subs=1; want_auto=1
            fi
            langs="${langs:+$langs,}$code"
        done
        [[ $bad -eq 0 && -n "$langs" ]] && break
    done

    SUB_ARGS=()
    (( want_subs )) && SUB_ARGS+=(--write-subs)
    (( want_auto )) && SUB_ARGS+=(--write-auto-subs)
    SUB_ARGS+=(--sub-langs "$langs")
    if confirm "Embed subtitles in the video file? (n = separate .srt files)" "y"; then
        # yt-dlp keeps the .vtt files when --write-subs is passed explicitly;
        # no-keep-subs makes it delete them once they are embedded.
        SUB_ARGS+=(--embed-subs --compat-options no-keep-subs)
    else
        SUB_ARGS+=(--convert-subs srt)
    fi
    ok "Subtitles: $langs"
}

# ---------- installers ----------
# Make sure $1 is on PATH for the rest of this session. No-op if it already is.
# When it does add the dir, say so: the change doesn't outlive this run.
ensure_on_path() {
    local dir="$1"
    case ":$PATH:" in
        *":$dir:"*) return 0 ;;
    esac
    export PATH="$dir:$PATH"
    warn "Added ${dir} to PATH for this session only."
    warn "To make it permanent, add to your shell config:"
    warn "    export PATH=\"${dir/#$HOME/\$HOME}:\$PATH\""
}

# Download the official yt-dlp release (Python zipapp) into ~/.local/bin.
install_ytdlp() {
    if ! command -v curl >/dev/null 2>&1; then
        err "curl is required to install yt-dlp. Please install curl first."
        return 1
    fi
    # The release file is a Python zipapp: without python3 >= 3.10 it won't run.
    if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
        err "yt-dlp needs python3 3.10 or newer, found: $(python3 -V 2>&1 | head -n1)"
        err "Install a newer Python (macOS: brew install python), then re-run."
        return 1
    fi
    local bindir="$HOME/.local/bin"
    mkdir -p "$bindir"
    info "Downloading yt-dlp to ${bindir}/yt-dlp …"
    if ! curl -L --fail --progress-bar \
            https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp \
            -o "${bindir}/yt-dlp"; then
        err "Download failed."
        return 1
    fi
    chmod a+rx "${bindir}/yt-dlp"
    ensure_on_path "$bindir"
    ok "yt-dlp installed."
}

# Run the official Deno installer. It writes to ~/.deno/bin and patches the
# user's shell rc files, but not the running shell — so we manually add the
# bin dir to PATH for this session afterward.
install_deno() {
    if ! command -v curl >/dev/null 2>&1; then
        err "curl is required to install Deno. Please install curl first."
        return 1
    fi
    info "Running the Deno installer (curl … | sh) …"
    if ! curl -fsSL https://deno.land/install.sh | sh; then
        err "Deno installation failed."
        return 1
    fi
    local deno_bin="$HOME/.deno/bin"
    if [[ ! -x "$deno_bin/deno" ]]; then
        err "Deno binary not found at ${deno_bin}/deno after install."
        return 1
    fi
    ensure_on_path "$deno_bin"
    ok "Deno installed."
    warn "Note: open a new shell (or source your rc file) to use Deno outside this script."
}

# Print the package-manager command that installs a package here, or nothing
# if there's no known package manager (or no way to get root). Used for tools
# with no single portable build like yt-dlp/Deno (ffmpeg, python3).
# Args: the package's name on apt, dnf, pacman, brew (they differ).
pkg_install_cmd() {
    local apt="$1" dnf="$2" pacman="$3" brew="$4"
    if command -v brew >/dev/null 2>&1; then
        echo "brew install ${brew}"   # brew refuses to run under sudo
        return 0
    fi
    local s=""
    if (( EUID != 0 )); then
        command -v sudo >/dev/null 2>&1 || return 0
        s="sudo "
    fi
    if   command -v apt-get >/dev/null 2>&1; then echo "${s}apt-get update && ${s}apt-get install -y ${apt}"
    elif command -v dnf     >/dev/null 2>&1; then echo "${s}dnf install -y ${dnf}"
    elif command -v pacman  >/dev/null 2>&1; then echo "${s}pacman -S --needed --noconfirm ${pacman}"
    fi
}

# Offer to install missing command $1 by running $2 (from pkg_install_cmd).
# Exits the script if the user refuses or the install doesn't work.
require_pkg() {
    local bin="$1" cmd="$2"
    warn "${bin} is not installed or not on PATH."
    if [[ -z "$cmd" ]]; then
        err "${bin} is required. Install it with your package manager, then re-run."
        exit 1
    fi
    if ! confirm "Install ${bin} now? Runs: ${cmd}" "y"; then
        err "${bin} is required. Install it yourself, then re-run:"
        echo "    ${cmd}"
        exit 1
    fi
    # Safe to eval: the string comes from pkg_install_cmd, never from input.
    eval "$cmd" || { err "${bin} installation failed."; exit 1; }
    if ! command -v "$bin" >/dev/null 2>&1; then
        err "${bin} still not found after install."
        exit 1
    fi
    ok "${bin} installed."
}

# ---------- preflight ----------
# A previous install may have left yt-dlp / Deno in their default dirs without
# those dirs being on PATH yet. Patch them in so we don't offer to reinstall.
[[ -x "$HOME/.local/bin/yt-dlp" ]] && ensure_on_path "$HOME/.local/bin"
[[ -x "$HOME/.deno/bin/deno"   ]] && ensure_on_path "$HOME/.deno/bin"

# python3 runs the yt-dlp release build (install_ytdlp checks for 3.10+) and
# powers the artwork search and the subtitle picker. Checked first for that.
if ! command -v python3 >/dev/null 2>&1; then
    require_pkg python3 "$(pkg_install_cmd python3 python3 python python)"
fi

if ! command -v yt-dlp >/dev/null 2>&1; then
    warn "yt-dlp is not installed or not on PATH."
    if ! confirm "Install yt-dlp now (to ~/.local/bin)?" "y"; then
        err "yt-dlp is required. Install it yourself, then re-run:"
        echo "    pipx install yt-dlp   (or)   brew install yt-dlp"
        exit 1
    fi
    install_ytdlp || exit 1
fi

# Sites change often and old yt-dlp builds break, so offer an update when a
# newer stable release exists. Offline / timeout: skip the check silently.
YTDLP_CUR=$(yt-dlp --version 2>/dev/null || true)
YTDLP_NEW=$(curl -fsLI -o /dev/null -w '%{url_effective}' --max-time 5 \
    https://github.com/yt-dlp/yt-dlp/releases/latest 2>/dev/null || true)
YTDLP_NEW="${YTDLP_NEW##*/}"   # .../releases/tag/2026.10.26 -> 2026.10.26
# sort -VC succeeds when CUR <= NEW, so a newer nightly build isn't "outdated".
if [[ "$YTDLP_NEW" =~ ^[0-9.]+$ && -n "$YTDLP_CUR" && "$YTDLP_CUR" != "$YTDLP_NEW" ]] \
    && printf '%s\n' "$YTDLP_CUR" "$YTDLP_NEW" | sort -VC; then
    warn "yt-dlp ${YTDLP_CUR} is out of date (latest: ${YTDLP_NEW})."
    if confirm "Update yt-dlp now?" "y"; then
        yt-dlp -U || true
        # -U refuses for pip/pipx/apt/brew installs (and prints how to update
        # instead), so trust the version it reports, not its exit code.
        if [[ "$(yt-dlp --version 2>/dev/null)" == "$YTDLP_CUR" ]]; then
            warn "yt-dlp is still ${YTDLP_CUR}. Update it with the tool you installed it with."
        else
            ok "yt-dlp updated to $(yt-dlp --version)."
        fi
    else
        warn "Continuing with yt-dlp ${YTDLP_CUR}."
    fi
fi

# yt-dlp needs a JS runtime for full YouTube support (since 2025.11.12).
if ! command -v deno >/dev/null 2>&1; then
    warn "Deno (JS runtime) is not installed or not on PATH."
    warn "yt-dlp needs it for full YouTube support."
    if ! confirm "Install Deno now (to ~/.deno)?" "y"; then
        err "Deno is required. Install it yourself, then re-run:"
        echo "    curl -fsSL https://deno.land/install.sh | sh   (or)   brew install deno"
        exit 1
    fi
    install_deno || exit 1
fi

# ffmpeg does the audio extraction, video merging and tag/artwork embedding.
if ! command -v ffmpeg >/dev/null 2>&1; then
    # Fedora's own repo ships it as ffmpeg-free (the full build is in RPM Fusion).
    require_pkg ffmpeg "$(pkg_install_cmd ffmpeg ffmpeg-free ffmpeg ffmpeg)"
fi

if (( BASH_VERSINFO[0] < 4 )); then
    warn "Note: bash ${BASH_VERSION%%[^0-9.]*} doesn't support input prefilling."
    warn "      Detected values will appear as [defaults] instead of editable text."
    warn "      For the best experience, install bash 4+ (e.g. brew install bash)."
fi

# Album-artwork feature needs python3 (JSON parsing + URL encoding) and curl
# (downloading the image). yt-dlp itself requires Python, so this is almost
# always satisfied — but degrade gracefully if not.
if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
    HAS_ARTWORK=1
else
    HAS_ARTWORK=0
    warn "python3 and/or curl not found — iTunes artwork search disabled."
fi

# Inline image preview in supported terminals (Kitty/Ghostty/iTerm2/WezTerm/etc).
IMAGE_PREVIEWER=$(detect_image_previewer)

# Temp dir for downloaded artwork + the list of files yt-dlp produced.
# Cleaned up on exit regardless of how we leave (success, error, Ctrl-C).
TMPDIR_RUN=$(mktemp -d -t ytdlp-cli.XXXXXX)
PRODUCED_LIST="${TMPDIR_RUN}/produced.txt"
cleanup() { rm -rf "$TMPDIR_RUN"; }
trap cleanup EXIT INT TERM

# ---------- banner ----------
cat <<EOF
${BLUE}${BOLD}
╭──────────────────────────────────────╮
│        yt-dlp downloader             │
╰──────────────────────────────────────╯${RESET}
${DIM}Press Enter to accept the [default] for any field. Type :q to abort.${RESET}

EOF

# ---------- mode selection ----------
echo
info "── What are we downloading? ──"
printf "  %s1)%s Music — audio-only, with metadata + album artwork\n" "$BOLD" "$RESET"
printf "  %s2)%s Video — full video, configurable quality and format\n" "$BOLD" "$RESET"
while true; do
    ask "Mode" "1" MODE_CHOICE
    case "$MODE_CHOICE" in
        1|m|music|Music|M) MODE=music; break ;;
        2|v|video|Video|V) MODE=video; break ;;
        *) warn "Pick 1 or 2." ;;
    esac
done

# ---------- session setup (one-time) ----------
echo
if [[ "$MODE" == "music" ]]; then
    DEFAULT_DEST="${HOME}/Media/Music"
    ask "Destination directory" "$DEFAULT_DEST" DEST
    DEST="${DEST/#\~/$HOME}"
    mkdir -p "$DEST"

    ask "Audio format (mp3/m4a/opus/flac/wav)" "mp3" AUDIO_FORMAT
    ask "Audio quality (0=best, 9=worst)"      "0"   AUDIO_QUALITY
else
    DEFAULT_DEST="${HOME}/Media/Youtube"
    ask "Destination directory" "$DEFAULT_DEST" DEST
    DEST="${DEST/#\~/$HOME}"
    mkdir -p "$DEST"

    ask "Container format (mp4/mkv/webm)"                     "mp4"  VIDEO_FORMAT
    ask "Max video height (best/2160/1440/1080/720/480/360)"  "1080" VIDEO_QUALITY
    ask "Audio bitrate cap (best, or kbps like 128)"          "best" AUDIO_BITRATE
fi

# Cookies let YouTube treat us as a signed-in browser, which avoids
# "Sign in to confirm you're not a bot" on long playlists.
ask "Cookies: browser name (firefox/chrome/brave/...) or cookies.txt path, Enter for none" "" COOKIES
COOKIES="${COOKIES/#\~/$HOME}"
COOKIE_ARGS=()
if [[ -f "$COOKIES" ]]; then
    COOKIE_ARGS=(--cookies "$COOKIES")
elif [[ -n "$COOKIES" ]]; then
    COOKIE_ARGS=(--cookies-from-browser "$COOKIES")
fi

# IDs of finished downloads. Re-running a URL skips everything listed here.
ARCHIVE="${DEST%/}/.ytdlp-archive.txt"

# ---------- per-URL loop ----------
ITER=0
while true; do
    ITER=$((ITER + 1))

    # Reset every per-URL variable so state from the previous iteration
    # can't leak in (stale metadata, stale artwork, leftover override flags).
    URL=""
    IS_PLAYLIST=0
    PREVIEW_TITLE=""; PREVIEW_UPLOADER=""; PREVIEW_ALBUM=""
    PREVIEW_ARTIST=""; PREVIEW_ALBUM_ARTIST=""
    PREVIEW_GENRE="";  PREVIEW_YEAR=""
    ALBUM_ARTIST=""; ARTIST=""; ALBUM=""; GENRE=""; YEAR=""
    ART_URL=""; ART_FILE=""
    FFMPEG_META=()
    SUB_ARGS=()
    SLEEP_BETWEEN=0
    CMD=()
    TEMPLATE=""

    # Clear the temp dir contents but keep the directory itself (the EXIT
    # trap removes it on script exit). This wipes any cover.jpg / preview_*.jpg
    # from a previous iteration so we don't accidentally render or embed it.
    rm -rf "${TMPDIR_RUN:?}"/* 2>/dev/null || true
    PRODUCED_LIST="${TMPDIR_RUN}/produced.txt"

    echo
    if (( ITER == 1 )); then
        ask "URL" "" URL
    else
        info "── Next download (#${ITER}) ──"
        ask "URL" "" URL
    fi
    if [[ -z "$URL" ]]; then
        err "URL is required."
        if confirm "Try again?" "y"; then continue; else break; fi
    fi

    echo
    info "── Playlist vs single track ──"
    if confirm "Is this a playlist/album?" "y"; then
        IS_PLAYLIST=1
        if confirm "Pause between videos to avoid YouTube's bot check? (adds ~15-30 s each)" "y"; then
            SLEEP_BETWEEN=1
        fi
    else
        IS_PLAYLIST=0
    fi

    if [[ "$MODE" == "music" ]]; then
        echo
        info "── Fetching metadata ──"
        fetch_preview "$URL" || true

        echo
        info "── Detected metadata ──"
        [[ -n "$PREVIEW_TITLE" ]] && preview_row "First track:" "$PREVIEW_TITLE"
        preview_row "Album artist:" "$PREVIEW_ALBUM_ARTIST"
        preview_row "Artist:"       "$PREVIEW_ARTIST"
        preview_row "Album:"        "$PREVIEW_ALBUM"
        preview_row "Year:"         "$PREVIEW_YEAR"
        preview_row "Genre:"        "$PREVIEW_GENRE"

        echo
        info "── Metadata (edit any field, or press Enter to keep) ──"
        ask_prefill "Album artist" "$PREVIEW_ALBUM_ARTIST" ALBUM_ARTIST
        ask_prefill "Artist"       "$PREVIEW_ARTIST"       ARTIST
        ask_prefill "Album"        "$PREVIEW_ALBUM"        ALBUM
        ask_prefill "Genre"        "$PREVIEW_GENRE"        GENRE
        ask_prefill "Year"         "$PREVIEW_YEAR"         YEAR

        # ---------- album artwork ----------
        if (( HAS_ARTWORK )); then
            echo
            info "── Album artwork ──"
            if confirm "Find album artwork on iTunes?" "y"; then
                # Build the seed search term from final (post-override) metadata.
                seed_term=""
                [[ -n "$ALBUM" ]]  && seed_term="$ALBUM"
                [[ -n "$ARTIST" ]] && seed_term="${seed_term:+$seed_term }$ARTIST"
                [[ -z "$seed_term" ]] && seed_term="$PREVIEW_TITLE"

                if pick_artwork "$seed_term"; then
                    ART_FILE="${TMPDIR_RUN}/cover.jpg"
                    info "Downloading artwork…"
                    if download_artwork "$ART_URL" "$ART_FILE"; then
                        ok "Artwork saved (will embed after download)."
                    else
                        warn "Couldn't download artwork — continuing without it."
                        ART_FILE=""
                    fi
                fi
            fi
        fi
    else
        echo
        info "── Subtitles ──"
        if confirm "Download subtitles?" "n"; then
            pick_subs "$URL" || true
        fi
    fi

    echo
    info "── Output template ──"
    if [[ "$MODE" == "music" ]]; then
        if [[ $IS_PLAYLIST -eq 1 ]]; then
            DEFAULT_TEMPLATE='%(playlist)s/%(playlist_index)02d - %(title)s.%(ext)s'
        else
            DEFAULT_TEMPLATE='%(uploader)s - %(title)s.%(ext)s'
        fi
    else
        # Video mode: file named by channel + title (fallback to uploader).
        if [[ $IS_PLAYLIST -eq 1 ]]; then
            DEFAULT_TEMPLATE='%(playlist)s/%(channel,uploader)s - %(title)s.%(ext)s'
        else
            DEFAULT_TEMPLATE='%(channel,uploader)s - %(title)s.%(ext)s'
        fi
    fi
    ask "Output template" "$DEFAULT_TEMPLATE" TEMPLATE

    # ---------- build the command ----------
    # ---------- build the command ----------
    if [[ "$MODE" == "music" ]]; then
        CMD=(yt-dlp
            -x
            --audio-format "$AUDIO_FORMAT"
            --audio-quality "$AUDIO_QUALITY"
            --add-metadata
            --embed-metadata
            -o "${DEST%/}/${TEMPLATE}"
        )

        # If the user picked a custom artwork, we'll embed it ourselves with ffmpeg
        # after yt-dlp finishes. Skip yt-dlp's embed-thumbnail to avoid embedding
        # YouTube's thumbnail first (wasteful — we'd just overwrite it).
        if [[ -z "$ART_FILE" ]]; then
            CMD+=(--embed-thumbnail --convert-thumbnails jpg)
        fi

        # Track which files yt-dlp actually produced (after the rename to its final
        # location). We use this list to post-process artwork below.
        CMD+=(--print-to-file "after_move:%(filepath)s" "$PRODUCED_LIST")

        # Always-useful parse-metadata mappings (used when overrides are blank)
        # Fall back only when the source has no native value (same chains as
        # fetch_preview), so real artist/album tags from YouTube Music survive.
        if [[ $IS_PLAYLIST -eq 1 ]]; then
            CMD+=(--parse-metadata "playlist_index:%(track_number)s")
            CMD+=(--parse-metadata "%(album,playlist_title)s:%(album)s")
        fi
        CMD+=(--parse-metadata "%(artist,uploader)s:%(artist)s")
        CMD+=(--parse-metadata "%(album_artist,uploader)s:%(album_artist)s")

        add_meta_override "album_artist" "$ALBUM_ARTIST" "$PREVIEW_ALBUM_ARTIST"
        add_meta_override "artist"       "$ARTIST"       "$PREVIEW_ARTIST"
        add_meta_override "album"        "$ALBUM"        "$PREVIEW_ALBUM"
        add_meta_override "genre"        "$GENRE"        "$PREVIEW_GENRE"
        add_meta_override "date"         "$YEAR"         "$PREVIEW_YEAR"

        if (( ${#FFMPEG_META[@]} > 0 )); then
            # --postprocessor-args takes a single shell-tokenized string for the named PP.
            # Quote each value so spaces survive the round-trip.
            pp_args="ffmpeg:"
            for tok in "${FFMPEG_META[@]}"; do
                # Wrap values that contain whitespace or shell-special chars in single quotes.
                if [[ "$tok" =~ [[:space:]\'\"\\\$] ]]; then
                    pp_args+=" '${tok//\'/\'\\\'\'}'"
                else
                    pp_args+=" $tok"
                fi
            done
            CMD+=(--postprocessor-args "$pp_args")
        fi
    else
        # Video mode: pick a format selector that prefers container-compatible
        # codecs but falls back so unusual videos still download.
        FMT_SELECTOR=$(build_video_format_selector "$VIDEO_QUALITY" "$AUDIO_BITRATE" "$VIDEO_FORMAT")
        CMD=(yt-dlp
            -f "$FMT_SELECTOR"
            --merge-output-format "$VIDEO_FORMAT"
            --embed-metadata
            -o "${DEST%/}/${TEMPLATE}"
        )
        # No post-process needed in video mode, but we keep the produced-files
        # list for consistency / future use.
        CMD+=(--print-to-file "after_move:%(filepath)s" "$PRODUCED_LIST")
        if (( ${#SUB_ARGS[@]} > 0 )); then
            CMD+=("${SUB_ARGS[@]}")
        fi
    fi

    CMD+=(--download-archive "$ARCHIVE" ${COOKIE_ARGS[@]+"${COOKIE_ARGS[@]}"})
    if (( SLEEP_BETWEEN )); then
        CMD+=(-t sleep)
    fi

    CMD+=("$URL")

    # ---------- preview & confirm ----------
    echo
    info "── Command preview ──"
    printf "%s" "${DIM}"
    # pretty-print one flag per line
    for token in "${CMD[@]}"; do
        if [[ "$token" == -* ]]; then
            printf "\n  %s" "$token"
        else
            printf " %q" "$token"
        fi
    done
    printf "%s\n\n" "${RESET}"

    if ! confirm "Run it?" "y"; then
        warn "Skipped."
        if confirm "Download another?" "n"; then continue; else break; fi
    fi

    # ---------- run ----------
    echo
    ok "Downloading to: $DEST"
    echo
    "${CMD[@]}" || warn "yt-dlp reported errors (see above). Run the same URL again to retry; finished items are skipped."

    # ---------- post-process: embed custom artwork (music mode only) ----------
    if [[ "$MODE" == "music" ]]; then
        if [[ -n "$ART_FILE" && -f "$ART_FILE" && -s "$PRODUCED_LIST" ]]; then
            echo
            info "── Embedding custom artwork ──"
            while IFS= read -r f; do
                [[ -z "$f" || ! -f "$f" ]] && continue
                printf "  %s%s%s\n" "$DIM" "${f##*/}" "$RESET"
                embed_artwork_file "$f" "$ART_FILE" || true
            done < "$PRODUCED_LIST"
        elif [[ -n "$ART_FILE" && ! -s "$PRODUCED_LIST" ]]; then
            warn "yt-dlp didn't report any produced files — skipping artwork embed."
        fi
    fi

    echo
    ok "Finished this download."

    echo
    if ! confirm "Download another?" "n"; then
        break
    fi
done

echo
ok "All done."
