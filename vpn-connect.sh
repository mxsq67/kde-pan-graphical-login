#!/bin/bash

# Installed and run from /home/scottmi/VPN/ (see the .desktop launchers).

# --- Configuration ---
PORTAL="gp.bgss.boeing.com"
USERNAME="scottmi"
VPN_DEV="gpd0"
LOCAL_INTERFACES=("enp2s0" "ens160")
TARGET_PREFIX="10.0.2."

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

# Explicitly set xterm as the terminal emulator for this session
export TERM=xterm-256color

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

dlg_notify() {   # dlg_notify "message"
    if [ "$DIALOG" = "zenity" ]; then
        zenity --notification --text="$1"
    else
        kdialog --passivepopup "$1" 4
    fi
}

dlg_input() {    # dlg_input "title" "message" -> echoes value, returns dialog exit code
    if [ "$DIALOG" = "zenity" ]; then
        zenity --title "$1" --entry --text="$2"
    else
        kdialog --title "$1" --inputbox "$2"
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
check_command "ip"
check_command "grep"
check_command "xterm"
check_command "sudo"

# Resolve absolute path to xterm
XTERM_BIN=$(command -v xterm)

# --- Temp files for IPC: globalprotect exit code and route-verify result ---
GP_EXIT_FILE=$(mktemp /tmp/vpn_gp_exit.XXXXXX)
ROUTE_STATUS_FILE=$(mktemp /tmp/vpn_route_status.XXXXXX)
chmod 600 "$GP_EXIT_FILE" "$ROUTE_STATUS_FILE"

cleanup() {
    rm -f "$GP_EXIT_FILE" "$ROUTE_STATUS_FILE"
}
trap cleanup EXIT

# ─────────────────────────────────────────────
# STEP 1: Graphical username prompt (if not hardcoded)
# ─────────────────────────────────────────────
if [ -z "$USERNAME" ]; then
    USERNAME=$(dlg_input "GlobalProtect VPN" "Enter Boeing Username:")
    if [ $? -ne 0 ] || [ -z "$USERNAME" ]; then
        exit 0
    fi
fi

# ─────────────────────────────────────────────
# STEP 2: Notify user — xterm is opening for auth
# ─────────────────────────────────────────────
dlg_notify "Opening secure authentication terminal for $USERNAME@$PORTAL..."

# ─────────────────────────────────────────────
# STEP 3: Run globalprotect in an xterm window
#   - Interactive: user types password + MFA here
#   - Exit code written to temp file for main script
# ─────────────────────────────────────────────
"$XTERM_BIN" \
    -title "Boeing GlobalProtect — Authentication" \
    -geometry 90x30 \
    -bg "#0d1117" \
    -fg "#58d68d" \
    -fa "Monospace" \
    -fs 12 \
    -bd "#1f6feb" \
    -bw 2 \
    -e bash -c '
        echo ""
        echo -e "\033[1;34m  ╔══════════════════════════════════════════════════════╗\033[0m"
        echo -e "\033[1;34m  ║        Boeing GlobalProtect VPN — Auth Terminal      ║\033[0m"
        echo -e "\033[1;34m  ╚══════════════════════════════════════════════════════╝\033[0m"
        echo ""
        echo -e "\033[0;33m  Portal   : '"$PORTAL"'\033[0m"
        echo -e "\033[0;33m  Username : '"$USERNAME"'\033[0m"
        echo ""
        echo -e "\033[0;37m  Enter your password and complete MFA below.\033[0m"
        echo -e "\033[0;37m  This window will close automatically on success.\033[0m"
        echo ""
        echo -e "\033[1;34m  ────────────────────────────────────────────────────────\033[0m"
        echo ""

        globalprotect connect --portal "'"$PORTAL"'" --username "'"$USERNAME"'"
        GP_RESULT=$?

        # Write exit code; default to 1 if something went very wrong
        echo "${GP_RESULT:-1}" > "'"$GP_EXIT_FILE"'"

        if [ "$GP_RESULT" -eq 0 ]; then
            echo ""
            echo -e "\033[1;32m  ✔  Authentication successful. Closing terminal...\033[0m"
            sleep 2
        else
            echo ""
            echo -e "\033[1;31m  ✘  Connection failed (exit code: $GP_RESULT).\033[0m"
            echo -e "\033[0;37m  Review the output above, then press Enter to close.\033[0m"
            read -r
        fi
    '

# ─────────────────────────────────────────────
# STEP 4: Read exit code written by xterm subshell
# ─────────────────────────────────────────────
GP_EXIT=$(cat "$GP_EXIT_FILE" 2>/dev/null)

# Treat missing/empty exit file as failure
if [ -z "$GP_EXIT" ]; then
    GP_EXIT=1
fi

# Belt-and-suspenders: if GP reported failure, check if the interface came up anyway
# (globalprotect on Linux has unreliable exit codes)
if [ "$GP_EXIT" != "0" ]; then
    sleep 2
    if ip link show "$VPN_DEV" 2>/dev/null | grep -q "UP"; then
        GP_EXIT=0
    fi
fi

if [ "$GP_EXIT" != "0" ]; then
    dlg_error "VPN connection failed. Please check your credentials or network."
    exit 1
fi

# ─────────────────────────────────────────────
# STEP 5: Check if custom routes are needed
# ─────────────────────────────────────────────
SHOULD_ADD_ROUTES=false

for iface in "${LOCAL_INTERFACES[@]}"; do
    LOCAL_IP=$(ip -4 addr show "$iface" 2>/dev/null \
        | awk '/inet / {split($2,a,"/"); print a[1]; exit}')

    if [[ -n "$LOCAL_IP" ]] && [[ "$LOCAL_IP" == "$TARGET_PREFIX"* ]]; then
        SHOULD_ADD_ROUTES=true
        break
    fi
done

if [ "$SHOULD_ADD_ROUTES" = false ]; then
    dlg_info "VPN Connected" $'Connected successfully!\n\nNo matching subnets detected — custom routes skipped.'
    exit 0
fi

# ─────────────────────────────────────────────
# STEP 6: Collect sudo password ONCE via the dialog helper
#   - Validated immediately before use
#   - Exported to environment for the route xterm
# ─────────────────────────────────────────────
SUDO_PASS=$(dlg_password "Administrative Authentication" $'Matching subnet detected. Enter your sudo password to apply corporate routing tables.\n\nThis will be used for all route entries — you will not be prompted again.')

if [ $? -ne 0 ] || [ -z "$SUDO_PASS" ]; then
    dlg_error "Authentication cancelled. Routes were not applied."
    exit 1
fi

# Validate password before proceeding
if ! echo "$SUDO_PASS" | sudo -S true 2>/dev/null; then
    dlg_error "Incorrect sudo password. Routes were not applied."
    exit 1
fi

# ─────────────────────────────────────────────
# STEP 7: Apply routes in a styled xterm window
#   - sudo -S reads password from stdin (no prompt)
#   - stderr kept visible so auth failures are shown
# ─────────────────────────────────────────────
export VPN_DEV
export CORPORATE_ROUTES_STR="${CORPORATE_ROUTES[*]}"
export SUDO_PASS
export ROUTE_STATUS_FILE

"$XTERM_BIN" \
    -title "Boeing GlobalProtect — Applying Routes" \
    -geometry 90x22 \
    -bg "#0d1117" \
    -fg "#58d68d" \
    -fa "Monospace" \
    -fs 12 \
    -bd "#1f6feb" \
    -bw 2 \
    -e bash -c '
        echo ""
        echo -e "\033[1;34m  ╔══════════════════════════════════════════════════════╗\033[0m"
        echo -e "\033[1;34m  ║         Boeing GlobalProtect — Route Injection       ║\033[0m"
        echo -e "\033[1;34m  ╚══════════════════════════════════════════════════════╝\033[0m"
        echo ""
        echo -e "\033[0;33m  Applying corporate routing tables via $VPN_DEV...\033[0m"
        echo -e "\033[1;34m  ────────────────────────────────────────────────────────\033[0m"
        echo ""

        # Keep NetworkManager out of the way: if it is present and running, mark
        # the VPN device unmanaged so NM does not reclaim it and flush the routes
        # we are about to add. Best-effort — ignored if nmcli is absent or fails.
        if command -v nmcli > /dev/null 2>&1 \
           && nmcli -t -f RUNNING general 2>/dev/null | grep -q "running"; then
            printf "  \033[0;37m%-28s\033[0m" "NetworkManager: unmanage $VPN_DEV"
            if echo "$SUDO_PASS" | sudo -S nmcli device set "$VPN_DEV" managed no 2>/dev/null; then
                echo -e "\033[1;32m  ✔  Done\033[0m"
            else
                echo -e "\033[1;33m  ⚠  Skipped\033[0m"
            fi
            echo ""
        fi

        read -r -a routes <<< "$CORPORATE_ROUTES_STR"

        # route_present: true if the exact route is installed on $VPN_DEV
        route_present() {
            ip route show "$1" dev "$VPN_DEV" 2>/dev/null | grep -q .
        }

        for route in "${routes[@]}"; do
            printf "  \033[0;37m%-28s\033[0m" "$route"
            # stderr is suppressed so sudo/ip errors do not pollute the status
            # line; failures still register via exit status and show as "Failed"
            if echo "$SUDO_PASS" | sudo -S ip route replace "$route" dev "$VPN_DEV" 2>/dev/null; then
                echo -e "\033[1;32m  ✔  Applied\033[0m"
            else
                echo -e "\033[1;31m  ✘  Failed\033[0m"
            fi
            sleep 0.15
        done

        echo ""
        echo -e "\033[0;33m  Verifying routes are present, re-adding any that are missing...\033[0m"
        echo -e "\033[1;34m  ────────────────────────────────────────────────────────\033[0m"
        echo ""

        # Verification pass: confirm each route actually exists in the table and
        # re-add (up to 3 attempts) any that GlobalProtect or a race dropped.
        ALL_OK=true
        for route in "${routes[@]}"; do
            printf "  \033[0;37m%-28s\033[0m" "$route"

            if route_present "$route"; then
                echo -e "\033[1;32m  ✔  Present\033[0m"
                continue
            fi

            READDED=false
            for attempt in 1 2 3; do
                echo "$SUDO_PASS" | sudo -S ip route replace "$route" dev "$VPN_DEV" 2>/dev/null
                sleep 0.3
                if route_present "$route"; then
                    READDED=true
                    break
                fi
            done

            if [ "$READDED" = true ]; then
                echo -e "\033[1;33m  ⟳  Re-added\033[0m"
            else
                echo -e "\033[1;31m  ✘  Missing (re-add failed)\033[0m"
                ALL_OK=false
            fi
            sleep 0.15
        done

        echo ""
        echo -e "\033[1;34m  ────────────────────────────────────────────────────────\033[0m"

        # Report verification result back to the parent script.
        if [ "$ALL_OK" = true ]; then
            echo "ok" > "$ROUTE_STATUS_FILE"
            echo -e "\033[1;32m  ✔  All routes verified present. Closing in 3 seconds...\033[0m"
            sleep 3
        else
            echo "fail" > "$ROUTE_STATUS_FILE"
            echo -e "\033[1;33m  ⚠  Some routes could not be verified. Press Enter to close.\033[0m"
            read -r
        fi
    '

# ─────────────────────────────────────────────
# STEP 8: Final notification — reflect the route-verification result,
#         and clear secrets first
# ─────────────────────────────────────────────
unset SUDO_PASS CORPORATE_ROUTES_STR VPN_DEV

ROUTE_STATUS=$(cat "$ROUTE_STATUS_FILE" 2>/dev/null)

if [ "$ROUTE_STATUS" = "ok" ]; then
    dlg_info "VPN Connected" $'Connected successfully!\n\nCorporate routing tables have been applied and verified.'
else
    dlg_error $'Connected, but some corporate routes could not be verified or re-added.\n\nCheck the route terminal output and your VPN connection.'
    exit 1
fi

exit 0
