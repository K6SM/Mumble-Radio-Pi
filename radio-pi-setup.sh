#!/usr/bin/env bash
#
# radio-pi-setup.sh --- set up a Raspberry Pi as the radio-end computer of a
# remote amateur radio station.
#
# It installs and configures, so that all three come up at boot:
#
#   * Hamlib's rigctld, driving the transceiver you select from the list of
#     radios your Hamlib build supports;
#   * a Mumble server, tuned for a radio link rather than for a chat room;
#   * a headless Mumble client at the radio, feeding receiver audio into the
#     link and the link's audio into the transmitter.
#
# It also leaves the Pi reachable over SSH, usable on a directly attached
# screen and keyboard for Emacs in the terminal, in console mode with no
# desktop, and tuned to keep latency low while otherwise drawing as little
# power as it can.
#
# Written for the K6SM remote station: ham.el / ham-remote.el and the Emacs
# QSO Logger at the operator's end, this Pi at the radio's end.
#
# Run it as root, on a console or over SSH, from a file -- not piped from
# curl, because it asks questions:
#
#     sudo bash radio-pi-setup.sh
#
# It is safe to run again: everything it does is written to be repeatable, so
# re-running after a software upgrade re-applies the configuration without
# installing second copies of anything or resetting a password you changed.
#
#     sudo bash radio-pi-setup.sh --unattended     # re-run with saved answers
#
# License: same terms as the K6SM ham.el package.

set -euo pipefail

VERSION="1.0"
CONF_DIR="/etc/ham-radio-pi"
CONF_FILE="$CONF_DIR/setup.conf"
BACKUP_DIR="$CONF_DIR/backups"
STAMP="$(date +%Y%m%d-%H%M%S)"

# The password this script gives a login account it creates itself. It is
# documented in the README, which means everyone knows it; the summary at the
# end says so too. Change it on first login with passwd.
DEFAULT_PASSWORD="ChangeMe73"

UNATTENDED=0
RESET_PASSWORD=0
SKIP_APT=0

CHANGES=()

# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_HEAD=$'\033[1;36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'
    C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
    C_HEAD=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_OFF=""
fi

head_()  { printf '\n%s== %s ==%s\n' "$C_HEAD" "$*" "$C_OFF"; }
say()    { printf '   %s\n' "$*"; }
ok()     { printf '   %s+%s %s\n' "$C_OK" "$C_OFF" "$*"; }
note()   { printf '   %s. %s%s\n' "$C_DIM" "$*" "$C_OFF"; }
warn()   { printf '   %s! %s%s\n' "$C_WARN" "$*" "$C_OFF" >&2; }
die()    { printf '\n%sError:%s %s\n\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }
changed(){ CHANGES+=("$1"); ok "$1"; }

# --------------------------------------------------------------------------
# Asking
# --------------------------------------------------------------------------

# Questions are read from the terminal rather than from standard input, so
# that the script still works when it is started from somewhere odd.
TTY_IN="/dev/tty"

ask() { # ask <prompt> <default> -> answer on stdout
    local prompt=$1 default=$2 reply=""
    if [ "$UNATTENDED" = 1 ]; then printf '%s' "$default"; return 0; fi
    if [ -n "$default" ]; then
        printf '   %s [%s]: ' "$prompt" "$default" > "$TTY_IN"
    else
        printf '   %s: ' "$prompt" > "$TTY_IN"
    fi
    IFS= read -r reply < "$TTY_IN" || reply=""
    printf '%s' "${reply:-$default}"
}

ask_yn() { # ask_yn <prompt> <yes|no default> -> returns 0 for yes
    local prompt=$1 default=$2 reply hint
    [ "$default" = yes ] && hint="Y/n" || hint="y/N"
    if [ "$UNATTENDED" = 1 ]; then
        if [ "$default" = yes ]; then return 0; else return 1; fi
    fi
    while :; do
        printf '   %s (%s): ' "$prompt" "$hint" > "$TTY_IN"
        IFS= read -r reply < "$TTY_IN" || reply=""
        reply=${reply:-$default}
        case "${reply,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *)     printf '   Please answer y or n.\n' > "$TTY_IN" ;;
        esac
    done
}

# --------------------------------------------------------------------------
# Files
# --------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

backup_once() { # keep the first version of anything we overwrite
    local path=$1 dest="$BACKUP_DIR/$(echo "${path#/}" | tr '/' '_')"
    [ -f "$path" ] || return 0
    mkdir -p "$BACKUP_DIR"
    [ -f "$dest.original" ] || cp -a "$path" "$dest.original"
    cp -a "$path" "$dest.$STAMP"
}

# install_file <path> [mode] [owner:group]   -- content on stdin.
# Writes only when the content differs, so a re-run touches nothing it does
# not have to, which matters on an SD card.
install_file() {
    local path=$1 mode=${2:-0644} owner=${3:-root:root} tmp
    tmp=$(mktemp)
    cat > "$tmp"
    mkdir -p "$(dirname "$path")"
    if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"; note "unchanged  $path"; return 0
    fi
    backup_once "$path"
    install -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$path"
    rm -f "$tmp"
    changed "wrote      $path"
}

# Replace the block this script owns inside a file it shares with the system,
# such as config.txt. Everything outside the markers is left alone.
managed_block() { # managed_block <file> <comment-prefix>  -- body on stdin
    local file=$1 pfx=$2 body tmp
    body=$(cat)
    tmp=$(mktemp)
    if [ -f "$file" ]; then
        sed "/^${pfx} ham-radio-pi BEGIN\$/,/^${pfx} ham-radio-pi END\$/d" \
            "$file" > "$tmp"
    fi
    # Drop any trailing blank lines, then append our block.
    printf '%s\n' "$(cat "$tmp")" > "$tmp.trim"
    {
        cat "$tmp.trim"
        printf '%s ham-radio-pi BEGIN\n' "$pfx"
        printf '%s\n' "$body"
        printf '%s ham-radio-pi END\n' "$pfx"
    } > "$tmp.new"
    rm -f "$tmp" "$tmp.trim"
    install_file "$file" 0644 root:root < "$tmp.new"
    rm -f "$tmp.new"
}

# Set key=value in an ini file, removing any earlier or commented-out copy so
# that running twice cannot leave two of them.
ini_set() { # ini_set <file> <key> <value>
    local file=$1 key=$2 value=$3
    touch "$file"
    sed -i -E "/^[[:space:]]*[#;]?[[:space:]]*${key}[[:space:]]*=/d" "$file"
    printf '%s=%s\n' "$key" "$value" >> "$file"
}

# Set or replace one key=value token on the Pi's single-line kernel cmdline.
cmdline_set() { # cmdline_set <file> <key> <value>
    local file=$1 key=$2 value=$3 line
    [ -f "$file" ] || return 0
    line=$(tr -s ' ' ' ' < "$file" | tr -d '\n')
    line=$(printf '%s' "$line" | sed -E "s/(^| )${key}=[^ ]*/\1/g")
    line=$(printf '%s %s=%s' "$line" "$key" "$value" | sed -E 's/^ +//; s/ +/ /g')
    printf '%s\n' "$line" | install_file "$file" 0755 root:root
}

# --------------------------------------------------------------------------
# Arguments
# --------------------------------------------------------------------------

usage() {
    cat <<USAGE
radio-pi-setup.sh $VERSION -- radio-end Raspberry Pi for remote operating

  sudo bash radio-pi-setup.sh [options]

  --unattended        Do not ask anything; use the answers saved in
                      $CONF_FILE.
                      Intended for re-running after a software upgrade.
  --reset-password    Set the login account's password back to the
                      documented default. Off by default so that a re-run
                      never undoes a password you changed.
  --skip-apt          Do not install or update packages; only rewrite the
                      configuration and restart the services.
  -h, --help          This text.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --unattended)     UNATTENDED=1 ;;
        --reset-password) RESET_PASSWORD=1 ;;
        --skip-apt)       SKIP_APT=1 ;;
        -h|--help)        usage; exit 0 ;;
        *)                usage; die "Unknown option: $1" ;;
    esac
    shift
