#!/bin/bash
set -euo pipefail

# ============================================================
#  Screentaem Display Client — Quick Installer
#  https://releases.screentaem.com/install.sh
#
#  Usage: curl -fsSL https://releases.screentaem.com/install.sh | bash
# ============================================================

RELEASES_BASE="https://releases.screentaem.com/latest"
KIOSK_SCRIPT_URL="https://releases.screentaem.com/kiosk/screentaem_install.sh"

# --- Colors & Formatting ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m' # No Color

print_banner() {
  echo ""
  echo -e "${BOLD}  ┌─────────────────────────────────────────┐${NC}"
  echo -e "${BOLD}  │                                         │${NC}"
  echo -e "${BOLD}  │     ${BLUE}Screentaem Display Client${NC}${BOLD}          │${NC}"
  echo -e "${BOLD}  │     ${DIM}Quick Installer${NC}${BOLD}                    │${NC}"
  echo -e "${BOLD}  │                                         │${NC}"
  echo -e "${BOLD}  └─────────────────────────────────────────┘${NC}"
  echo ""
}

info()    { echo -e "  ${BLUE}ℹ${NC}  $1"; }
success() { echo -e "  ${GREEN}✓${NC}  $1"; }
warn()    { echo -e "  ${YELLOW}!${NC}  $1"; }
error()   { echo -e "  ${RED}✗${NC}  $1"; }
step()    { echo -e "\n  ${BOLD}[$1/$TOTAL_STEPS]${NC} $2"; }

ask_yn() {
  local prompt="$1"
  local default="${2:-n}"
  local yn_hint
  if [ "$default" = "y" ]; then
    yn_hint="[Y/n]"
  else
    yn_hint="[y/N]"
  fi

  while true; do
    echo -en "  ${YELLOW}?${NC}  ${prompt} ${DIM}${yn_hint}${NC} "
    read -r answer </dev/tty
    answer="${answer:-$default}"
    case "$answer" in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) echo -e "  ${DIM}   Please answer y or n${NC}" ;;
    esac
  done
}

# ============================================================
#  PHASE 1: Detect Platform
# ============================================================

detect_platform() {
  OS_RAW="$(uname -s)"
  ARCH_RAW="$(uname -m)"

  case "$OS_RAW" in
    Linux*)  PLATFORM="linux" ;;
    Darwin*) PLATFORM="mac" ;;
    MINGW*|MSYS*|CYGWIN*)
      error "Windows detected. Please download the installer directly from:"
      info "https://releases.screentaem.com/latest/win/amd"
      exit 1
      ;;
    *)
      error "Unsupported operating system: $OS_RAW"
      exit 1
      ;;
  esac

  case "$ARCH_RAW" in
    x86_64|amd64)   ARCH="x64"; URL_ARCH="amd" ;;
    aarch64|arm64)   ARCH="arm64"; URL_ARCH="arm" ;;
    *)
      error "Unsupported architecture: $ARCH_RAW"
      exit 1
      ;;
  esac
}

# ============================================================
#  PHASE 2: Ask All Questions Upfront
# ============================================================

ask_questions() {
  echo -e "  ${BOLD}Configuration${NC}"
  echo -e "  ${DIM}─────────────${NC}"
  echo ""

  KIOSK_MODE="n"
  AUTO_START="n"

  if [ "$PLATFORM" = "linux" ]; then
    if ask_yn "Is this a dedicated kiosk device? (auto-login, watchdog, security hardening)" "n"; then
      KIOSK_MODE="y"
      AUTO_START="y"  # Kiosk mode implies auto-start
    fi
  fi

  if [ "$KIOSK_MODE" = "n" ]; then
    if ask_yn "Enable auto-start on boot?" "y"; then
      AUTO_START="y"
    fi
  fi

  echo ""
}

# ============================================================
#  PHASE 3: Confirm & Summarize
# ============================================================

