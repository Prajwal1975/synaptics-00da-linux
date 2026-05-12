#!/bin/bash
# Install synaTudor with 06cb:00da fingerprint reader support.
# Must be run as root (sudo ./install.sh).
# Tested on: ThinkPad E15 Gen 2, CachyOS (Arch-based).

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root: sudo ./install.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TUDOR_SRC="/opt/synaTudor"
TUDOR_COMMIT="31dfdb0"

# --- Dependencies ---
echo "[1/5] Checking dependencies..."
MISSING=()
for cmd in git meson ninja pkg-config innoextract wget; do
    command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    echo "Missing: ${MISSING[*]}"
    echo "Arch/CachyOS: pacman -S git meson ninja pkg-config innoextract wget"
    exit 1
fi

# --- Clone & pin synaTudor ---
echo "[2/5] Setting up synaTudor source..."
if [ -d "$TUDOR_SRC/.git" ]; then
    echo "  -> Found existing clone at $TUDOR_SRC"
else
    git clone https://github.com/Popax21/synaTudor.git "$TUDOR_SRC"
fi
git -C "$TUDOR_SRC" checkout "$TUDOR_COMMIT"

# --- Apply patch ---
echo "[3/5] Applying 06cb:00da patches..."
git -C "$TUDOR_SRC" apply --check "$SCRIPT_DIR/patches/00da-support.patch" 2>/dev/null \
    && git -C "$TUDOR_SRC" apply "$SCRIPT_DIR/patches/00da-support.patch" \
    || echo "  -> Patch already applied, skipping."
cp "$SCRIPT_DIR/patches/user32.c" "$TUDOR_SRC/libtudor/src/winapi/user32.c"

# --- Build & install ---
# The build system calls download_driver.sh automatically to fetch the Lenovo DLLs.
echo "[4/5] Building (will download Lenovo driver DLLs ~30MB)..."
BUILD_DIR="$TUDOR_SRC/build"
meson setup "$BUILD_DIR" "$TUDOR_SRC" --wipe 2>/dev/null || meson setup "$BUILD_DIR" "$TUDOR_SRC"
ninja -C "$BUILD_DIR" install

# --- Enable service ---
echo "[5/5] Enabling tudor-host-launcher..."
systemctl daemon-reload
systemctl enable --now tudor-host-launcher

echo ""
echo "Done. Next steps:"
echo "  Enroll fingerprint : tudor_cli /var/lib/tudor/data.db -P0x00da"
echo "  PAM for sudo       : cp $SCRIPT_DIR/pam/sudo /etc/pam.d/sudo"
echo "  PAM for SDDM       : cp $SCRIPT_DIR/pam/sddm /etc/pam.d/sddm"
echo ""
echo "Note: on SDDM, press Enter (empty password) first to activate fingerprint."
echo "This is a known SDDM limitation, not a driver bug."