done

# --------------------------------------------------------------------------
# Preflight
# --------------------------------------------------------------------------

head_ "Checking the machine"

[ "$(id -u)" = 0 ] || die "Run this with sudo: sudo bash $0"
have apt-get || die "This script is for Debian and Raspberry Pi OS (no apt-get here)."

if [ "$UNATTENDED" = 0 ] && [ ! -r "$TTY_IN" ]; then
    die "No terminal to ask questions on. Save the script to a file and run it
       from a console or an SSH session, or use --unattended."
fi

IS_PI=0
if [ -r /proc/device-tree/model ] && tr -d '\0' < /proc/device-tree/model | grep -qi raspberry; then
    IS_PI=1
    PI_MODEL="$(tr -d '\0' < /proc/device-tree/model)"
    ok "$PI_MODEL"
else
    warn "This does not look like a Raspberry Pi. Everything except the"
    warn "Pi-specific firmware tuning will still be applied."
fi

# Raspberry Pi OS moved the firmware configuration in Bookworm.
if [ -d /boot/firmware ]; then BOOT=/boot/firmware; else BOOT=/boot; fi

FREE_MB=$(df -Pm / | awk 'NR==2 {print $4}')
[ "${FREE_MB:-0}" -ge 1200 ] || warn "Only ${FREE_MB}MB free on /. Mumble and its Qt libraries want about 1GB."

mkdir -p "$CONF_DIR" "$BACKUP_DIR"
chmod 0750 "$CONF_DIR"

