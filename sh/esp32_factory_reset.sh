#!/bin/bash

# This script performs a factory reset on an ESP32-family board.
# It erases all data on the board and flashes it with MicroPython firmware
# matching the chip (original ESP32, S2, S3, C3, C6 or H2).
#
# The chip is auto-detected with esptool; you confirm it, or fall back to a
# manual menu. esptool can identify the *chip* (the silicon) but not the
# specific *board* model, which is fine here — the firmware file, --chip flag
# and flash offset all depend only on the chip family.
#
# The script uses esptool to handle the erase and flash operations.

# MicroPython firmware version shared across all board variants.
# For a given stable release every ESP32_GENERIC* build uses the same
# DATE-VERSION suffix, so you only update this in one place.
FIRMWARE_VERSION="20260406-v1.28.0"

# These get populated by chip detection or the manual menu.
CHIP=""
FW_PREFIX=""
FLASH_OFFSET=""
FIRMWARE_FILE=""
SERIAL_PORT=""

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

# Single source of truth: given a chip id, set the chip flag, firmware prefix
# and flash offset. Offsets matter: the original ESP32 and S2 expect the
# bootloader at 0x1000, while the S3 and the RISC-V parts (C3/C6/H2) expect it
# at 0x0. Flashing at the wrong offset "succeeds" but the board won't boot.
set_board_by_chip() {
    case "$1" in
        esp32)   CHIP="esp32";   FW_PREFIX="ESP32_GENERIC";    FLASH_OFFSET="0x1000" ;;
        esp32s2) CHIP="esp32s2"; FW_PREFIX="ESP32_GENERIC_S2"; FLASH_OFFSET="0x1000" ;;
        esp32s3) CHIP="esp32s3"; FW_PREFIX="ESP32_GENERIC_S3"; FLASH_OFFSET="0x0"    ;;
        esp32c3) CHIP="esp32c3"; FW_PREFIX="ESP32_GENERIC_C3"; FLASH_OFFSET="0x0"    ;;
        esp32c6) CHIP="esp32c6"; FW_PREFIX="ESP32_GENERIC_C6"; FLASH_OFFSET="0x0"    ;;
        esp32h2) CHIP="esp32h2"; FW_PREFIX="ESP32_GENERIC_H2"; FLASH_OFFSET="0x0"    ;;
        *) return 1 ;;
    esac
    FIRMWARE_FILE="${FW_PREFIX}-${FIRMWARE_VERSION}.bin"
}

# Optional PSRAM build suffix per chip. Boards that embed extra PSRAM need a
# different MicroPython image (a suffix on the GENERIC prefix), e.g.
#   ESP32_GENERIC_S3 -> ESP32_GENERIC_S3-SPIRAM_OCT  (S3 N16R8/N8R8, octal PSRAM)
#   ESP32_GENERIC    -> ESP32_GENERIC-SPIRAM         (WROVER, quad PSRAM)
# esptool can't tell a PSRAM board from a plain one (same chip die), so we ask.
# Echoes the suffix, or nothing for chips with no PSRAM build at this release.
psram_variant_for_chip() {
    case "$1" in
        esp32)   echo "SPIRAM" ;;       # WROVER / modules with quad PSRAM
        esp32s3) echo "SPIRAM_OCT" ;;   # S3 modules with octal PSRAM (N16R8)
        *) echo "" ;;                   # S2/C3/C6/H2: no GENERIC PSRAM build
    esac
}

# If the chosen chip has a PSRAM build, let the user opt into it. The variant is
# appended to the GENERIC prefix and the firmware filename is recomputed.
# No-op for chips without a PSRAM build, so it's safe to always call.
choose_variant() {
    local variant
    variant="$(psram_variant_for_chip "$CHIP")"
    [[ -z "$variant" ]] && return 0

    echo
    echo "${BOLD}Does this board have extra PSRAM?${RESET}"
    if [[ "$CHIP" == "esp32s3" ]]; then
        echo "  ${DIM}e.g. ESP32-S3 N16R8 / N8R8 (octal PSRAM)${RESET}"
    else
        echo "  ${DIM}e.g. WROVER or any module with quad PSRAM${RESET}"
    fi
    read -p "Use the ${variant} (PSRAM) firmware? [y/N]: " ans
    case "$ans" in
        [Yy]*)
            FW_PREFIX="${FW_PREFIX}-${variant}"
            FIRMWARE_FILE="${FW_PREFIX}-${FIRMWARE_VERSION}.bin"
            echo "Using PSRAM build: ${GREEN}${BOLD}${FIRMWARE_FILE}${RESET}"
            ;;
        *)
            echo "Using non-PSRAM build: ${GREEN}${FIRMWARE_FILE}${RESET}"
            ;;
    esac
}

