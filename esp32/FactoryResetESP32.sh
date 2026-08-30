#!/bin/bash

# This script performs a factory reset on an Adafruit Huzzah32 board.
# It erases all data on the board and flashes it with a specified firmware file.
# The user is prompted to confirm the operation and select a serial port.
# The firmware file is defined at the top of the script as a variable for easy modification.
# The script uses esptool.py to handle the erase and flash operations.

# Define firmware file variable
FIRMWARE_FILE="ESP32_GENERIC-S3-20260406-v1.28.0.bin"

# Color setup (only emit escape codes when stdout is a real terminal)
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'
    DIM=$'\033[2m'
    GREEN=$'\033[32m'
    CYAN=$'\033[36m'
    YELLOW=$'\033[33m'
    RESET=$'\033[0m'
else
    BOLD='' DIM='' GREEN='' CYAN='' YELLOW='' RESET=''
fi

# Function to list available serial ports
list_serial_ports() {
    echo "${BOLD}Likely serial ports for Huzzah32:${RESET}"
    likely_ports=( $(ls /dev/tty.SLAB* /dev/tty.usb* /dev/ttyUSB* /dev/ttyACM* 2>/dev/null) )
    if (( ${#likely_ports[@]} == 0 )); then
        echo "  ${DIM}(none found)${RESET}"
    fi
    for i in "${!likely_ports[@]}"; do
        echo "  ${CYAN}${i})${RESET} ${GREEN}${BOLD}${likely_ports[$i]}${RESET}"
    done

    echo "${BOLD}Other serial ports:${RESET}"
    other_ports=( $(ls /dev/tty.* 2>/dev/null | grep -vE '/dev/tty\.(SLAB|usb)') )
    if (( ${#other_ports[@]} == 0 )); then
        echo "  ${DIM}(none found)${RESET}"
    fi
    for i in "${!other_ports[@]}"; do
        echo "  ${CYAN}$((i + ${#likely_ports[@]})))${RESET} ${YELLOW}${other_ports[$i]}${RESET}"
    done

    serial_ports=( "${likely_ports[@]}" "${other_ports[@]}" )
}

# Function to select a serial port
select_serial_port() {
    while true; do
        read -p "Select the serial port number (or press Enter to cancel): " port_number
        if [[ -z "$port_number" ]]; then
            echo "No serial port selected. Exiting."
            exit 1
        elif [[ "$port_number" =~ ^[0-9]+$ ]] && (( port_number >= 0 && port_number < ${#serial_ports[@]} )); then
            echo "Selected serial port: ${GREEN}${BOLD}${serial_ports[$port_number]}${RESET}"
            SERIAL_PORT="${serial_ports[$port_number]}"
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
}

# Function to confirm factory reset
confirm_reset() {
    echo "This script will factory reset the Huzzah32 board. ALL DATA WILL BE ERASED."
    read -p "Are you sure you want to proceed? Type 'yes' to confirm (default is no): " confirmation
    if [[ "$confirmation" != "yes" ]]; then
        echo "Operation cancelled. Exiting."
        exit 1
    fi
}

ensure_firmware_file() {
    local force="${1:-}"
    local url="https://micropython.org/resources/firmware/${FIRMWARE_FILE}"
    local output="${PWD}/${FIRMWARE_FILE}"

    if [[ -f "$output" && "$force" != "--force" ]]; then
        echo "Firmware already exists: $output (use --force to re-download)"
        return 0
    fi

    echo "Downloading firmware..."
    if command -v curl >/dev/null 2>&1; then
        curl -fL "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$output" "$url"
    else
        echo "Error: neither curl nor wget is available." >&2
        return 1
    fi
    echo "Saved to: $output"
}

ensure_esptool() {
    # If esptool is already on PATH, don't reinstall it.
    if command -v esptool >/dev/null 2>&1; then
        echo "esptool already installed: $(command -v esptool)"
        return 0
    fi

    # Otherwise we need Python 3.10+ to pip install it.
    local python_cmd=""
    for cmd in python3 python; do
        if command -v "$cmd" >/dev/null 2>&1; then
            python_cmd="$cmd"
            break
        fi
    done

    if [[ -z "$python_cmd" ]]; then
        echo "Error: Python is not installed or not on PATH." >&2
        return 1
    fi

    # Ask Python for its own version — cleaner than parsing "Python X.Y.Z"
    local version major minor
    version="$("$python_cmd" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    major="${version%%.*}"
    minor="${version#*.}"

    if (( major < 3 || (major == 3 && minor < 10) )); then
        echo "Error: Python 3.10+ required, but found $version." >&2
        return 1
    fi

    echo "Python $version detected ($python_cmd)."
    "$python_cmd" -m pip install esptool
}

# Main script logic
confirm_reset
list_serial_ports
select_serial_port
ensure_firmware_file
ensure_esptool


# Perform factory reset
esptool --chip esp32 --port "$SERIAL_PORT" erase-flash
if [[ $? -ne 0 ]]; then
    echo "Failed to erase flash. Exiting."
    exit 1
fi

esptool --chip esp32 --port "$SERIAL_PORT" --baud 921600 write-flash -z 0x1000 "$FIRMWARE_FILE"
if [[ $? -eq 0 ]]; then
    echo "Factory reset complete."
else
    echo "Failed to write firmware. Exiting."
    exit 1
fi

# Exit protocol
for n in {3..1}; do
    echo "Shutting down in $n"
    sleep 1
done