if [ -f "$CONF_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONF_FILE"
    ok "Read previous answers from $CONF_FILE"
    FIRST_RUN=0
else
    FIRST_RUN=1
fi

if [ "$UNATTENDED" = 1 ] && [ "$FIRST_RUN" = 1 ]; then
    die "--unattended needs answers from an earlier run, and $CONF_FILE
       does not exist yet. Run the script once without it."
fi

# --------------------------------------------------------------------------
# Packages, first pass
# --------------------------------------------------------------------------
#
# Hamlib and the ALSA tools go on first so that the questions below can offer
# the real list of radios this Hamlib supports and the real list of sound
# devices this Pi has.

apt_install() {
    if [ "$SKIP_APT" = 1 ]; then note "skipping apt (--skip-apt): $*"; return 0; fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

if [ "$SKIP_APT" = 0 ]; then
    head_ "Installing Hamlib"
    DEBIAN_FRONTEND=noninteractive apt-get update
    apt_install libhamlib-utils alsa-utils openssl ca-certificates
    ok "Hamlib $(rigctld --version 2>/dev/null | head -1 | awk '{print $NF}')"
fi

have rigctl || die "rigctl is not installed; cannot offer the list of radios."

# --------------------------------------------------------------------------
# The interview
# --------------------------------------------------------------------------

head_ "The station"

if [ "$UNATTENDED" = 0 ]; then
    cat <<'INTRO'
   A few questions. Enter accepts the value in brackets.

   The defaults match the K6SM ham-remote configuration, whose operator end
   looks for the radio end at radio.local.

INTRO
fi

PI_HOSTNAME=$(ask "Hostname for this Pi" "${PI_HOSTNAME:-radio}")
OP_USER=$(ask "Login account for the operator" "${OP_USER:-radio}")

# --- the radio ------------------------------------------------------------

head_ "The radio"

RIGLIST=$(mktemp); trap 'rm -f "$RIGLIST"' EXIT
rigctl -l > "$RIGLIST" 2>/dev/null || die "rigctl -l failed."
RIGCOUNT=$(grep -cE '^[[:space:]]*[0-9]+' "$RIGLIST" || true)
say "This Hamlib supports $RIGCOUNT radios."

# One line of "rigctl -l" is: number, maker, model, version, status, macro.
# The maker and the model can both hold spaces; the last three fields cannot.
rig_name_of() {
    printf '%s' "$1" | awk '{$1=""; NF=NF-3; print}' | sed -E 's/^ +| +$//g'
}

pick_radio() {
    local search matches n i line choice
    while :; do
        search=$(ask "Search the radio list (maker or model, e.g. FTDX10, IC-7300, Elecraft)" "")
        if [ -z "$search" ]; then
            warn "Enter something to search for, or a Hamlib model number if you know it."
            continue
        fi
        # A bare number is taken as the model number itself.
        if printf '%s' "$search" | grep -qE '^[0-9]+$'; then
            if line=$(grep -E "^[[:space:]]*${search}[[:space:]]" "$RIGLIST"); then
                RIG_MODEL="$search"
                RIG_MODEL_NAME=$(rig_name_of "$line")
                return 0
            fi
            warn "No radio with model number $search."
            continue
        fi
        mapfile -t matches < <(grep -iE "^[[:space:]]*[0-9]+.*${search}" "$RIGLIST" || true)
        n=${#matches[@]}
        if [ "$n" = 0 ]; then
            warn "Nothing matched \"$search\"."
            continue
        fi
        if [ "$n" -gt 40 ]; then
            warn "$n radios matched. Narrow the search."
            continue
        fi
        printf '\n'
        for i in "${!matches[@]}"; do
            printf '   %3d) %s\n' "$((i + 1))" "$(printf '%s' "${matches[$i]}" | sed -E 's/^ +//')"
        done
        printf '\n'
        choice=$(ask "Number from this list, or Enter to search again" "")
        if [ -z "$choice" ]; then continue; fi
        if ! printf '%s' "$choice" | grep -qE '^[0-9]+$' || \
           [ "$choice" -lt 1 ] || [ "$choice" -gt "$n" ]; then
            warn "Not one of the numbers above."
            continue
        fi
        line=${matches[$((choice - 1))]}
        RIG_MODEL=$(printf '%s' "$line" | awk '{print $1}')
        RIG_MODEL_NAME=$(rig_name_of "$line")
        return 0
    done
}

if [ "$UNATTENDED" = 1 ]; then
    : "${RIG_MODEL:?no saved radio model}"
else
    if [ -n "${RIG_MODEL:-}" ]; then
        say "Currently configured: ${RIG_MODEL_NAME:-model $RIG_MODEL} (model $RIG_MODEL)"
        ask_yn "Keep this radio?" yes || pick_radio
    else
        say "Hamlib's dummy radio is model 1, if you want to test without one."
        pick_radio
    fi
fi
ok "Radio: ${RIG_MODEL_NAME:-model $RIG_MODEL}  (Hamlib model $RIG_MODEL)"

# --- how the radio is attached -------------------------------------------

pick_serial() {
    local devs=() d i choice
    # by-id names survive a reboot and a different USB port; prefer them.
    while IFS= read -r d; do devs+=("$d"); done < <(
        { ls -1 /dev/serial/by-id/* 2>/dev/null || true
          ls -1 /dev/ttyUSB* /dev/ttyACM* 2>/dev/null || true; } | sort -u)
    if [ "${#devs[@]}" -gt 0 ]; then
        printf '\n   Serial ports found now:\n'
        for i in "${!devs[@]}"; do
            printf '   %3d) %s\n' "$((i + 1))" "${devs[$i]}"
        done
        printf '   %3d) type a path myself\n\n' "$(( ${#devs[@]} + 1 ))"
        note "The /dev/serial/by-id/... names are the ones to pick: they name the"
        note "adapter itself, so they do not move when something else is plugged in."
        choice=$(ask "Which port is the radio on" "1")
        if printf '%s' "$choice" | grep -qE '^[0-9]+$' && \
           [ "$choice" -ge 1 ] && [ "$choice" -le "${#devs[@]}" ]; then
            RIG_DEVICE="${devs[$((choice - 1))]}"
            return 0
        fi
    else
        warn "No USB serial port is plugged in at the moment."
    fi
    RIG_DEVICE=$(ask "Path to the radio's serial port" "${RIG_DEVICE:-/dev/ttyUSB0}")
}

if [ "$UNATTENDED" = 0 ]; then
    if [ -n "${RIG_DEVICE:-}" ] && ask_yn "Keep serial port ${RIG_DEVICE}?" yes; then
        :
    else
        pick_serial
    fi
fi
RIG_DEVICE="${RIG_DEVICE:-/dev/ttyUSB0}"

RIG_SPEED=$(ask "Serial speed (blank lets Hamlib use the radio's own default)" "${RIG_SPEED:-}")
RIG_CIVADDR=$(ask "Icom CI-V address, hex, blank for none" "${RIG_CIVADDR:-}")
RIG_PTT_TYPE=$(ask "PTT type: RIG, DTR, RTS, NONE, or blank for the backend default" "${RIG_PTT_TYPE:-}")
RIGCTLD_PORT=$(ask "Port for rigctld" "${RIGCTLD_PORT:-4532}")

if [ "$UNATTENDED" = 0 ]; then
    cat <<'BINDNOTE'

   rigctld has no password and no encryption of any kind. Anyone who can
   reach its port can key your transmitter.

     localhost  reachable only from this Pi. The operator's Emacs reaches it
                through an SSH tunnel or a VPN. This is the safe answer.
     lan        reachable from anywhere that can route to this Pi.

BINDNOTE
fi
RIGCTLD_SCOPE=$(ask "rigctld reachable from [localhost/lan]" "${RIGCTLD_SCOPE:-localhost}")
case "${RIGCTLD_SCOPE,,}" in
    lan|all|any) RIGCTLD_SCOPE=lan;  RIGCTLD_BIND="0.0.0.0" ;;
    *)           RIGCTLD_SCOPE=localhost; RIGCTLD_BIND="127.0.0.1" ;;
esac

# --- audio ----------------------------------------------------------------

head_ "Audio"

if [ "$UNATTENDED" = 0 ]; then
    cat <<'AUDIONOTE'
   The capture device is what the receiver's audio goes into, and the
   playback device is what feeds the transmitter's audio input. On most
   modern transceivers both are the same USB sound device in the radio.

AUDIONOTE
fi

pick_alsa() { # pick_alsa <arecord|aplay> <prompt> <current> -> device on stdout
    local tool=$1 prompt=$2 current=$3 devs=() names=() line i choice
    while IFS='|' read -r idx id name dev; do
        [ -n "$idx" ] || continue
        devs+=("plughw:CARD=${id},DEV=${dev}")
        names+=("$name (card $idx, device $dev)")
    done < <("$tool" -l 2>/dev/null |
        sed -n 's/^card \([0-9]*\): \([^ ]*\) \[\([^]]*\)\], device \([0-9]*\):.*/\1|\2|\3|\4/p')

    if [ "${#devs[@]}" = 0 ]; then
        warn "$tool found no sound cards. Using \"default\"."
        printf 'default'; return 0
    fi
    printf '\n' > "$TTY_IN"
    for i in "${!devs[@]}"; do
        printf '   %3d) %-40s %s\n' "$((i + 1))" "${names[$i]}" "${devs[$i]}" > "$TTY_IN"
    done
    printf '   %3d) %s\n\n' "$(( ${#devs[@]} + 1 ))" "type an ALSA device myself" > "$TTY_IN"
    choice=$(ask "$prompt" "1")
    if printf '%s' "$choice" | grep -qE '^[0-9]+$' && \
       [ "$choice" -ge 1 ] && [ "$choice" -le "${#devs[@]}" ]; then
        printf '%s' "${devs[$((choice - 1))]}"
    else
        ask "ALSA device name" "${current:-default}"
    fi
}

if [ "$UNATTENDED" = 0 ]; then
    if [ -n "${AUDIO_CAPTURE:-}" ] && \
       ask_yn "Keep audio devices (in: ${AUDIO_CAPTURE}, out: ${AUDIO_PLAYBACK})?" yes; then
        :
    else
        AUDIO_CAPTURE=$(pick_alsa arecord "Receiver audio comes in on which device" "${AUDIO_CAPTURE:-}")
        AUDIO_PLAYBACK=$(pick_alsa aplay "Transmitter audio goes out on which device" "${AUDIO_PLAYBACK:-}")
    fi
fi
AUDIO_CAPTURE="${AUDIO_CAPTURE:-default}"
AUDIO_PLAYBACK="${AUDIO_PLAYBACK:-default}"

# --- Mumble ---------------------------------------------------------------

head_ "Mumble"

MUMBLE_PORT=$(ask "Mumble server port" "${MUMBLE_PORT:-64738}")
MUMBLE_USERS=$(ask "How many clients the server admits at once" "${MUMBLE_USERS:-4}")
MUMBLE_BANDWIDTH=$(ask "Bandwidth ceiling per client, bits/s" "${MUMBLE_BANDWIDTH:-72000}")
MUMBLE_RADIO_USER=$(ask "Name the radio end joins under" "${MUMBLE_RADIO_USER:-radio}")
if [ "$UNATTENDED" = 0 ]; then
    note "Leave the server password blank on a home LAN or behind a VPN. Set one"
    note "if port $MUMBLE_PORT is forwarded from the internet."
fi
MUMBLE_SERVER_PASSWORD=$(ask "Server password, blank for none" "${MUMBLE_SERVER_PASSWORD:-}")

if [ "$UNATTENDED" = 0 ]; then
    note "The Mumble client has a graphical interface and no headless mode, so it"
    note "runs against a virtual display. Xvfb is the reliable way; offscreen is"
    note "Qt's own and saves about 20MB, which can matter on a Pi Zero 2W."
fi
MUMBLE_DISPLAY=$(ask "Virtual display for the client [xvfb/offscreen]" "${MUMBLE_DISPLAY:-xvfb}")
case "${MUMBLE_DISPLAY,,}" in
    offscreen) MUMBLE_DISPLAY=offscreen ;;
    *)         MUMBLE_DISPLAY=xvfb ;;
esac

# --- the Pi itself --------------------------------------------------------

head_ "Power and latency"

if [ "$UNATTENDED" = 0 ]; then
    cat <<'POWERNOTE'
   Wi-Fi power saving parks the radio between packets. It saves real current
   on a battery and costs tens of milliseconds, unpredictably, on every
   transmission. Off is the right answer for operating; on is the right
   answer for a station that is idle most of the day.

POWERNOTE
fi
WIFI_POWERSAVE=$(ask "Wi-Fi power saving [off/on]" "${WIFI_POWERSAVE:-off}")
case "${WIFI_POWERSAVE,,}" in on|yes) WIFI_POWERSAVE=on ;; *) WIFI_POWERSAVE=off ;; esac

CPU_GOVERNOR=$(ask "CPU governor [ondemand/powersave/performance]" "${CPU_GOVERNOR:-ondemand}")
CONSOLE_BLANK=$(ask "Blank an attached screen after how many seconds, 0 for never" "${CONSOLE_BLANK:-300}")

if ask_yn "Turn off Bluetooth? Say no if your keyboard is Bluetooth." \
          "${DISABLE_BT_DEFAULT:-yes}"; then DISABLE_BT=yes; else DISABLE_BT=no; fi
if ask_yn "Turn off the Pi's activity LEDs?" "${LED_OFF_DEFAULT:-yes}"; then
    LED_OFF=yes; else LED_OFF=no; fi
if ask_yn "Log in automatically on an attached screen?" "${AUTOLOGIN_DEFAULT:-yes}"; then
    AUTOLOGIN=yes; else AUTOLOGIN=no; fi

head_ "Emacs at the radio"
if ask_yn "Install Emacs (terminal build) for use on an attached screen?" "${INSTALL_EMACS_DEFAULT:-yes}"; then
    INSTALL_EMACS=yes; else INSTALL_EMACS=no; fi
INSTALL_K6SM=no
if [ "$INSTALL_EMACS" = yes ]; then
    if ask_yn "Also fetch the K6SM ham.el and QSO logger packages from GitHub?" \
              "${INSTALL_K6SM_DEFAULT:-yes}"; then INSTALL_K6SM=yes; fi
fi

# --------------------------------------------------------------------------
# Save the answers
# --------------------------------------------------------------------------

install_file "$CONF_FILE" 0640 root:root <<CONF
# Answers given to radio-pi-setup.sh $VERSION.
# Edit this file and re-run "sudo bash radio-pi-setup.sh --unattended"
# to change the station without being asked the questions again.

PI_HOSTNAME="$PI_HOSTNAME"
OP_USER="$OP_USER"

RIG_MODEL="$RIG_MODEL"
RIG_MODEL_NAME="${RIG_MODEL_NAME:-}"
RIG_DEVICE="$RIG_DEVICE"
RIG_SPEED="$RIG_SPEED"
RIG_CIVADDR="$RIG_CIVADDR"
RIG_PTT_TYPE="$RIG_PTT_TYPE"
RIGCTLD_PORT="$RIGCTLD_PORT"
RIGCTLD_SCOPE="$RIGCTLD_SCOPE"

AUDIO_CAPTURE="$AUDIO_CAPTURE"
AUDIO_PLAYBACK="$AUDIO_PLAYBACK"

MUMBLE_PORT="$MUMBLE_PORT"
MUMBLE_USERS="$MUMBLE_USERS"
MUMBLE_BANDWIDTH="$MUMBLE_BANDWIDTH"
MUMBLE_RADIO_USER="$MUMBLE_RADIO_USER"
MUMBLE_SERVER_PASSWORD="$MUMBLE_SERVER_PASSWORD"
MUMBLE_DISPLAY="$MUMBLE_DISPLAY"

WIFI_POWERSAVE="$WIFI_POWERSAVE"
CPU_GOVERNOR="$CPU_GOVERNOR"
CONSOLE_BLANK="$CONSOLE_BLANK"
DISABLE_BT="$DISABLE_BT"
LED_OFF="$LED_OFF"
AUTOLOGIN="$AUTOLOGIN"
INSTALL_EMACS="$INSTALL_EMACS"
INSTALL_K6SM="$INSTALL_K6SM"

# Defaults for the questions on a re-run.
DISABLE_BT_DEFAULT="$DISABLE_BT"
LED_OFF_DEFAULT="$LED_OFF"
AUTOLOGIN_DEFAULT="$AUTOLOGIN"
INSTALL_EMACS_DEFAULT="$INSTALL_EMACS"
INSTALL_K6SM_DEFAULT="$INSTALL_K6SM"
CONF

# --------------------------------------------------------------------------
# Packages, second pass
# --------------------------------------------------------------------------

if [ "$SKIP_APT" = 0 ]; then
    head_ "Installing the rest"
    PKGS=(mumble mumble-server avahi-daemon iw rsync)
    if [ "$MUMBLE_DISPLAY" = xvfb ]; then PKGS+=(xvfb); fi
    if [ "$INSTALL_EMACS" = yes ];  then PKGS+=(emacs-nox); fi
    if [ "$INSTALL_K6SM" = yes ];   then PKGS+=(git); fi
    say "${PKGS[*]}"
    apt_install "${PKGS[@]}"
fi

have mumble || die "The Mumble client did not install."

# Debian has called the server binary mumble-server since 1.4 and murmurd
# before that, and the BSDs call it murmur.
MS_BIN=""
for c in mumble-server murmurd murmur; do
    if have "$c"; then MS_BIN=$(command -v "$c"); break; fi
done
[ -n "$MS_BIN" ] || die "No Mumble server binary found (looked for mumble-server, murmurd, murmur)."

MS_INI=""
for c in /etc/mumble-server.ini /etc/murmur.ini; do
    if [ -f "$c" ]; then MS_INI=$c; break; fi
done
[ -n "$MS_INI" ] || MS_INI=/etc/mumble-server.ini

MS_SERVICE=""
for c in mumble-server murmur; do
    if systemctl list-unit-files "$c.service" >/dev/null 2>&1 && \
       systemctl list-unit-files "$c.service" | grep -q "$c.service"; then
        MS_SERVICE="$c.service"; break
    fi
done
[ -n "$MS_SERVICE" ] || MS_SERVICE="mumble-server.service"
ok "Mumble server: $MS_BIN, $MS_INI, $MS_SERVICE"

# --------------------------------------------------------------------------
# Hostname, account, SSH
# --------------------------------------------------------------------------

head_ "Hostname and login"

if [ "$(hostname)" != "$PI_HOSTNAME" ]; then
    hostnamectl set-hostname "$PI_HOSTNAME"
    # Keep /etc/hosts agreeing with it, or sudo pauses on every command.
    if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
        sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$PI_HOSTNAME/" /etc/hosts
    else
        printf '127.0.1.1\t%s\n' "$PI_HOSTNAME" >> /etc/hosts
    fi
    changed "hostname   $PI_HOSTNAME (so the station answers to $PI_HOSTNAME.local)"
else
    note "hostname   already $PI_HOSTNAME"
fi

PASSWORD_NOTE=""
if id -u "$OP_USER" >/dev/null 2>&1; then
    note "account    $OP_USER exists"
    if [ "$RESET_PASSWORD" = 1 ]; then
        printf '%s:%s\n' "$OP_USER" "$DEFAULT_PASSWORD" | chpasswd
        PASSWORD_NOTE="reset to the documented default"
        changed "password   $OP_USER reset to the default"
    else
        PASSWORD_NOTE="unchanged"
    fi
else
    adduser --disabled-password --gecos "Remote station operator" "$OP_USER"
    printf '%s:%s\n' "$OP_USER" "$DEFAULT_PASSWORD" | chpasswd
    PASSWORD_NOTE="set to the documented default"
    changed "account    created $OP_USER"
fi

# dialout reaches the radio's serial port, audio reaches the sound card.
for g in dialout audio plugdev sudo; do
    getent group "$g" >/dev/null 2>&1 && adduser "$OP_USER" "$g" >/dev/null 2>&1 || true
done
OP_HOME=$(getent passwd "$OP_USER" | cut -d: -f6)
[ -n "$OP_HOME" ] || die "Cannot find the home directory of $OP_USER."

head_ "SSH"

if have raspi-config; then raspi-config nonint do_ssh 0 || true; fi
systemctl enable ssh >/dev/null 2>&1 || systemctl enable sshd >/dev/null 2>&1 || true
systemctl start  ssh >/dev/null 2>&1 || systemctl start  sshd >/dev/null 2>&1 || true

# Password logins have to be allowed for the documented default password to
# work at all. The README says to change it and then move to keys.
if grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
    install_file /etc/ssh/sshd_config.d/99-ham-radio-pi.conf 0644 root:root <<'SSHD'
# ham-radio-pi: the station ships with a documented default password, which
# needs password authentication to be allowed. Change the password on first
# login, then consider moving to keys and setting PasswordAuthentication no.
PasswordAuthentication yes
SSHD
else
    warn "/etc/ssh/sshd_config has no sshd_config.d include; leaving it alone."
    warn "Check that PasswordAuthentication is yes if you use the default password."
fi
systemctl reload ssh >/dev/null 2>&1 || systemctl restart ssh >/dev/null 2>&1 || true
ok "SSH is enabled"

# --------------------------------------------------------------------------
# Console, no desktop
# --------------------------------------------------------------------------

head_ "Console mode"

systemctl set-default multi-user.target >/dev/null
ok "boots to the console, not a desktop"

for dm in lightdm gdm3 sddm xdm; do
    if systemctl list-unit-files "$dm.service" 2>/dev/null | grep -q "$dm.service"; then
        systemctl disable "$dm.service" >/dev/null 2>&1 || true
        changed "disabled   $dm (the desktop login manager)"
    fi
done

if [ "$AUTOLOGIN" = yes ]; then
    if have raspi-config; then
        raspi-config nonint do_boot_behaviour B2 >/dev/null 2>&1 || true
    fi
    install_file /etc/systemd/system/getty@tty1.service.d/autologin.conf <<AUTOLOGIN_UNIT
# ham-radio-pi: log the operator in on the screen attached to the radio, so
# that a screen and keyboard give a usable terminal with no typing.
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $OP_USER --noclear %I \$TERM
AUTOLOGIN_UNIT
else
    if have raspi-config; then
        raspi-config nonint do_boot_behaviour B1 >/dev/null 2>&1 || true
    fi
    rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
fi

# --------------------------------------------------------------------------
# rigctld
# --------------------------------------------------------------------------

head_ "rigctld"

RIGCTLD_ARGS=(-m "$RIG_MODEL" -r "$RIG_DEVICE" -T "$RIGCTLD_BIND" -t "$RIGCTLD_PORT")
if [ -n "$RIG_SPEED" ];    then RIGCTLD_ARGS+=(-s "$RIG_SPEED");    fi
if [ -n "$RIG_CIVADDR" ];  then RIGCTLD_ARGS+=(-c "$RIG_CIVADDR");  fi
if [ -n "$RIG_PTT_TYPE" ]; then RIGCTLD_ARGS+=(-P "$RIG_PTT_TYPE"); fi

RIGCTLD_BIN=$(command -v rigctld)

install_file /etc/systemd/system/rigctld.service <<RIGUNIT
[Unit]
Description=Hamlib rigctld for ${RIG_MODEL_NAME:-model $RIG_MODEL}
Documentation=man:rigctld(1)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$OP_USER
Group=$(id -gn "$OP_USER")
SupplementaryGroups=dialout
ExecStart=$RIGCTLD_BIN ${RIGCTLD_ARGS[*]}
Restart=always
RestartSec=3
# A little priority: the control link should answer while the board is busy
# encoding audio, and this costs nothing when it is idle.
Nice=-5
# It speaks to one serial port and one socket and needs nothing else.
NoNewPrivileges=true
ProtectSystem=full
PrivateTmp=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

[Install]
WantedBy=multi-user.target
RIGUNIT

ok "rigctld ${RIGCTLD_ARGS[*]}"

# --------------------------------------------------------------------------
# Mumble server
# --------------------------------------------------------------------------

head_ "Mumble server"

# The packaged ini carries the database, log and pid paths the service unit
# expects, so it is edited in place rather than replaced.
if [ ! -f "$MS_INI" ]; then
    install_file "$MS_INI" 0640 root:root <<'MSINI_NEW'
; Minimal Mumble server configuration created by ham-radio-pi.
database=/var/lib/mumble-server/mumble-server.sqlite
logfile=/var/log/mumble-server/mumble-server.log
pidfile=/run/mumble-server/mumble-server.pid
uname=mumble-server
MSINI_NEW
fi

MS_OWNER=$(stat -c '%U:%G' "$MS_INI")
MS_MODE=$(stat -c '%a' "$MS_INI")
MS_TMP=$(mktemp)
cp "$MS_INI" "$MS_TMP"

ini_set "$MS_TMP" port            "$MUMBLE_PORT"
ini_set "$MS_TMP" users           "$MUMBLE_USERS"
ini_set "$MS_TMP" bandwidth       "$MUMBLE_BANDWIDTH"
# Opus whatever connects. One old client otherwise drops the whole server to
# CELT, which costs CPU a small board does not have and sounds worse.
ini_set "$MS_TMP" opusthreshold   0
# The server writes its log into SQLite, and those writes are what wears out
# an SD card. Keep none.
ini_set "$MS_TMP" logdays         0
# Nothing here announces itself to the public server list.
ini_set "$MS_TMP" registerName    ""
ini_set "$MS_TMP" registerUrl     ""
ini_set "$MS_TMP" registerHostname ""
ini_set "$MS_TMP" allowping       "false"
ini_set "$MS_TMP" serverpassword  "$MUMBLE_SERVER_PASSWORD"
ini_set "$MS_TMP" welcometext     "<b>${PI_HOSTNAME}</b><br />Radio link. Voice processing off, Opus forced."
install_file "$MS_INI" "$MS_MODE" "$MS_OWNER" < "$MS_TMP"
rm -f "$MS_TMP"

# The SuperUser account administers the server from inside a client. It is
# only generated once, and kept where only root can read it.
SUPW_FILE="$CONF_DIR/mumble-superuser-password"
if [ ! -f "$SUPW_FILE" ]; then
    SUPW=$(head -c 12 /dev/urandom | base64 | tr -d '/+=' | cut -c1-12)
    if "$MS_BIN" -ini "$MS_INI" -supw "$SUPW" >/dev/null 2>&1; then
        printf '%s\n' "$SUPW" > "$SUPW_FILE"
        chmod 0600 "$SUPW_FILE"
        changed "created    Mumble SuperUser password in $SUPW_FILE"
    else
        warn "Could not set the Mumble SuperUser password automatically."
        warn "Set it by hand later: sudo $MS_BIN -ini $MS_INI -supw YOURPASSWORD"
    fi
else
    note "kept       Mumble SuperUser password in $SUPW_FILE"
fi

systemctl enable "$MS_SERVICE" >/dev/null 2>&1 || true

# --------------------------------------------------------------------------
# Mumble client at the radio
# --------------------------------------------------------------------------

head_ "Mumble client at the radio"

MUMBLE_CONF_DIR="$OP_HOME/.config/Mumble"
MUMBLE_CONF="$MUMBLE_CONF_DIR/Mumble.conf"
MUMBLE_CERT_DIR="$OP_HOME/Documents"
MUMBLE_P12="$MUMBLE_CERT_DIR/MumbleAutomaticCertificateBackup.p12"

# Mumble writes its settings back out when it exits, so it must not be
# running while the file is replaced.
systemctl stop mumble-radio.service >/dev/null 2>&1 || true

install -d -o "$OP_USER" -g "$(id -gn "$OP_USER")" -m 0755 "$MUMBLE_CONF_DIR" "$MUMBLE_CERT_DIR"

# Mumble authenticates by certificate and opens a modal wizard to make one,
# which nothing can click on a machine with no screen. It imports this file
# instead if it finds it, so generate it here and the wizard never appears.
if [ ! -f "$MUMBLE_P12" ]; then
    TMPD=$(mktemp -d)
    if openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout "$TMPD/key.pem" -out "$TMPD/cert.pem" \
            -subj "/CN=${MUMBLE_RADIO_USER}/O=ham-radio-pi" >/dev/null 2>&1 &&
       openssl pkcs12 -export -out "$TMPD/cert.p12" \
            -inkey "$TMPD/key.pem" -in "$TMPD/cert.pem" \
            -name "$MUMBLE_RADIO_USER" -passout pass: >/dev/null 2>&1; then
        install -o "$OP_USER" -g "$(id -gn "$OP_USER")" -m 0600 \
                "$TMPD/cert.p12" "$MUMBLE_P12"
        changed "created    Mumble certificate $MUMBLE_P12"
    else
        warn "Could not generate a Mumble certificate; the client may stop on its"
        warn "certificate wizard. Run mumble once with a screen attached if so."
    fi
    rm -rf "$TMPD"
else
    note "kept       Mumble certificate $MUMBLE_P12"
fi

# Every value here is either a radio requirement or a latency control. The
# comments say which is which; the README explains them at length.
install_file "$MUMBLE_CONF" 0644 "$OP_USER:$(id -gn "$OP_USER")" <<MUMBLECONF
; Mumble client settings for the radio end of a remote station.
; Written by radio-pi-setup.sh -- edited by hand only between runs, because
; re-running the script replaces this file. Change the answers in
; $CONF_FILE instead.

[General]
; Any value but 0 tells Mumble its configuration has been through a release,
; which is what stops the first-run audio wizard opening a window that nothing
; on a headless machine can close.
lastupdate=5

[audio]
; Continuous: the radio end has no operator to key it, and what it is sending
; is the receiver. 0=continuous 1=voice activated 2=push to talk.
transmit=0
mute=false
deaf=false

; 72000 bits/s is Mumble's ceiling and enables Opus low delay mode.
quality=$MUMBLE_BANDWIDTH
allowlowdelay=true

; The three voice processors, all off. Each is a model of a human voice in a
; quiet room; what crosses this link is a signal at the noise floor or a
; modulated waveform carrying data. Noise suppression removes weak signals as
; though they were noise.
noiseCancelMode=0
speexNoiseCancelStrength=0
noisesupress=0
echooptionid=0
echo=false
echomulti=false
; Mumble's AGC cannot be switched off, only held to unity gain, which is what
; 30000 does. Set the input level in alsamixer, not here.
loudness=30000

positional=false
postransmit=false
idleaction=0

; ALSA directly: no sound server to run, wake up or buffer through.
input=ALSA
output=ALSA

[alsa]
input=$AUDIO_CAPTURE
output=$AUDIO_PLAYBACK

[net]
; 1 frame per packet is 10ms, the main latency control.
framesperpacket=1
; Jitter buffer in units of 10ms. Raise this before anything else if the
; audio breaks up; jitter breaks audio, latency alone does not.
jitterbuffer=2
qos=true
tcponly=false
reconnect=true
autoconnect=true

[tts]
; Text to speech would be spoken into the transmitter.
enable=false

[shortcut]
; No keyboard here, and the X11 shortcut machinery has nothing to grab.
enable=false

[ui]
updatecheck=false
hidetray=true
MUMBLECONF

MUMBLE_URL="mumble://${MUMBLE_RADIO_USER}@127.0.0.1:${MUMBLE_PORT}/"
MUMBLE_BIN=$(command -v mumble)

if [ "$MUMBLE_DISPLAY" = xvfb ]; then
    have xvfb-run || die "xvfb-run is missing; install the xvfb package or choose offscreen."
    MUMBLE_EXEC="$(command -v xvfb-run) -a -s \"-screen 0 640x480x16 -nolisten tcp\" $MUMBLE_BIN $MUMBLE_URL"
    MUMBLE_ENV="Environment=QT_LOGGING_RULES=*.debug=false"
else
    MUMBLE_EXEC="$MUMBLE_BIN $MUMBLE_URL"
    MUMBLE_ENV=$'Environment=QT_QPA_PLATFORM=offscreen\nEnvironment=QT_LOGGING_RULES=*.debug=false'
fi

install_file /etc/systemd/system/mumble-radio.service <<CLIENTUNIT
[Unit]
Description=Mumble client at the radio (receiver audio out, transmitter audio in)
After=network-online.target sound.target $MS_SERVICE
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=$OP_USER
Group=$(id -gn "$OP_USER")
SupplementaryGroups=audio
WorkingDirectory=$OP_HOME
Environment=HOME=$OP_HOME
$MUMBLE_ENV
# The server is on this machine, so give it a moment to be listening.
ExecStartPre=/bin/sleep 5
ExecStart=$MUMBLE_EXEC
Restart=always
RestartSec=10
Nice=-5

[Install]
WantedBy=multi-user.target
CLIENTUNIT

ok "client joins $MUMBLE_URL as $MUMBLE_RADIO_USER, transmitting continuously"

# --------------------------------------------------------------------------
# Power and latency
# --------------------------------------------------------------------------

head_ "Power and latency"

# --- firmware -------------------------------------------------------------

if [ "$IS_PI" = 1 ] && [ -f "$BOOT/config.txt" ]; then
    {
        echo "# Written by radio-pi-setup.sh. Delete this block to undo it."
        echo "disable_splash=1"
        if [ "$DISABLE_BT" = yes ]; then
            echo "dtoverlay=disable-bt"
        fi
        # The onboard analog/HDMI audio is not what carries the radio, and
        # leaving it enabled keeps a clock running for nothing.
        case "$AUDIO_CAPTURE$AUDIO_PLAYBACK" in
            *bcm2835*|*Headphones*|*default*) : ;;
            *) echo "dtparam=audio=off" ;;
        esac
        if [ "$LED_OFF" = yes ]; then
            echo "dtparam=act_led_trigger=none"
            echo "dtparam=act_led_activelow=off"
            echo "dtparam=pwr_led_trigger=none"
            echo "dtparam=pwr_led_activelow=off"
        fi
    } | managed_block "$BOOT/config.txt" "#"

    if [ "$DISABLE_BT" = yes ]; then
        systemctl disable --now hciuart.service >/dev/null 2>&1 || true
        systemctl disable --now bluetooth.service >/dev/null 2>&1 || true
    fi
