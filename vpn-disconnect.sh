#!/bin/bash

# --- Configuration ---
PORTAL="gp.bgss.boeing.com"

# Fix for VMware/libEGL software fallback warnings
export LIBGL_ALWAYS_SOFTWARE=1
export EGL_LOG_LEVEL=fatal

# --- Graphical dialog abstraction (zenity for GNOME, kdialog for KDE) ---
# Prefer whichever toolkit's dialog helper is installed so the script works on
# both desktops. All prompts below go through the dlg_* wrappers.
if command -v zenity &> /dev/null; then
    DIALOG="zenity"
elif command -v kdialog &> /dev/null; then
    DIALOG="kdialog"
else
    echo "Error: neither 'zenity' (GNOME) nor 'kdialog' (KDE) is installed." >&2
    exit 1
fi

dlg_error() {    # dlg_error "message"
    if [ "$DIALOG" = "zenity" ]; then
        zenity --error --text="$1"
    else
        kdialog --error "$1"
    fi
}

dlg_info() {     # dlg_info "title" "message"
    if [ "$DIALOG" = "zenity" ]; then
        zenity --title "$1" --info --text="$2"
    else
        kdialog --title "$1" --msgbox "$2"
    fi
}

dlg_question() { # dlg_question "title" "message" -> returns 0 if user confirms
    if [ "$DIALOG" = "zenity" ]; then
        zenity --title "$1" --question --text="$2"
    else
        kdialog --title "$1" --yesno "$2"
    fi
}

# --- Dependency Checks ---
check_command() {
    if ! command -v "$1" &> /dev/null; then
        dlg_error "Required command '$1' is not installed."
        exit 1
    fi
}

check_command "globalprotect"

# ─────────────────────────────────────────────
# STEP 1: Confirm the user wants to disconnect
# ─────────────────────────────────────────────
if ! dlg_question "GlobalProtect VPN" $'Disconnect from the GlobalProtect VPN?'; then
    exit 0
fi

# ─────────────────────────────────────────────
# STEP 2: Disconnect (non-interactive, no terminal needed)
# ─────────────────────────────────────────────
globalprotect disconnect
GP_RESULT=$?

# ─────────────────────────────────────────────
# STEP 3: Report result
# ─────────────────────────────────────────────
if [ "$GP_RESULT" -eq 0 ]; then
    dlg_info "VPN Disconnected" $'Disconnected from the GlobalProtect VPN.'
    exit 0
else
    dlg_error "Failed to disconnect (exit code: $GP_RESULT). You may already be disconnected."
    exit 1
fi