# Human-readable labels and the chip id each maps to. Index must stay in sync.
BOARD_LABELS=(
    "ESP32 (original / Huzzah32, WROOM, WROVER)"
    "ESP32-S2"
    "ESP32-S3 (Feather S3, QT Py S3, DevKitC)"
    "ESP32-C3 (RISC-V, native USB)"
    "ESP32-C6 (RISC-V, native USB)"
    "ESP32-H2 (RISC-V, native USB)"
)
BOARD_CHIPS=(esp32 esp32s2 esp32s3 esp32c3 esp32c6 esp32h2)

# Manual fallback menu.
# (Indexed arrays + case keep this working on the bash 3.2 that ships on macOS.)
select_board() {
    echo "${BOLD}Select your ESP32 board:${RESET}"
    for i in "${!BOARD_LABELS[@]}"; do
        echo "  ${CYAN}${i})${RESET} ${BOARD_LABELS[$i]}"
    done

    while true; do
        read -p "Board number (or press Enter to cancel): " n
        if [[ -z "$n" ]]; then
            echo "No board selected. Exiting."
            exit 1
        elif [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 0 && n < ${#BOARD_CHIPS[@]} )); then
            set_board_by_chip "${BOARD_CHIPS[$n]}"
            echo "Selected: ${GREEN}${BOLD}${BOARD_LABELS[$n]}${RESET}"
            echo "  chip=${CHIP}  offset=${FLASH_OFFSET}  firmware=${FIRMWARE_FILE}"
            break
        else
            echo "Invalid selection. Please try again."
        fi
    done
}

# Ask esptool what's connected and map it to our build settings.
# Returns non-zero (so the caller falls back to the menu) if it can't connect
# or the chip has no GENERIC build wired into this script.
detect_board() {
    echo "Detecting chip on ${SERIAL_PORT}..."
    local out chip_line
    if ! out="$(esptool --port "$SERIAL_PORT" chip-id 2>&1)"; then
        echo "${YELLOW}Could not connect to auto-detect the chip.${RESET}"
        echo "${DIM}${out}${RESET}"
        return 1
    fi

    # esptool's output wording varies by version: older builds print
    # "Chip is ESP32-S3 ...", while v5+ prints "Connected to ESP32-S3 on ..."
    # and "Chip type: ESP32-S3 ...". Show a friendly line for the user, but
    # match against the *whole* output so we don't depend on one label.
    chip_line="$(printf '%s\n' "$out" | grep -iE 'chip type|chip is|connected to' | head -1)"
    echo "esptool reports: ${chip_line:-$(printf '%s\n' "$out" | head -1)}"

    # Match the SoC variants first; the bare ESP32 catch-all is last so it only
    # picks up original dies (D0WD, PICO, U4WDH, ...). Newer SoCs without a
    # standard build here are routed to the manual menu rather than mis-mapped.
    case "$out" in
        *ESP32-S2*) set_board_by_chip esp32s2 ;;
        *ESP32-S3*) set_board_by_chip esp32s3 ;;
        *ESP32-C3*) set_board_by_chip esp32c3 ;;
        *ESP32-C6*) set_board_by_chip esp32c6 ;;
        *ESP32-H2*) set_board_by_chip esp32h2 ;;
        *ESP32-C2*|*ESP32-C5*|*ESP32-C61*|*ESP32-P4*)
            echo "${YELLOW}No MicroPython GENERIC build wired in for this chip.${RESET}"
            return 1 ;;
        *ESP32*) set_board_by_chip esp32 ;;
        *) echo "${YELLOW}Unrecognized chip.${RESET}"; return 1 ;;
    esac
}

# Try detection, let the user confirm, fall back to the menu otherwise.
choose_board() {
    if detect_board; then
        echo "Detected ${GREEN}${BOLD}${CHIP}${RESET}: firmware=${FIRMWARE_FILE}, offset=${FLASH_OFFSET}"
        read -p "Use the detected chip? [Y/n]: " ans
        case "$ans" in
            [Nn]*) select_board ;;
            *) : ;;   # keep detected
        esac
    else
        echo "Falling back to manual selection."
        select_board
    fi
}

# Function to list available serial ports
list_serial_ports() {
    echo "${BOLD}Likely serial ports for ESP32:${RESET}"
    # USB-UART bridges (CP210x/CH340 -> SLAB/usbserial/ttyUSB) and
    # native-USB chips (S3/C3/C6/H2 -> ttyACM on Linux, usbmodem on macOS).
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
    echo "This script will factory reset the ESP32 board. ALL DATA WILL BE ERASED."
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
ensure_esptool          # needed before detection, which calls esptool
list_serial_ports
select_serial_port
choose_board            # auto-detect chip, confirm, or fall back to menu
choose_variant          # offer the PSRAM build for chips that have one
ensure_firmware_file


# Perform factory reset
esptool --chip "$CHIP" --port "$SERIAL_PORT" erase-flash
if [[ $? -ne 0 ]]; then
    echo "Failed to erase flash. Exiting."
    exit 1
fi

esptool --chip "$CHIP" --port "$SERIAL_PORT" --baud 921600 write-flash -z "$FLASH_OFFSET" "$FIRMWARE_FILE"
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