fi

# Blanking the screen powers down an attached monitor without logging anyone
# out; a keypress brings it straight back.
if [ -f "$BOOT/cmdline.txt" ]; then
    cmdline_set "$BOOT/cmdline.txt" consoleblank "$CONSOLE_BLANK"
fi

# --- Wi-Fi ----------------------------------------------------------------

if [ "$WIFI_POWERSAVE" = off ]; then WIFI_NM=2; else WIFI_NM=3; fi
if [ -d /etc/NetworkManager ]; then
    install_file /etc/NetworkManager/conf.d/99-ham-radio-pi.conf <<NMCONF
# ham-radio-pi: 2 disables Wi-Fi power saving, 3 enables it.
# Power saving parks the radio between packets: it saves current and costs
# latency, unpredictably, on the first packet of every transmission.
[connection]
wifi.powersave = $WIFI_NM
NMCONF
    systemctl reload NetworkManager >/dev/null 2>&1 || true
fi

# Not every image runs NetworkManager, so set it directly as well.
install_file /etc/systemd/system/ham-radio-pi-tuning.service <<TUNEUNIT
[Unit]
Description=ham-radio-pi latency and power tuning
After=multi-user.target
Wants=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/ham-radio-pi-tune

[Install]
WantedBy=multi-user.target
TUNEUNIT

