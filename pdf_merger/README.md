# merge_to_pdf

Merge a folder full of images and PDFs into a single PDF — from the command line or a small terminal UI.

Supports `.pdf`, `.jpg`, `.jpeg`, `.png`, `.webp`, `.bmp`, `.tif`, `.tiff`, `.gif`.

## What's in the package

| File | Purpose |
|---|---|
| `setup.sh` / `setup.ps1` / `setup.cmd` | One-time setup. Creates `.venv` and installs dependencies. |
| `run.sh` / `run.ps1` / `run.cmd` | Ensures setup, then launches the TUI. |
| `merge_to_pdf.py` | The CLI (built with Typer). |
| `merge_to_pdf_tui.py` | The TUI (built with Textual). |
| `requirements.txt` | Pinned dependencies. |

On Windows, the `.cmd` files are double-clickable from File Explorer and don't require any PowerShell setup. The `.ps1` files do the actual work; `.cmd` are tiny wrappers that invoke them with the execution policy bypassed for that one call.

You only need Python 3.9+ installed. The setup script handles everything else.

## Two ways to use it

### 1. Just run the TUI (easiest)

**macOS / Linux**

```bash
chmod +x run.sh setup.sh    # one-time
./run.sh
```

**Windows**

Double-click **`run.cmd`** in File Explorer, or from a terminal:

```cmd
run.cmd
```

If you're already in PowerShell and prefer to use the script directly, `.\run.ps1` works the same — see *PowerShell on Windows* below for the one-time setup it requires.

`run.sh` / `run.cmd` / `run.ps1` calls the setup script automatically the first time, then launches the TUI. Subsequent runs start instantly.

### 2. Use the CLI directly (for experienced users)

Run the setup script once:

```bash
chmod +x setup.sh    # one-time, macOS/Linux only
./setup.sh           # macOS / Linux
setup.cmd            # Windows (double-clickable, no PS setup needed)
.\setup.ps1          # Windows (PowerShell, see note below)
```

It prints exactly how to call the CLI when it's done. Either invoke the venv's Python directly:

```bash
.venv/bin/python merge_to_pdf.py ./scans -o report.pdf            # macOS/Linux
.venv\Scripts\python.exe merge_to_pdf.py .\scans -o report.pdf    # Windows
```

…or activate the venv and call it normally:

```bash
source .venv/bin/activate          # macOS/Linux
.\.venv\Scripts\Activate.ps1       # Windows
python merge_to_pdf.py ./scans -o report.pdf
```

Setup is idempotent — it only reinstalls when `requirements.txt` has actually changed.

### PowerShell on Windows

Windows blocks `.ps1` scripts by default. You have two options:

- **Use `setup.cmd` and `run.cmd`.** The `.cmd` wrappers are unrestricted and call PowerShell with `-ExecutionPolicy Bypass` for that single invocation. Nothing to configure, double-clickable from Explorer.
- **Or relax the policy once.** Open PowerShell and run:
  ```powershell
  Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
  ```
  After that, `.\setup.ps1` and `.\run.ps1` work directly. Files downloaded from the internet may also need to be unblocked: right-click → **Properties** → **Unblock** → OK.

## CLI reference

```
python merge_to_pdf.py [OPTIONS] FOLDER
```

| Flag | Short | Description | Default |
|---|---|---|---|
| `--output` | `-o` | Path for the merged PDF | `merged.pdf` |
| `--recursive` | `-r` | Recurse into subfolders | off |
| `--overwrite` | `-y` | Overwrite an existing output file | off |
| `--help` | | Show help and exit | |

Files are merged in **alphabetical order** (case-insensitive). Prefix filenames with numbers (`01_`, `02_`, …) to control the sequence.

### Examples

```bash
python merge_to_pdf.py ~/Pictures/receipts-2025 -o receipts-2025.pdf
python merge_to_pdf.py ./quarterly -r -o Q3-final.pdf
python merge_to_pdf.py ./scans -o report.pdf --overwrite
```

## TUI reference

The TUI lets you preview the file list, reorder it, and remove items before merging — useful when alphabetical order isn't quite right and you don't want to rename files.

Workflow:

1. Either type/paste a folder path, or press **Browse...** to pick one from a directory tree.
2. Toggle **Recursive** if you want subfolders included.
3. Press **Scan** (or `Ctrl+R`).
4. Reorder or trim the file list.
5. Set the output path (typing or via **Browse...**) and press **Merge** (or `Ctrl+S`).

Inside the Browse dialog you can reach **any** folder on the system:

- The **path field** at the top accepts any path — type or paste it and press Enter (or click **Go**) to make the tree show that location.
- **↑ Up** moves the tree's root one level up — useful when you want to escape the script's own directory.
- **~ Home** jumps to your home directory.
- Inside the tree: arrow keys move the cursor, Enter expands/collapses folders, **Select** confirms the highlighted folder (picking a file resolves to its parent), and **Esc** cancels.

### Keyboard shortcuts

| Key | Action |
|---|---|
| `Ctrl+R` | Scan folder |
| `Ctrl+S` | Merge |
| `Ctrl+↑` / `Ctrl+↓` | Move highlighted file up/down |
| `Delete` | Remove highlighted file from the list |
| `Tab` / `Shift+Tab` | Move between fields |
| `q` | Quit |

The TUI works best in a modern terminal. On Windows that means **Windows Terminal** rather than the legacy `cmd.exe`.

## How images are handled

- Multi-page formats (e.g. multi-page TIFFs) are flattened to a single page.
- Transparent images (RGBA PNGs and similar) are placed on a white background — PDF has no alpha channel.
- All images are converted to RGB before being embedded.

## How PDFs are handled

Each page of every PDF is appended in order. Pages are copied, not re-rendered, so the original quality is preserved.

## Troubleshooting

**"python3 not found" / "python not found"**
Install Python 3.9 or newer from <https://www.python.org/downloads/>. On Windows, tick "Add Python to PATH" during install.

**"Permission denied" running `./run.sh` or `./setup.sh`**
Run `chmod +x run.sh setup.sh` once.

**"No supported files found"**
The folder is empty, or only contains unsupported file types. Add `-r` if your files are in subfolders.

**"Refusing to overwrite …"**
The output path already exists. Pick a different name with `-o`, or pass `--overwrite`.

**A specific file is skipped with an error**
The tool keeps going and merges the rest. Common causes are corrupt PDFs or unusual image encodings — open the file in a viewer to confirm it's intact.

**The TUI looks broken on Windows**
Use Windows Terminal (free in the Microsoft Store) instead of the legacy console.

**I want to force a fresh dependency install**
Delete the `.venv` folder next to the scripts. The next setup or run will recreate it.
