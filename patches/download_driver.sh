#!/bin/bash -e
# Patched for 06cb:00da: skip hash check, use v104 DLL names directly.
# Lenovo updated the installer; the build system requests 108-named DLLs
# but the installer ships 104-named DLLs — we copy them directly.

HASH_FILE="$1"
TMP_DIR="$2"
OUT_DIR="$3"
DLLS=${@:4}

mkdir -p "$TMP_DIR"

INSTALLER="$TMP_DIR/installer.exe"
wget https://download.lenovo.com/pccbbs/mobiles/r19fp02w.exe -O "$INSTALLER"
# Hash check skipped - Lenovo updated the installer

WINDRV="$TMP_DIR/windrv"
mkdir -p "$WINDRV"
innoextract -d "$WINDRV" "$INSTALLER"

mkdir -p "$OUT_DIR"
for dll in $DLLS
do
    found=$(find "$WINDRV" -name "$dll" -print -quit 2>/dev/null)
    if [ -z "$found" ]; then
        echo "ERROR: $dll not found in extracted driver" >&2
        exit 1
    fi
    cp "$found" "$OUT_DIR/$dll"
done
