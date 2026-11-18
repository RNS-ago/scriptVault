"""Textual TUI for merging images and PDFs into a single PDF."""

from __future__ import annotations

from pathlib import Path

from pypdf import PdfReader, PdfWriter
from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen
from textual.widgets import (
    Button,
    DataTable,
    DirectoryTree,
    Footer,
    Header,
    Input,
    Label,
    RichLog,
    Switch,
    Tree,
)

from merge_to_pdf import PDF_EXTS, collect_files, image_to_pdf_pages


# ---------------------------------------------------------------------------
# Folder-picker modal
# ---------------------------------------------------------------------------
class FolderPickerScreen(ModalScreen[Path | None]):
    """Modal that lets the user pick any folder on the system.

    The tree's root can be moved by typing a path into the path input,
    pressing the Up button, or pressing the Home button.
    """

    CSS = """
    FolderPickerScreen {
        align: center middle;
    }
    #picker-dialog {
        width: 80%;
        height: 80%;
        max-width: 110;
        max-height: 42;
        background: $panel;
        border: round $accent;
        padding: 1 2;
    }
    #picker-title {
        height: 1;
        margin-bottom: 1;
        text-style: bold;
    }
    #picker-path-row {
        height: 3;
        margin-bottom: 1;
    }
    #picker-path-row Input {
        width: 1fr;
    }
    #picker-path-row Button {
        margin-left: 1;
    }
    #picker-tree {
        height: 1fr;
        border: round $accent;
        margin-bottom: 1;
    }
    #picker-selected {
        height: 1;
        margin-bottom: 1;
        color: $text-muted;
    }
    #picker-buttons {
        height: 3;
        align: right middle;
    }
    #picker-buttons Button {
        margin-left: 1;
    }
    """

    BINDINGS = [
        Binding("escape", "cancel", "Cancel"),
        Binding("alt+up", "go_up", "Up", show=False),
    ]

    def __init__(self, start: Path, title: str = "Select folder") -> None:
        super().__init__()
        expanded = start.expanduser()
        if expanded.is_dir():
            self.start_path = expanded.resolve()
        else:
            try:
                self.start_path = Path.home()
            except Exception:  # noqa: BLE001
                self.start_path = Path("/")
        self.dialog_title = title
        self.current_root = self.start_path
        self.current_selection = self.start_path

    def compose(self) -> ComposeResult:
        with Vertical(id="picker-dialog"):
            yield Label(self.dialog_title, id="picker-title")
            with Horizontal(id="picker-path-row"):
                yield Input(
                    value=str(self.current_root),
                    placeholder="Type any path and press Enter",
                    id="picker-path",
                )
                yield Button("↑ Up", id="picker-up")
                yield Button("~ Home", id="picker-home")
                yield Button("Go", id="picker-go", variant="primary")
            yield DirectoryTree(str(self.current_root), id="picker-tree")
            yield Label(f"Selected: {self.current_root}", id="picker-selected")
            with Horizontal(id="picker-buttons"):
                yield Button("Cancel", id="picker-cancel")
                yield Button("Select", id="picker-select", variant="primary")

    def on_mount(self) -> None:
        self.query_one("#picker-tree", DirectoryTree).focus()

    # --- navigation: change the tree's root --------------------------------
    @on(Input.Submitted, "#picker-path")
    def _path_submitted(self, event: Input.Submitted) -> None:
        self._set_root(Path(event.value))

    @on(Button.Pressed, "#picker-go")
    def _go_button(self) -> None:
        self._set_root(Path(self.query_one("#picker-path", Input).value))

    @on(Button.Pressed, "#picker-up")
    def _go_up_button(self) -> None:
        self.action_go_up()

    @on(Button.Pressed, "#picker-home")
    def _go_home_button(self) -> None:
        try:
            self._set_root(Path.home())
        except Exception:  # noqa: BLE001
            pass

    def action_go_up(self) -> None:
        parent = self.current_root.parent
        if parent != self.current_root:
            self._set_root(parent)

    def _set_root(self, new_root: Path) -> None:
        try:
            resolved = new_root.expanduser().resolve()
        except (OSError, RuntimeError) as exc:
            self._update_status(f"[red]Invalid path: {exc}[/red]")
            return
        if not resolved.is_dir():
            self._update_status(f"[red]Not a directory: {resolved}[/red]")
            return

        self.current_root = resolved
        self.current_selection = resolved
        self.query_one("#picker-path", Input).value = str(resolved)
        # Reassigning .path on a DirectoryTree triggers a reload of its contents.
        tree = self.query_one("#picker-tree", DirectoryTree)
        tree.path = str(resolved)
        self._update_status(f"Selected: {resolved}")

    # --- track what's highlighted inside the tree --------------------------
    @on(Tree.NodeHighlighted, "#picker-tree")
    def _node_highlighted(self, event: Tree.NodeHighlighted) -> None:
        data = event.node.data
        if data is None:
            return
        path = Path(getattr(data, "path", "")) if not isinstance(data, Path) else data
        if not str(path):
            return
        if path.is_dir():
            self.current_selection = path
            self._update_status(f"Selected: {path}")
        else:
            self.current_selection = path.parent
            self._update_status(f"Selected: {path.parent}  (file → its parent folder)")

    def _update_status(self, msg: str) -> None:
        self.query_one("#picker-selected", Label).update(msg)

    # --- confirm / cancel --------------------------------------------------
    @on(Button.Pressed, "#picker-cancel")
    def _cancel_button(self) -> None:
        self.action_cancel()

    @on(Button.Pressed, "#picker-select")
    def _select_button(self) -> None:
        self.dismiss(self.current_selection)

    def action_cancel(self) -> None:
        self.dismiss(None)


