#!/usr/bin/env python3
"""
Photo Grid Generator — 4×6" prints on A0 paper
=================================================
Lays out photos in standard 4×6 inch (102 × 152 mm) cells on A0 paper.
The grid size is auto-calculated to fit as many 4×6 slots as possible,
or you can override with --cols and --rows.

Usage:
    python photo_grid_a0.py /path/to/photos/folder
    python photo_grid_a0.py /path/to/photos/folder --cols 5 --rows 6
    python photo_grid_a0.py /path/to/photos/folder --landscape --title "Vacation 2025"
    python photo_grid_a0.py /path/to/photos/folder --photo-size 5x7 --gap 12

Options:
    --photo-size  Photo size in inches, WxH (default: 4x6)
    --cols        Override number of columns (default: auto-fit)
    --rows        Override number of rows (default: auto-fit)
    --margin      Page margin in mm (default: 20)
    --gap         Gap between photos in mm (default: 10)
    --landscape   Use landscape orientation for the A0 page
    --output      Output filename (default: photo_grid_a0.pdf)
    --title       Optional title at the top of the poster
    --bg-color    Background color as hex (default: #ffffff)
    --border      Border width around each photo in mm (default: 0)
    --border-color Border color as hex (default: #000000)
    --crop-fill   Crop-to-fill each cell instead of fit-inside (no letterboxing)
    --auto-rotate Auto-rotate landscape photos to fit portrait cells (and vice versa)
    --photo-orient  Force all cells to 'portrait' (4×6) or 'landscape' (6×4) (default: portrait)
"""

import argparse
import math
import sys
from pathlib import Path

from reportlab.lib.pagesizes import A0
from reportlab.lib.units import mm, inch
from reportlab.lib.colors import HexColor
from reportlab.pdfgen import canvas
from reportlab.lib.utils import ImageReader
from PIL import Image


SUPPORTED_FORMATS = {".jpg", ".jpeg", ".png", ".bmp", ".tiff", ".tif", ".webp"}

# Common photo print sizes (inches)
COMMON_SIZES = {
    "4x6": (4, 6),
    "5x7": (5, 7),
    "3.5x5": (3.5, 5),
    "8x10": (8, 10),
    "wallet": (2.5, 3.5),
}


def collect_images(folder: str) -> list[str]:
    """Collect all supported image files from a folder, sorted by name."""
    folder_path = Path(folder)
    if not folder_path.is_dir():
        print(f"Error: '{folder}' is not a valid directory.")
        sys.exit(1)
    images = sorted(
        str(p) for p in folder_path.iterdir()
        if p.suffix.lower() in SUPPORTED_FORMATS
    )
    if not images:
        print(f"Error: No supported images found in '{folder}'.")
        print(f"Supported formats: {', '.join(SUPPORTED_FORMATS)}")
        sys.exit(1)
    return images


def parse_photo_size(size_str: str) -> tuple[float, float]:
    """Parse photo size string like '4x6' into (width_inches, height_inches)."""
    if size_str.lower() in COMMON_SIZES:
        return COMMON_SIZES[size_str.lower()]
    try:
        w, h = size_str.lower().split("x")
        return float(w), float(h)
    except ValueError:
        print(f"Error: Invalid photo size '{size_str}'. Use format WxH (e.g. 4x6)")
        sys.exit(1)


def fit_image_in_cell(img_path: str, cell_w: float, cell_h: float, crop_fill: bool = False):
    """
    Calculate draw parameters for an image in a cell.
    - fit (default): letterbox, entire image visible, aspect ratio preserved.
    - crop_fill: fill the entire cell, cropping overflow, no letterboxing.
    """
    with Image.open(img_path) as img:
        img_w, img_h = img.size

    if crop_fill:
        scale = max(cell_w / img_w, cell_h / img_h)
    else:
        scale = min(cell_w / img_w, cell_h / img_h)

    draw_w = img_w * scale
    draw_h = img_h * scale
    offset_x = (cell_w - draw_w) / 2
    offset_y = (cell_h - draw_h) / 2
    return draw_w, draw_h, offset_x, offset_y


