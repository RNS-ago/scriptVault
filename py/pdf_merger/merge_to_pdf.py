"""Merge all images and PDFs in a folder into a single PDF file."""

from __future__ import annotations

import io
from pathlib import Path
from typing import Annotated

import typer
from PIL import Image
from pypdf import PdfReader, PdfWriter

app = typer.Typer(
    help="Merge images and PDFs in a folder into a single PDF.",
    add_completion=False,
)

IMAGE_EXTS = {".jpg", ".jpeg", ".png", ".webp", ".bmp", ".tif", ".tiff", ".gif"}
PDF_EXTS = {".pdf"}
SUPPORTED = IMAGE_EXTS | PDF_EXTS


def collect_files(folder: Path, recursive: bool) -> list[Path]:
    """Find all supported files in `folder`, sorted by name."""
    it = folder.rglob("*") if recursive else folder.glob("*")
    return sorted(
        (p for p in it if p.is_file() and p.suffix.lower() in SUPPORTED),
        key=lambda p: str(p).lower(),
    )


def image_to_pdf_pages(path: Path) -> list:
    """Convert an image file to a list of PDF pages."""
    with Image.open(path) as img:
        # PDF doesn't support alpha — flatten onto white if needed.
        if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
            img = img.convert("RGBA")
            bg = Image.new("RGB", img.size, (255, 255, 255))
            bg.paste(img, mask=img.split()[-1])
            img = bg
        elif img.mode != "RGB":
            img = img.convert("RGB")

        buf = io.BytesIO()
        img.save(buf, format="PDF")
        buf.seek(0)
        return list(PdfReader(buf).pages)


@app.command()
def merge(
    folder: Annotated[
        Path,
        typer.Argument(
            help="Folder containing images and/or PDFs.",
            exists=True,
            file_okay=False,
            dir_okay=True,
            readable=True,
            resolve_path=True,
        ),
    ],
    output: Annotated[
        Path,
        typer.Option("--output", "-o", help="Output PDF path."),
    ] = Path("merged.pdf"),
    recursive: Annotated[
        bool,
        typer.Option("--recursive", "-r", help="Recurse into subfolders."),
    ] = False,
    overwrite: Annotated[
        bool,
        typer.Option("--overwrite", "-y", help="Overwrite output if it exists."),
    ] = False,
) -> None:
    """Merge all images and PDFs in FOLDER into a single PDF."""
    if output.exists() and not overwrite:
        typer.secho(
            f"Refusing to overwrite {output} (pass --overwrite to allow).",
            fg=typer.colors.RED,
            err=True,
        )
        raise typer.Exit(1)

    files = collect_files(folder, recursive)
    if not files:
        typer.secho(f"No supported files found in {folder}.", fg=typer.colors.RED, err=True)
        raise typer.Exit(1)

    typer.echo(f"Merging {len(files)} file(s) from {folder}:")
    writer = PdfWriter()
    failed: list[tuple[Path, str]] = []

    for path in files:
        try:
            if path.suffix.lower() in PDF_EXTS:
                pages = list(PdfReader(str(path)).pages)
            else:
                pages = image_to_pdf_pages(path)
            for page in pages:
                writer.add_page(page)
            typer.secho(f"  ✓ {path.name}  ({len(pages)} page{'s' if len(pages) != 1 else ''})", fg=typer.colors.GREEN)
        except Exception as exc:  # noqa: BLE001
            failed.append((path, str(exc)))
            typer.secho(f"  ✗ {path.name}: {exc}", fg=typer.colors.RED, err=True)

    if len(writer.pages) == 0:
        typer.secho("Nothing was merged.", fg=typer.colors.RED, err=True)
        raise typer.Exit(1)

    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as f:
        writer.write(f)

    typer.secho(
        f"\nWrote {len(writer.pages)} page(s) to {output}",
        fg=typer.colors.CYAN,
        bold=True,
    )
    if failed:
        typer.secho(f"{len(failed)} file(s) skipped due to errors.", fg=typer.colors.YELLOW)


if __name__ == "__main__":
    app()
