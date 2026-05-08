#!/usr/bin/env python3
"""
Image Resizer TUI — A terminal-based image resizing tool.

Dependencies:
    pip install Pillow textual

Usage:
    python image_resizer.py [image_path]
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Container, Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.validation import Number
from textual.widgets import (
    Button,
    Collapsible,
    DirectoryTree,
    Footer,
    Header,
    Input,
    Label,
    RichLog,
    Select,
    Static,
)

from PIL import Image

# ── Constants ─────────────────────────────────────────────────────────────────

IMAGE_EXTENSIONS = {
    ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".tiff", ".tif", ".ico",
}

PRESETS = {
    "Custom": None,
    "1:1 (Square)": (1, 1),
    "4:3 (Classic)": (4, 3),
    "3:2 (Photo)": (3, 2),
    "16:9 (Widescreen)": (16, 9),
    "21:9 (Ultrawide)": (21, 9),
    "9:16 (Vertical Video)": (9, 16),
    "3:4 (Portrait)": (3, 4),
    "2:3 (Portrait Photo)": (2, 3),
    "5:4 (Large Format)": (5, 4),
    "A4 (210:297)": (210, 297),
}

RESAMPLE_METHODS = {
    "Lanczos (Best)": Image.LANCZOS,
    "Bicubic": Image.BICUBIC,
    "Bilinear": Image.BILINEAR,
    "Nearest": Image.NEAREST,
}

FIT_MODES = {
    "stretch": "Stretch — distort to fill",
    "crop": "Crop — fill & trim overflow",
    "pad": "Pad — fit inside, add background",
    "fit": "Fit — scale to fit, keep aspect",
}

OUTPUT_FORMATS = ["Same as input", "JPEG", "PNG", "WEBP", "BMP", "TIFF"]


# ── Custom Widgets ────────────────────────────────────────────────────────────

class ImageDirectoryTree(DirectoryTree):
    """DirectoryTree filtered to only show image files."""

    def filter_paths(self, paths):
        return [
            p for p in paths
            if p.is_dir() or p.suffix.lower() in IMAGE_EXTENSIONS
        ]


class FieldRow(Horizontal):
    """A label + widget row used in forms."""
    DEFAULT_CSS = """
    FieldRow {
        height: auto;
        margin: 0 0 1 0;

        & > Label {
            width: 16;
            padding: 1 1 0 0;
            text-style: bold;
            color: $text-muted;
        }
        & > Input {
            width: 1fr;
        }
        & > Select {
            width: 1fr;
        }
        & > Button {
            margin-left: 1;
        }
    }
    """


# ── File Browser Modal ───────────────────────────────────────────────────────

class FileBrowserScreen(ModalScreen[str]):
    """Modal for navigating the filesystem and picking an image."""

    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    DEFAULT_CSS = """
    FileBrowserScreen {
        align: center middle;

        & #browser {
            width: 80;
            height: 36;
            border: thick $accent;
            background: $surface;
            padding: 1 2;
            border-title-color: $accent;
            border-title-style: bold;
        }

        & #nav-bar {
            height: auto;
            margin-bottom: 1;

            & > Input {
                width: 1fr;
            }
            & > Button {
                min-width: 6;
                margin-left: 1;
            }
        }

        & #shortcuts {
            height: auto;
            margin-bottom: 1;

            & > Button {
                margin-right: 1;
                min-width: 12;
            }
        }

        & ImageDirectoryTree {
            height: 1fr;
        }

        & #browser-footer {
            height: auto;
            margin-top: 1;
            align: right middle;
        }
    }
    """

    def __init__(self, start_path: str = ".") -> None:
        super().__init__()
        candidate = os.path.expanduser(start_path)
        self.start_path = (
            candidate
            if os.path.isdir(candidate) and candidate != "."
            else str(Path.home())
        )

    def compose(self) -> ComposeResult:
        with Container(id="browser") as c:
            c.border_title = "Open Image"
            with Horizontal(id="nav-bar"):
                yield Input(value=self.start_path, placeholder="Path...", id="nav-input")
                yield Button("Go", id="btn-go", variant="primary")

            with Horizontal(id="shortcuts"):
                yield Button("Home", id="btn-home")
                yield Button("Desktop", id="btn-desktop")
                yield Button("Pictures", id="btn-pictures")
                yield Button("Downloads", id="btn-downloads")
                yield Button("/", id="btn-root")

            yield ImageDirectoryTree(self.start_path, id="dir-tree")

            with Horizontal(id="browser-footer"):
                yield Button("Cancel", id="btn-cancel")

    def _navigate_to(self, path: str) -> None:
        path = os.path.expanduser(path.strip())
        if not os.path.isdir(path):
            return
        self.query_one("#nav-input", Input).value = path
        tree = self.query_one("#dir-tree", ImageDirectoryTree)
        tree.path = path
        tree.reload()

    @on(Input.Submitted, "#nav-input")
    def _nav_submitted(self, event: Input.Submitted) -> None:
        self._navigate_to(event.value)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        targets = {
            "btn-go": lambda: self._navigate_to(
                self.query_one("#nav-input", Input).value
            ),
            "btn-cancel": lambda: self.dismiss(""),
            "btn-home": lambda: self._navigate_to(str(Path.home())),
            "btn-desktop": lambda: self._navigate_to(str(Path.home() / "Desktop")),
            "btn-pictures": lambda: self._navigate_to(str(Path.home() / "Pictures")),
            "btn-downloads": lambda: self._navigate_to(
                str(Path.home() / "Downloads")
            ),
            "btn-root": lambda: self._navigate_to("/"),
        }
        handler = targets.get(event.button.id or "")
        if handler:
            handler()

    def on_directory_tree_file_selected(
        self, event: DirectoryTree.FileSelected
    ) -> None:
        if Path(str(event.path)).suffix.lower() in IMAGE_EXTENSIONS:
            self.dismiss(str(event.path))

    def on_directory_tree_directory_selected(
        self, event: DirectoryTree.DirectorySelected
    ) -> None:
        self.query_one("#nav-input", Input).value = str(event.path)

    def action_cancel(self) -> None:
        self.dismiss("")


# ── Main Application ─────────────────────────────────────────────────────────

class ImageResizerApp(App):
    """A TUI for resizing images to any aspect ratio."""

    TITLE = "Image Resizer"
    SUB_TITLE = "Resize · Crop · Pad · Fit"
    theme = "catppuccin-mocha"

    CSS = """
    Screen {
        background: $surface;
    }

    #sidebar {
        width: 42;
        dock: left;
        border-right: solid $border;
        padding: 1;

        & #source-panel {
            height: auto;
            border: round $border;
            padding: 1;
            border-title-color: $accent;
            border-title-style: bold;
            margin-bottom: 1;

            & Input {
                width: 1fr;
                margin-bottom: 1;
            }
            & Button {
                width: 1fr;
            }
            & #image-info {
                height: auto;
                color: $text-muted;
                margin-top: 1;
            }
        }

        & #output-panel {
            height: auto;
            border: round $border;
            padding: 1;
            border-title-color: $accent;
            border-title-style: bold;

            & Input {
                width: 1fr;
                margin-bottom: 1;
            }
            & Select {
                width: 1fr;
            }
        }

        & #actions {
            height: auto;
            margin-top: 1;
            align: center middle;

            & > Button {
                margin: 0 1;
                min-width: 16;
            }
        }
    }

    #main-area {
        width: 1fr;
        padding: 1;

        & Collapsible {
            margin-bottom: 1;
            padding: 0;
            background: transparent;
        }

        & FieldRow {
            margin: 0 0 1 1;
        }

        & #dim-row {
            height: auto;
            margin: 0 0 1 1;

            & > Label {
                width: 8;
                padding: 1 1 0 0;
                text-style: bold;
                color: $text-muted;
            }
            & > Input {
                width: 14;
            }
            & > Static {
                width: 5;
                padding: 1 1 0 1;
                text-align: center;
                color: $accent;
            }
        }

        & #log-container {
            height: 1fr;
            min-height: 6;
            border: round $border;
            border-title-color: $accent;
            border-title-style: bold;

            & RichLog {
                height: 1fr;
                scrollbar-gutter: stable;
            }
        }
    }

    .hidden {
        display: none;
    }
    """

    BINDINGS = [
        Binding("ctrl+o", "open_file", "Open", tooltip="Browse for an image file"),
        Binding("ctrl+r", "resize", "Resize", tooltip="Resize the loaded image"),
        Binding("ctrl+q", "quit", "Quit", tooltip="Exit the application"),
    ]

    def __init__(self, initial_path: str = "") -> None:
        super().__init__()
        self.initial_path = initial_path
        self.source_image: Image.Image | None = None

    def compose(self) -> ComposeResult:
        yield Header(show_clock=True)

        # ── Left sidebar: source + output + actions ───────────────────────
        with Vertical(id="sidebar"):
            with Container(id="source-panel") as sp:
                sp.border_title = "Source Image"
                yield Input(
                    placeholder="Path to image...",
                    id="input-path",
                    value=self.initial_path,
                )
                yield Button("Browse...", id="btn-browse", variant="primary")
                yield Static("No image loaded", id="image-info")

            with Container(id="output-panel") as op:
                op.border_title = "Output"
                yield Input(placeholder="Auto-generated if blank", id="output-path")
                yield Select(
                    [(f, f) for f in OUTPUT_FORMATS],
                    value="Same as input",
                    id="format-select",
                    prompt="Format",
                )

            with Horizontal(id="actions"):
                yield Button("Resize", id="btn-resize", variant="success")
                yield Button("Reset", id="btn-reset", variant="error")

        # ── Main area: options + log ──────────────────────────────────────
        with VerticalScroll(id="main-area"):
            with Collapsible(title="Aspect Ratio & Dimensions", collapsed=False):
                with FieldRow():
                    yield Label("Preset")
                    yield Select(
                        [(name, name) for name in PRESETS],
                        value="Custom",
                        id="preset-select",
                        prompt="Ratio",
                    )

                with Horizontal(id="dim-row"):
                    yield Label("W")
                    yield Input(
                        placeholder="width",
                        id="width-input",
                        validators=[Number(minimum=1, maximum=65535)],
                    )
                    yield Static("×")
                    yield Label("H")
                    yield Input(
                        placeholder="height",
                        id="height-input",
                        validators=[Number(minimum=1, maximum=65535)],
                    )

            with Collapsible(title="Resize Options", collapsed=False):
                with FieldRow():
                    yield Label("Fit mode")
                    yield Select(
                        [(desc, key) for key, desc in FIT_MODES.items()],
                        value="crop",
                        id="fit-mode",
                    )

                with FieldRow(id="pad-color-row", classes="hidden"):
                    yield Label("Pad color")
                    yield Input(
                        value="black",
                        id="pad-color",
                        placeholder="e.g. black, #ff0000",
                    )

                with FieldRow():
                    yield Label("Resample")
                    yield Select(
                        [(name, name) for name in RESAMPLE_METHODS],
                        value="Lanczos (Best)",
                        id="resample-select",
                    )

            with Collapsible(title="JPEG Settings", collapsed=True):
                with FieldRow():
                    yield Label("Quality")
                    yield Input(
                        value="95",
                        id="jpeg-quality",
                        validators=[Number(minimum=1, maximum=100)],
                    )

            with Container(id="log-container") as lc:
                lc.border_title = "Log"
                yield RichLog(highlight=True, markup=True, id="log-panel")

        yield Footer()

    # ── Lifecycle ─────────────────────────────────────────────────────────

    def on_mount(self) -> None:
        self._log("Ready. [bold]Ctrl+O[/] to open · [bold]Ctrl+R[/] to resize.")
        if self.initial_path:
            self.load_image(self.initial_path)

    # ── Helpers ───────────────────────────────────────────────────────────

    def _log(self, msg: str) -> None:
        self.query_one("#log-panel", RichLog).write(msg)

    def load_image(self, path: str) -> None:
        path = os.path.expanduser(path.strip())
        info = self.query_one("#image-info", Static)

        if not os.path.isfile(path):
            self._log(f"[red]File not found:[/] {path}")
            self.source_image = None
            info.update("No image loaded")
            return

        try:
            img = Image.open(path)
            img.load()
            self.source_image = img
            size_kb = os.path.getsize(path) / 1024
            name = Path(path).name
            info.update(
                f"[bold]{name}[/]\n"
                f"{img.width}×{img.height}  {img.mode}  {size_kb:.0f} KB"
            )
            self.query_one("#width-input", Input).value = str(img.width)
            self.query_one("#height-input", Input).value = str(img.height)
            self._log(f"[green]Loaded[/] {name} ({img.width}×{img.height})")
        except Exception as e:
            self.source_image = None
            info.update("No image loaded")
            self._log(f"[red]Error:[/] {e}")

    def _output_path(self, input_path: str, fmt: str) -> str:
        p = Path(input_path)
        ext_map = {
            "JPEG": ".jpg", "PNG": ".png", "WEBP": ".webp",
            "BMP": ".bmp", "TIFF": ".tiff",
        }
        ext = ext_map.get(fmt, p.suffix)
        return str(p.parent / f"{p.stem}_resized{ext}")

    # ── Event handlers ────────────────────────────────────────────────────

    def on_button_pressed(self, event: Button.Pressed) -> None:
        dispatch = {
            "btn-browse": self.action_open_file,
            "btn-resize": self.action_resize,
            "btn-reset": self.action_reset,
        }
        handler = dispatch.get(event.button.id or "")
        if handler:
            handler()

    def action_open_file(self) -> None:
        def on_result(path: str) -> None:
            if path:
                self.query_one("#input-path", Input).value = path
                self.load_image(path)

        current = self.query_one("#input-path", Input).value.strip()
        start = (
            os.path.dirname(os.path.expanduser(current))
            if current
            else str(Path.home())
        )
        if not os.path.isdir(start):
            start = str(Path.home())
        self.push_screen(FileBrowserScreen(start), on_result)

    @on(Input.Submitted, "#input-path")
    def _input_path_submitted(self, event: Input.Submitted) -> None:
        self.load_image(event.value)

    @on(Input.Changed, "#input-path")
    def _input_path_changed(self, event: Input.Changed) -> None:
        path = os.path.expanduser(event.value.strip())
        if os.path.isfile(path):
            self.load_image(path)

    @on(Select.Changed, "#preset-select")
    def _preset_changed(self, event: Select.Changed) -> None:
        preset = PRESETS.get(str(event.value))
        if preset and self.source_image:
            rw, rh = preset
            base = max(self.source_image.width, self.source_image.height)
            if rw >= rh:
                w, h = base, int(base * rh / rw)
            else:
                h, w = base, int(base * rw / rh)
            self.query_one("#width-input", Input).value = str(w)
            self.query_one("#height-input", Input).value = str(h)
            self._log(f"Preset [bold]{event.value}[/] → {w}×{h}")

    @on(Select.Changed, "#fit-mode")
    def _fit_mode_changed(self, event: Select.Changed) -> None:
        row = self.query_one("#pad-color-row")
        if str(event.value) == "pad":
            row.remove_class("hidden")
        else:
            row.add_class("hidden")

    def action_reset(self) -> None:
        self.query_one("#input-path", Input).value = ""
        self.query_one("#width-input", Input).value = ""
        self.query_one("#height-input", Input).value = ""
        self.query_one("#output-path", Input).value = ""
        self.query_one("#image-info", Static).update("No image loaded")
        self.query_one("#preset-select", Select).value = "Custom"
        self.query_one("#fit-mode", Select).value = "crop"
        self.query_one("#jpeg-quality", Input).value = "95"
        self.source_image = None
        self._log("[yellow]Reset[/] all fields.")

    def action_resize(self) -> None:
        self._do_resize()

    @work(thread=True)
    def _do_resize(self) -> None:
        input_path = self.query_one("#input-path", Input).value.strip()
        if not input_path or not os.path.isfile(os.path.expanduser(input_path)):
            self.call_from_thread(self._log, "[red]No valid input file.[/]")
            return

        input_path = os.path.expanduser(input_path)
        w_str = self.query_one("#width-input", Input).value.strip()
        h_str = self.query_one("#height-input", Input).value.strip()

        if not w_str or not h_str:
            self.call_from_thread(self._log, "[red]Enter both width and height.[/]")
            return

        try:
            tw, th = int(w_str), int(h_str)
        except ValueError:
            self.call_from_thread(
                self._log, "[red]Width/height must be integers.[/]"
            )
            return

        if tw < 1 or th < 1:
            self.call_from_thread(self._log, "[red]Dimensions must be ≥ 1px.[/]")
            return

        fit = str(self.query_one("#fit-mode", Select).value)
        resample_name = str(self.query_one("#resample-select", Select).value)
        resample = RESAMPLE_METHODS.get(resample_name, Image.LANCZOS)
        out_fmt = str(self.query_one("#format-select", Select).value)
        pad_color = self.query_one("#pad-color", Input).value.strip() or "black"
        jpeg_q = int(self.query_one("#jpeg-quality", Input).value or "95")

        output = self.query_one("#output-path", Input).value.strip()
        if not output:
            output = self._output_path(
                input_path, out_fmt if out_fmt != "Same as input" else ""
            )
        output = os.path.expanduser(output)

        name = Path(input_path).name
        self.call_from_thread(
            self._log,
            f"[cyan]Resizing[/] {name} → {tw}×{th} ({fit})...",
        )

        try:
            img = Image.open(input_path)

            # Handle JPEG colour mode conversion
            is_jpeg = out_fmt == "JPEG" or (
                out_fmt == "Same as input"
                and Path(input_path).suffix.lower() in {".jpg", ".jpeg"}
            )
            if is_jpeg:
                if img.mode in ("RGBA", "P", "PA", "LA"):
                    bg = Image.new("RGB", img.size, pad_color)
                    if img.mode == "P":
                        img = img.convert("RGBA")
                    bg.paste(
                        img, mask=img.split()[-1] if "A" in img.mode else None
                    )
                    img = bg
                elif img.mode != "RGB":
                    img = img.convert("RGB")

            # Resize
            if fit == "stretch":
                result = img.resize((tw, th), resample)
            elif fit == "crop":
                scale = max(tw / img.width, th / img.height)
                nw, nh = int(img.width * scale), int(img.height * scale)
                img = img.resize((nw, nh), resample)
                l, t = (nw - tw) // 2, (nh - th) // 2
                result = img.crop((l, t, l + tw, t + th))
            elif fit == "pad":
                from PIL import ImageOps
                result = ImageOps.pad(
                    img, (tw, th), method=resample, color=pad_color
                )
            elif fit == "fit":
                img.thumbnail((tw, th), resample)
                result = img
            else:
                result = img.resize((tw, th), resample)

            # Save
            save_kwargs: dict = {}
            save_fmt = None if out_fmt == "Same as input" else out_fmt
            if (save_fmt or "").upper() in ("JPEG", "") and Path(
                output
            ).suffix.lower() in (".jpg", ".jpeg"):
                save_kwargs["quality"] = jpeg_q
                save_kwargs["optimize"] = True

            if save_fmt:
                result.save(output, format=save_fmt, **save_kwargs)
            else:
                result.save(output, **save_kwargs)

            kb = os.path.getsize(output) / 1024
            self.call_from_thread(
                self._log,
                f"[green]Saved[/] {output}\n"
                f"       {result.width}×{result.height}  {kb:.1f} KB",
            )

        except Exception as e:
            self.call_from_thread(self._log, f"[red]Error:[/] {e}")


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    path = sys.argv[1] if len(sys.argv) > 1 else ""
    ImageResizerApp(initial_path=path).run()


if __name__ == "__main__":
    main()