def _get_display_size(img_path: str) -> tuple[int, int]:
    """Get the image dimensions as they would appear after EXIF orientation correction."""
    from PIL import ImageOps
    with Image.open(img_path) as img:
        img = ImageOps.exif_transpose(img)
        return img.size


def needs_rotation(img_path: str, cell_w: float, cell_h: float) -> bool:
    """Check if an image's *display* orientation mismatches the cell."""
    img_w, img_h = _get_display_size(img_path)
    img_is_landscape = img_w > img_h
    cell_is_landscape = cell_w > cell_h
    # Square images never need rotation
    if img_w == img_h:
        return False
    return img_is_landscape != cell_is_landscape


def prepare_image(img_path: str, cell_w: float, cell_h: float, auto_rotate: bool, temp_dir: Path) -> str:
    """
    Prepare an image for placement:
    1. Apply EXIF orientation so photos from cameras/phones display correctly.
    2. If auto_rotate is True and the corrected image still mismatches the cell
       orientation, rotate it 90° CCW.
    Returns the path to a temp file ready for placement.
    """
    from PIL import ImageOps
    with Image.open(img_path) as img:
        # Always apply EXIF orientation first
        img = ImageOps.exif_transpose(img)
        img_w, img_h = img.size

        # Check orientation mismatch on the EXIF-corrected image
        img_is_landscape = img_w > img_h
        cell_is_landscape = cell_w > cell_h
        should_rotate = (auto_rotate
                         and img_w != img_h
                         and img_is_landscape != cell_is_landscape)

        if should_rotate:
            img = img.rotate(90, expand=True)
            temp_path = temp_dir / f"rotated_{Path(img_path).name}"
        else:
            temp_path = temp_dir / f"prep_{Path(img_path).name}"

        img.save(str(temp_path), quality=95)
        return str(temp_path)


