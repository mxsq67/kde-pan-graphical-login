#!/bin/bash

# Installed and run from /home/scottmi/VPN/ (see the .desktop launchers).

# --- Configuration ---
PORTAL="gp.bgss.boeing.com"
VPN_DEV="gpd0"

# Corporate routes added by vpn-connect.sh — removed here on disconnect so a
# later connect re-adds them cleanly with no stale/cached entries. Keep this
# list in sync with CORPORATE_ROUTES in vpn-connect.sh.
CORPORATE_ROUTES=(
    "10.0.0.0/8"
    "172.16.0.0/12"
    "192.168.0.0/16"
    "10.0.2.47/32"
    "10.0.2.12/32"
)

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

dlg_password() { # dlg_password "title" "message" -> echoes value, returns dialog exit code
    if [ "$DIALOG" = "zenity" ]; then
        zenity --title "$1" --password --text="$2"
    else
        kdialog --title "$1" --password "$2"
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

# Give the client a moment to tear the tunnel/interface down before we check
# for leftover routes (the kernel drops routes bound to $VPN_DEV as it goes).
sleep 1

# ─────────────────────────────────────────────
# STEP 3: Clean up leftover corporate routes
#   - Normally the kernel already removed them with $VPN_DEV; this handles the
#     case where they linger so a later connect starts from a clean slate.
#   - Only prompts for sudo if something actually needs removing.
# ─────────────────────────────────────────────
CLEAN_MSG=""

LEFTOVER=()
for route in "${CORPORATE_ROUTES[@]}"; do
    if ip route show "$route" dev "$VPN_DEV" 2>/dev/null | grep -q .; then
        LEFTOVER+=("$route")
    fi
done

if [ "${#LEFTOVER[@]}" -gt 0 ]; then
    check_command "ip"
    check_command "sudo"

    SUDO_PASS=$(dlg_password "Administrative Authentication" $'Removing leftover VPN routes so the next connection starts clean.\n\nEnter your sudo password.')

    if [ $? -ne 0 ] || [ -z "$SUDO_PASS" ]; then
        CLEAN_MSG=$'\n\nLeftover VPN routes were NOT removed (cancelled).'
    elif ! echo "$SUDO_PASS" | sudo -S true 2>/dev/null; then
        CLEAN_MSG=$'\n\nLeftover VPN routes were NOT removed (incorrect sudo password).'
    else
        REMAIN=0
        for route in "${LEFTOVER[@]}"; do
            echo "$SUDO_PASS" | sudo -S ip route del "$route" dev "$VPN_DEV" 2>/dev/null
            if ip route show "$route" dev "$VPN_DEV" 2>/dev/null | grep -q .; then
                REMAIN=$((REMAIN + 1))
            fi
        done
        if [ "$REMAIN" -eq 0 ]; then
            CLEAN_MSG=$'\n\nLeftover corporate routes were removed.'
        else
            CLEAN_MSG=$'\n\nWarning: some corporate routes could not be removed.'
        fi
    fi
    unset SUDO_PASS
fi

# ─────────────────────────────────────────────
# STEP 4: Remove leftover IPC/cache files from vpn-connect.sh
#   - These are normally deleted by that script's EXIT trap; sweep any that a
#     crash or kill left behind so no stale data persists after disconnect.
# ─────────────────────────────────────────────
rm -f /tmp/vpn_gp_exit.* /tmp/vpn_route_status.* 2>/dev/null

# ─────────────────────────────────────────────
# STEP 5: Report result
# ─────────────────────────────────────────────
if [ "$GP_RESULT" -eq 0 ]; then
    dlg_info "VPN Disconnected" "Disconnected from the GlobalProtect VPN.${CLEAN_MSG}"
    exit 0
else
    dlg_error "Failed to disconnect (exit code: $GP_RESULT). You may already be disconnected.${CLEAN_MSG}"
    exit 1
fi