print_summary() {
  echo -e "  ${BOLD}Install Summary${NC}"
  echo -e "  ${DIM}───────────────${NC}"
  success "Platform: ${BOLD}${PLATFORM}${NC} (${ARCH})"

  if [ "$PLATFORM" = "linux" ]; then
    if [ "$KIOSK_MODE" = "y" ]; then
      success "Mode: ${BOLD}Kiosk deployment${NC} (dedicated device)"
      success "Auto-login, crash watchdog, security hardening"
    else
      success "Mode: ${BOLD}Standard install${NC}"
    fi

    DOWNLOAD_URL="${RELEASES_BASE}/linux/${URL_ARCH}"
    success "Download: ${DIM}${DOWNLOAD_URL}${NC}"

    if [ "$KIOSK_MODE" = "n" ]; then
      if [ "$AUTO_START" = "y" ]; then
        success "Auto-start: ${BOLD}enabled${NC}"
      else
        info "Auto-start: disabled"
      fi
    fi
  elif [ "$PLATFORM" = "mac" ]; then
    DOWNLOAD_URL="${RELEASES_BASE}/mac/${URL_ARCH}"
    success "Download: ${DIM}${DOWNLOAD_URL}${NC}"
    if [ "$AUTO_START" = "y" ]; then
      success "Auto-start: ${BOLD}enabled${NC} (Login Items)"
    else
      info "Auto-start: disabled"
    fi
  fi

  echo ""

  if ! ask_yn "Proceed with installation?" "y"; then
    info "Installation cancelled."
    exit 0
  fi
}

# ============================================================
#  PHASE 4: Install
# ============================================================

install_linux_standard() {
  INSTALL_DIR="$HOME/.local/bin"
  APPIMAGE_PATH="$INSTALL_DIR/screentaem.AppImage"

  step 1 "Downloading Screentaem..."
  mkdir -p "$INSTALL_DIR"
  curl -fSL --progress-bar "$DOWNLOAD_URL" -o "$APPIMAGE_PATH"
  chmod +x "$APPIMAGE_PATH"
  success "Downloaded to ${BOLD}${APPIMAGE_PATH}${NC}"

  if [ "$AUTO_START" = "y" ]; then
    step 2 "Setting up auto-start..."
    AUTOSTART_DIR="$HOME/.config/autostart"
    mkdir -p "$AUTOSTART_DIR"
    cat > "$AUTOSTART_DIR/screentaem.desktop" << DEOF
[Desktop Entry]
Type=Application
Name=Screentaem
Exec=$APPIMAGE_PATH --no-sandbox --kiosk
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
DEOF
    success "Autostart entry created"
  fi

  NEXT_STEP=$((AUTO_START == "y" ? 3 : 2))
  step $NEXT_STEP "Creating desktop shortcut..."
  DESKTOP_DIR="$HOME/Desktop"
  if [ -d "$DESKTOP_DIR" ]; then
    cat > "$DESKTOP_DIR/screentaem.desktop" << DEOF
[Desktop Entry]
Type=Application
Name=Screentaem
Exec=$APPIMAGE_PATH --no-sandbox --kiosk
Terminal=false
Icon=screentaem
DEOF
    chmod +x "$DESKTOP_DIR/screentaem.desktop"
    success "Desktop shortcut created"
  else
    info "No Desktop directory found, skipping shortcut"
  fi
}

install_linux_kiosk() {
  step 1 "Downloading Screentaem AppImage..."
  TMP_APPIMAGE="/tmp/screentaem-installer.AppImage"
  curl -fSL --progress-bar "$DOWNLOAD_URL" -o "$TMP_APPIMAGE"
  chmod +x "$TMP_APPIMAGE"
  success "AppImage downloaded"

  step 2 "Downloading kiosk provisioning script..."
  TMP_KIOSK_SCRIPT="/tmp/screentaem_install.sh"
  curl -fSL --progress-bar "$KIOSK_SCRIPT_URL" -o "$TMP_KIOSK_SCRIPT"
  chmod +x "$TMP_KIOSK_SCRIPT"
  success "Provisioning script downloaded"

  step 3 "Running kiosk provisioning (requires sudo)..."
  echo ""
  warn "This will create a 'kiosk' user, configure auto-login, and harden the system."
  warn "The system will need to be rebooted after setup."
  echo ""

  sudo bash "$TMP_KIOSK_SCRIPT" "$TMP_APPIMAGE"

  rm -f "$TMP_APPIMAGE" "$TMP_KIOSK_SCRIPT"
  success "Kiosk provisioning complete"
}

