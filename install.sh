#!/bin/bash
# Install synaTudor with 06cb:00da fingerprint reader support.
# Must be run as root (sudo ./install.sh).
# Tested on: ThinkPad E15 Gen 2, CachyOS (Arch-based) and Ubuntu 22.04.
set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo ./install.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUDOR_SRC="/opt/synaTudor"
TUDOR_COMMIT="31dfdb0"

# --- Detect distro ---
DISTRO="unknown"
if [ -f /etc/os-release ]; then
    . /etc/os-release
    case "$ID" in
        ubuntu|debian) DISTRO="ubuntu" ;;
        arch|cachyos|endeavouros|manjaro) DISTRO="arch" ;;
    esac
fi
echo "Detected distro family: $DISTRO"

# --- Dependencies ---
echo "[1/6] Checking and installing dependencies..."
if [ "$DISTRO" = "ubuntu" ]; then
    echo "  -> Installing Ubuntu dependencies..."
    apt-get install -y \
        git meson ninja-build pkg-config innoextract wget \
        libusb-1.0-0-dev libssl-dev libglib2.0-dev libudev-dev \
        libgusb-dev libjson-glib-dev libdbus-1-dev libfprint-2-tod-dev \
        libcap-dev libseccomp-dev fprintd libpam-fprintd
    # ninja-build installs as ninja-build on Ubuntu, symlink for build system
    if ! command -v ninja &>/dev/null; then
        ln -sf /usr/bin/ninja-build /usr/local/bin/ninja
    fi
