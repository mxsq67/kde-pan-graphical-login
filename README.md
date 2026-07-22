# GlobalProtect graphical login (`vpn-connect.sh`)

A desktop-integrated wrapper around Palo Alto Networks GlobalProtect that provides a graphical
login/authentication flow and optional automatic corporate route injection, intended to be
launched from a GNOME or KDE menu entry, panel button, or autostart item rather than a raw
terminal. It detects the running desktop session and uses that desktop's native dialog toolkit
(see [Desktop environment detection](#desktop-environment-detection)).

## Usage

The scripts are installed in and run from `/home/scottmi/VPN/`. The two `.desktop`
launchers' `Exec=` lines already point there.

```bash
# Install the scripts into /home/scottmi/VPN/
mkdir -p /home/scottmi/VPN
cp vpn-connect.sh vpn-disconnect.sh /home/scottmi/VPN/
chmod +x /home/scottmi/VPN/vpn-connect.sh /home/scottmi/VPN/vpn-disconnect.sh

# Install the launcher buttons (Connect / Disconnect)
cp vpn-connect.desktop vpn-disconnect.desktop ~/.local/share/applications/
update-desktop-database ~/.local/share/applications/   # optional

# Or run a script directly
/home/scottmi/VPN/vpn-connect.sh
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
   - Opens a second styled `xterm` window that loops over `CORPORATE_ROUTES`
     (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `10.0.2.47/32`, `10.0.2.12/32`) and runs
     `sudo -S ip route replace <route> dev gpd0` for each, piping in the previously-captured
     password so the user isn't prompted again.
   - Reports per-route success/failure in the terminal.

7. **Cleanup** — unsets `SUDO_PASS`, `CORPORATE_ROUTES_STR`, and `VPN_DEV` from the environment
   before showing the final success dialog.

## Required programs / packages

| Command | Typical package | Purpose |
|---|---|---|
| `globalprotect` | GlobalProtect Linux client **6.2.x or higher** (vendor package from Palo Alto Networks) | Establishes the VPN tunnel |
| `zenity` **or** `kdialog` | `zenity` (GNOME) / `kdialog` (KDE) | All graphical prompts/dialogs; the one required depends on the detected desktop (see above) |
| `xterm` | `xterm` | Hosts the interactive auth and route-injection sessions |
| `ip` | `iproute2` | Reads interface addresses and checks/sets routes |
| `grep` | `grep` (coreutils/base install) | Used to check `ip link show` output for `UP` state |
| `sudo` | `sudo` | Required to run `ip route replace` with elevated privileges |
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