install_mac() {
  TMP_DMG="/tmp/screentaem-installer.dmg"

  step 1 "Downloading Screentaem..."
  curl -fSL --progress-bar "$DOWNLOAD_URL" -o "$TMP_DMG"
  success "DMG downloaded"

  step 2 "Installing to /Applications..."
  MOUNT_OUTPUT=$(hdiutil attach "$TMP_DMG" -nobrowse -quiet 2>&1)
  MOUNT_POINT=$(echo "$MOUNT_OUTPUT" | tail -1 | awk '{for(i=3;i<=NF;i++) printf "%s ", $i; print ""}' | sed 's/ *$//')

  if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT" ]; then
    # Fallback: find mounted volume
    MOUNT_POINT=$(ls -d /Volumes/Screentaem* 2>/dev/null | head -1)
  fi

  if [ -z "$MOUNT_POINT" ]; then
    error "Failed to mount DMG"
    rm -f "$TMP_DMG"
    exit 1
  fi

  APP_BUNDLE=$(find "$MOUNT_POINT" -maxdepth 1 -name "*.app" | head -1)
  if [ -z "$APP_BUNDLE" ]; then
    error "No .app bundle found in DMG"
    hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
    rm -f "$TMP_DMG"
    exit 1
  fi

  APP_NAME_INSTALLED=$(basename "$APP_BUNDLE")
  cp -R "$APP_BUNDLE" /Applications/
  success "Installed to ${BOLD}/Applications/${APP_NAME_INSTALLED}${NC}"

  hdiutil detach "$MOUNT_POINT" -quiet 2>/dev/null || true
  rm -f "$TMP_DMG"

  if [ "$AUTO_START" = "y" ]; then
    step 3 "Enabling auto-start..."
    osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"/Applications/${APP_NAME_INSTALLED}\", hidden:true}" 2>/dev/null || true
    success "Added to Login Items"
  fi
}

# ============================================================
#  PHASE 5: Done
# ============================================================

print_done() {
  echo ""
  echo -e "  ${BOLD}${GREEN}┌─────────────────────────────────────────┐${NC}"
  echo -e "  ${BOLD}${GREEN}│                                         │${NC}"
  echo -e "  ${BOLD}${GREEN}│     ✓ Installation Complete!             │${NC}"
  echo -e "  ${BOLD}${GREEN}│                                         │${NC}"
  echo -e "  ${BOLD}${GREEN}└─────────────────────────────────────────┘${NC}"
  echo ""

  if [ "$PLATFORM" = "linux" ]; then
    if [ "$KIOSK_MODE" = "y" ]; then
      info "Reboot the system to start the kiosk:"
      echo -e "     ${BOLD}sudo reboot${NC}"
    else
      info "Launch the app:"
      echo -e "     ${BOLD}${APPIMAGE_PATH} --kiosk${NC}"
      if [ "$AUTO_START" = "y" ]; then
        echo ""
        info "The app will auto-start on your next login."
      fi
    fi
  elif [ "$PLATFORM" = "mac" ]; then
    info "Launch the app:"
    echo -e "     ${BOLD}open '/Applications/${APP_NAME_INSTALLED}'${NC}"
    if [ "$AUTO_START" = "y" ]; then
      echo ""
      info "The app will auto-start on your next login."
    fi
  fi

  echo ""
  info "Once launched, a pairing code will appear on screen."
  info "Enter it at ${BOLD}https://app.screentaem.com${NC} to connect your display."
  echo ""
}

# ============================================================
#  Main
# ============================================================

print_banner
detect_platform

info "Detected ${BOLD}${PLATFORM}${NC} (${ARCH})"
echo ""

ask_questions

# Calculate total steps for step counter
if [ "$PLATFORM" = "linux" ]; then
  if [ "$KIOSK_MODE" = "y" ]; then
    TOTAL_STEPS=3
  else
    if [ "$AUTO_START" = "y" ]; then
      TOTAL_STEPS=3
    else
      TOTAL_STEPS=2
    fi
  fi
elif [ "$PLATFORM" = "mac" ]; then
  if [ "$AUTO_START" = "y" ]; then
    TOTAL_STEPS=3
  else
    TOTAL_STEPS=2
  fi
fi

print_summary

echo ""

if [ "$PLATFORM" = "linux" ]; then
  if [ "$KIOSK_MODE" = "y" ]; then
    install_linux_kiosk
  else
    install_linux_standard
  fi
elif [ "$PLATFORM" = "mac" ]; then
  install_mac
fi

print_done
