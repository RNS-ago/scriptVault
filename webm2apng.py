#!/usr/bin/env python3
"""
webm2apng.py — Convert WebM (e.g. Telegram video stickers) to optimized APNG.

Pipeline: ffmpeg extracts palette-quantized frames at a capped frame rate,
then apngasm assembles them into a looping APNG with frame differencing.
APNG is lossless, so the fps cap + 256-color palette is what keeps size sane
(~6x smaller than a naive lossless conversion) with near-identical quality.

Requirements:
  - ffmpeg / ffprobe on PATH
  - Python package: apngasm-python   (pip install apngasm-python)

Usage:
  webm2apng.py                                 # interactive menu (no args)
  webm2apng.py FILE.webm [FILE2.webm ...]      # convert specific files
  webm2apng.py -d /path/to/folder              # convert every *.webm in folder
  webm2apng.py -d folder --fps 15 --colors 128 # smaller/lower-quality
  webm2apng.py FILE.webm -o out/               # write outputs to out/

Output: FILE.png next to the source (or in --outdir). The .png extension is the
standard for APNG. Originals are never modified.
"""
import argparse
import glob
import os
import shutil
import subprocess
import sys
import tempfile

# --- Color setup (only emit escape codes when stdout is a real terminal) -----
if sys.stdout.isatty():
    BOLD = "\033[1m"; DIM = "\033[2m"; GREEN = "\033[32m"
    CYAN = "\033[36m"; YELLOW = "\033[33m"; RED = "\033[31m"; RESET = "\033[0m"
else:
    BOLD = DIM = GREEN = CYAN = YELLOW = RED = RESET = ""

# Quality presets: label -> (fps, colors, description)
PRESETS = {
    "1": ("Optimize (recommended)", 20, 256, "capped 20fps, 256 colors — near-identical, ~6x smaller"),
    "2": ("High quality",           30, 256, "30fps, 256 colors — larger files, smoothest motion"),
    "3": ("Smaller",                15, 128, "15fps, 128 colors — smallest, slight quality loss"),
}


def convert(webm, out_png, fps, colors, max_frames=None,
            dither="bayer:bayer_scale=3"):
    """Convert a single webm to an optimized APNG. Returns frame count.

    max_frames, if set, caps the number of output frames (trims duration by
    frame count, which is robust even when the container's timestamps are
    bogus — as some WebM stickers' are).

    dither is the ffmpeg paletteuse dithering mode. The default (bayer)
    reduces banding; pass "none" for flat colors that compress much smaller.
    """
    from apngasm_python.apngasm import APNGAsm

    tmp = tempfile.mkdtemp(prefix="webm2apng_")
    try:
        vf = (
            f"fps={fps},split[s0][s1];"
            f"[s0]palettegen=max_colors={colors}:stats_mode=diff[p];"
            f"[s1][p]paletteuse=dither={dither}"
        )
        cmd = ["ffmpeg", "-y", "-v", "error", "-i", webm, "-vf", vf]
        if max_frames:
            cmd += ["-frames:v", str(int(max_frames))]
        cmd.append(os.path.join(tmp, "f_%05d.png"))
        subprocess.run(cmd, check=True)
        frames = sorted(glob.glob(os.path.join(tmp, "f_*.png")))
        if not frames:
            raise RuntimeError("ffmpeg extracted no frames")
        a = APNGAsm()
        for fr in frames:
            a.add_frame_from_file(fr, 1, fps)  # per-frame delay = 1/fps sec
        a.set_loops(0)                          # 0 = loop forever
        a.assemble(out_png)
        a.reset()
        return len(frames)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def check_deps():
    missing = [t for t in ("ffmpeg", "ffprobe") if shutil.which(t) is None]
    if missing:
        sys.exit(f"{RED}error:{RESET} not found on PATH: {', '.join(missing)}")
    try:
        import apngasm_python.apngasm  # noqa: F401
    except ImportError:
        sys.exit(f"{RED}error:{RESET} missing package. Run: pip install apngasm-python")