# ---------------------------------------------------------------------------
# Main app
# ---------------------------------------------------------------------------
class MergePdfApp(App):
    """Pick a folder, review the file order, and merge to a single PDF."""

    TITLE = "merge_to_pdf"
    SUB_TITLE = "Combine images and PDFs into one file"
    theme = "catppuccin-frappe"

    CSS = """
    #controls {
        height: auto;
        padding: 1 2;
        border: round $accent;
    }
    .row {
        height: 3;
        margin-bottom: 1;
    }
    .row Label {
        width: 12;
        content-align: left middle;
        height: 3;
    }
    .row Input {
        width: 1fr;
    }
    .row .browse {
        width: 12;
        margin-left: 1;
    }
    #switches {
        height: 3;
        align: left middle;
    }
    #switches Label {
        width: auto;
        margin-right: 1;
    }
    #switches Switch {
        margin-right: 3;
    }
    #buttons {
        height: 3;
        align: center middle;
    }
    #buttons Button {
        margin: 0 1;
    }
    #files-panel {
        height: 1fr;
        border: round $accent;
        padding: 0 1;
    }
    #files-panel > Label {
        margin: 0 0 1 0;
    }
    #files {
        height: 1fr;
    }
    #log-panel {
        height: 12;
        border: round $accent;
        padding: 0 1;
    }
    #log {
        height: 1fr;
    }
    """

    BINDINGS = [
        Binding("ctrl+r", "scan", "Scan folder"),
        Binding("ctrl+s", "merge", "Merge"),
        Binding("ctrl+up", "move_up", "Move up"),
        Binding("ctrl+down", "move_down", "Move down"),
        Binding("delete", "remove_file", "Remove from list"),
        Binding("q", "quit", "Quit"),
    ]

    def __init__(self) -> None:
        super().__init__()
        self.files: list[Path] = []

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with Vertical(id="controls"):
            with Horizontal(classes="row"):
                yield Label("Folder:")
                yield Input(placeholder="/path/to/folder", id="folder")
                yield Button("Browse...", id="browse-folder", classes="browse")
            with Horizontal(classes="row"):
                yield Label("Output:")
                yield Input(value="merged.pdf", id="output")
                yield Button("Browse...", id="browse-output", classes="browse")
            with Horizontal(id="switches"):
                yield Label("Recursive:")
                yield Switch(id="recursive", value=False)
                yield Label("Overwrite:")
                yield Switch(id="overwrite", value=False)
            with Horizontal(id="buttons"):
                yield Button("Scan", id="scan-btn", variant="primary")
                yield Button("Merge", id="merge-btn", variant="success")
                yield Button("Quit", id="quit-btn", variant="error")
        with Vertical(id="files-panel"):
            yield Label("Files (top → bottom = merge order). Ctrl+↑/↓ to reorder, Del to remove.")
            table = DataTable(id="files", cursor_type="row", zebra_stripes=True)
            table.add_columns("#", "Type", "Name", "Path")
            yield table
        with Vertical(id="log-panel"):
            yield Label("Log")
            yield RichLog(id="log", markup=True, highlight=True, wrap=True)
        yield Footer()

    # --- helpers -----------------------------------------------------------
    def _log(self, msg: str) -> None:
        self.query_one("#log", RichLog).write(msg)

    def _refresh_table(self) -> None:
        table = self.query_one("#files", DataTable)
        table.clear()
        for i, p in enumerate(self.files, 1):
            kind = "PDF" if p.suffix.lower() in PDF_EXTS else "IMG"
            table.add_row(str(i), kind, p.name, str(p.parent))

    def _starting_path_for(self, hint: str) -> Path:
        """Pick a sensible directory to open the picker at."""
        if hint:
            candidate = Path(hint).expanduser()
            if candidate.is_dir():
                return candidate.resolve()
            if candidate.parent.is_dir():
                return candidate.parent.resolve()
        try:
            return Path.home()
        except Exception:  # noqa: BLE001
            return Path.cwd()

    # --- button → action bridges ------------------------------------------
    @on(Button.Pressed, "#scan-btn")
    def _scan_button(self) -> None:
        self.action_scan()

    @on(Button.Pressed, "#merge-btn")
    def _merge_button(self) -> None:
        self.action_merge()

    @on(Button.Pressed, "#quit-btn")
    def _quit_button(self) -> None:
        self.exit()

    @on(Button.Pressed, "#browse-folder")
    def _browse_folder(self) -> None:
        current = self.query_one("#folder", Input).value.strip()
        start = self._starting_path_for(current)

        def handle(picked: Path | None) -> None:
            if picked is not None:
                self.query_one("#folder", Input).value = str(picked)

        self.push_screen(FolderPickerScreen(start, "Select source folder"), handle)

    @on(Button.Pressed, "#browse-output")
    def _browse_output(self) -> None:
        current = self.query_one("#output", Input).value.strip()
        if current:
            cur_path = Path(current).expanduser()
            filename = cur_path.name or "merged.pdf"
            start = self._starting_path_for(str(cur_path.parent))
        else:
            filename = "merged.pdf"
            start = self._starting_path_for("")

        def handle(picked: Path | None) -> None:
            if picked is not None:
                self.query_one("#output", Input).value = str(picked / filename)

        self.push_screen(FolderPickerScreen(start, "Select output folder"), handle)

    # --- actions -----------------------------------------------------------
    def action_scan(self) -> None:
        folder_str = self.query_one("#folder", Input).value.strip()
        if not folder_str:
            self._log("[red]Enter a folder path first.[/red]")
            return
        folder = Path(folder_str).expanduser()
        try:
            folder = folder.resolve(strict=True)
        except FileNotFoundError:
            self._log(f"[red]Folder not found: {folder}[/red]")
            return
        if not folder.is_dir():
            self._log(f"[red]Not a directory: {folder}[/red]")
            return
        recursive = self.query_one("#recursive", Switch).value
        self.files = collect_files(folder, recursive)
        self._refresh_table()
        if self.files:
            self._log(f"[cyan]Found {len(self.files)} file(s) in {folder}[/cyan]")
        else:
            self._log(f"[yellow]No supported files in {folder}.[/yellow]")

    def action_move_up(self) -> None:
        table = self.query_one("#files", DataTable)
        row = table.cursor_row
        if row is None or row <= 0 or row >= len(self.files):
            return
        self.files[row - 1], self.files[row] = self.files[row], self.files[row - 1]
        self._refresh_table()
        table.move_cursor(row=row - 1)

    def action_move_down(self) -> None:
        table = self.query_one("#files", DataTable)
        row = table.cursor_row
        if row is None or row < 0 or row >= len(self.files) - 1:
            return
        self.files[row], self.files[row + 1] = self.files[row + 1], self.files[row]
        self._refresh_table()
        table.move_cursor(row=row + 1)

    def action_remove_file(self) -> None:
        table = self.query_one("#files", DataTable)
        row = table.cursor_row
        if row is None or row < 0 or row >= len(self.files):
            return
        removed = self.files.pop(row)
        self._refresh_table()
        self._log(f"[yellow]Removed {removed.name} from list.[/yellow]")
        if self.files:
            new_row = min(row, len(self.files) - 1)
            table.move_cursor(row=new_row)

    def action_merge(self) -> None:
        if not self.files:
            self._log("[red]No files to merge — scan a folder first.[/red]")
            return
        output_str = self.query_one("#output", Input).value.strip()
        if not output_str:
            self._log("[red]Enter an output path.[/red]")
            return
        output = Path(output_str).expanduser().resolve()
        overwrite = self.query_one("#overwrite", Switch).value
        if output.exists() and not overwrite:
            self._log(f"[red]{output} exists — enable Overwrite to replace it.[/red]")
            return
        self.query_one("#merge-btn", Button).disabled = True
        self._do_merge(list(self.files), output)

    # --- background work ---------------------------------------------------
    @work(exclusive=True, thread=True)
    def _do_merge(self, files: list[Path], output: Path) -> None:
        def post(msg: str) -> None:
            self.call_from_thread(self._log, msg)

        post(f"[cyan]Merging {len(files)} file(s) into {output} ...[/cyan]")
        writer = PdfWriter()
        failed = 0
        for path in files:
            try:
                if path.suffix.lower() in PDF_EXTS:
                    pages = list(PdfReader(str(path)).pages)
                else:
                    pages = image_to_pdf_pages(path)
                for page in pages:
                    writer.add_page(page)
                pg = "page" if len(pages) == 1 else "pages"
                post(f"  [green]✓[/green] {path.name} ({len(pages)} {pg})")
            except Exception as exc:  # noqa: BLE001
                failed += 1
                post(f"  [red]✗[/red] {path.name}: {exc}")

        if len(writer.pages) == 0:
            post("[red]Nothing was merged.[/red]")
            self.call_from_thread(self._reenable_merge)
            return

        try:
            output.parent.mkdir(parents=True, exist_ok=True)
            with output.open("wb") as f:
                writer.write(f)
        except Exception as exc:  # noqa: BLE001
            post(f"[red]Failed to write {output}: {exc}[/red]")
            self.call_from_thread(self._reenable_merge)
            return

        post(f"[bold cyan]Wrote {len(writer.pages)} page(s) to {output}[/bold cyan]")
        if failed:
            post(f"[yellow]{failed} file(s) skipped due to errors.[/yellow]")
        self.call_from_thread(self._reenable_merge)

    def _reenable_merge(self) -> None:
        self.query_one("#merge-btn", Button).disabled = False


if __name__ == "__main__":
    MergePdfApp().run()
