#!/bin/bash
# Blue Archive Waydroid Installer (Rust Style)
# Author: Minhmc2007

set -e
START_TIME=$SECONDS

# --- CONFIGURATION ---
GAME_URL="https://github.com/minhmc2007/Blue-Archive-Linux-Repo/releases/download/v0.0.1/blue_archive.xapk"
WORK_DIR="/tmp/bal_installer"
CACHE_DIR="$HOME/.cache/bal-blue-archive-waydroid"
CACHED_XAPK="$CACHE_DIR/blue_archive.xapk"
PKG_NAME="com.nexon.bluearchive"

# --- STYLING ---
BOLD='\033[1m'
GREEN='\033[1;32m'
RED='\033[1;31m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# Rust-like logging function
# Usage: log_status "Verb" "Message"
log_status() {
    printf "${GREEN}%12s${NC} %s\n" "$1" "$2"
}

log_error() {
    printf "${RED}%12s${NC} %s\n" "Error" "$1"
    exit 1
}

log_warn() {
    printf "${CYAN}%12s${NC} %s\n" "Warning" "$1"
}

# Cleanup
cleanup() {
    if [ -d "$WORK_DIR" ]; then
        # Sudo needed for root-owned pycache files
        sudo rm -rf "$WORK_DIR" &>/dev/null
    fi
    adb disconnect &>/dev/null || true
}
trap cleanup EXIT

# --- PRE-FLIGHT ---
if [ "$EUID" -eq 0 ]; then
    log_error "Please run as normal user (not root)."
fi

# --- 1. SYSTEM CHECK ---
log_status "Checking" "Waydroid environment..."

# Ensure Service (Root)
if ! systemctl is-active --quiet waydroid-container; then
    log_status "Starting" "Waydroid container service (requires sudo)..."
    sudo systemctl start waydroid-container
fi

# Ensure Session (User)
if ! waydroid status | grep -q "Session:.*RUNNING"; then
    log_status "Booting" "Waydroid user session..."
    waydroid session start &

    # Silent wait loop
    TIMEOUT=30
    while [ $TIMEOUT -gt 0 ]; do
        if waydroid status | grep -q "Session:.*RUNNING"; then break; fi
        sleep 1
        ((TIMEOUT--))
    done
fi

# --- 2. CONNECTIVITY ---
log_status "Connecting" "ADB interface..."

# Enable ADB
sudo waydroid shell setprop persist.waydroid.enable_adb true || true

# IP Detection
CONTAINER_IP=$(sudo waydroid shell ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
if [ -z "$CONTAINER_IP" ]; then
    CONTAINER_IP="192.168.240.112" # Fallback
fi

adb connect "$CONTAINER_IP:5555" &>/dev/null

# Authorization Check
sleep 1
if adb devices | grep "$CONTAINER_IP" | grep -q "unauthorized"; then
    log_warn "Device unauthorized."
    printf "${GRAY}%12s${NC} %s\n" "Action" "Check Waydroid window -> Click 'Allow' on USB Popup"
    while adb devices | grep -q "unauthorized"; do sleep 1; done
fi

if ! adb devices | grep -q "device"; then
    log_error "Failed to connect to Waydroid ($CONTAINER_IP)."
fi

# --- 3. ARCHITECTURE ---
log_status "Verifying" "ARM64 compatibility..."
ABI=$(adb shell getprop ro.product.cpu.abilist)

if [[ "$ABI" != *"arm64-v8a"* ]]; then
    log_status "Installing" "Libhoudini translation layer (arm64-v8a)..."

    sudo rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"

    # Quiet clone
    git clone https://github.com/casualsnek/waydroid_script "$WORK_DIR/waydroid_script" &>/dev/null

    cd "$WORK_DIR/waydroid_script"
    python3 -m venv venv
    venv/bin/pip install -r requirements.txt &>/dev/null

    log_status "Running" "Libhoudini installer script..."
    if sudo venv/bin/python3 main.py install libhoudini &>/dev/null; then
        log_status "Rebooting" "Waydroid container to apply changes..."
        sudo systemctl restart waydroid-container
        sleep 5
        waydroid session start &
        sleep 10
        adb connect "$CONTAINER_IP:5555" &>/dev/null
    else
        log_error "Libhoudini installation failed."
    fi
fi

# --- 4. DOWNLOAD ---
mkdir -p "$CACHE_DIR"
if [ ! -f "$CACHED_XAPK" ]; then
    log_status "Downloading" "Blue Archive (XAPK)..."
    # Quiet curl, show progress only if you want, but Rust style usually quiet unless verbose
    # using curl -# for a nice progress bar
    curl -L -o "$CACHED_XAPK" "$GAME_URL" -#
else
    log_status "Using" "Cached file ($CACHED_XAPK)"
fi

# --- 5. INSTALL ---
log_status "Unpacking" "XAPK resources..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR/extracted"
cp "$CACHED_XAPK" "$WORK_DIR/ba.xapk"
cd "$WORK_DIR/extracted"
unzip -q -o ../ba.xapk

mapfile -t APK_LIST < <(find . -name "*.apk")

log_status "Installing" "$PKG_NAME..."
INSTALL_LOG=$(adb install-multiple "${APK_LIST[@]}" 2>&1)

if echo "$INSTALL_LOG" | grep -q "Success"; then
    ELAPSED=$((SECONDS - START_TIME))
    log_status "Finished" "installation in ${ELAPSED}s."
    printf "${GRAY}%12s${NC} %s\n" "Run" "waydroid app launch $PKG_NAME"
else
    log_error "Installation failed.\n${INSTALL_LOG}"
fi
