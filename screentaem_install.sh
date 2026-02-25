#!/bin/bash
# =============================================================================
# Screentaem Kiosk Setup — Ubuntu LTS (GNOME Desktop)
# =============================================================================
# Run as root on a fresh Ubuntu LTS install:
#   sudo bash screentaem_install.sh /path/to/screentaem.AppImage
#
# The system will:
#   - Install full Ubuntu Desktop (GNOME)
#   - Auto-login as kiosk user
#   - Auto-launch Screentaem in fullscreen kiosk mode
#   - On clean exit → normal GNOME desktop with desktop shortcut
#   - On crash → watchdog auto-restarts within 30 seconds
# =============================================================================

set -euo pipefail
# Allow non-critical commands to fail without killing the script
safe() { "$@" || echo "  (non-critical command failed, continuing)"; }

APPIMAGE_PATH="$1"
KIOSK_USER="kiosk"
KIOSK_HOME="/home/$KIOSK_USER"

# --- Validate input ---
if [ -z "$APPIMAGE_PATH" ]; then
    echo "Usage: sudo bash screentaem_install.sh /path/to/screentaem.AppImage"
    exit 1
fi

if [ ! -f "$APPIMAGE_PATH" ]; then
    echo "Error: AppImage not found at '$APPIMAGE_PATH'"
    exit 1
fi

if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo)"
    exit 1
fi

echo "============================================"
echo "  Screentaem Kiosk Setup (GNOME Desktop)"
echo "============================================"
echo ""
echo "  This will install Ubuntu Desktop (~2-3 GB)"
echo "  and configure the kiosk environment."
echo ""
read -rp "  Continue? (y/n): " CONFIRM
case "$CONFIRM" in
    [yY]|[yY][eE][sS]) ;;
    *) echo "  Aborted."; exit 2 ;;
esac

# --- 1. System update & install Ubuntu Desktop ---
echo ""
echo "[1/12] Installing Ubuntu Desktop and dependencies..."
apt update && apt upgrade -y

# Install full GNOME desktop environment
apt install -y ubuntu-desktop

# Install additional kiosk dependencies
apt install -y \
    libfuse2 \
    fuse3 \
    xdotool \
    pulseaudio \
    alsa-utils \
    wget \
    curl \
    pciutils \
    ubuntu-drivers-common \
    python3-secretstorage \
    --no-install-recommends

echo "  Done"

# --- 2. Install Google Chrome if not present ---
echo "[2/12] Checking for Google Chrome..."
if command -v google-chrome &>/dev/null || command -v google-chrome-stable &>/dev/null; then
    echo "  Chrome is already installed"
else
    echo "  Chrome not found — installing..."
    wget -q -O /tmp/google-chrome.deb \
        "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
    apt install -y /tmp/google-chrome.deb || apt --fix-broken install -y
    rm -f /tmp/google-chrome.deb
    echo "  Chrome installed"
fi

# --- 3. Auto-detect and install GPU drivers ---
echo "[3/12] Detecting GPU and installing drivers..."
GPU_INFO=$(lspci | grep -iE "vga|3d|display" || true)
echo "  Detected: $GPU_INFO"

if echo "$GPU_INFO" | grep -qi "nvidia"; then
    echo "  NVIDIA GPU detected, installing drivers..."
    ubuntu-drivers install --gpgpu nvidia 2>/dev/null || ubuntu-drivers autoinstall || true
    echo "  NVIDIA drivers installed (reboot required)"
elif echo "$GPU_INFO" | grep -qi "amd\|radeon"; then
    echo "  AMD GPU detected, installing mesa drivers..."
    apt install -y mesa-vulkan-drivers mesa-va-drivers --no-install-recommends || true
    echo "  AMD mesa drivers installed"
elif echo "$GPU_INFO" | grep -qi "intel"; then
    echo "  Intel GPU detected, installing drivers..."
    apt install -y intel-media-va-driver mesa-vulkan-drivers --no-install-recommends || true
    echo "  Intel drivers installed"
else
    echo "  No dedicated GPU detected, using default drivers"
fi

# --- 4. Network configuration ---
echo "[4/12] Configuring network..."
systemctl enable NetworkManager
systemctl start NetworkManager

# Configure fallback DNS via systemd-resolved (safe — does not override DHCP DNS)
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/fallback-dns.conf << 'DNSEOF'
[Resolve]
FallbackDNS=8.8.8.8 1.1.1.1
DNSEOF
systemctl restart systemd-resolved 2>/dev/null || true