install_file /usr/local/sbin/ham-radio-pi-tune 0755 root:root <<TUNESCRIPT
#!/bin/sh
# Written by radio-pi-setup.sh. Applied at every boot.
set -u

# CPU governor. ondemand idles the cores down to save current and ramps in a
# few milliseconds; up_threshold and io_is_busy make that ramp eager, which
# is what keeps an audio thread from waiting on a slow core.
for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [ -w "\$g" ] && echo "$CPU_GOVERNOR" > "\$g"
done
for f in /sys/devices/system/cpu/cpufreq/ondemand; do
    [ -w "\$f/up_threshold" ]        && echo 50 > "\$f/up_threshold"
    [ -w "\$f/io_is_busy" ]          && echo 1  > "\$f/io_is_busy"
    [ -w "\$f/sampling_down_factor" ] && echo 1 > "\$f/sampling_down_factor"
done

# Wi-Fi power saving, for images that do not run NetworkManager.
if command -v iw >/dev/null 2>&1; then
    for dev in \$(iw dev 2>/dev/null | awk '\$1=="Interface"{print \$2}'); do
        iw dev "\$dev" set power_save $WIFI_POWERSAVE 2>/dev/null || true
    done
fi

# A tuning knob missing on this kernel is not a failure of the unit.
exit 0
TUNESCRIPT

