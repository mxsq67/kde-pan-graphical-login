#!/bin/bash

# Installed and run from /home/scottmi/VPN/ (see the .desktop launchers).

# --- Configuration ---
PORTAL="gp.bgss.boeing.com"

# Fix for VMware/libEGL software fallback warnings
export LIBGL_ALWAYS_SOFTWARE=1
export EGL_LOG_LEVEL=fatal

# --- Detect desktop environment and bind to its native dialog toolkit ---
# Validate the running session and lock to exactly one toolkit: GNOME uses
# zenity only, KDE uses kdialog only. The script does NOT fall back to the
# other toolkit — it must match the detected environment. All prompts below
# go through the dlg_* wrappers, never a raw zenity/kdialog call.
DESKTOP_ENV="${XDG_CURRENT_DESKTOP:-$DESKTOP_SESSION}"
shopt -s nocasematch
case "$DESKTOP_ENV" in
    *gnome*)
        DIALOG="zenity"
        ;;
    *kde*|*plasma*)
        DIALOG="kdialog"
        ;;
    *)
        echo "Error: unsupported desktop environment '${DESKTOP_ENV:-unknown}'." \
             "This script supports only GNOME (zenity) or KDE (kdialog)." >&2
        exit 1
        ;;
esac
shopt -u nocasematch

# The environment's required dialog tool must be present — no cross-toolkit fallback.
if ! command -v "$DIALOG" &> /dev/null; then
    echo "Error: '$DIALOG' is required for the detected $DESKTOP_ENV session but is not installed." >&2
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