else
    MISSING=()
    for cmd in git meson ninja pkg-config innoextract wget; do
        command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
    done
    if [ ${#MISSING[@]} -gt 0 ]; then
        echo "Missing: ${MISSING[*]}"
        echo "Arch/CachyOS: pacman -S git meson ninja pkg-config innoextract wget"
        exit 1
    fi
fi

# --- Clone & pin synaTudor ---
echo "[2/6] Setting up synaTudor source..."
if [ -d "$TUDOR_SRC/.git" ]; then
    echo "  -> Found existing clone at $TUDOR_SRC"
else
    git clone https://github.com/Popax21/synaTudor.git "$TUDOR_SRC"
fi
git -C "$TUDOR_SRC" checkout "$TUDOR_COMMIT"

# --- Apply patch ---
echo "[3/6] Applying 06cb:00da patches..."
git -C "$TUDOR_SRC" apply --check "$SCRIPT_DIR/patches/00da-support.patch" 2>/dev/null \
    && git -C "$TUDOR_SRC" apply "$SCRIPT_DIR/patches/00da-support.patch" \
    || echo "  -> Patch already applied, skipping."
cp "$SCRIPT_DIR/patches/user32.c" "$TUDOR_SRC/libtudor/src/winapi/user32.c"

# --- Fix download_driver.sh (Ubuntu: Lenovo installer ships v104 DLLs not v108) ---
if [ "$DISTRO" = "ubuntu" ]; then
    echo "  -> Applying Ubuntu download_driver.sh fix (v104 DLL names)..."
    cp "$SCRIPT_DIR/patches/download_driver.sh" "$TUDOR_SRC/libtudor/download_driver.sh"
    chmod +x "$TUDOR_SRC/libtudor/download_driver.sh"
fi

# --- Build & install ---
echo "[4/6] Building (will download Lenovo driver DLLs ~30MB)..."
BUILD_DIR="$TUDOR_SRC/build"
meson setup "$BUILD_DIR" "$TUDOR_SRC" --wipe 2>/dev/null || meson setup "$BUILD_DIR" "$TUDOR_SRC"
ninja -C "$BUILD_DIR" install

# --- Setup data directory (Ubuntu: tudor drops root before opening data file) ---
if [ "$DISTRO" = "ubuntu" ]; then
    echo "  -> Creating tudor data directory..."
    mkdir -p /var/lib/tudor
    # Give ownership to the first non-root user (the one running sudo)
    REAL_USER="${SUDO_USER:-$USER}"
    chown "$REAL_USER:$REAL_USER" /var/lib/tudor
fi

# --- Fix systemd race condition (Ubuntu: fprintd and tudor-host-launcher start together) ---
if [ "$DISTRO" = "ubuntu" ]; then
    echo "  -> Installing systemd ordering fix..."
    mkdir -p /etc/systemd/system/fprintd.service.d
    cp "$SCRIPT_DIR/systemd/fprintd-tudor-wait.conf" \
       /etc/systemd/system/fprintd.service.d/tudor-wait.conf
    mkdir -p /etc/systemd/system/tudor-host-launcher.service.d
    cp "$SCRIPT_DIR/systemd/tudor-delay.conf" \
       /etc/systemd/system/tudor-host-launcher.service.d/override.conf
fi

# --- Enable service ---
echo "[5/6] Enabling tudor-host-launcher..."
systemctl daemon-reload
systemctl enable --now tudor-host-launcher 2>/dev/null || true

# --- PAM configuration ---
echo "[6/6] Configuring PAM authentication..."
if [ "$DISTRO" = "ubuntu" ]; then
    PAM_FPRINT_SO="/usr/lib/x86_64-linux-gnu/security/pam_fprintd.so"
    if [ ! -f "$PAM_FPRINT_SO" ]; then
        echo "  -> WARNING: pam_fprintd.so not found at expected path."
        echo "     Run: sudo apt install libpam-fprintd"
        echo "     Then manually apply PAM config from pam/common-auth"
    else
        echo "  -> Applying Ubuntu PAM config..."
        cp "$SCRIPT_DIR/pam/common-auth" /etc/pam.d/common-auth
        # Patch sudo PAM to use full path
        cat > /etc/pam.d/sudo << PAMEOF
#%PAM-1.0
auth       sufficient    ${PAM_FPRINT_SO} timeout=10
auth       sufficient    pam_unix.so try_first_pass nullok
auth       required      pam_deny.so
account    required      pam_permit.so
session    required      pam_limits.so
PAMEOF
    fi
else
    echo "  -> Arch PAM: copy manually if needed:"
    echo "     sudo cp $SCRIPT_DIR/pam/sudo /etc/pam.d/sudo"
fi

echo ""
echo "================================================================"
echo "Done!"
echo "================================================================"
echo ""
if [ "$DISTRO" = "ubuntu" ]; then
    echo "Next steps (Ubuntu):"
    echo ""
    echo "  1. Restart services:"
    echo "     sudo killall tudor_host tudor_host_launcher 2>/dev/null; true"
    echo "     sudo systemctl restart tudor-host-launcher && sleep 3"
    echo "     sudo systemctl restart fprintd"
    echo ""
    echo "  2. Enroll your fingerprint:"
    echo "     fprintd-enroll -f right-index-finger"
    echo "     (run 3-4 times at different angles for best accuracy)"
    echo ""
    echo "  3. Verify it works:"
    echo "     fprintd-verify"
    echo ""
    echo "  4. Test sudo:"
    echo "     sudo -k && sudo ls"
    echo "     (touch sensor when prompted — do not type password)"
    echo ""
    echo "  5. Fix login keyring popup (if it appears):"
    echo "     Open 'Passwords and Keys' app → right-click Login → Change Password → leave blank"
else
    echo "Next steps (Arch/CachyOS):"
    echo "  Enroll fingerprint : sudo tudor_cli /var/lib/tudor/data.db -P0x00da"
    echo "  PAM for sudo       : sudo cp $SCRIPT_DIR/pam/sudo /etc/pam.d/sudo"
    echo "  PAM for SDDM       : sudo cp $SCRIPT_DIR/pam/sddm /etc/pam.d/sddm"
    echo ""
    echo "Note: on SDDM, press Enter (empty password) first to activate fingerprint."
fi
echo ""