systemctl enable ham-radio-pi-tuning.service >/dev/null 2>&1 || true

# --- writes to the card ---------------------------------------------------

install_file /etc/sysctl.d/99-ham-radio-pi.conf <<'SYSCTL'
# ham-radio-pi: fewer, later writes to the SD card. Each flush spins up the
# card and costs current; on a battery station that adds up over a day.
vm.dirty_writeback_centisecs = 1500
vm.dirty_expire_centisecs = 3000
# Swapping on an SD card is slow enough to be heard in the audio.
vm.swappiness = 10
SYSCTL
sysctl -q --system >/dev/null 2>&1 || true

install_file /etc/systemd/journald.conf.d/99-ham-radio-pi.conf <<'JOURNALD'
# ham-radio-pi: keep the journal in RAM. It is the steadiest writer on an
# otherwise idle station, and an appliance that reboots cleanly has little
# use for yesterday's log. journalctl still shows this boot.
[Journal]
Storage=volatile
RuntimeMaxUse=32M
JOURNALD
systemctl restart systemd-journald >/dev/null 2>&1 || true

# --- services that do nothing here ---------------------------------------

for svc in triggerhappy cups cups-browsed ModemManager packagekit \
           apt-daily.timer apt-daily-upgrade.timer man-db.timer \
           e2scrub_all.timer fstrim.timer; do
    if systemctl list-unit-files "$svc" 2>/dev/null | grep -q "^$svc"; then
        systemctl disable --now "$svc" >/dev/null 2>&1 || true
        note "disabled   $svc"
    fi
