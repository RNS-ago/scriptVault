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

    if ! raw=$(yt-dlp --skip-download --no-warnings --ignore-no-formats-error \
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

# ---------- installers ----------
# Make sure $1 is on PATH for the rest of this session. No-op if it already is.
ensure_on_path() {
    local dir="$1"
    case ":$PATH:" in
        *":$dir:"*) ;;
        *) export PATH="$dir:$PATH" ;;
    esac
}

# Download the official yt-dlp static binary into ~/.local/bin.
install_ytdlp() {
    if ! command -v curl >/dev/null 2>&1; then
        err "curl is required to install yt-dlp. Please install curl first."
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
    # If $bindir wasn't on PATH before we prepend it, warn that the change
    # is session-only and the user needs to update their shell rc to persist.
    local was_on_path=0
    case ":$PATH:" in *":$bindir:"*) was_on_path=1 ;; esac
    ensure_on_path "$bindir"
    if (( ! was_on_path )); then
        warn "Added ${bindir} to PATH for this session only."
        warn "To make it permanent, add to your shell config:"
        warn "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    fi
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

# ---------- preflight ----------
# yt-dlp may already be installed at ~/.local/bin/yt-dlp from a previous run
# of this script even if that dir isn't yet on the user's PATH. Patch it in
# proactively so we don't offer to "install" something that's already there.
[[ -x "$HOME/.local/bin/yt-dlp" ]] && ensure_on_path "$HOME/.local/bin"
[[ -x "$HOME/.deno/bin/deno"   ]] && ensure_on_path "$HOME/.deno/bin"

if ! command -v yt-dlp >/dev/null 2>&1; then
    warn "yt-dlp is not installed or not on PATH."
    if confirm "Install yt-dlp now (to ~/.local/bin)?" "y"; then
        install_ytdlp || exit 1
    else
        err "yt-dlp is required. Aborting."
        echo "Other ways to install: pipx install yt-dlp   |   brew install yt-dlp"
        exit 1
    fi
fi

# Deno is required for full YouTube support as of yt-dlp 2025.11.12. Without
# it, downloads still work for now but format availability is limited. Offer
# the install but don't make it mandatory.
if ! command -v deno >/dev/null 2>&1; then
    warn "Deno (JS runtime) not found."
    warn "yt-dlp needs a JS runtime for full YouTube support; without it some formats are unavailable."
    if confirm "Install Deno now?" "y"; then
        install_deno || warn "Continuing without Deno — YouTube downloads may be limited."
    else
        warn "Continuing without Deno — YouTube downloads may be limited."
    fi
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    warn "ffmpeg not found — audio extraction and embedding may fail."
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
│        yt-dlp music downloader       │
╰──────────────────────────────────────╯${RESET}
${DIM}Press Enter to accept the [default] for any field. Type :q to abort.${RESET}

EOF

# ---------- gather inputs ----------
ask "URL" "" URL
if [[ -z "$URL" ]]; then
    err "URL is required."
    exit 1
fi

DEFAULT_DEST="${HOME}/Media/Music"
ask "Destination directory" "$DEFAULT_DEST" DEST
DEST="${DEST/#\~/$HOME}"
mkdir -p "$DEST"

ask "Audio format (mp3/m4a/opus/flac/wav)" "mp3" AUDIO_FORMAT
ask "Audio quality (0=best, 9=worst)"      "0"   AUDIO_QUALITY

echo
info "── Playlist vs single track ──"
if confirm "Is this a playlist/album?" "y"; then
    IS_PLAYLIST=1
else
    IS_PLAYLIST=0
fi

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

echo
info "── Output template ──"
if [[ $IS_PLAYLIST -eq 1 ]]; then
    DEFAULT_TEMPLATE='%(playlist)s/%(playlist_index)02d - %(title)s.%(ext)s'
else
    DEFAULT_TEMPLATE='%(uploader)s - %(title)s.%(ext)s'
fi
ask "Output template" "$DEFAULT_TEMPLATE" TEMPLATE

# ---------- build the command ----------
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
if [[ $IS_PLAYLIST -eq 1 ]]; then
    CMD+=(--parse-metadata "playlist_index:%(track_number)s")
    CMD+=(--parse-metadata "playlist_title:%(album)s")
fi
CMD+=(--parse-metadata "uploader:%(artist)s")
CMD+=(--parse-metadata "uploader:%(album_artist)s")

# Force-set metadata tags by passing -metadata args straight to ffmpeg.
# We only emit an override when the user's value differs from what yt-dlp
# would have picked up on its own (passed in as $detected). If they match,
# yt-dlp's own metadata mapping handles it and we keep the command minimal.
FFMPEG_META=()
add_meta_override() {
    local tag="$1" value="$2" detected="${3-}"
    [[ -z "$value" ]] && return 0
    [[ -n "$detected" && "$value" == "$detected" ]] && return 0
    FFMPEG_META+=(-metadata "${tag}=${value}")
}

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
    warn "Aborted."
    exit 0
fi

# ---------- run ----------
echo
ok "Downloading to: $DEST"
echo
"${CMD[@]}"

# ---------- post-process: embed custom artwork ----------
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

echo
ok "Done."
