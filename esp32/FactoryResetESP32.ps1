# FactoryResetHuzzah32.ps1
# This script performs a factory reset on an Adafruit Huzzah32 board.
# It erases all data on the board and flashes it with a specified firmware file.

# Define firmware file variable (update the path if necessary)
$FIRMWARE_FILE = "ESP32_GENERIC-20260406-v1.28.0.bin"


# Initialize the serial_ports array in script scope
$script:serial_ports = @()

# Function to list available serial ports
function List-SerialPorts {
    Write-Host "`nListing available serial ports:"

    # Fetch all serial ports using Get-CimInstance
    $serialPortsCim = Get-CimInstance Win32_SerialPort

    # Add serial ports from Win32_SerialPort
    foreach ($port in $serialPortsCim) {
        $script:serial_ports += $port.DeviceID
        $index = $script:serial_ports.Count - 1
        Write-Host "  $index) " -ForegroundColor Cyan -NoNewline
        Write-Host "$($port.Caption) ($($port.DeviceID))" -ForegroundColor Green
    }

    # Include additional virtual COM ports not captured by Win32_SerialPort
    $existingPorts = $serialPortsCim | Select-Object -ExpandProperty DeviceID
    $virtualPorts = [System.IO.Ports.SerialPort]::GetPortNames() | Where-Object { $_ -notin $existingPorts }

    foreach ($vPort in $virtualPorts) {
        $script:serial_ports += $vPort
        $index = $script:serial_ports.Count - 1
        Write-Host "  $index) " -ForegroundColor Cyan -NoNewline
        Write-Host "Virtual Serial Port ($vPort)" -ForegroundColor Yellow
    }

    if ($script:serial_ports.Count -eq 0) {
        Write-Error "No serial ports found. Please connect your Huzzah32 board and try again."
        exit 1
    }
}

# Function to select a serial port
function Select-SerialPort {
    while ($true) {
        $port_number = Read-Host "`nSelect the serial port number (or press Enter to cancel)"
        if ([string]::IsNullOrWhiteSpace($port_number)) {
            Write-Output "No serial port selected. Exiting."
            exit 1
        }

        # Validate input is a number
        if ($port_number -match '^\d+$') {
            $port_index = [int]$port_number
            if ($port_index -ge 0 -and $port_index -lt $script:serial_ports.Count) {
                $selectedPort = $script:serial_ports[$port_index]
                Write-Host "Selected serial port: " -NoNewline
                Write-Host $selectedPort -ForegroundColor Green
                $script:SERIAL_PORT = $selectedPort
                break
            } else {
                Write-Output "Invalid selection. Please enter a number between 0 and $($script:serial_ports.Count - 1)."
            }
        } else {
            Write-Output "Invalid input. Please enter a numeric value."
        }
    }
}

# Function to confirm factory reset
function Confirm-Reset {
    Write-Output "`nWARNING: This script will factory reset the Huzzah32 board. ALL DATA WILL BE ERASED."
    $confirmation = Read-Host "Are you sure you want to proceed? Type 'yes' to confirm (default is no)"
    if ($confirmation -ne "yes") {
        Write-Output "Operation cancelled. Exiting."
        exit 1
    }
}

function Ensure-Firmware-File {
    $url = "https://micropython.org/resources/firmware/" + $FIRMWARE_FILE
    $output = Join-Path $PWD $FIRMWARE_FILE

    if (Test-Path $output) {
        Write-Host "Firmware already exists: $output" -ForegroundColor Yellow
        return
    }

    Write-Host "Downloading firmware..." -ForegroundColor Cyan
    $ProgressPreference = 'SilentlyContinue'
    Invoke-WebRequest -Uri $url -OutFile $output
    $ProgressPreference = 'Continue'
    Write-Host "Saved to: $output" -ForegroundColor Green
}

function Ensure-Esptool {
    # If esptool is already on PATH, don't reinstall it.
    $esptoolCmd = Get-Command esptool -ErrorAction SilentlyContinue
    if ($esptoolCmd) {
        Write-Host "esptool already installed: $($esptoolCmd.Source)" -ForegroundColor Green
        return
    }

    # Otherwise we need Python 3.10+ to pip install it.
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) {
        Write-Error "Python is not installed or not on PATH."
        return
    }

    # Get the version and compare
    $versionString = (python --version 2>&1) -replace 'Python\s+', ''
    $version = [version]$versionString

    if ($version -lt [version]"3.10") {
        Write-Error "Python 3.10+ required, but found $version."
        return
    }

    Write-Host "Python $version detected." -ForegroundColor Green
    pip install esptool
}

# Function to perform erase-flash
function Erase-Flash {
    Write-Output "`nErasing flash on $script:SERIAL_PORT..."
    esptool --chip esp32 --port "$script:SERIAL_PORT" erase-flash
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to erase flash. Please check the connection and try again."
        exit 1
    }
    Write-Output "Flash erased successfully."
}

# Function to perform write-flash
function Write-Flash {
    Write-Output "`nFlashing firmware to $script:SERIAL_PORT..."
    esptool --chip esp32 --port "$script:SERIAL_PORT" --baud 921600 write-flash -z 0x1000 "$FIRMWARE_FILE"
    if ($LASTEXITCODE -eq 0) {
        Write-Output "Factory reset complete."
    }
    else {
        Write-Error "Failed to write firmware. Please check the connection and try again."
        exit 1
    }
}

# Main Script Logic
Confirm-Reset
List-SerialPorts
Select-SerialPort
Ensure-Esptool
Ensure-Firmware-File
Erase-Flash
Write-Flash
# Exit sequence
foreach ($n in 3..1) {
    Write-Host "Shutting down in $n"
    sleep 1
}