done

# Avahi stays: it is what answers to ${PI_HOSTNAME}.local, which is how the
# operator's ham-remote configuration finds this machine.
systemctl enable --now avahi-daemon >/dev/null 2>&1 || true
ok "avahi kept, so the station answers to ${PI_HOSTNAME}.local"

# --------------------------------------------------------------------------
# Emacs
# --------------------------------------------------------------------------

if [ "$INSTALL_EMACS" = yes ]; then
    head_ "Emacs"
    LISP_DIR="$OP_HOME/.emacs.d/lisp"
    install -d -o "$OP_USER" -g "$(id -gn "$OP_USER")" -m 0755 "$LISP_DIR"

    if [ "$INSTALL_K6SM" = yes ] && have git; then
        for repo in ham Emacs-QSO-Logger; do
            target="$LISP_DIR/$repo"
            if [ -d "$target/.git" ]; then
                sudo -u "$OP_USER" git -C "$target" pull --quiet --ff-only \
                    && note "updated    $target" || warn "could not update $target"
            else
                if sudo -u "$OP_USER" git clone --quiet --depth 1 \
                        "https://github.com/K6SM/$repo.git" "$target"; then
                    changed "cloned     $target"
                else
                    warn "Could not clone K6SM/$repo. Check the network and re-run."
                fi
            fi
        done

        INIT="$OP_HOME/.emacs.d/init.el"
        if [ ! -f "$INIT" ] || ! grep -q 'ham-radio-pi' "$INIT"; then
            backup_once "$INIT"
            cat >> "$INIT" <<INITEL