def generate_grid(
    image_paths: list[str],
    output: str = "photo_grid_a0.pdf",
    photo_w_in: float = 4.0,
    photo_h_in: float = 6.0,
    cols: int | None = None,
    rows: int | None = None,
    margin_mm: float = 20,
    gap_mm: float = 10,
    landscape: bool = False,
    title: str | None = None,
    bg_color: str = "#ffffff",
    border_mm: float = 0,
    border_color: str = "#000000",
    center_grid: bool = True,
    crop_fill: bool = False,
    auto_rotate: bool = False,
):
    # Page dimensions
    page_w, page_h = A0
    if landscape:
        page_w, page_h = page_h, page_w

    margin = margin_mm * mm
    gap = gap_mm * mm
    border = border_mm * mm

    # Fixed cell size from photo dimensions
    cell_w = photo_w_in * inch
    cell_h = photo_h_in * inch

    # Reserve space for title
    title_space = 0
    if title:
        title_space = 30 * mm

    # Usable area
    usable_w = page_w - 2 * margin
    usable_h = page_h - 2 * margin - title_space

    # Auto-calculate grid if not specified
    if cols is None:
        cols = max(1, int((usable_w + gap) / (cell_w + gap)))
    if rows is None:
        rows = max(1, int((usable_h + gap) / (cell_h + gap)))

    # Validate that the grid fits
    needed_w = cols * cell_w + (cols - 1) * gap
    needed_h = rows * cell_h + (rows - 1) * gap
    if needed_w > usable_w + 0.1 or needed_h > usable_h + 0.1:
        print(f"Warning: {cols}x{rows} grid of {photo_w_in}x{photo_h_in}\" photos "
              f"needs {needed_w/mm:.0f}x{needed_h/mm:.0f} mm but only "
              f"{usable_w/mm:.0f}x{usable_h/mm:.0f} mm is available.")
        print("Reducing grid to fit...")
        cols = max(1, int((usable_w + gap) / (cell_w + gap)))
        rows = max(1, int((usable_h + gap) / (cell_h + gap)))
        needed_w = cols * cell_w + (cols - 1) * gap
        needed_h = rows * cell_h + (rows - 1) * gap

    # Centering offsets
    if center_grid:
        offset_x = margin + (usable_w - needed_w) / 2
        offset_y_top = margin + title_space + (usable_h - needed_h) / 2
    else:
        offset_x = margin
        offset_y_top = margin + title_space

    per_page = cols * rows
    total_pages = max(1, math.ceil(len(image_paths) / per_page))

    # Pre-process images (EXIF correction + optional rotation)
    import tempfile, shutil
    temp_dir = Path(tempfile.mkdtemp(prefix="photogrid_"))
    try:
        print("Pre-processing images (EXIF correction" + (" + auto-rotate)..." if auto_rotate else ")..."))
        prepared_paths = []
        rotated_count = 0
        for img_path in image_paths:
            if auto_rotate and needs_rotation(img_path, cell_w, cell_h):
                rotated_count += 1
            prepared_paths.append(
                prepare_image(img_path, cell_w, cell_h, auto_rotate, temp_dir)
            )
        if auto_rotate:
            print(f"   Rotated {rotated_count} image(s) to match cell orientation")

        _draw_pages(
            prepared_paths, output, page_w, page_h, cols, rows, per_page,
            total_pages, cell_w, cell_h, gap, border, margin, title,
            title_space, offset_x, offset_y_top, bg_color, border_color, crop_fill,
        )
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)

    print(f"✅ Created '{output}' — {total_pages} page(s), {len(image_paths)} photo(s)")
    print(f"   Grid: {cols} cols × {rows} rows = {per_page} slots/page")
    print(f"   Photo size: {photo_w_in}\" × {photo_h_in}\" ({photo_w_in*25.4:.0f} × {photo_h_in*25.4:.0f} mm)")
    print(f"   Paper: A0 {'landscape' if landscape else 'portrait'} ({page_w/mm:.0f} × {page_h/mm:.0f} mm)")
    if auto_rotate:
        print(f"   Auto-rotate: ON")


def _draw_pages(
    image_paths, output, page_w, page_h, cols, rows, per_page,
    total_pages, cell_w, cell_h, gap, border, margin, title,
    title_space, offset_x, offset_y_top, bg_color, border_color, crop_fill,
):

    c = canvas.Canvas(output, pagesize=(page_w, page_h))
    bg = HexColor(bg_color)

    for page_idx in range(total_pages):
        # Background
        c.setFillColor(bg)
        c.rect(0, 0, page_w, page_h, fill=True, stroke=False)

        # Title
        if title:
            c.setFillColor(HexColor("#000000"))
            c.setFont("Helvetica-Bold", 48)
            c.drawCentredString(page_w / 2, page_h - margin - 20 * mm, title)

        # Draw grid
        start = page_idx * per_page
        batch = image_paths[start : start + per_page]

        for idx, img_path in enumerate(batch):
            row = idx // cols
            col = idx % cols

            # Cell origin (bottom-left in PDF coordinates)
            x = offset_x + col * (cell_w + gap)
            y = page_h - offset_y_top - (row + 1) * cell_h - row * gap

            # Draw cell background (white) for letterboxed areas
            c.setFillColor(HexColor("#ffffff"))
            c.rect(x, y, cell_w, cell_h, fill=True, stroke=False)

            # Optional border
            if border > 0:
                c.setStrokeColor(HexColor(border_color))
                c.setLineWidth(border)
                c.rect(
                    x - border / 2, y - border / 2,
                    cell_w + border, cell_h + border,
                    fill=False, stroke=True,
                )

            # Draw image
            try:
                draw_w, draw_h, off_x, off_y = fit_image_in_cell(
                    img_path, cell_w, cell_h, crop_fill
                )

                if crop_fill:
                    # Clip to cell bounds so overflow is hidden
                    c.saveState()
                    clip = c.beginPath()
                    clip.rect(x, y, cell_w, cell_h)
                    c.clipPath(clip, stroke=0)
                    c.drawImage(
                        ImageReader(img_path),
                        x + off_x, y + off_y,
                        width=draw_w, height=draw_h,
                        preserveAspectRatio=True,
                        mask="auto",
                    )
                    c.restoreState()
                else:
                    c.drawImage(
                        ImageReader(img_path),
                        x + off_x, y + off_y,
                        width=draw_w, height=draw_h,
                        preserveAspectRatio=True,
                        mask="auto",
                    )
            except Exception as e:
                c.setFillColor(HexColor("#cccccc"))
                c.rect(x, y, cell_w, cell_h, fill=True, stroke=False)
                c.setFillColor(HexColor("#666666"))
                c.setFont("Helvetica", 12)
                c.drawCentredString(
                    x + cell_w / 2, y + cell_h / 2,
                    f"Error: {Path(img_path).name}"
                )
                print(f"Warning: Could not load '{img_path}': {e}")

        c.showPage()

    c.save()


