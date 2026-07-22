# GlobalProtect graphical login (`vpn-connect.sh`)

A desktop-integrated wrapper around Palo Alto Networks GlobalProtect that provides a graphical
login/authentication flow and optional automatic corporate route injection (with verification and
re-add), intended to be launched from a GNOME or KDE menu entry, panel button, or autostart item
rather than a raw terminal. It detects the running desktop session and uses that desktop's native
dialog toolkit (see [Desktop environment detection](#desktop-environment-detection)), keeps
NetworkManager from flushing its routes, and ships a companion `vpn-disconnect.sh` that cleans up
routes and cache files on disconnect.

## Usage

The scripts are installed in and run from `/home/scottmi/VPN/`. The two `.desktop`
launchers' `Exec=` lines already point there.

```bash
# Install the scripts into /home/scottmi/VPN/
mkdir -p /home/scottmi/VPN
cp vpn-connect.sh vpn-disconnect.sh vpn-menu.sh /home/scottmi/VPN/
chmod +x /home/scottmi/VPN/vpn-connect.sh /home/scottmi/VPN/vpn-disconnect.sh /home/scottmi/VPN/vpn-menu.sh

# Install the launcher(s). Either the single combined chooser...
cp vpn.desktop ~/.local/share/applications/
# ...or the two separate Connect / Disconnect buttons (or all three):
cp vpn-connect.desktop vpn-disconnect.desktop ~/.local/share/applications/
update-desktop-database ~/.local/share/applications/   # optional

# Or run a script directly
/home/scottmi/VPN/vpn-menu.sh        # combined chooser
/home/scottmi/VPN/vpn-connect.sh     # connect only
```

The scripts are fully graphical once launched — they open dialogs for prompts (via `zenity` on
GNOME or `kdialog` on KDE) and `vpn-connect.sh` opens a styled `xterm` for the interactive
GlobalProtect authentication (password + MFA). They need a running X / desktop session; they will
not work over a plain SSH session without an X display.

Install the runtime dependencies first (Debian/Ubuntu example — use `zenity` for GNOME or
`kdialog` for KDE):

```bash
sudo apt install zenity xterm iproute2      # GNOME
# sudo apt install kdialog xterm iproute2   # KDE
```

The GlobalProtect client (`globalprotect`, 6.2.x or higher) is a separate vendor package from Palo
Alto Networks and must already be installed and configured.

## Launchers

Three `.desktop` launchers are provided — install whichever you prefer:

| Launcher | Runs | Purpose |
|---|---|---|
| `vpn.desktop` | `vpn-menu.sh` | **Combined chooser** — one icon that opens a single pane with Connect / Disconnect buttons and a live status LED |
| `vpn-connect.desktop` | `vpn-connect.sh` | Connect only |
| `vpn-disconnect.desktop` | `vpn-disconnect.sh` | Disconnect only |

### Combined chooser (`vpn-menu.sh`)

`vpn-menu.sh` presents a single dialog with **Connect**, **Disconnect**, and **Cancel** buttons
(`zenity --question` with an extra button on GNOME; `kdialog --yesnocancel` on KDE) and then
launches the matching script from its own directory. It resolves that directory with
`readlink -f "$0"`, so it works regardless of the launcher's working directory as long as
`vpn-connect.sh` / `vpn-disconnect.sh` sit alongside it. If the chosen target is missing or not
executable, the chooser shows a graphical error dialog (rather than failing silently to stderr
under the `Terminal=false` launcher) and exits.

At the top of the pane it shows a **status LED** based on the `gpd0` interface state:

- 🟢 green ● **VPN connected** — `gpd0` link flags include `UP`.
- 🔴 red ● **VPN disconnected** — otherwise.

The LED is rendered with each toolkit's rich text (Pango markup for `zenity`, Qt rich text for
`kdialog`). It is a **snapshot taken when the pane opens** and does not live-update — reopen the
launcher to refresh the status.

## Desktop environment detection

At startup each script determines which desktop session it is running under and locks itself to
that desktop's native dialog toolkit — it does **not** fall back to the other toolkit:

- **GNOME** → uses `zenity` exclusively.
- **KDE / Plasma** → uses `kdialog` exclusively.
- **Any other environment** → prints an "unsupported desktop environment" error and exits without
  attempting anything.

How it works:

1. The environment is read from `$XDG_CURRENT_DESKTOP`, falling back to `$DESKTOP_SESSION` if the
   former is unset. Matching is case-insensitive (via `shopt -s nocasematch`) and substring-based,
   so values like `ubuntu:GNOME` or `plasma` are recognized correctly.
2. A `case` statement maps the value to `zenity` (`*gnome*`) or `kdialog` (`*kde*` / `*plasma*`),
   or exits on anything else.
3. The selected toolkit must actually be installed; if it is missing, the script exits with an
   error naming the required command rather than silently degrading.

All graphical prompts route through internal `dlg_*` wrapper functions (`dlg_error`, `dlg_info`,
`dlg_notify`, `dlg_input`, `dlg_password`; `vpn-disconnect.sh` also has `dlg_question`) that
dispatch to the correct toolkit based on the detected environment — there are no raw
`zenity`/`kdialog` calls elsewhere in the scripts.

> **Note:** detection depends on `$XDG_CURRENT_DESKTOP` / `$DESKTOP_SESSION` being present in the
> environment. A normal GNOME or KDE graphical session (including launches from the `.desktop`
> files) sets these. Running a script from a stripped shell — bare `cron`, some `sudo`
> configurations, or an SSH session without those variables exported — will hit the "unsupported
> desktop environment" path by design.

## What it does

1. **Environment setup**
   - Sets `LIBGL_ALWAYS_SOFTWARE=1` and `EGL_LOG_LEVEL=fatal` to silence VMware/libEGL
     software-rendering warnings.
   - Forces `TERM=xterm-256color` for the hardcoded `xterm` calls.
   - Detects the desktop session (GNOME → `zenity`, KDE → `kdialog`) and binds all dialogs to
     that toolkit — see [Desktop environment detection](#desktop-environment-detection).

2. **Dependency check** — verifies `globalprotect`, `ip`, `grep`, `xterm`, and `sudo` are all on
   `PATH` before doing anything else (the dialog toolkit is validated separately by the
   environment detection above); shows an error dialog and exits if any are missing.

3. **Username prompt** — `USERNAME` is hardcoded (`scottmi`) in this copy of the script; the
   input-box prompt (`zenity --entry` / `kdialog --inputbox`) only fires if `USERNAME` is empty.

4. **Interactive GlobalProtect authentication** — opens a styled `xterm` window and runs
   `globalprotect connect --portal gp.bgss.boeing.com --username <user>` inside it so the user
   can type their password and complete MFA interactively. The subshell writes GlobalProtect's
   exit code to a `mktemp`'d temp file (mode `600`) so the parent script can read it back; the
   temp file is removed via an `EXIT` trap.

5. **Exit-code handling with fallback** — because GlobalProtect's Linux exit codes are
   unreliable, if the reported exit code is non-zero the script waits 2 seconds and checks
   whether the `gpd0` VPN interface came up anyway (`ip link show gpd0 | grep UP`) before
   declaring failure.

6. **Conditional route injection** — checks each interface in `LOCAL_INTERFACES`
   (`enp2s0`, `ens160`) for an IPv4 address starting with `TARGET_PREFIX` (`10.0.2.`). If none
   matches, it reports success and exits without touching routes. If a match is found, it:
   - Prompts once for the sudo password via the password dialog (`zenity --password` /
     `kdialog --password`), validates it immediately with
     `sudo -S true`, and aborts if it's wrong or cancelled.
   - Opens a second styled `xterm` window that first keeps NetworkManager out of the way (see
     [NetworkManager](#networkmanager)), then loops over `CORPORATE_ROUTES`
     (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `10.0.2.47/32`, `10.0.2.12/32`) and runs
     `sudo -S ip route replace <route> dev gpd0` for each, piping in the previously-captured
     password so the user isn't prompted again.
   - Reports per-route success/failure in the terminal.

7. **Route verification with re-add** — after the initial apply, the same `xterm` re-checks every
   route with `ip route show <route> dev gpd0`. Any route that is missing is re-added with up to
   three `ip route replace` attempts (marked `⟳ Re-added`); a route that still can't be installed
   is flagged `✘ Missing`. The verification result is passed back to the parent script through a
   `mktemp`'d status file so the final dialog reflects it — a success dialog only if **all** routes
   verified present, otherwise an error dialog and non-zero exit.

8. **Cleanup** — unsets `SUDO_PASS`, `CORPORATE_ROUTES_STR`, and `VPN_DEV` from the environment,
   and removes the IPC temp files via an `EXIT` trap, before showing the final dialog.

## NetworkManager

If NetworkManager is present and running, it can reclaim the VPN interface and flush the routes the
script adds. Before injecting routes, `vpn-connect.sh` therefore marks the VPN device unmanaged:

```bash
sudo nmcli device set gpd0 managed no
```

This is **best-effort and narrowly scoped**:

- It runs only when `nmcli` exists **and** `nmcli -t -f RUNNING general` reports `running`; on
  systems without NetworkManager it is silently skipped (no hard dependency).
- Only the `gpd0` VPN device is touched — Ethernet/Wi-Fi interfaces stay fully NM-managed.
- The change is runtime-only (not persistent across reboots or NM restarts); `gpd0` is recreated
  and re-marked unmanaged on each connect. No revert is needed on disconnect because the device
  disappears when the tunnel drops.

Even with the device unmanaged, the route-verification pass above still re-adds anything a race
during tunnel bring-up manages to drop.

## Disconnecting (`vpn-disconnect.sh`)

`vpn-disconnect.sh` (wired to the **Disconnect** launcher) tears the session down and leaves the
environment clean so the next connect starts fresh:

1. **Confirm** — asks for confirmation via the question dialog (`zenity --question` /
   `kdialog --yesno`); cancelling exits without changes.
2. **Disconnect** — runs `globalprotect disconnect`.
3. **Route cleanup** — scans `CORPORATE_ROUTES` for any still installed on `gpd0`. Normally the
   kernel already removed them with the interface, so nothing lingers and **no sudo prompt
   appears**. Only if routes remain does it prompt once for sudo and `ip route del` each one,
   verifying removal — so no stale/cached routes carry into the next connect.
4. **Cache-file cleanup** — removes leftover `vpn-connect.sh` IPC files
   (`/tmp/vpn_gp_exit.*`, `/tmp/vpn_route_status.*`) in case a crash left them behind. During
   normal runs these are already gone (removed by the connect script's `EXIT` trap).
5. **Report** — shows a final dialog summarizing the disconnect and any cleanup performed.

Keep the `CORPORATE_ROUTES` / `VPN_DEV` values in `vpn-disconnect.sh` in sync with `vpn-connect.sh`;
they are defined in both scripts.

## Required programs / packages

| Command | Typical package | Purpose |
|---|---|---|
| `globalprotect` | GlobalProtect Linux client **6.2.x or higher** (vendor package from Palo Alto Networks) | Establishes the VPN tunnel |
| `zenity` **or** `kdialog` | `zenity` (GNOME) / `kdialog` (KDE) | All graphical prompts/dialogs; the one required depends on the detected desktop (see above) |
| `xterm` | `xterm` | Hosts the interactive auth and route-injection sessions |
| `ip` | `iproute2` | Reads interface addresses and checks/sets routes |
| `grep` | `grep` (coreutils/base install) | Used to check `ip link show` output for `UP` state |
| `sudo` | `sudo` | Required to run `ip route replace` with elevated privileges |
| `nmcli` *(optional)* | `network-manager` | If present and running, used to mark the VPN device unmanaged so NetworkManager doesn't flush routes; skipped if absent |
| `bash` | `bash` | Script interpreter and the `-c` subshells run inside each `xterm` |

The scripts also assume a GNOME or KDE desktop session (with `$XDG_CURRENT_DESKTOP` /
`$DESKTOP_SESSION` set) and a working `sudo` configuration for the invoking user.

## Configuration

Edit the variables at the top of the script for your environment:

- `PORTAL` — GlobalProtect portal FQDN.
- `USERNAME` — hardcode a username, or leave blank (`""`) to be prompted each run.
- `VPN_DEV` — name of the network device GlobalProtect creates (commonly `gpd0` for Linux
  GlobalProtect clients).
- `LOCAL_INTERFACES` — physical/virtual interfaces to inspect when deciding whether corporate
  routes should be injected.
- `TARGET_PREFIX` — IPv4 prefix that triggers route injection when found on a local interface.
- `CORPORATE_ROUTES` — CIDR routes to point at `VPN_DEV` once the VPN is up.

## Security notes

- The sudo password is captured once via the password dialog (`zenity --password` /
  `kdialog --password`), held in memory in `SUDO_PASS`,
  piped to `sudo -S` for each route command, and explicitly `unset` before the script exits.
- The GlobalProtect exit-code temp file is created with `mktemp` and `chmod 600`, and removed via
  an `EXIT` trap regardless of how the script terminates.