;; ham-radio-pi: the K6SM packages, and this Pi's own rigctld.
(add-to-list 'load-path "$LISP_DIR/ham")
(add-to-list 'load-path "$LISP_DIR/Emacs-QSO-Logger")
(setq ham-rig-host "127.0.0.1"
      ham-rig-port $RIGCTLD_PORT
      qso-hamlib-enable t
      qso-hamlib-host "127.0.0.1"
      qso-hamlib-port $RIGCTLD_PORT)
(require 'ham-rig nil t)
(require 'qso nil t)
INITEL
            chown "$OP_USER:$(id -gn "$OP_USER")" "$INIT"
            changed "wrote      $INIT"
        else
            note "kept       $INIT (already set up)"
        fi
    fi
    ok "M-x ham-rig and M-x qso-log-form work on the attached screen"
fi

# --------------------------------------------------------------------------
# Start everything
# --------------------------------------------------------------------------

head_ "Starting the station"

systemctl daemon-reload
systemctl enable rigctld.service mumble-radio.service >/dev/null 2>&1 || true

systemctl restart "$MS_SERVICE" || warn "$MS_SERVICE did not start."
systemctl restart rigctld.service || warn "rigctld did not start."
systemctl restart mumble-radio.service || warn "mumble-radio did not start."

# The Mumble client waits five seconds for the server, and Mumble's Qt
# startup on a Zero 2W is not instant.
sleep 12

# --------------------------------------------------------------------------
# Check it
# --------------------------------------------------------------------------

head_ "Checking"

FAILED=0
check_service() {
    if systemctl is-active --quiet "$1"; then
        ok "running    $1"
    else
        warn "not running: $1   --   journalctl -u $1 -n 40"
        FAILED=1
    fi
}
check_service "$MS_SERVICE"
check_service rigctld.service
check_service mumble-radio.service

RESTARTS=$(systemctl show -p NRestarts --value mumble-radio.service 2>/dev/null || echo 0)
if [ "${RESTARTS:-0}" -gt 1 ]; then
    warn "the Mumble client has restarted ${RESTARTS} times already, so it is"
    warn "starting and dying. journalctl -u mumble-radio -n 40 says why; a"
    warn "missing sound device is the usual reason."
    FAILED=1
fi

# Hamlib model 2 is "NET rigctl": rigctl talking to rigctld, which is exactly
# what the operator's Emacs does.
if FREQ=$(timeout 10 rigctl -m 2 -r "127.0.0.1:$RIGCTLD_PORT" f 2>/dev/null); then
    ok "radio      answered: $FREQ Hz"
else
    warn "rigctld is up but the radio did not answer."
    warn "Check that it is switched on, on the right serial speed, and set to"
    warn "the CAT protocol Hamlib model $RIG_MODEL expects."
    FAILED=1
fi

if have ss && ss -lnt 2>/dev/null | grep -q ":$MUMBLE_PORT "; then
    ok "listening  Mumble on port $MUMBLE_PORT"
else
    warn "Nothing is listening on Mumble's port $MUMBLE_PORT."
    FAILED=1
fi

if timeout 5 arecord -D "$AUDIO_CAPTURE" -d 1 -f S16_LE -r 48000 -c 1 \
        /dev/null >/dev/null 2>&1; then
    ok "audio in   $AUDIO_CAPTURE opens"
else
    note "capture device $AUDIO_CAPTURE is busy -- expected, the Mumble client has it"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------

IP=$(hostname -I 2>/dev/null | awk '{print $1}')

cat <<SUMMARY

$C_HEAD== The station ==$C_OFF

   Radio        ${RIG_MODEL_NAME:-model $RIG_MODEL} (Hamlib model $RIG_MODEL) on $RIG_DEVICE
   rigctld      ${RIGCTLD_BIND}:${RIGCTLD_PORT}  (${RIGCTLD_SCOPE})
   Mumble       port $MUMBLE_PORT, TCP and UDP, up to $MUMBLE_USERS clients
   Radio client joins as "$MUMBLE_RADIO_USER", transmitting continuously
   Audio        in $AUDIO_CAPTURE
                out $AUDIO_PLAYBACK
   Reachable at ${PI_HOSTNAME}.local${IP:+ / $IP}

$C_HEAD== Logging in ==$C_OFF

   ssh ${OP_USER}@${PI_HOSTNAME}.local
   Password: $PASSWORD_NOTE
SUMMARY

if [ "$PASSWORD_NOTE" != unchanged ]; then
cat <<SUMMARY2
   The password is "$DEFAULT_PASSWORD", which is printed in the README and so
   is known to everyone. Change it now:

       ssh ${OP_USER}@${PI_HOSTNAME}.local
       passwd

SUMMARY2
else
cat <<'SUMMARY3'
   The password is the one already on this account; this run did not change it.

SUMMARY3
fi

cat <<SUMMARY4
$C_HEAD== At the operator's end ==$C_OFF

   (setq ham-remote-host "${PI_HOSTNAME}.local"
         ham-remote-transport "mumble"
         ham-remote-mumble-user "YOURCALL"     ; not "$MUMBLE_RADIO_USER"
         ham-remote-mumble-port $MUMBLE_PORT
         ham-remote-mumble-run 'client
         ham-rig-host "${PI_HOSTNAME}.local"
         ham-rig-port $RIGCTLD_PORT)
SUMMARY4

if [ "$RIGCTLD_SCOPE" = localhost ]; then
cat <<SUMMARY5

   rigctld listens on this Pi only, so tunnel it from the operator's machine:

       ssh -N -L ${RIGCTLD_PORT}:127.0.0.1:${RIGCTLD_PORT} ${OP_USER}@${PI_HOSTNAME}.local

   and set ham-rig-host to "127.0.0.1" there. A VPN such as WireGuard is the
   better answer if this station is not on your own LAN.
SUMMARY5
else
cat <<'SUMMARY6'

   rigctld is reachable from the network with no password of any kind. Keep
   this station behind a VPN, and do not forward its port from the internet.
SUMMARY6
fi

cat <<SUMMARY7

$C_HEAD== Before you transmit ==$C_OFF

   Enable the transceiver's own transmit timeout. Nothing at the operator's
   end can unkey the radio once the network is gone.

   Set the transmit audio level with the rig's ALC meter, not by ear: bring
   it up in alsamixer until ALC just begins to move, and stop there.

   Changed something? Edit $CONF_FILE and run
   sudo bash $0 --unattended

SUMMARY7

if [ "$FAILED" = 1 ]; then
    warn "Some checks did not pass; see the notes above."
    exit 1
fi

printf '%s   Ready.%s\n\n' "$C_OK" "$C_OFF"