def run_batch(files, outdir, fps, colors):
    """Convert a list of files; print per-file progress and a total."""
    if outdir:
        os.makedirs(outdir, exist_ok=True)
    total_in = total_out = fails = 0
    for i, webm in enumerate(files, 1):
        base = os.path.splitext(os.path.basename(webm))[0] + ".png"
        out = os.path.join(outdir, base) if outdir else \
            os.path.splitext(webm)[0] + ".png"
        try:
            n = convert(webm, out, fps, colors)
            si, so = os.path.getsize(webm), os.path.getsize(out)
            total_in += si
            total_out += so
            print(f"{CYAN}[{i}/{len(files)}]{RESET} {os.path.basename(webm)} -> "
                  f"{GREEN}{base}{RESET}  {n}f  {si // 1024}KB -> {so // 1024}KB",
                  flush=True)
        except Exception as e:
            fails += 1
            print(f"{RED}[{i}/{len(files)}] FAILED{RESET} "
                  f"{os.path.basename(webm)}: {e}", flush=True)
    print(f"\n{BOLD}TOTAL:{RESET} {total_in // 1024 // 1024}MB webm -> "
          f"{total_out // 1024 // 1024}MB apng"
          + (f"  {RED}({fails} failed){RESET}" if fails else ""))
    return 1 if fails else 0


# --- Interactive mode --------------------------------------------------------
def ask(prompt, default=None):
    suffix = f" {DIM}[{default}]{RESET}" if default is not None else ""
    ans = input(f"{prompt}{suffix}: ").strip()
    return ans if ans else (default if default is not None else "")


def interactive():
    print(f"{BOLD}webm -> APNG converter{RESET}\n")

    # 1) Source directory / files
    default_dir = os.getcwd()
    src = ask(f"Folder containing {BOLD}.webm{RESET} files", default_dir)
    src = os.path.expanduser(src)
    if os.path.isfile(src) and src.endswith(".webm"):
        files = [src]
    elif os.path.isdir(src):
        files = sorted(glob.glob(os.path.join(src, "*.webm")))
    else:
        sys.exit(f"{RED}error:{RESET} not a folder or .webm file: {src}")
    if not files:
        sys.exit(f"{RED}error:{RESET} no .webm files found in {src}")
    print(f"  {GREEN}Found {len(files)} .webm file(s).{RESET}\n")

    # 2) Quality preset
    print(f"{BOLD}Quality preset:{RESET}")
    for k, (label, fps, colors, desc) in PRESETS.items():
        print(f"  {CYAN}{k}){RESET} {BOLD}{label}{RESET} {DIM}— {desc}{RESET}")
    while True:
        choice = ask("Select preset", "1")
        if choice in PRESETS:
            _, fps, colors, _ = PRESETS[choice]
            break
        print(f"  {RED}Invalid selection.{RESET}")

    # 3) Output location
    print(f"\n{BOLD}Output location:{RESET}")
    print(f"  {CYAN}1){RESET} Next to each source file {DIM}(default){RESET}")
    print(f"  {CYAN}2){RESET} A separate folder")
    outdir = None
    if ask("Select", "1") == "2":
        outdir = os.path.expanduser(ask("Output folder", os.path.join(src, "apng")))

    # 4) Confirm
    print(f"\n{BOLD}Ready:{RESET} {len(files)} file(s), {fps}fps / {colors} colors, "
          f"output -> {GREEN}{outdir or 'alongside sources'}{RESET}")
    if ask("Proceed? (yes/no)", "yes").lower() not in ("y", "yes"):
        sys.exit("Cancelled.")
    print()
    return run_batch(files, outdir, fps, colors)


def main():
    p = argparse.ArgumentParser(
        description="Convert WebM video stickers to optimized looping APNG.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("files", nargs="*", help="webm file(s) to convert")
    p.add_argument("-d", "--dir", help="convert every *.webm in this directory")
    p.add_argument("-o", "--outdir", help="write outputs here (default: next to source)")
    p.add_argument("--fps", type=int, default=20, help="max frame rate")
    p.add_argument("--colors", type=int, default=256, help="max palette colors (2-256)")
    args = p.parse_args()

    check_deps()

    # No inputs given -> interactive menu (matching the other scripts' style).
    if not args.files and not args.dir:
        if sys.stdin.isatty():
            return interactive()
        p.error("no input: pass webm file(s), -d DIR, or run interactively in a terminal")

    files = list(args.files)
    if args.dir:
        files += sorted(glob.glob(os.path.join(args.dir, "*.webm")))
    if not files:
        p.error("no .webm files found")

    return run_batch(files, args.outdir, args.fps, args.colors)


if __name__ == "__main__":
    sys.exit(main())
