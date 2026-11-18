#!/usr/bin/env python3
"""
Image Resizer TUI — A terminal-based image resizing tool.

Dependencies:
    pip install Pillow textual

Usage:
    python image_resizer.py [image_path]
"""

import sys
import os
from pathlib import Path

from textual import on, work
from textual.app import App, ComposeResult
from textual.containers import Horizontal, Vertical, Center, Container
from textual.widgets import (
    Header, Footer, Static, Input, Button, Select,
    RadioButton, RadioSet, Label, DirectoryTree, Log,
    ProgressBar, Switch, Rule,
)
from textual.screen import ModalScreen
from textual.binding import Binding
from textual.validation import Number
from textual.message import Message

from PIL import Image


# ── Preset aspect ratios ──────────────────────────────────────────────────────
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
    "stretch": "Stretch — distort to fill exact dimensions",
    "crop": "Crop — fill dimensions, trim overflow",
    "pad": "Pad — fit inside dimensions, add background",
    "fit": "Fit — scale to fit, preserve original aspect",
}

OUTPUT_FORMATS = ["Same as input", "JPEG", "PNG", "WEBP", "BMP", "TIFF"]


# ── File Browser Screen ──────────────────────────────────────────────────────
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".tiff", ".tif", ".ico"}


class ImageDirectoryTree(DirectoryTree):
    """DirectoryTree that only shows image files and directories."""

    def filter_paths(self, paths):
        return [
            p for p in paths
            if p.is_dir() or p.suffix.lower() in IMAGE_EXTENSIONS
        ]


class FileBrowserScreen(ModalScreen[str]):
    """Modal screen for picking a file with navigation controls."""

    BINDINGS = [Binding("escape", "cancel", "Cancel")]
    DEFAULT_CSS = """
    FileBrowserScreen {
        align: center middle;
    }
    #browser-container {
        width: 80;
        height: 35;
        border: thick $accent;
        background: $surface;
        padding: 1 2;
    }
    #browser-container ImageDirectoryTree {
        height: 1fr;
    }
    #browser-title {
        text-style: bold;
        color: $text;
        padding-bottom: 1;
    }
    #nav-row {
        height: auto;
        margin-bottom: 1;
    }
    #nav-row Input {
        width: 1fr;
    }
    #nav-row Button {
        min-width: 6;
        margin-left: 1;
    }
    #shortcut-row {
        height: auto;
        margin-bottom: 1;
    }
    #shortcut-row Button {
        margin-right: 1;
        min-width: 10;
    }
    #bottom-row {
        height: auto;
        margin-top: 1;
    }
    #selected-label {
        width: 1fr;
        padding-top: 1;
        color: $text-muted;
    }
    """

    def __init__(self, start_path: str = ".") -> None:
        super().__init__()
        # Start from home directory by default, fall back to cwd
        home = str(Path.home())
        candidate = os.path.expanduser(start_path)
        if os.path.isdir(candidate) and candidate != ".":
            self.start_path = candidate
        else:
            self.start_path = home
        self.selected_path = ""

    def compose(self) -> ComposeResult:
        with Vertical(id="browser-container"):
            yield Static("📂 Select an image file", id="browser-title")

            # Navigation bar — type a path and press Go / Enter
            with Horizontal(id="nav-row"):
                yield Input(
                    value=self.start_path,
                    placeholder="Enter directory path...",
                    id="nav-input",
                )
                yield Button("Go", id="btn-go", variant="primary")

            # Quick-jump shortcuts
            with Horizontal(id="shortcut-row"):
                yield Button("🏠 Home", id="btn-home")
                yield Button("📁 Desktop", id="btn-desktop")
                yield Button("🖼️ Pictures", id="btn-pictures")
                yield Button("📥 Downloads", id="btn-downloads")
                yield Button("/ Root", id="btn-root")

            yield ImageDirectoryTree(self.start_path, id="dir-tree")

            with Horizontal(id="bottom-row"):
                yield Static("No file selected", id="selected-label")
                yield Button("Cancel", variant="default", id="btn-cancel")

    def _navigate_to(self, path: str) -> None:
        """Navigate the directory tree to a new root path."""
        path = os.path.expanduser(path.strip())
        if not os.path.isdir(path):
            return
        self.query_one("#nav-input", Input).value = path
        tree = self.query_one("#dir-tree", ImageDirectoryTree)
        tree.path = path
        tree.reload()

    @on(Input.Submitted, "#nav-input")
    def on_nav_submitted(self, event: Input.Submitted) -> None:
        self._navigate_to(event.value)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        btn = event.button.id
        if btn == "btn-cancel":
            self.dismiss("")
        elif btn == "btn-go":
            self._navigate_to(self.query_one("#nav-input", Input).value)
        elif btn == "btn-home":
            self._navigate_to(str(Path.home()))
        elif btn == "btn-desktop":
            self._navigate_to(str(Path.home() / "Desktop"))
        elif btn == "btn-pictures":
            self._navigate_to(str(Path.home() / "Pictures"))
        elif btn == "btn-downloads":
            self._navigate_to(str(Path.home() / "Downloads"))
        elif btn == "btn-root":
            self._navigate_to("/")

    def on_directory_tree_file_selected(self, event: DirectoryTree.FileSelected) -> None:
        path = str(event.path)
        ext = Path(path).suffix.lower()
        if ext in IMAGE_EXTENSIONS:
            self.dismiss(path)

    def on_directory_tree_directory_selected(self, event: DirectoryTree.DirectorySelected) -> None:
        self.query_one("#nav-input", Input).value = str(event.path)

    def action_cancel(self) -> None:
        self.dismiss("")