def main():
    parser = argparse.ArgumentParser(
        description="Generate a photo grid with standard print sizes on A0 paper (PDF)"
    )
    parser.add_argument("folder", help="Folder containing images")
    parser.add_argument("--photo-size", default="4x6",
                        help="Photo print size in inches WxH (default: 4x6). "
                             f"Presets: {', '.join(COMMON_SIZES.keys())}")
    parser.add_argument("--cols", type=int, default=None,
                        help="Number of columns (default: auto-fit)")
    parser.add_argument("--rows", type=int, default=None,
                        help="Number of rows (default: auto-fit)")
    parser.add_argument("--margin", type=float, default=20,
                        help="Page margin in mm (default: 20)")
    parser.add_argument("--gap", type=float, default=10,
                        help="Gap between photos in mm (default: 10)")
    parser.add_argument("--landscape", action="store_true",
                        help="Landscape orientation for the A0 page")
    parser.add_argument("--output", default="photo_grid_a0.pdf",
                        help="Output filename")
    parser.add_argument("--title", default=None, help="Optional title text")
    parser.add_argument("--bg-color", default="#ffffff",
                        help="Background color (hex)")
    parser.add_argument("--border", type=float, default=0,
                        help="Border width in mm (default: 0)")
    parser.add_argument("--border-color", default="#000000",
                        help="Border color (hex)")
    parser.add_argument("--crop-fill", action="store_true",
                        help="Crop photos to fill cells (no letterboxing)")
    parser.add_argument("--auto-rotate", action="store_true",
                        help="Auto-rotate landscape photos to fit portrait cells (and vice versa)")
    parser.add_argument("--photo-orient", choices=["portrait", "landscape"], default=None,
                        help="Force cell orientation: 'portrait' = 4×6, 'landscape' = 6×4 (default: as given by --photo-size)")
    args = parser.parse_args()

    photo_w, photo_h = parse_photo_size(args.photo_size)
    # Apply orientation override
    if args.photo_orient == "landscape" and photo_h > photo_w:
        photo_w, photo_h = photo_h, photo_w
    elif args.photo_orient == "portrait" and photo_w > photo_h:
        photo_w, photo_h = photo_h, photo_w
    images = collect_images(args.folder)
    print(f"Found {len(images)} image(s) in '{args.folder}'")
    print(f"Photo size: {photo_w}\" × {photo_h}\"")

    generate_grid(
        image_paths=images,
        output=args.output,
        photo_w_in=photo_w,
        photo_h_in=photo_h,
        cols=args.cols,
        rows=args.rows,
        margin_mm=args.margin,
        gap_mm=args.gap,
        landscape=args.landscape,
        title=args.title,
        bg_color=args.bg_color,
        border_mm=args.border,
        border_color=args.border_color,
        crop_fill=args.crop_fill,
        auto_rotate=args.auto_rotate,
    )


if __name__ == "__main__":
    main()