echo "  NetworkManager enabled — configure WiFi/Ethernet via GNOME Settings"

# --- 5. Automatic security updates ---
echo "[5/12] Configuring automatic security updates..."
apt install -y unattended-upgrades --no-install-recommends
safe apt install -y apt-listchanges --no-install-recommends

cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'UUEOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
UUEOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUEOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
AUEOF

systemctl enable unattended-upgrades
echo "  Automatic security updates enabled (reboot at 4:00 AM if needed)"

# --- 6. Firewall (UFW) ---
echo "[6/12] Configuring firewall..."
apt install -y ufw --no-install-recommends
ufw default deny incoming
ufw default allow outgoing
ufw --force enable
echo "  Firewall enabled (deny incoming, allow outgoing)"

# --- 7. SSH configuration + security hardening ---
echo "[7/12] SSH configuration..."
echo ""
echo "  SSH allows remote access to this kiosk."
echo "  Disabling it improves security but prevents remote maintenance."
echo ""
read -rp "  Do you want to keep SSH enabled? (y/n): " SSH_CHOICE
case "$SSH_CHOICE" in
    [yY]|[yY][eE][sS])
        ufw allow ssh
        echo "  SSH enabled (port 22 open)"
        ;;
    *)
        systemctl disable --now ssh 2>/dev/null || true
        ufw deny ssh
        echo "  SSH disabled and blocked"
        ;;
esac

# Additional hardening
# Disable core dumps
echo "* hard core 0" >> /etc/security/limits.conf
echo "fs.suid_dumpable = 0" >> /etc/sysctl.d/99-kiosk-security.conf

# Block USB storage (prevent data exfiltration)
echo "blacklist usb-storage" > /etc/modprobe.d/block-usb-storage.conf

# Apply sysctl changes
sysctl -p /etc/sysctl.d/99-kiosk-security.conf 2>/dev/null || true
echo "  Core dumps disabled, USB storage blocked"

# --- 8. Create kiosk user ---
echo "[8/12] Creating kiosk user..."
if ! id "$KIOSK_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$KIOSK_USER"
fi
# Add to necessary groups
usermod -aG audio,video,input,plugdev "$KIOSK_USER"
# Lock down home directory permissions
chmod 700 "$KIOSK_HOME"

# --- 9. Copy AppImage + extract icon ---
echo "[9/12] Setting up AppImage..."
mkdir -p "$KIOSK_HOME/app"
cp "$APPIMAGE_PATH" "$KIOSK_HOME/app/screentaem.AppImage"
chmod +x "$KIOSK_HOME/app/screentaem.AppImage"

# Extract icon from AppImage for desktop shortcut
mkdir -p "$KIOSK_HOME/.local/share/icons"
ICON_PATH="$KIOSK_HOME/.local/share/icons/screentaem.png"

cd /tmp
"$KIOSK_HOME/app/screentaem.AppImage" --appimage-extract "*.png" 2>/dev/null || true
if [ -f /tmp/squashfs-root/.DirIcon ]; then
    cp /tmp/squashfs-root/.DirIcon "$ICON_PATH"
elif [ -f /tmp/squashfs-root/icon.png ]; then
    cp /tmp/squashfs-root/icon.png "$ICON_PATH"
