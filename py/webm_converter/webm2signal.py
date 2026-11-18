#!/usr/bin/env python3
"""
webm2signal.py — Turn WebM stickers into Signal-ready sticker files.

Builds on webm2apng.py and enforces Signal's sticker requirements:
  * Animated  -> APNG   (non-animated -> PNG)
  * <= 300 KB per sticker
  * <= 3 seconds of animation
  * 512 x 512 px

Because Signal's 300 KB cap is very tight for animated stickers, this script
adaptively steps DOWN quality per file (trim to 3s, then lower fps / colors,
with flat non-dithered palettes) until each sticker fits, and reports the
settings each one landed on so you can see which were degraded to fit. A final
lossless pyoxipng pass squeezes a bit more. Static stickers become plain PNGs.

Signal recommendations that this script can't infer from opaque source video
(transparent background, 16 px margin, outlines for light/dark) are printed as
reminders — add them in your art if you need them.

Requirements:
  ffmpeg/ffprobe on PATH, plus:  pip install apngasm-python pyoxipng
  (pyoxipng is optional but strongly recommended — without it many animated
   stickers cannot reach 300 KB.)

Usage:
  webm2signal.py                          # interactive menu
  webm2signal.py -d FOLDER                # all *.webm in FOLDER -> FOLDER/signal
  webm2signal.py a.webm b.webm -o out/
  webm2signal.py -d FOLDER --target-kb 300 --max-seconds 3 --no-cover
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile

# Reuse the base converter (same directory).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import webm2apng  # noqa: E402
from webm2apng import (BOLD, DIM, GREEN, CYAN, YELLOW, RED, RESET)  # noqa: E402

# Signal hard limits
SIGNAL_SIZE_KB = 300
SIGNAL_MAX_SECONDS = 3
SIGNAL_DIM = 512

# Quality ladder for animated stickers: (fps, colors), best -> worst.
# We descend until the file fits the size cap. Flat (dither=none) palettes are
# used throughout — they compress far smaller and match Signal's flat/outlined
# recommendation.
LADDER = [
    (30, 256), (24, 192), (20, 128), (18, 96), (15, 64),
    (12, 48), (10, 32), (10, 16), (8, 16), (6, 8), (5, 6), (5, 4),
]
STATIC_COLORS = [256, 128, 64, 32, 16]

# Optional lossless recompressor.
try:
    import oxipng
    HAVE_OXI = True
except ImportError:
    HAVE_OXI = False


def oxi_inplace(path, level=4):
    """Losslessly recompress a PNG/APNG in place (if pyoxipng present).
    Returns the resulting file size in bytes."""
    if HAVE_OXI:
        data = open(path, "rb").read()          # read BEFORE opening for write
        try:
            out = oxipng.optimize_from_memory(data, level=level)
            if len(out) < len(data):
                with open(path, "wb") as f:
                    f.write(out)
        except Exception:
            pass  # keep the un-optimized file on any oxipng hiccup
    return os.path.getsize(path)


def frame_count(webm):
    """Number of frames in the source (via ffprobe)."""
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-count_frames", "-select_streams", "v:0",
         "-show_entries", "stream=nb_read_frames", "-of",
         "default=noprint_wrappers=1:nokey=1", webm],
        capture_output=True, text=True, check=True).stdout.strip()
    try:
        return int(out)
    except ValueError:
        return 0


def build_static(webm, out_png, target_bytes):
    """Write a single-frame PNG under the size cap. Returns result dict."""
    tmp = tempfile.mkdtemp(prefix="sig_static_")
    try:
        result = None
        for colors in STATIC_COLORS:
            frame = os.path.join(tmp, "s.png")
            vf = (f"scale={SIGNAL_DIM}:{SIGNAL_DIM}:force_original_aspect_ratio="
                  f"decrease,split[s0][s1];[s0]palettegen=max_colors={colors}[p];"
                  f"[s1][p]paletteuse=dither=none")
            subprocess.run(["ffmpeg", "-y", "-v", "error", "-i", webm,
                            "-frames:v", "1", "-vf", vf, frame], check=True)
            shutil.copyfile(frame, out_png)
            size = oxi_inplace(out_png)
            result = dict(kind="static", frames=1, fps=0, colors=colors, size=size)
            if size <= target_bytes:
                result["ok"] = True
                return result
        result["ok"] = result["size"] <= target_bytes
        return result
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def build_animated(webm, out_png, target_bytes, max_seconds):
    """Assemble an APNG under the size cap by descending the quality ladder."""
    result = None
    for fps, colors in LADDER:
        n = webm2apng.convert(webm, out_png, fps, colors,
                              max_frames=fps * max_seconds, dither="none")
        raw = os.path.getsize(out_png)
        # oxipng only saves ~8%, so only bother running it when this rung is
        # close enough to the cap to plausibly fit — skip it on the huge early
        # rungs we're going to discard anyway.
        size = oxi_inplace(out_png) if raw <= target_bytes * 1.15 else raw
        result = dict(kind="animated", frames=n, fps=fps, colors=colors, size=size)
        if size <= target_bytes:
            result["ok"] = True
            return result
    result["ok"] = False   # smallest rung still over the cap (rare)
    return result


def make_sticker(webm, out_png, target_bytes, max_seconds):
    if frame_count(webm) <= 1:
        return build_static(webm, out_png, target_bytes)
    return build_animated(webm, out_png, target_bytes, max_seconds)


def make_cover(src_webm, out_png, target_bytes):
    """512x512 PNG cover from the first frame of src_webm."""
    r = build_static(src_webm, out_png, target_bytes)
    return r["ok"]


def kb(n):
    return f"{n // 1024}KB"


def run(files, outdir, target_kb, max_seconds, cover_from):
    os.makedirs(outdir, exist_ok=True)
    target_bytes = target_kb * 1000  # treat "300kb" as 300,000 bytes (stricter)
    if not HAVE_OXI:
        print(f"{YELLOW}warning:{RESET} pyoxipng not installed — files will be "
              f"larger and some may exceed {target_kb} KB. "
              f"Install with: pip install pyoxipng\n")

    rows, over = [], 0
    for i, webm in enumerate(files, 1):
        base = os.path.splitext(os.path.basename(webm))[0] + ".png"
        out = os.path.join(outdir, base)
        try:
            r = make_sticker(webm, out, target_bytes, max_seconds)
        except Exception as e:
            print(f"{RED}[{i}/{len(files)}] FAILED{RESET} "
                  f"{os.path.basename(webm)}: {e}", flush=True)
            rows.append((base, "ERROR", "", "", False))
            over += 1
            continue

        dur = r["frames"] / r["fps"] if r["fps"] else 0
        fits = r["ok"]
        over += 0 if fits else 1
        setting = (f"{r['fps']}fps/{r['colors']}c" if r["kind"] == "animated"
                   else f"{r['colors']}c")
        tag = f"{GREEN}OK{RESET}" if fits else f"{RED}OVER {target_kb}KB{RESET}"
        print(f"{CYAN}[{i}/{len(files)}]{RESET} {base}  {r['kind'][:4]}  "
              f"{r['frames']}f {setting}  {kb(r['size'])}  "
              f"{dur:.1f}s  {tag}", flush=True)
        rows.append((base, r["kind"], setting, kb(r["size"]), fits))

    # Cover
    if cover_from:
        cover = os.path.join(outdir, "cover.png")
        try:
            ok = make_cover(cover_from, cover, target_bytes)
            print(f"\n{BOLD}Cover:{RESET} cover.png from "
                  f"{os.path.basename(cover_from)} "
                  f"({kb(os.path.getsize(cover))}) "
                  f"{GREEN+'OK'+RESET if ok else RED+'OVER'+RESET}")
        except Exception as e:
            print(f"{RED}cover failed:{RESET} {e}")

    # Summary + compliance reminders
    ok_count = sum(1 for r in rows if r[4])
    print(f"\n{BOLD}Signal compliance:{RESET} {ok_count}/{len(rows)} within "
          f"{target_kb} KB, 512x512, <= {max_seconds}s -> {GREEN}{outdir}{RESET}")
    if over:
        print(f"{YELLOW}{over} file(s) could not reach {target_kb} KB even at the "
              f"lowest quality — these are busy, opaque, full-frame animations. "
              f"Consider a transparent redraw or fewer frames.{RESET}")
    print(f"\n{DIM}Reminders (add in Signal's upload UI / your art):{RESET}")
    print(f"{DIM}  - assign one emoji per sticker; set pack title + author")
    print(f"  - max 200 stickers per pack")
    print(f"  - recommended: transparent background, 16px margin, outline for "
          f"light/dark, seamless loop (source video here is opaque){RESET}")
    return 1 if over else 0


# --- Interactive mode (matches the style of the other scripts) ---------------
def ask(prompt, default=None):
    suffix = f" {DIM}[{default}]{RESET}" if default is not None else ""
    ans = input(f"{prompt}{suffix}: ").strip()
    return ans if ans else (default if default is not None else "")


def interactive():
    print(f"{BOLD}webm -> Signal sticker prep{RESET}\n")
    src = os.path.expanduser(ask(f"Folder containing {BOLD}.webm{RESET} files",
                                 os.getcwd()))
    if os.path.isfile(src) and src.endswith(".webm"):
        files = [src]; base_dir = os.path.dirname(src)
    elif os.path.isdir(src):
        files = sorted(glob.glob(os.path.join(src, "*.webm"))); base_dir = src
    else:
        sys.exit(f"{RED}error:{RESET} not a folder or .webm file: {src}")
    if not files:
        sys.exit(f"{RED}error:{RESET} no .webm files found in {src}")
    print(f"  {GREEN}Found {len(files)} .webm file(s).{RESET}\n")

    outdir = os.path.expanduser(ask("Output folder",
                                    os.path.join(base_dir, "signal")))
    target_kb = int(ask("Max size per sticker (KB)", str(SIGNAL_SIZE_KB)))
    max_seconds = int(ask("Max animation length (seconds)",
                          str(SIGNAL_MAX_SECONDS)))
    want_cover = ask("Generate cover.png from first sticker? (yes/no)",
                     "yes").lower() in ("y", "yes")
    cover_from = files[0] if want_cover else None

    print(f"\n{BOLD}Ready:{RESET} {len(files)} file(s), <= {target_kb}KB / "
          f"<= {max_seconds}s, cover={'yes' if cover_from else 'no'}, "
          f"output -> {GREEN}{outdir}{RESET}")
    if ask("Proceed? (yes/no)", "yes").lower() not in ("y", "yes"):
        sys.exit("Cancelled.")
    print()
    return run(files, outdir, target_kb, max_seconds, cover_from)


def check_deps():
    webm2apng.check_deps()  # ffmpeg/ffprobe + apngasm-python


def main():
    p = argparse.ArgumentParser(
        description="Prepare WebM stickers as Signal-ready APNG/PNG files.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    p.add_argument("files", nargs="*", help="webm file(s)")
    p.add_argument("-d", "--dir", help="process every *.webm in this directory")
    p.add_argument("-o", "--outdir", help="output folder "
                   "(default: <dir>/signal or ./signal)")
    p.add_argument("--target-kb", type=int, default=SIGNAL_SIZE_KB,
                   help="max size per sticker in KB")
    p.add_argument("--max-seconds", type=int, default=SIGNAL_MAX_SECONDS,
                   help="max animation length")
    p.add_argument("--no-cover", action="store_true", help="skip cover.png")
    p.add_argument("--cover-from", help="webm to build cover.png from "
                   "(default: first input)")
    args = p.parse_args()

    check_deps()

    if not args.files and not args.dir:
        if sys.stdin.isatty():
            return interactive()
        p.error("no input: pass webm file(s), -d DIR, or run in a terminal")

    files = list(args.files)
    base_dir = args.dir or (os.path.dirname(files[0]) if files else os.getcwd())
    if args.dir:
        files += sorted(glob.glob(os.path.join(args.dir, "*.webm")))
    if not files:
        p.error("no .webm files found")

    outdir = args.outdir or os.path.join(base_dir, "signal")
    cover_from = None if args.no_cover else (args.cover_from or files[0])
    return run(files, outdir, args.target_kb, args.max_seconds, cover_from)


if __name__ == "__main__":
    sys.exit(main())
