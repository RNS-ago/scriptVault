# Launch the merge_to_pdf TUI. Ensures the venv is set up first.

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

& (Join-Path $ScriptDir "setup.ps1") -Quiet
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$VenvPy = Join-Path $ScriptDir ".venv\Scripts\python.exe"
if (-not (Test-Path $VenvPy)) {
    $VenvPy = Join-Path $ScriptDir ".venv/bin/python"
}

& $VenvPy (Join-Path $ScriptDir "merge_to_pdf_tui.py") @args
exit $LASTEXITCODE
