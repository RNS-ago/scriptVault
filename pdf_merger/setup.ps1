# One-time setup: creates a local .venv and installs dependencies.
# Re-running is safe -- it only reinstalls when requirements.txt has changed.
#
# After it succeeds, the CLI can be called directly:
#     .\.venv\Scripts\python.exe merge_to_pdf.py .\folder -o out.pdf
#
# Pass -Quiet to suppress informational output (used by run.ps1).
#
# If you get an "execution policy" error, run this once in PowerShell:
#     Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned

[CmdletBinding()]
param(
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

function Write-Info($msg) {
    if (-not $Quiet) { Write-Host $msg }
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$VenvDir   = Join-Path $ScriptDir ".venv"
$ReqFile   = Join-Path $ScriptDir "requirements.txt"
$HashFile  = Join-Path $VenvDir ".req-hash"

# --- locate a usable Python ------------------------------------------------
$PythonBin = $null
foreach ($cmd in @("py", "python", "python3")) {
    if (Get-Command $cmd -ErrorAction SilentlyContinue) {
        $PythonBin = $cmd
        break
    }
}

if (-not $PythonBin) {
    Write-Host "Error: python not found in PATH." -ForegroundColor Red
    Write-Host "Install Python 3.9+ from https://www.python.org/downloads/" -ForegroundColor Red
    exit 1
}

# --- create venv if missing ------------------------------------------------
if (-not (Test-Path $VenvDir)) {
    Write-Info "Creating virtual environment in $VenvDir ..."
    & $PythonBin -m venv $VenvDir
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

$VenvPy = Join-Path $VenvDir "Scripts\python.exe"
if (-not (Test-Path $VenvPy)) {
    # Fallback for PowerShell Core on macOS/Linux
    $VenvPy = Join-Path $VenvDir "bin/python"
}

# --- (re)install deps if requirements.txt changed --------------------------
$CurrentHash = ""
if (Test-Path $ReqFile) {
    $CurrentHash = (Get-FileHash -Path $ReqFile -Algorithm SHA256).Hash
}

$StoredHash = ""
if (Test-Path $HashFile) {
    $StoredHash = (Get-Content -Path $HashFile -Raw -ErrorAction SilentlyContinue)
    if ($StoredHash) { $StoredHash = $StoredHash.Trim() }
}

if ($CurrentHash -ne $StoredHash) {
    Write-Info "Installing dependencies ..."
    & $VenvPy -m pip install --quiet --upgrade pip
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    & $VenvPy -m pip install --quiet -r $ReqFile
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    [System.IO.File]::WriteAllText($HashFile, $CurrentHash)
}

# --- summary ---------------------------------------------------------------
if (-not $Quiet) {
    $CliPath = Join-Path $ScriptDir "merge_to_pdf.py"
    $ActivatePath = Join-Path $VenvDir "Scripts\Activate.ps1"
    $RunPath = Join-Path $ScriptDir "run.ps1"

    Write-Host ""
    Write-Host "Setup complete." -ForegroundColor Green
    Write-Host ""
    Write-Host "To use the CLI directly:"
    Write-Host "  $VenvPy $CliPath FOLDER [options]"
    Write-Host ""
    Write-Host "Example:"
    Write-Host "  $VenvPy $CliPath .\scans -o report.pdf"
    Write-Host ""
    Write-Host "Or activate the venv first and drop the long path:"
    Write-Host "  $ActivatePath"
    Write-Host "  python merge_to_pdf.py .\scans -o report.pdf"
    Write-Host ""
    Write-Host "To launch the interactive TUI:"
    Write-Host "  $RunPath"
}
