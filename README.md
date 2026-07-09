# Synaptics 06cb:00da Fingerprint Reader on Linux
<p align="center">
  <a href="https://paypal.me/fraxdea0102">
    <img src="https://img.shields.io/badge/Donate-PayPal-00457C?style=for-the-badge&logo=paypal&logoColor=white" alt="Donate with PayPal"/>
  </a>
</p>

> If this project saved you hours of frustration, consider buying me a coffee ☕

Linux support for the **Synaptics 06cb:00da** fingerprint reader (ThinkPad E15 Gen 2 and similar), based on [synaTudor](https://github.com/Popax21/synaTudor) with additional patches to support this specific device.

## Tested hardware

| Field | Value |
|-------|-------|
| USB ID | `06cb:00da` |
| Family | VSI 55D |
| Firmware | ROM 10.1 (Jan 17 2020) |
| Tested on | ThinkPad E15 Gen 2 — CachyOS (Arch-based), Ubuntu 22.04 LTS |

## What these patches add

synaTudor upstream supports `06cb:00be`. These patches extend it to `06cb:00da`:

- **udev rules** — added `06cb:00da` device entry
- **libfprint-tod** — added `06cb:00da` to the driver device table
- **`user32.c`** (new file) — Win32 stubs required by the `00da` firmware
- **`reg.c`** — `RegQueryInfoKeyW` stub
- **`module.c`** — fixed `GetModuleHandleA/W` NULL self-handle
- **`api.h`** — added `base_addr`/`image_size` fields to `winmodule`
- **`wdf.c`** — `wdf_func_stub` calling convention fix
- **`wdf/device.c`** — additional WDF device function stubs
- **`download_driver.sh`** — skip hash check and use v104 DLL names (Lenovo updated the installer)

## Requirements

### Arch Linux / CachyOS
```bash
sudo pacman -S git meson ninja pkg-config innoextract wget libusb openssl fprintd
```

### Ubuntu 22.04 LTS
The install script handles dependencies automatically on Ubuntu. Just run it with sudo.

## Installation

```bash
git clone https://github.com/francescomcrtl/synaptics-00da-linux.git
cd synaptics-00da-linux
sudo ./install.sh
```

The script detects your distro automatically and:
1. Installs all required dependencies
2. Clones synaTudor at a pinned commit
3. Applies the 06cb:00da patches
4. Fixes the download_driver.sh for the current Lenovo installer (v104 DLLs)
5. Builds and installs the driver
6. Configures systemd and PAM automatically

---

## Ubuntu 22.04 — Additional Notes

Ubuntu requires several fixes that Arch does not. The install script handles all of these automatically, but they are documented here for reference.

### 1. Build dependencies
Ubuntu splits libraries differently from Arch. The script installs:
`libcap-dev libseccomp-dev libgusb-dev libudev-dev libjson-glib-dev libfprint-2-tod-dev libpam-fprintd`

### 2. Ninja symlink
Ubuntu installs ninja as `ninja-build`. The script creates a symlink at `/usr/local/bin/ninja`.

### 3. DLL version mismatch
The Lenovo installer (`r19fp02w.exe`) now ships v104 DLLs (`synaFpAdapter104.dll`, `synaWudfBioUsb104.dll`) but the build system requests v108 names. The patched `download_driver.sh` in `patches/` handles this correctly.

### 4. Data directory permissions
`tudor_cli` drops root privileges before opening the data file. The script creates `/var/lib/tudor/` and sets ownership to your user.

### 5. systemd race condition
At boot, `fprintd` and `tudor-host-launcher` start simultaneously. If fprintd connects before tudor-host-launcher has initialized the USB device, it fails with `ObjectPathInUse`. The script installs two overrides:
- `/etc/systemd/system/fprintd.service.d/tudor-wait.conf` — makes fprintd wait for tudor-host-launcher
- `/etc/systemd/system/tudor-host-launcher.service.d/override.conf` — adds a 2 second startup delay

### 6. PAM configuration
Ubuntu's `pam_fprintd.so` is at `/usr/lib/x86_64-linux-gnu/security/pam_fprintd.so` (not just `pam_fprintd.so`). The script writes the full path into `/etc/pam.d/sudo` and `/etc/pam.d/common-auth`. Ubuntu also uses `common-auth` instead of Arch's `system-auth`.

---

## After installation — enroll your fingerprint

```bash
# Restart services cleanly
sudo killall tudor_host tudor_host_launcher 2>/dev/null; true
sudo systemctl restart tudor-host-launcher && sleep 3
sudo systemctl restart fprintd

# Enroll (run 3-4 times at different angles for best accuracy)
fprintd-enroll -f right-index-finger

# Verify
fprintd-verify

# Test sudo
sudo -k && sudo ls
```

## PAM configuration (Arch only — Ubuntu is handled automatically)

### sudo
```bash
sudo cp pam/sudo /etc/pam.d/sudo
```

### SDDM login screen
```bash
sudo cp pam/sddm /etc/pam.d/sddm
```

> **Note on SDDM:** Press Enter on the login screen with an empty password field to activate the fingerprint prompt. This is a known SDDM limitation, not a driver bug.

## Troubleshooting

### Fingerprint stops working after reboot
A stale `tudor_host` process is blocking the USB device. Fix:
```bash
sudo killall tudor_host tudor_host_launcher 2>/dev/null; true
sudo systemctl restart tudor-host-launcher && sleep 3
sudo systemctl restart fprintd
```
If this keeps happening, make sure the systemd overrides were installed (Part 5 of the install script).

### `fprintd-verify` says "No devices available"
Run the restart sequence above.

### `PAM unable to dlopen pam_fprintd.so`
The PAM config has the wrong path. Find the correct path:
```bash
find /usr /lib -name "pam_fprintd.so"
```
Then update `/etc/pam.d/sudo` and `/etc/pam.d/common-auth` with the full path.

### Login keyring popup after fingerprint login
The GNOME keyring uses your password as its encryption key and cannot unlock with fingerprint. Fix:
Open **Passwords and Keys** app → right-click **Login** keyring → **Change Password** → leave new password blank → Continue.

## Credits

- [synaTudor](https://github.com/Popax21/synaTudor) by **Popax21** — the reverse-engineered Linux driver for Synaptics Tudor fingerprint readers
- Patches, reverse engineering work, and `06cb:00da` support by **[francescomcrtl](https://github.com/francescomcrtl)**
- Ubuntu 22.04 porting (dependency fixes, DLL version fix, systemd race condition fix, PAM configuration) by **[Prajwal1975](https://github.com/Prajwal1975)**
- Patch development assisted by **[Claude](https://claude.ai)** (Anthropic)

## License

GPL-2.0 — same as synaTudor.