# ── Main App ──────────────────────────────────────────────────────────────────
class ImageResizerApp(App):
    """A TUI for resizing images to any aspect ratio."""

    TITLE = "Image Resizer"
    SUB_TITLE = "Resize images to any aspect ratio"
    theme = "catppuccin-mocha"

    CSS = """
    Screen {
        background: $surface;
    }

    #main {
        height: 1fr;
        padding: 1 2;
    }

    .section-title {
        text-style: bold;
        color: $accent;
        padding: 1 0 0 0;
    }

    .field-row {
        height: auto;
        padding: 0 0 0 2;
        margin-bottom: 1;
    }

    .field-row Label {
        width: 18;
        padding-top: 1;
    }

    .field-row Input {
        width: 20;
    }

    .field-row Select {
        width: 30;
    }

    .field-row Static {
        padding-top: 1;
    }

    #input-path-row Input {
        width: 45;
    }

    #output-path-row Input {
        width: 45;
    }

    #info-panel {
        height: auto;
        border: round $primary;
        padding: 1 2;
        margin: 1 0;
        background: $panel;
    }

    #log-panel {
        height: 8;
        border: round $primary;
        margin: 1 0;
    }

    #action-row {
        height: auto;
        padding: 1 0;
        align: center middle;
    }

    #action-row Button {
        margin: 0 2;
    }

    #lock-icon {
        padding-top: 1;
        width: 5;
    }

    .hidden {
        display: none;
    }

    #pad-color-row {
        height: auto;
        padding: 0 0 0 2;
        margin-bottom: 1;
    }

    #pad-color-row Label {
        width: 18;
        padding-top: 1;
    }

    #pad-color-row Input {
        width: 20;
    }
    """

    BINDINGS = [
        Binding("ctrl+o", "open_file", "Open"),
        Binding("ctrl+r", "resize", "Resize"),
        Binding("ctrl+q", "quit", "Quit"),
    ]

    def __init__(self, initial_path: str = "") -> None:
        super().__init__()
        self.initial_path = initial_path
        self.source_image: Image.Image | None = None
        self.lock_ratio = True

    def compose(self) -> ComposeResult:
        yield Header()

        with Vertical(id="main"):
            # ── Input file ────────────────────────────────────────────────
            yield Static("📄 Source Image", classes="section-title")
            with Horizontal(classes="field-row", id="input-path-row"):
                yield Label("File path:")
                yield Input(
                    placeholder="Path to image...",
                    id="input-path",
                    value=self.initial_path,
                )
                yield Button("Browse", id="btn-browse", variant="primary")

            yield Static(id="image-info")

            yield Rule()

            # ── Preset / Dimensions ───────────────────────────────────────
            yield Static("📐 Target Size", classes="section-title")

            with Horizontal(classes="field-row"):
                yield Label("Preset ratio:")
                yield Select(
                    [(name, name) for name in PRESETS],
                    value="Custom",
                    id="preset-select",
                )

            with Horizontal(classes="field-row"):
                yield Label("Width (px):")
                yield Input(
                    placeholder="e.g. 1920",
                    id="width-input",
                    validators=[Number(minimum=1, maximum=65535)],
                )
                yield Static("🔗", id="lock-icon")
                yield Label("Height (px):")
                yield Input(
                    placeholder="e.g. 1080",
                    id="height-input",
                    validators=[Number(minimum=1, maximum=65535)],
                )

            yield Rule()

            # ── Options ───────────────────────────────────────────────────
            yield Static("⚙️  Options", classes="section-title")

            with Horizontal(classes="field-row"):
                yield Label("Fit mode:")
                yield Select(
                    [(desc, key) for key, desc in FIT_MODES.items()],
                    value="crop",
                    id="fit-mode",
                )

            with Horizontal(classes="field-row", id="pad-color-row"):
                yield Label("Pad color:")
                yield Input(value="black", id="pad-color", placeholder="e.g. black, #ff0000")

            with Horizontal(classes="field-row"):
                yield Label("Resample:")
                yield Select(
                    [(name, name) for name in RESAMPLE_METHODS],
                    value="Lanczos (Best)",
                    id="resample-select",
                )

            with Horizontal(classes="field-row"):
                yield Label("Output format:")
                yield Select(
                    [(f, f) for f in OUTPUT_FORMATS],
                    value="Same as input",
                    id="format-select",
                )

            with Horizontal(classes="field-row"):
                yield Label("JPEG quality:")
                yield Input(value="95", id="jpeg-quality", validators=[Number(minimum=1, maximum=100)])

            yield Rule()

            # ── Output ────────────────────────────────────────────────────
            yield Static("💾 Output", classes="section-title")
            with Horizontal(classes="field-row", id="output-path-row"):
                yield Label("Save to:")
                yield Input(placeholder="Auto-generated if blank", id="output-path")

            # ── Actions ───────────────────────────────────────────────────
            with Horizontal(id="action-row"):
                yield Button("✨ Resize", id="btn-resize", variant="success")
                yield Button("🔄 Reset", id="btn-reset", variant="warning")

            # ── Log ───────────────────────────────────────────────────────
            yield Log(id="log-panel")

        yield Footer()

    def on_mount(self) -> None:
        self.log_msg("Ready. Open an image or enter a path to get started.")
        if self.initial_path:
            self.load_image(self.initial_path)

    # ── Helpers ───────────────────────────────────────────────────────────────

    def log_msg(self, msg: str) -> None:
        log = self.query_one("#log-panel", Log)
        log.write_line(msg)

    def load_image(self, path: str) -> None:
        path = os.path.expanduser(path.strip())
        if not os.path.isfile(path):
            self.log_msg(f"❌ File not found: {path}")
            self.source_image = None
            self.query_one("#image-info", Static).update("")
            return

        try:
            img = Image.open(path)
            img.load()  # force load to catch errors
            self.source_image = img
            size_kb = os.path.getsize(path) / 1024
            info_text = (
                f"  Loaded: {Path(path).name}  |  "
                f"{img.width}×{img.height} px  |  "
                f"{img.mode}  |  "
                f"{size_kb:.1f} KB"
            )
            self.query_one("#image-info", Static).update(info_text)
            self.query_one("#width-input", Input).value = str(img.width)
            self.query_one("#height-input", Input).value = str(img.height)
            self.log_msg(f"✅ Loaded {Path(path).name} ({img.width}×{img.height})")
        except Exception as e:
            self.source_image = None
            self.query_one("#image-info", Static).update("")
            self.log_msg(f"❌ Failed to open image: {e}")

    def generate_output_path(self, input_path: str, fmt: str) -> str:
        p = Path(input_path)
        ext_map = {
            "JPEG": ".jpg",
            "PNG": ".png",
            "WEBP": ".webp",
            "BMP": ".bmp",
            "TIFF": ".tiff",
        }
        ext = ext_map.get(fmt, p.suffix)
        return str(p.parent / f"{p.stem}_resized{ext}")

    # ── Event handlers ────────────────────────────────────────────────────────

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-browse":
            self.action_open_file()
        elif event.button.id == "btn-resize":
            self.action_resize()
        elif event.button.id == "btn-reset":
            self.action_reset()

    def action_open_file(self) -> None:
        def on_result(path: str) -> None:
            if path:
                self.query_one("#input-path", Input).value = path
                self.load_image(path)

        # Start from the directory of the current input, or home
        current = self.query_one("#input-path", Input).value.strip()
        start = os.path.dirname(os.path.expanduser(current)) if current else str(Path.home())
        if not os.path.isdir(start):
            start = str(Path.home())
        self.push_screen(FileBrowserScreen(start), on_result)

    @on(Input.Submitted, "#input-path")
    def on_input_path_submitted(self, event: Input.Submitted) -> None:
        self.load_image(event.value)

    @on(Input.Changed, "#input-path")
    def on_input_path_changed(self, event: Input.Changed) -> None:
        # Auto-load if file exists
        path = os.path.expanduser(event.value.strip())
        if os.path.isfile(path):
            self.load_image(path)

    @on(Select.Changed, "#preset-select")
    def on_preset_changed(self, event: Select.Changed) -> None:
        preset = PRESETS.get(str(event.value))
        if preset and self.source_image:
            ratio_w, ratio_h = preset
            # Calculate target dimensions preserving rough size
            base = max(self.source_image.width, self.source_image.height)
            if ratio_w >= ratio_h:
                w = base
                h = int(base * ratio_h / ratio_w)
            else:
                h = base
                w = int(base * ratio_w / ratio_h)
            self.query_one("#width-input", Input).value = str(w)
            self.query_one("#height-input", Input).value = str(h)
            self.log_msg(f"Preset → {event.value}: {w}×{h}")

    @on(Select.Changed, "#fit-mode")
    def on_fit_mode_changed(self, event: Select.Changed) -> None:
        pad_row = self.query_one("#pad-color-row")
        if str(event.value) == "pad":
            pad_row.remove_class("hidden")
        else:
            pad_row.add_class("hidden")

    def action_reset(self) -> None:
        self.query_one("#input-path", Input).value = ""
        self.query_one("#width-input", Input).value = ""
        self.query_one("#height-input", Input).value = ""
        self.query_one("#output-path", Input).value = ""
        self.query_one("#image-info", Static).update("")
        self.query_one("#preset-select", Select).value = "Custom"
        self.query_one("#fit-mode", Select).value = "crop"
        self.query_one("#jpeg-quality", Input).value = "95"
        self.source_image = None
        self.log_msg("🔄 Reset all fields.")

    def action_resize(self) -> None:
        self.do_resize()

    @work(thread=True)
    def do_resize(self) -> None:
        # Gather values
        input_path = self.query_one("#input-path", Input).value.strip()
        if not input_path or not os.path.isfile(os.path.expanduser(input_path)):
            self.call_from_thread(self.log_msg, "❌ No valid input file selected.")
            return

        input_path = os.path.expanduser(input_path)

        w_str = self.query_one("#width-input", Input).value.strip()
        h_str = self.query_one("#height-input", Input).value.strip()

        if not w_str or not h_str:
            self.call_from_thread(self.log_msg, "❌ Please enter both width and height.")
            return

        try:
            target_w = int(w_str)
            target_h = int(h_str)
        except ValueError:
            self.call_from_thread(self.log_msg, "❌ Width and height must be integers.")
            return

        if target_w < 1 or target_h < 1:
            self.call_from_thread(self.log_msg, "❌ Dimensions must be at least 1px.")
            return

        fit_mode = str(self.query_one("#fit-mode", Select).value)
        resample_name = str(self.query_one("#resample-select", Select).value)
        resample = RESAMPLE_METHODS.get(resample_name, Image.LANCZOS)
        out_format = str(self.query_one("#format-select", Select).value)
        pad_color = self.query_one("#pad-color", Input).value.strip() or "black"
        jpeg_q = int(self.query_one("#jpeg-quality", Input).value or "95")

        output_path = self.query_one("#output-path", Input).value.strip()
        if not output_path:
            output_path = self.generate_output_path(
                input_path,
                out_format if out_format != "Same as input" else "",
            )

        output_path = os.path.expanduser(output_path)

        self.call_from_thread(
            self.log_msg,
            f"⏳ Resizing {Path(input_path).name} → {target_w}×{target_h} ({fit_mode})...",
        )

        try:
            img = Image.open(input_path)

            # Convert palette / RGBA for JPEG
            if out_format == "JPEG" or (
                out_format == "Same as input" and Path(input_path).suffix.lower() in {".jpg", ".jpeg"}
            ):
                if img.mode in ("RGBA", "P", "PA", "LA"):
                    bg = Image.new("RGB", img.size, pad_color)
                    if img.mode == "P":
                        img = img.convert("RGBA")
                    bg.paste(img, mask=img.split()[-1] if "A" in img.mode else None)
                    img = bg
                elif img.mode != "RGB":
                    img = img.convert("RGB")

            # ── Resize logic ──────────────────────────────────────────────
            if fit_mode == "stretch":
                result = img.resize((target_w, target_h), resample)

            elif fit_mode == "crop":
                # Scale so smallest dim fills target, then center-crop
                scale = max(target_w / img.width, target_h / img.height)
                new_w = int(img.width * scale)
                new_h = int(img.height * scale)
                img = img.resize((new_w, new_h), resample)
                left = (new_w - target_w) // 2
                top = (new_h - target_h) // 2
                result = img.crop((left, top, left + target_w, top + target_h))

            elif fit_mode == "pad":
                from PIL import ImageOps
                result = ImageOps.pad(img, (target_w, target_h), method=resample, color=pad_color)

            elif fit_mode == "fit":
                img.thumbnail((target_w, target_h), resample)
                result = img

            else:
                result = img.resize((target_w, target_h), resample)

            # ── Save ──────────────────────────────────────────────────────
            save_kwargs = {}
            if out_format == "Same as input":
                save_fmt = None  # Pillow infers from extension
            else:
                save_fmt = out_format

            if (save_fmt or "").upper() in ("JPEG", "") and Path(output_path).suffix.lower() in (
                ".jpg", ".jpeg"
            ):
                save_kwargs["quality"] = jpeg_q
                save_kwargs["optimize"] = True

            if save_fmt:
                result.save(output_path, format=save_fmt, **save_kwargs)
            else:
                result.save(output_path, **save_kwargs)

            size_kb = os.path.getsize(output_path) / 1024
            self.call_from_thread(
                self.log_msg,
                f"✅ Saved: {output_path} ({result.width}×{result.height}, {size_kb:.1f} KB)",
            )

        except Exception as e:
            self.call_from_thread(self.log_msg, f"❌ Error: {e}")


# ── Entry point ───────────────────────────────────────────────────────────────
def main():
    path = sys.argv[1] if len(sys.argv) > 1 else ""
    app = ImageResizerApp(initial_path=path)
    app.run()


if __name__ == "__main__":
    main()
