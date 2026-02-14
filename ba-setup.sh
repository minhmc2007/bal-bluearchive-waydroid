#!/bin/bash
# Blue Archive Waydroid Installer (Human-Speed Fix)
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
YELLOW='\033[1;33m'
GRAY='\033[0;90m'
NC='\033[0m'

# --- LOGGING ---
log_status() { printf "${GREEN}%12s${NC} %s\n" "$1" "$2"; }
log_warn()   { printf "${YELLOW}%12s${NC} %s\n" "Warning" "$1"; }
log_info()   { printf "${CYAN}%12s${NC} %s\n" "Info" "$1"; }
log_error()  { printf "${RED}%12s${NC} %s\n" "Error" "$1"; exit 1; }

# --- CLEANUP ---
cleanup() {
    if [ -d "$WORK_DIR" ]; then sudo rm -rf "$WORK_DIR" &>/dev/null; fi
}
trap cleanup EXIT

# --- HELPER: ADB WAIT ---
wait_for_adb() {
    local IP=$1
    log_status "Connecting" "Waiting for Waydroid..."

    # Check 1: Is it already there? (Fast path)
    if adb devices | grep -w "device" >/dev/null; then
        log_status "Connected" "Ready."
        return 0
    fi

    local TIMEOUT=30
    while [ $TIMEOUT -gt 0 ]; do
        # Try to connect (with 1s timeout so it doesn't hang the script)
        timeout 1s adb connect "$IP:5555" >/dev/null 2>&1 || true

        # Check if connected
        if adb devices | grep -w "device" >/dev/null; then
            log_status "Connected" "Waydroid is ready."
            return 0
        fi

        sleep 1
        ((TIMEOUT--))
    done

    log_warn "Connection timed out (Check Waydroid settings)."
}

# --- HELPER: REBOOT FUNCTION ---
# This mimics the manual steps exactly
reboot_waydroid() {
    log_status "Rebooting" "Waydroid session..."

    # 1. Stop Session
    waydroid session stop >/dev/null 2>&1 || true

    # 2. Kill ADB (Clean slate)
    adb kill-server >/dev/null 2>&1 || true

    # 3. Restart Container
    sudo systemctl restart waydroid-container

    # 4. Start ADB Server explicitly (Fixes 'Connection refused')
    adb start-server >/dev/null 2>&1 || true

    # 5. Start Session
    waydroid session start &

    # 6. THE HUMAN PAUSE: Wait 5s for boot before doing anything else
    # This prevents the script from freaking out while Android loads
    log_status "Booting" "Waiting 5s for Android..."
    sleep 5

    waydroid show-full-ui &
}

# --- 0. PRE-FLIGHT CHECKS ---
if [ "$EUID" -eq 0 ]; then log_error "Please run as normal user (not root)."; fi

dependencies=(adb curl unzip git sudo sqlite3)
for cmd in "${dependencies[@]}"; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Missing dependency: '$cmd'. Install it (e.g., sudo apt install $cmd)."
    fi
done

# --- 1. SYSTEM CHECK ---
log_status "Checking" "Waydroid environment..."

if [ ! -f "/var/lib/waydroid/waydroid.cfg" ]; then
    log_warn "Waydroid is not initialized."
    log_status "Initializing" "Waydroid with GAPPS..."
    sudo waydroid init -s GAPPS -f
    sudo systemctl restart waydroid-container
    sleep 5
fi

# Ensure Service
if ! systemctl is-active --quiet waydroid-container; then
    sudo systemctl start waydroid-container
    sleep 2
fi

# Ensure Session
if ! waydroid status | grep -q "Session:.*RUNNING"; then
    log_status "Booting" "Waydroid user session..."
    waydroid session start &
    # Allow boot time
    sleep 5
    waydroid show-full-ui &
fi

# --- 2. CONNECTIVITY ---
sudo waydroid shell setprop persist.waydroid.enable_adb true || true

# IP Detection
CONTAINER_IP=$(sudo waydroid shell ip addr show eth0 2>/dev/null | grep "inet\b" | awk '{print $2}' | cut -d/ -f1 | head -n 1)
if [ -z "$CONTAINER_IP" ]; then CONTAINER_IP="192.168.240.112"; fi

wait_for_adb "$CONTAINER_IP"

# Authorization Loop
if adb devices | grep -q "unauthorized"; then
    log_warn "Device unauthorized."
    printf "${GRAY}%12s${NC} %s\n" "Action" "Check Waydroid window -> Click 'Allow' on USB Popup"
    while adb devices | grep -q "unauthorized"; do sleep 1; done
    log_status "Authorized" "Device connected."
fi

# --- 3. GOOGLE PLAY CERTIFICATION ---
log_status "Checking" "Google Play Certification..."

# Extract Android ID
ANDROID_ID=$(sudo waydroid shell sqlite3 /data/data/com.google.android.gsf/databases/gservices.db "select value from main where name = 'android_id'" 2>/dev/null || true)

if [ -z "$ANDROID_ID" ]; then
    log_warn "No Android ID found (GSF initializing?)"
    log_info "Skipping registration."
else
    echo -e "\n${BOLD}--- ACTION REQUIRED: REGISTER DEVICE ---${NC}"
    echo -e "1. Go to: ${CYAN}https://www.google.com/android/uncertified${NC}"
    echo -e "2. Log in and paste this ID:"
    echo -e "\n    ${GREEN}${BOLD}${ANDROID_ID}${NC}\n"
    echo -e "3. Click 'Register'."

    read -p "Press [Enter] after you have registered the ID..."

    # CALL THE NEW REBOOT FUNCTION
    reboot_waydroid

    wait_for_adb "$CONTAINER_IP"
fi

# --- 4. LIBHOUDINI ---
log_status "Verifying" "ARM64 compatibility..."
ABI=$(adb shell getprop ro.product.cpu.abilist || echo "unknown")

if [[ "$ABI" != *"arm64-v8a"* ]]; then
    log_status "Installing" "Libhoudini (ARM translation)..."
    sudo rm -rf "$WORK_DIR"
    mkdir -p "$WORK_DIR"

    git clone https://github.com/casualsnek/waydroid_script "$WORK_DIR/waydroid_script" &>/dev/null
    cd "$WORK_DIR/waydroid_script"
    python3 -m venv venv
    venv/bin/pip install -r requirements.txt &>/dev/null

    if sudo venv/bin/python3 main.py install libhoudini &>/dev/null; then

        # CALL THE NEW REBOOT FUNCTION
        reboot_waydroid

        wait_for_adb "$CONTAINER_IP"
    else
        log_error "Libhoudini installation failed."
    fi
fi

# --- 5. INSTALL GAME ---
mkdir -p "$CACHE_DIR"
if [ ! -f "$CACHED_XAPK" ]; then
    log_status "Downloading" "Blue Archive (XAPK)..."
    curl -L -o "$CACHED_XAPK" "$GAME_URL" -#
else
    log_status "Using" "Cached file ($CACHED_XAPK)"
fi

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
    log_status "Finished" "Installation complete!"
    echo -e "\nRun: ${BOLD}waydroid app launch $PKG_NAME${NC}"
else
    log_error "Installation failed.\n${INSTALL_LOG}"
fi
