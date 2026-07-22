#!/bin/bash

# Installed and run from /home/scottmi/VPN/ (see vpn.desktop).
#
# Single-pane chooser: shows one dialog with Connect / Disconnect / Cancel
# buttons and launches the matching script from the same directory. Uses the
# running desktop's native toolkit (zenity on GNOME, kdialog on KDE).

# --- Detect desktop environment and bind to its native dialog toolkit ---
# GNOME uses zenity only, KDE uses kdialog only; no cross-toolkit fallback.
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

# Resolve the directory this script lives in so we can find its siblings even
# when launched from a menu entry with an arbitrary working directory.
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

# --- Connection status LED ---
# The VPN device is considered up if its link flags include UP. A colored dot
# is shown in the chooser (green = connected, red = disconnected). This is a
# snapshot taken when the pane opens; it does not live-update.
VPN_DEV="gpd0"
vpn_up() {
    command -v ip > /dev/null 2>&1 && ip link show "$VPN_DEV" 2>/dev/null | grep -q "UP"
}

if vpn_up; then
    LED_ZENITY='<span foreground="#2ecc71" font_weight="bold">●</span>  <b>VPN connected</b>  <span foreground="#7f8c8d">('"$VPN_DEV"' up)</span>'
    LED_KDE='<font color="#2ecc71">●</font> <b>VPN connected</b> <font color="#7f8c8d">('"$VPN_DEV"' up)</font>'
else
    LED_ZENITY='<span foreground="#e74c3c" font_weight="bold">●</span>  VPN disconnected  <span foreground="#7f8c8d">('"$VPN_DEV"' down)</span>'
    LED_KDE='<font color="#e74c3c">●</font> VPN disconnected <font color="#7f8c8d">('"$VPN_DEV"' down)</font>'
fi

# ─────────────────────────────────────────────
# Present the chooser and map the click to an action
# ─────────────────────────────────────────────
ACTION="cancel"

if [ "$DIALOG" = "zenity" ]; then
    # OK button = Connect; the extra button prints its label = Disconnect;
    # Cancel/close prints nothing. Exit code alone cannot tell Disconnect from
    # Cancel, so we key off the printed label.
    CLICK=$(zenity --question \
        --title "GlobalProtect VPN" \
        --text "${LED_ZENITY}"$'\n\nChoose an action:' \
        --ok-label "Connect" \
        --extra-button "Disconnect" \
        --cancel-label "Cancel" \
        2>/dev/null)
    RC=$?
    if [ "$CLICK" = "Disconnect" ]; then
        ACTION="disconnect"
    elif [ "$RC" -eq 0 ]; then
        ACTION="connect"
    fi
else
    # kdialog --yesnocancel: Yes=0, No=1, Cancel/close=2
    kdialog --title "GlobalProtect VPN" \
        --yesnocancel "${LED_KDE}<br><br>Choose an action:" \
        --yes-label "Connect" \
        --no-label "Disconnect"
    case $? in
        0) ACTION="connect" ;;
        1) ACTION="disconnect" ;;
    esac
fi

# ─────────────────────────────────────────────
# Launch the chosen script (replaces this process)
#   - Verify the sibling exists/executable first; a missing script must surface
#     a graphical error, not fail silently under a Terminal=false launcher.
# ─────────────────────────────────────────────
launch() {
    local target="$SCRIPT_DIR/$1"
    if [ ! -x "$target" ]; then
        if [ "$DIALOG" = "zenity" ]; then
            zenity --error --text="Cannot find $1 in $SCRIPT_DIR. Is it installed and executable?"
        else
            kdialog --error "Cannot find $1 in $SCRIPT_DIR. Is it installed and executable?"
        fi
        exit 1
    fi
    exec "$target"
}

case "$ACTION" in
    connect)    launch "vpn-connect.sh" ;;
    disconnect) launch "vpn-disconnect.sh" ;;
    *)          exit 0 ;;
esac
