# GNOME GlobalProtect graphical login (`vpn-connect.sh`)

A GNOME-integrated wrapper around Palo Alto Networks GlobalProtect that provides a graphical
login/authentication flow and optional automatic corporate route injection, intended to be
launched from a GNOME menu entry, panel button, or autostart item rather than a raw
terminal.

## Usage

```bash
# One-time: make the script executable
chmod +x vpn-connect.sh

# Run it (from a menu entry, panel launcher, or a terminal)
./vpn-connect.sh
```

The script is fully graphical once launched — it opens `zenity` dialogs for prompts and a styled
`xterm` for the interactive GlobalProtect authentication (password + MFA). It needs a running X /
GNOME session; it will not work over a plain SSH session without an X display. To wire it to a
desktop launcher, point a `.desktop` file's `Exec=` at the absolute path of the script.

Install the runtime dependencies first (Debian/Ubuntu example):

```bash
sudo apt install zenity xterm iproute2
```

The GlobalProtect client (`globalprotect`, 6.2.x or higher) is a separate vendor package from Palo
Alto Networks and must already be installed and configured.

## What it does

1. **Environment setup**
   - Sets `LIBGL_ALWAYS_SOFTWARE=1` and `EGL_LOG_LEVEL=fatal` to silence VMware/libEGL
     software-rendering warnings.
   - Forces `TERM=xterm-256color` for the hardcoded `xterm` calls.

2. **Dependency check** — verifies `globalprotect`, `ip`, `grep`, `zenity`, `xterm`, and `sudo`
   are all on `PATH` before doing anything else; shows a `zenity` error dialog and exits if any
   are missing.

3. **Username prompt** — `USERNAME` is hardcoded (`scottmi`) in this copy of the script; the
   `zenity --entry` prompt only fires if `USERNAME` is empty.

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
   - Prompts once for the sudo password via `zenity --password`, validates it immediately with
     `sudo -S true`, and aborts if it's wrong or cancelled.
   - Opens a second styled `xterm` window that loops over `CORPORATE_ROUTES`
     (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `10.0.2.47/32`, `10.0.2.12/32`) and runs
     `sudo -S ip route replace <route> dev gpd0` for each, piping in the previously-captured
     password so the user isn't prompted again.
   - Reports per-route success/failure in the terminal.

7. **Cleanup** — unsets `SUDO_PASS`, `CORPORATE_ROUTES_STR`, and `VPN_DEV` from the environment
   before showing the final `zenity` success dialog.

## Required programs / packages

| Command | Typical package | Purpose |
|---|---|---|
| `globalprotect` | GlobalProtect Linux client **6.2.x or higher** (vendor package from Palo Alto Networks) | Establishes the VPN tunnel |
| `zenity` | `zenity` (GNOME) | All graphical prompts/dialogs (input, password, error, message boxes) |
| `xterm` | `xterm` | Hosts the interactive auth and route-injection sessions |
| `ip` | `iproute2` | Reads interface addresses and checks/sets routes |
| `grep` | `grep` (coreutils/base install) | Used to check `ip link show` output for `UP` state |
| `sudo` | `sudo` | Required to run `ip route replace` with elevated privileges |
| `bash` | `bash` | Script interpreter and the `-c` subshells run inside each `xterm` |

The script also assumes a GNOME desktop session and a working `sudo` configuration for the
invoking user.

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

- The sudo password is captured once via `zenity --password`, held in memory in `SUDO_PASS`,
  piped to `sudo -S` for each route command, and explicitly `unset` before the script exits.
- The GlobalProtect exit-code temp file is created with `mktemp` and `chmod 600`, and removed via
  an `EXIT` trap regardless of how the script terminates.