elif [ -f /tmp/squashfs-root/usr/share/icons/hicolor/256x256/apps/*.png ]; then
    cp /tmp/squashfs-root/usr/share/icons/hicolor/256x256/apps/*.png "$ICON_PATH" 2>/dev/null || true
fi
rm -rf /tmp/squashfs-root

# Fallback: check if build-icons/icon.png was provided alongside the script
if [ ! -f "$ICON_PATH" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [ -f "$SCRIPT_DIR/build-icons/icon.png" ]; then
        cp "$SCRIPT_DIR/build-icons/icon.png" "$ICON_PATH"
    else
        ICON_PATH="application-x-executable"  # generic fallback
    fi
fi

chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/app"
chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/.local"
echo "  AppImage deployed"

# --- 10. Configure GDM3 auto-login + GNOME session ---
echo "[10/12] Configuring GNOME auto-login..."

# Configure GDM3 auto-login
GDM_CONF="/etc/gdm3/custom.conf"
if [ -f "$GDM_CONF" ]; then
    cp "$GDM_CONF" "${GDM_CONF}.bak"
fi

cat > "$GDM_CONF" << EOF
# GDM configuration — Screentaem kiosk
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=$KIOSK_USER
WaylandEnable=false

[security]

[xdmcp]

[chooser]

[debug]
EOF

# Skip GNOME initial setup wizard
mkdir -p "$KIOSK_HOME/.config"
echo "yes" > "$KIOSK_HOME/.config/gnome-initial-setup-done"
chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/.config"

echo "  GDM3 auto-login configured for user '$KIOSK_USER' (X11 forced)"

# --- 11. Create autostart, desktop shortcut, launcher, and GNOME settings ---
echo "[11/12] Creating autostart, desktop shortcut, and kiosk settings..."

mkdir -p "$KIOSK_HOME/.config/autostart"
mkdir -p "$KIOSK_HOME/Desktop"

# --- Launcher wrapper (detects crash vs clean exit) ---
cat > "$KIOSK_HOME/app/screentaem-launcher.sh" << 'LAUNCHEREOF'
#!/bin/bash
# Screentaem launcher with crash detection
# Exit code 0 = intentional exit (user goes to desktop, no restart)
# Exit code != 0 = crash (write flag for watchdog to pick up)

KIOSK_HOME="/home/kiosk"
CRASH_FLAG="$KIOSK_HOME/.app-crashed"
APPIMAGE="$KIOSK_HOME/app/screentaem.AppImage"

# Remove stale crash flag
rm -f "$CRASH_FLAG"

# Launch the app in kiosk mode
"$APPIMAGE" --no-sandbox --kiosk
EXIT_CODE=$?

if [ $EXIT_CODE -ne 0 ]; then
    echo "[screentaem-launcher] App crashed with exit code $EXIT_CODE"
    touch "$CRASH_FLAG"
fi
LAUNCHEREOF
chmod +x "$KIOSK_HOME/app/screentaem-launcher.sh"

# --- Autostart .desktop (launches app on login) ---
cat > "$KIOSK_HOME/.config/autostart/screentaem.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Screentaem
Comment=Digital Signage Kiosk Display
Exec=$KIOSK_HOME/app/screentaem-launcher.sh
Icon=$ICON_PATH
Terminal=false
Categories=Utility;
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=3
EOF

# --- Desktop shortcut (for manual relaunch) ---
cat > "$KIOSK_HOME/Desktop/screentaem.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Screentaem
Comment=Launch Screentaem Kiosk Display
Exec=$KIOSK_HOME/app/screentaem-launcher.sh
Icon=$ICON_PATH
Terminal=false
Categories=Utility;
EOF
chmod +x "$KIOSK_HOME/Desktop/screentaem.desktop"

# --- One-shot: trust the desktop shortcut (GNOME 42+ requires explicit trust) ---
cat > "$KIOSK_HOME/.config/autostart/trust-desktop-file.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Trust Desktop Files
Exec=bash -c 'sleep 2; gio set ~/Desktop/screentaem.desktop metadata::trusted true 2>/dev/null; rm -f ~/.config/autostart/trust-desktop-file.desktop'
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=1
NoDisplay=true
EOF

# --- One-shot: GNOME kiosk settings (runs on first login) ---
cat > "$KIOSK_HOME/app/gnome-kiosk-setup.sh" << 'SETUPEOF'
#!/bin/bash
# One-time GNOME settings for kiosk mode

# Initialize GNOME Keyring with empty password (prevents "choose password" popup)
# This allows apps like Spotify and Chrome to store credentials without prompting
echo -n "" | gnome-keyring-daemon --unlock --replace 2>/dev/null || true

# Create the default keyring file with empty password if it doesn't exist
if [ ! -f "$HOME/.local/share/keyrings/Default_keyring.keyring" ] && \
   [ ! -f "$HOME/.local/share/keyrings/default.keyring" ]; then
    mkdir -p "$HOME/.local/share/keyrings"
    python3 -c "
import secretstorage
conn = secretstorage.dbus_init()
secretstorage.get_default_collection(conn)
" 2>/dev/null || true
fi

# Disable screen lock
gsettings set org.gnome.desktop.screensaver lock-enabled false
gsettings set org.gnome.desktop.screensaver ubuntu-lock-on-suspend false 2>/dev/null || true

# Disable screen blanking (idle-delay 0 = never blank)
gsettings set org.gnome.desktop.session idle-delay 0

# Disable screen dimming
gsettings set org.gnome.settings-daemon.plugins.power idle-dim false 2>/dev/null || true

# Disable power button action
gsettings set org.gnome.settings-daemon.plugins.power power-button-action 'nothing' 2>/dev/null || true

# Disable notifications (prevent popups over kiosk app)
gsettings set org.gnome.desktop.notifications show-banners false 2>/dev/null || true

# Set volume to maximum
amixer -q sset Master 100% unmute 2>/dev/null || true
amixer -q sset PCM 100% unmute 2>/dev/null || true
pactl set-sink-volume @DEFAULT_SINK@ 100% 2>/dev/null || true
pactl set-sink-mute @DEFAULT_SINK@ 0 2>/dev/null || true

# Note: X11 DPMS and screen sleep prevention is now handled by the Electron app
# via powerSaveBlocker (cross-platform). No xset commands needed.

# Mark setup complete
touch "$HOME/.gnome-kiosk-setup-done"
SETUPEOF
chmod +x "$KIOSK_HOME/app/gnome-kiosk-setup.sh"

cat > "$KIOSK_HOME/.config/autostart/gnome-kiosk-setup.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Kiosk GNOME Setup
Exec=bash -c 'if [ ! -f \$HOME/.gnome-kiosk-setup-done ]; then $KIOSK_HOME/app/gnome-kiosk-setup.sh; fi'
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=1
NoDisplay=true
EOF

# --- Unlock GNOME Keyring on every login (auto-login skips PAM unlock) ---
cat > "$KIOSK_HOME/.config/autostart/unlock-keyring.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Unlock Keyring
Exec=bash -c 'echo -n "" | gnome-keyring-daemon --unlock --replace 2>/dev/null || true'
Terminal=false
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=0
NoDisplay=true
EOF

# Note: DPMS autostart entry removed — Electron's powerSaveBlocker handles this now.

chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/.config"
chown -R "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/Desktop"
chown "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/app/screentaem-launcher.sh"
chown "$KIOSK_USER:$KIOSK_USER" "$KIOSK_HOME/app/gnome-kiosk-setup.sh"

echo "  Autostart, desktop shortcut, and GNOME settings configured"

# --- 12. Security hardening + watchdog ---
echo "[12/12] Security hardening and setting up watchdog..."

# Note: sleep/suspend/hibernate prevention is now handled by Electron's powerSaveBlocker.
# We still mask Ctrl+Alt+Delete to prevent accidental reboots on kiosk hardware.
systemctl mask ctrl-alt-del.target

# --- Simplified watchdog: only restart on crash ---
cat > /etc/systemd/system/kiosk-watchdog.service << EOF
[Unit]
Description=Screentaem Kiosk Crash Watchdog
After=graphical.target

[Service]
Type=simple
User=$KIOSK_USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$KIOSK_USER/.Xauthority
ExecStart=/bin/bash -c 'while true; do sleep 30; if [ -f /home/kiosk/.app-crashed ]; then rm -f /home/kiosk/.app-crashed; echo "[watchdog] Crash detected, restarting app..."; /home/kiosk/app/screentaem-launcher.sh; fi; done'
Restart=always
RestartSec=10

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable kiosk-watchdog.service

echo "  Power management disabled, watchdog enabled"

# --- Done ---
echo ""
echo "============================================"
echo "  Setup complete!"
echo "============================================"
echo ""
echo "  Kiosk user:  $KIOSK_USER"
echo "  AppImage:    $KIOSK_HOME/app/screentaem.AppImage"
echo ""
echo "  On reboot, the system will:"
echo "    1. Start GDM3 and auto-login as '$KIOSK_USER'"
echo "    2. Load GNOME desktop"
echo "    3. Auto-launch Screentaem in fullscreen kiosk mode"
echo "    4. Set volume to 100%"
echo ""
echo "  When the app exits cleanly (via PIN/menu):"
echo "    -> You see the full GNOME desktop"
echo "    -> WiFi/network managed via GNOME Settings"
echo "    -> Double-click 'Screentaem' desktop icon to relaunch"
echo ""
echo "  If the app crashes:"
echo "    -> Watchdog restarts it within 30 seconds"
echo ""
echo "  Reboot now?  sudo reboot"
echo "============================================"
