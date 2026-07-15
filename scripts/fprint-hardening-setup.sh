#!/bin/bash
#
# fprint-hardening-setup.sh
# ---------------------------------------------------------------------------
# Hardening + self-recovery for the Synaptics 06cb:00da fingerprint sensor
# (synaTudor driver via libfprint-2-tod1) on ThinkPad E15 Gen 2, Ubuntu 22.04.
#
# Context: this sensor stores enrolled prints in on-chip storage keyed to a
# host pairing that the driver re-establishes on load. A kernel/module update
# can re-probe the device, re-pair with a fresh host key, and leave old prints
# undiscoverable (fprintd reports NoEnrolledPrints). This cannot be fully
# prevented from the host side. The goals here are therefore:
#   1. Prevent the one failure that truly breaks the DRIVER (a libfprint/TOD
#      package upgrade overwriting the ported driver)  -> apt-mark hold
#   2. Make the recurring enrollment-wipe a notified, 15-second re-enroll
#      instead of a lock-screen surprise                -> boot healthcheck
#   3. Keep known-good backups of pairing state + config for fast recovery
#
# Idempotent: safe to run multiple times.
# Run with: sudo ./fprint-hardening-setup.sh
# ---------------------------------------------------------------------------

set -euo pipefail

TARGET_USER="${SUDO_USER:-prajwal}"
BACKUP_DIR="/root"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo." >&2
    exit 1
fi

echo "==> [1/6] Backing up current (working) pairing state..."
# synaTudor host pairing + enrollment store lives under /var/lib/fprint
tar czf "${BACKUP_DIR}/fprint-pairing-backup.tar.gz" -C /var/lib fprint
echo "    saved: ${BACKUP_DIR}/fprint-pairing-backup.tar.gz"

echo "==> [2/6] Holding driver packages against upgrades..."
# libfprint-2-tod1 carries the ported synaTudor driver (Touch OEM Driver iface).
# fprintd / libpam-fprintd / libfprint-2-2 complete the stack.
apt-mark hold fprintd libfprint-2-2 libfprint-2-tod1 libpam-fprintd
echo "    currently held:"
apt-mark showhold | sed 's/^/      /'

echo "==> [3/6] Purging conflicting open-fprintd remnants (if any)..."
# open-fprintd (PPA) fights fprintd over the D-Bus name if it ever comes back.
apt purge -y open-fprintd 2>/dev/null || true

echo "==> [4/6] Backing up PAM + tudor-wait drop-in as known-good..."
cp /etc/pam.d/common-auth "${BACKUP_DIR}/common-auth.known-good"
if [[ -f /etc/systemd/system/fprintd.service.d/tudor-wait.conf ]]; then
    cp /etc/systemd/system/fprintd.service.d/tudor-wait.conf \
       "${BACKUP_DIR}/tudor-wait.conf.bak"
fi

echo "==> [5/6] Installing boot-time enrollment healthcheck..."
cat > /usr/local/bin/fprint-healthcheck.sh <<EOF
#!/bin/bash
# Checks fingerprint enrollment on boot; notifies the desktop user if wiped.
sleep 15  # let fprintd + tudor-wait settle after boot
if ! fprintd-list ${TARGET_USER} 2>/dev/null | grep -q "right-index-finger"; then
    logger -t fprint-healthcheck "No enrolled prints found - sensor likely re-probed"
    for uid in \$(loginctl list-users --no-legend | awk '{print \$1}'); do
        user=\$(id -nu "\$uid" 2>/dev/null) || continue
        sudo -u "\$user" DISPLAY=:0 \\
          DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/\$uid/bus" \\
          notify-send "Fingerprint" "Prints wiped by update. Run: fixfp" 2>/dev/null
    done
fi
EOF
chmod +x /usr/local/bin/fprint-healthcheck.sh

cat > /etc/systemd/system/fprint-healthcheck.service <<EOF
[Unit]
Description=Fingerprint enrollment health check
After=fprintd.service graphical.target
Wants=fprintd.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/fprint-healthcheck.sh

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable fprint-healthcheck.service

echo "==> [6/6] Installing 'fixfp' recovery alias for ${TARGET_USER}..."
ALIAS_LINE="alias fixfp='fprintd-enroll && fprintd-verify'"
USER_HOME=$(getent passwd "${TARGET_USER}" | cut -d: -f6)
ALIAS_FILE="${USER_HOME}/.bash_aliases"
if ! grep -qF "$ALIAS_LINE" "$ALIAS_FILE" 2>/dev/null; then
    echo "$ALIAS_LINE" >> "$ALIAS_FILE"
    chown "${TARGET_USER}:${TARGET_USER}" "$ALIAS_FILE"
fi

echo
echo "==> Done. Summary:"
echo "    - Pairing backup ....... ${BACKUP_DIR}/fprint-pairing-backup.tar.gz"
echo "    - Driver packages held . fprintd libfprint-2-2 libfprint-2-tod1 libpam-fprintd"
echo "    - Healthcheck .......... enabled (notifies on boot if prints wiped)"
echo "    - Recovery alias ....... 'fixfp' (re-enroll + verify in one command)"
echo
echo "    RECOVERY, if a future update wipes prints:"
echo "      1) run:  fixfp"
echo "      2) if pairing itself is lost, restore backup:"
echo "           sudo systemctl stop fprintd"
echo "           sudo tar xzf ${BACKUP_DIR}/fprint-pairing-backup.tar.gz -C /var/lib"
echo "           sudo systemctl start fprintd"
echo
echo "    TO UPDATE HELD PACKAGES DELIBERATELY:"
echo "      sudo apt-mark unhold fprintd libfprint-2-2 libfprint-2-tod1 libpam-fprintd"
echo "      sudo apt update && sudo apt upgrade"
echo "      # verify fingerprint still works, then re-hold with apt-mark hold"
echo
echo "    KERNEL NOTE: keep at least one prior known-good kernel installed."
echo "    Do not 'apt autoremove' kernels blindly; if fingerprint dies after a"
echo "    kernel jump, boot the older kernel from GRUB while you re-enroll."
