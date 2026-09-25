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
REBUILD_HAMLIB=0

# Hamlib is built from the latest stable release on GitHub, looked up each
# time the script runs, rather than taken from Debian, whose Hamlib lags by
# years (Bookworm ships 4.5.4).
HAMLIB_REPO="Hamlib/Hamlib"
HAMLIB_PREFIX=/usr/local
RIGCTLD_BIN=$HAMLIB_PREFIX/bin/rigctld
RIGCTL_BIN=$HAMLIB_PREFIX/bin/rigctl

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
  --skip-apt          Do not install or update packages, and do not build
                      Hamlib; only rewrite the configuration and restart the
                      services.
  --rebuild-hamlib    Build Hamlib again even if the wanted version is
                      already installed.
  -h, --help          This text.
USAGE
}

while [ $# -gt 0 ]; do
    case "$1" in
        --unattended)     UNATTENDED=1 ;;
        --reset-password) RESET_PASSWORD=1 ;;
        --skip-apt)       SKIP_APT=1 ;;
        --rebuild-hamlib) REBUILD_HAMLIB=1 ;;
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
    # Runs before this one saved device names as plughw:CARD=Foo,DEV=0. That
    # comma is what Qt's QSettings turns into a list separator when Mumble
    # reads the name back, leaving it with no device at all. DEV=0 is ALSA's
    # default, so dropping it names the same device without the hazard.
    if [ "${AUDIO_CAPTURE:-}" != "${AUDIO_CAPTURE%,DEV=0}" ] ||
       [ "${AUDIO_PLAYBACK:-}" != "${AUDIO_PLAYBACK%,DEV=0}" ]; then
        AUDIO_CAPTURE="${AUDIO_CAPTURE%,DEV=0}"
        AUDIO_PLAYBACK="${AUDIO_PLAYBACK%,DEV=0}"
        changed "corrected  saved audio device names, dropping \",DEV=0\""
    fi
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

# Command-line packages: no recommends, to keep a Lite image lean.
apt_install() {
    if [ "$SKIP_APT" = 1 ]; then note "skipping apt (--skip-apt): $*"; return 0; fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
}

# Graphical packages: recommends INCLUDED, deliberately. Mumble is a Qt
# program, and on a Lite image the libraries its xcb platform plugin needs
# arrive as recommends of the Qt runtime rather than as hard dependencies.
# Installed lean, Mumble dies at startup with "could not load the Qt platform
# plugin xcb" -- which on a headless machine looks like a client that simply
# never connects. The extra packages are disk space; this is not the place to
# save it.
apt_install_gui() {
    if [ "$SKIP_APT" = 1 ]; then note "skipping apt (--skip-apt): $*"; return 0; fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# --------------------------------------------------------------------------
# Hamlib, built from source
# --------------------------------------------------------------------------
#
# The version is the latest stable release on GitHub, found when the script
# runs: GitHub's "latest release" is the newest one that is neither a draft
# nor a pre-release, which is exactly what stable means here. A re-run after
# a new release builds it; a re-run without one does nothing. HAMLIB_VERSION
# in setup.conf pins a particular version instead.
#
# Installed under /usr/local and linked with a run path to its own library,
# so that it cannot pick up Debian's older libhamlib.so.4 by accident: both
# have the same soname, and the dynamic linker's search order would otherwise
# decide which one rigctld got.

# Prints the installed version, or nothing. It must never fail: it is called
# in assignments, where under set -e and pipefail a missing rigctld -- the
# normal state on a first run -- would end the script with no message.
hamlib_installed_version() {
    if [ -x "$RIGCTLD_BIN" ]; then
        "$RIGCTLD_BIN" --version 2>/dev/null | awk '{print $3; exit}' || true
    fi
}

# A release version, as Hamlib tags them: 4.7.2, 4.6. Anything else -- a
# pre-release tag, an error page -- is refused rather than built.
hamlib_version_ok() {
    printf '%s' "${1:-}" | grep -qE '^[0-9]+(\.[0-9]+)+$'
}

# Releases whose tarballs have been checked by hand, as a further check on
# top of the comparison with SourceForge. Not required: a release missing
# here is still verified, just against one source fewer.
hamlib_known_sha256() {
    case "$1" in
        4.7.2) echo ae1fcf2dbc80ea0786ea8f047b09399c3f7737d1930442f61a031708ed33e88f ;;
    esac
}

# The latest stable release, or nothing if GitHub cannot be asked. The web
# page's redirect first, which has no rate limit; the API second.
hamlib_latest_release() {
    local tag
    tag=$(curl -fsS -m 30 -o /dev/null -w '%{redirect_url}' \
               "https://github.com/$HAMLIB_REPO/releases/latest" 2>/dev/null || true)
    tag=${tag##*/tag/}
    if ! hamlib_version_ok "$tag"; then
        tag=$(curl -fsS -m 30 -H 'Accept: application/vnd.github+json' \
                   "https://api.github.com/repos/$HAMLIB_REPO/releases/latest" 2>/dev/null |
              sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' |
              head -1 || true)
    fi
    if hamlib_version_ok "$tag"; then printf '%s' "$tag"; fi
}

# Settles HAMLIB_VERSION_WANTED and HAMLIB_WANTED_WHY.
choose_hamlib_version() {
    local setting=${HAMLIB_VERSION:-latest} latest installed
    installed=$(hamlib_installed_version)

    if [ "$setting" != latest ]; then
        hamlib_version_ok "$setting" ||
            die "HAMLIB_VERSION=\"$setting\" in $CONF_FILE is not a release version."
        HAMLIB_VERSION_WANTED=$setting
        HAMLIB_WANTED_WHY="pinned in $CONF_FILE"
        return 0
    fi

    say "asking GitHub for the latest stable Hamlib release"
    latest=$(hamlib_latest_release)
    if [ -n "$latest" ]; then
        HAMLIB_VERSION_WANTED=$latest
        HAMLIB_WANTED_WHY="latest stable release on GitHub"
        ok "latest stable release: $latest (installed: ${installed:-none})"
    elif [ -n "$installed" ]; then
        # No network is no reason to break a station that works.
        warn "Could not reach GitHub to find the latest Hamlib release."
        warn "Keeping the installed $installed; re-run when the network is back."
        HAMLIB_VERSION_WANTED=$installed
        HAMLIB_WANTED_WHY="installed; GitHub could not be reached"
    else
        die "Could not reach GitHub to find the latest Hamlib release, and no
       Hamlib is installed yet. Check the Pi's network and run this again,
       or name a version in $CONF_FILE:  HAMLIB_VERSION=\"4.7.2\""
    fi
}

# Downloads the release tarball and makes sure it is the one Hamlib
# published. With no checksum to compare against in advance -- the script
# does not know what the latest release will be -- the GitHub copy is
# compared with the one Hamlib publishes separately on SourceForge. Two
# independent hosts serving the same bytes is good evidence neither has been
# tampered with; if they differ, nothing is built.
fetch_hamlib_tarball() { # fetch_hamlib_tarball <version> <tarball>
    local v=$1 tarball=$2 want got other tmp
    local gh="https://github.com/$HAMLIB_REPO/releases/download/$v/hamlib-$v.tar.gz"
    local sf="https://sourceforge.net/projects/hamlib/files/hamlib/$v/hamlib-$v.tar.gz/download"

    want=${HAMLIB_SHA256:-}
    if [ -z "$want" ]; then want=$(hamlib_known_sha256 "$v"); fi

    # A tarball kept from an earlier run is reused if it still matches the
    # checksum recorded when it was verified.
    if [ -s "$tarball" ] && [ -s "$tarball.sha256" ] &&
       [ "$(sha256sum "$tarball" | awk '{print $1}')" = "$(cat "$tarball.sha256")" ]; then
        if [ -z "$want" ] || [ "$want" = "$(cat "$tarball.sha256")" ]; then
            ok "Hamlib $v tarball, verified on an earlier run"
            return 0
        fi
    fi
    rm -f "$tarball" "$tarball.sha256"

    say "downloading Hamlib $v from GitHub"
    if ! curl -fsSL --retry 3 -m 300 -o "$tarball.part" "$gh"; then
        rm -f "$tarball.part"
        die "Could not download $gh"
    fi
    if ! gzip -t "$tarball.part" 2>/dev/null; then
        rm -f "$tarball.part"
        die "What GitHub returned for Hamlib $v is not a tarball."
    fi
    mv "$tarball.part" "$tarball"
    got=$(sha256sum "$tarball" | awk '{print $1}')

    if [ -n "$want" ]; then
        if [ "$got" != "$want" ]; then
            rm -f "$tarball"
            die "Hamlib $v failed its checksum: got $got, expected $want."
        fi
        ok "Hamlib $v tarball, checksum verified"
    else
        tmp=$(mktemp)
        if curl -fsSL --retry 2 -m 300 -o "$tmp" "$sf" 2>/dev/null && gzip -t "$tmp" 2>/dev/null; then
            other=$(sha256sum "$tmp" | awk '{print $1}')
            rm -f "$tmp"
            if [ "$other" != "$got" ]; then
                rm -f "$tarball"
                die "Hamlib $v differs between GitHub ($got) and SourceForge
       ($other). Not building something whose origin is in doubt."
            fi
            ok "Hamlib $v tarball, identical on GitHub and SourceForge"
        else
            rm -f "$tmp"
            warn "SourceForge has no copy of Hamlib $v to compare against yet,"
            warn "so it is trusted as downloaded from GitHub over HTTPS."
        fi
    fi
    printf '%s\n' "$got" > "$tarball.sha256"
    note "sha256 $got"
}

build_hamlib() {
    local v=$HAMLIB_VERSION_WANTED src tarball log jobs mem_mb have_v
    have_v=$(hamlib_installed_version)

    if [ "$have_v" = "$v" ] && [ "$REBUILD_HAMLIB" = 0 ]; then
        ok "Hamlib $v, already built in $HAMLIB_PREFIX"
        return 0
    fi
    if [ "$SKIP_APT" = 1 ]; then
        warn "--skip-apt: not building Hamlib $v (installed: ${have_v:-none})"
        return 0
    fi

    apt_install build-essential pkg-config libreadline-dev libusb-1.0-0-dev

    src=/usr/local/src/hamlib
    mkdir -p "$src"
    tarball=$src/hamlib-$v.tar.gz
    fetch_hamlib_tarball "$v" "$tarball"

    rm -rf "$src/hamlib-$v"
    tar -xzf "$tarball" -C "$src"
    [ -x "$src/hamlib-$v/configure" ] ||
        die "The Hamlib $v tarball has no configure script; it cannot be built as is."

    # Parallel compiles by memory, not by cores: a Zero 2W has four cores
    # and 512MB, and four compilers at once can run it out.
    mem_mb=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo)
    jobs=$(( mem_mb / 200 ))
    if [ "$jobs" -lt 1 ]; then jobs=1; fi
    if [ "$jobs" -gt "$(nproc)" ]; then jobs=$(nproc); fi

    log=$src/build-$v.log
    say "building Hamlib $v with $jobs parallel job(s)."
    say "On a Pi Zero 2W this takes 20 to 45 minutes; on a Pi 4 or 5, a few."
    say "Progress goes to $log"

    if ! (
        cd "$src/hamlib-$v" &&
        ./configure --prefix="$HAMLIB_PREFIX" --disable-static \
                    --without-cxx-binding --disable-html-matrix \
                    LDFLAGS="-Wl,-rpath,$HAMLIB_PREFIX/lib" &&
        make -j"$jobs" &&
        make install
    ) > "$log" 2>&1; then
        tail -25 "$log" >&2
        die "Hamlib $v did not build; the full log is $log.
       Nothing was removed: any rigctld that worked before still does."
    fi
    ldconfig

    have_v=$(hamlib_installed_version)
    if [ "$have_v" != "$v" ]; then
        die "Built Hamlib $v, but $RIGCTLD_BIN reports \"${have_v:-nothing}\"."
    fi
    if ! ldd "$RIGCTLD_BIN" 2>/dev/null | grep -q "$HAMLIB_PREFIX/lib/libhamlib"; then
        die "$RIGCTLD_BIN is not loading its own library from $HAMLIB_PREFIX/lib."
    fi

    rm -rf "${src:?}/hamlib-$v"      # the build tree; the tarball is kept
    # Tarballs of versions no longer in use are only disk space.
    find "$src" -maxdepth 1 -name 'hamlib-*.tar.gz*' ! -name "hamlib-$v.tar.gz*" -delete 2>/dev/null || true
    changed "built      Hamlib $v in $HAMLIB_PREFIX"
}

# Debian's copy goes once ours works, so that there is exactly one rigctld on
# the machine. Its library stays if something else needs it -- fldigi or
# WSJT-X, say -- which is harmless: our rigctld uses its own.
remove_distro_hamlib() {
    local pkg others
    if dpkg-query -W -f='${Status}' libhamlib-utils 2>/dev/null | grep -q 'ok installed'; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y libhamlib-utils >/dev/null 2>&1 &&
            changed "removed    Debian's libhamlib-utils, so only one rigctld exists"
    fi
    for pkg in libhamlib4 libhamlib4t64; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'ok installed'; then
            others=$(apt-cache rdepends --installed "$pkg" 2>/dev/null | tail -n +3 |
                     sed 's/^[ |]*//' | grep -v -x -e libhamlib-utils -e "$pkg" | sort -u |
                     tr '\n' ' ')
            if [ -z "${others// /}" ]; then
                DEBIAN_FRONTEND=noninteractive apt-get purge -y "$pkg" >/dev/null 2>&1 &&
                    changed "removed    Debian's $pkg, which nothing else used"
            else
                note "kept       Debian's $pkg: needed by $others"
            fi
        fi
    done
}

head_ "Hamlib"
if [ "$SKIP_APT" = 0 ]; then
    DEBIAN_FRONTEND=noninteractive apt-get update
    apt_install alsa-utils openssl ca-certificates curl
fi
if have curl; then
    choose_hamlib_version
else
    HAMLIB_VERSION_WANTED=$(hamlib_installed_version)
    HAMLIB_WANTED_WHY="installed; curl is not available to ask GitHub"
    [ -n "$HAMLIB_VERSION_WANTED" ] || die "curl is needed to find and fetch Hamlib."
fi
build_hamlib
if [ "$(hamlib_installed_version)" = "$HAMLIB_VERSION_WANTED" ]; then
    remove_distro_hamlib
fi

[ -x "$RIGCTL_BIN" ] || die "$RIGCTL_BIN is missing; cannot offer the list of radios."

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
"$RIGCTL_BIN" -l > "$RIGLIST" 2>/dev/null || die "rigctl -l failed."
RIGCOUNT=$(grep -cE '^[[:space:]]*[0-9]+' "$RIGLIST" || true)
say "Hamlib $(hamlib_installed_version) supports $RIGCOUNT radios."

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
        # Device 0 is left off the name on purpose. ALSA defaults DEV to 0,
        # so "plughw:CARD=Foo" and "plughw:CARD=Foo,DEV=0" open the same
        # thing -- but the first has no comma in it, and a comma is the one
        # character that Qt's QSettings turns into a list separator when
        # Mumble reads its configuration back. Fewer commas, fewer ways for
        # the device name to arrive at snd_pcm_open as an empty string.
        if [ "$dev" = 0 ]; then
            devs+=("plughw:CARD=${id}")
        else
            devs+=("plughw:CARD=${id},DEV=${dev}")
        fi
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

if [ "$UNATTENDED" = 0 ]; then
    cat <<'WATCHNOTE'

   A station you cannot walk over to has to put its own Wi-Fi back when it
   drops. The watchdog checks every 20 seconds; after a minute's outage it
   writes down the evidence, then tries rejoining, restarting the Wi-Fi, and
   reloading the driver, in that order. Rebooting is the last resort, at most
   three times a day and never in the first half hour after a boot.

WATCHNOTE
fi
if ask_yn "Watch the Wi-Fi and reconnect it when it drops?" "${WIFI_WATCHDOG_DEFAULT:-yes}"; then
    WIFI_WATCHDOG=yes
else
    WIFI_WATCHDOG=no
fi
WIFI_WATCHDOG_REBOOT=no
if [ "$WIFI_WATCHDOG" = yes ] &&
   ask_yn "As a last resort, reboot if nothing else brings it back?" "${WIFI_WATCHDOG_REBOOT_DEFAULT:-yes}"; then
    WIFI_WATCHDOG_REBOOT=yes
fi

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
WIFI_WATCHDOG="$WIFI_WATCHDOG"
WIFI_WATCHDOG_REBOOT="$WIFI_WATCHDOG_REBOOT"
CPU_GOVERNOR="$CPU_GOVERNOR"

# persistent keeps the journal across reboots, which is what finds a fault
# that stops the machine; volatile keeps it in RAM and saves the SD card.
JOURNAL_STORAGE="${JOURNAL_STORAGE:-persistent}"

# Hamlib is built from source. "latest" follows the latest stable release on
# GitHub: each run checks, and builds a new release when there is one. A
# version number pins that version instead, e.g. HAMLIB_VERSION="4.7.2".
# HAMLIB_SHA256, if set, must match the pinned version's tarball.
HAMLIB_VERSION="${HAMLIB_VERSION:-latest}"
HAMLIB_SHA256="${HAMLIB_SHA256:-}"
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
WIFI_WATCHDOG_DEFAULT="$WIFI_WATCHDOG"
WIFI_WATCHDOG_REBOOT_DEFAULT="$WIFI_WATCHDOG_REBOOT"
CONF

# --------------------------------------------------------------------------
# Packages, second pass
# --------------------------------------------------------------------------

if [ "$SKIP_APT" = 0 ]; then
    head_ "Installing the rest"
    PKGS=(mumble-server avahi-daemon iw rsync sqlite3)
    if [ "$INSTALL_EMACS" = yes ];  then PKGS+=(emacs-nox); fi
    if [ "$INSTALL_K6SM" = yes ];   then PKGS+=(git); fi
    say "${PKGS[*]}"
    apt_install "${PKGS[@]}"

    GUI_PKGS=(mumble)
    if [ "$MUMBLE_DISPLAY" = xvfb ]; then GUI_PKGS+=(xvfb); fi
    say "${GUI_PKGS[*]} (with recommends)"
    apt_install_gui "${GUI_PKGS[@]}"
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
# The server keeps log entries in its SQLite database, and those writes are
# what wears out an SD card. -1 disables that logging; 0 does NOT mean "none"
# here, it means KEEP FOREVER, which is the opposite of what is wanted.
ini_set "$MS_TMP" logdays         -1
# Nothing here announces itself to the public server list.
ini_set "$MS_TMP" registerName    ""
ini_set "$MS_TMP" registerUrl     ""
ini_set "$MS_TMP" registerHostname ""
ini_set "$MS_TMP" allowping       "false"
ini_set "$MS_TMP" serverpassword  "$MUMBLE_SERVER_PASSWORD"
# Quoted for the same QSettings reason as the client's ALSA device names:
# this text contains a comma.
ini_set "$MS_TMP" welcometext     "\"<b>${PI_HOSTNAME}</b><br />Radio link. Voice processing off, Opus forced.\""
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
; THE QUOTES ARE LOAD-BEARING. Mumble reads this file with Qt's QSettings,
; which treats an unquoted comma as a list separator: written bare, a name
; like plughw:CARD=CODEC,DEV=0 comes back as a two-item list, Qt converts
; that to an EMPTY string, and Mumble calls snd_pcm_open("") and reports
; "Unknown PCM" -- silence in both directions, with the client otherwise
; running normally. Quoted, it stays one string.
input="$AUDIO_CAPTURE"
output="$AUDIO_PLAYBACK"

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
# A runtime directory of its own, so Qt does not invent one under /tmp.
RuntimeDirectory=mumble-radio
RuntimeDirectoryMode=0700
Environment=XDG_RUNTIME_DIR=/run/mumble-radio
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

JOURNAL_STORAGE="${JOURNAL_STORAGE:-persistent}"
if [ "$JOURNAL_STORAGE" = volatile ]; then
    install_file /etc/systemd/journald.conf.d/99-ham-radio-pi.conf <<'JOURNALD'
# ham-radio-pi: the journal is kept in RAM, sparing the SD card. It is lost
# at every reboot, including the one that follows a fault.
[Journal]
Storage=volatile
RuntimeMaxUse=32M
JOURNALD
else
    install_file /etc/systemd/journald.conf.d/99-ham-radio-pi.conf <<'JOURNALD'
# ham-radio-pi: the journal is kept on disk, capped, so that a fault which
# stops or restarts the machine leaves its account behind: journalctl -b -1
# shows the boot before this one. A station you cannot walk over to needs
# that more than the SD card needs sparing. Writes are batched every five
# minutes, and anything at warning level or above is written at once.
[Journal]
Storage=persistent
SystemMaxUse=64M
SyncIntervalSec=5m
JOURNALD
fi
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

# --- keeping the Wi-Fi up ---------------------------------------------------

# NetworkManager tries a failing connection four times and then stops trying
# for good, until something outside it intervenes. On a machine nobody is in
# front of, that is the difference between a thirty-second drop and a station
# that is gone until someone visits. Zero means keep trying for ever.
if have nmcli; then
    while IFS=: read -r uuid ctype; do
        [ "$ctype" = 802-11-wireless ] || continue
        if [ "$(nmcli -g connection.autoconnect-retries connection show "$uuid" 2>/dev/null)" != 0 ]; then
            nmcli connection modify "$uuid" connection.autoconnect-retries 0 &&
                changed "wifi       $(nmcli -g connection.id connection show "$uuid") retries for ever instead of giving up"
        fi
    done < <(nmcli -t -f UUID,TYPE connection show 2>/dev/null || true)
fi

if [ "$WIFI_WATCHDOG" = yes ]; then
    install_file /etc/ham-radio-pi/wifiwatch.conf 0644 root:root <<WATCHCONF
# Settings for ham-radio-pi-wifiwatch, written by radio-pi-setup.sh.
IFACE=wlan0
REBOOT=$WIFI_WATCHDOG_REBOOT
WATCHCONF

    install_file /usr/local/sbin/ham-radio-pi-wifiwatch 0755 root:root <<'WIFIWATCH'
#!/usr/bin/env bash
#
# ham-radio-pi-wifiwatch --- keep the radio-end Pi on the network, and write
# down why it fell off.
#
# Every INTERVAL seconds it asks whether the Wi-Fi is really working: is the
# interface there, is it joined to a network, does it have an address, does
# the gateway answer. After CONFIRM failures in a row it treats it as an
# outage and does two things, in this order:
#
#   1. Records the evidence, BEFORE touching anything: the kernel's log, the
#      network manager's log, the link and address state, whether the network
#      can still be seen at all. Recovery destroys most of this, so it comes
#      first. One file per outage, in /var/log/ham-radio-pi/wifi-incidents/.
#
#   2. Recovers, in escalating steps, stopping at the first that works:
#        reassociate         ask the network manager to rejoin
#        restart-interface   Wi-Fi radio off and on again
#        reload-driver       unload and reload the Wi-Fi driver, which
#                            restarts its firmware
#        reboot              last resort, rate limited, and never within the
#                            first half hour after a boot
#
# Which step works is itself the diagnosis: a network manager that had given
# up is fixed by the first, a driver whose firmware has hung only by the
# third. `ham-radio-pi-wifiwatch --report` counts them.
#
# Settings are read from /etc/ham-radio-pi/wifiwatch.conf.
#
#   ham-radio-pi-wifiwatch            run (systemd does this)
#   ham-radio-pi-wifiwatch --report   what has happened so far
#   ham-radio-pi-wifiwatch --check    one health check, printed, then exit

set -u

IFACE=wlan0
INTERVAL=20                 # seconds between checks
CONFIRM=3                   # failures in a row before acting: about a minute
SETTLE=45                   # seconds to wait for each recovery step to work
REBOOT=yes                  # allow the last resort at all
MAX_REBOOTS_PER_DAY=3
MIN_UPTIME_FOR_REBOOT=1800  # a window after boot for a human, and no loops
RETRY_WHILE_DOWN=300        # after every step has failed, try again this often
KEEP_INCIDENTS=100
LOGDIR=/var/log/ham-radio-pi
STATEDIR=/var/lib/ham-radio-pi
SYSNET=/sys/class/net
CONF=/etc/ham-radio-pi/wifiwatch.conf

# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF"

LOG=$LOGDIR/wifi-watch.log
INCIDENTS=$LOGDIR/wifi-incidents
REBOOTS=$STATEDIR/wifiwatch-reboots

GATEWAY=""          # last IPv4 gateway seen, remembered across the outage
PING_TRUSTED=0      # the gateway has answered at least once: some never do
PROBLEM=""          # set by check(); empty means healthy
DRIVER=""           # the kernel module behind the interface

have() { command -v "$1" >/dev/null 2>&1; }

log() {
    printf '%s %s\n' "$(date -Is)" "$*" >> "$LOG"
    logger -t wifiwatch -- "$*" 2>/dev/null || true
}

# The driver is looked up while the interface exists, because a firmware hang
# can take the interface away and the name with it.
remember_driver() {
    local mod
    mod=$(readlink -f "$SYSNET/$IFACE/device/driver/module" 2>/dev/null) || true
    if [ -n "$mod" ]; then DRIVER=$(basename "$mod"); fi
}

# --------------------------------------------------------------------------
# Is it working?
# --------------------------------------------------------------------------

# Sets PROBLEM to "<class>: <detail>", or to "" when the link is healthy. The
# class names the layer that failed, which is the first clue to why.
check() {
    local v4 v6 gw
    PROBLEM=""

    if [ ! -e "$SYSNET/$IFACE" ]; then
        PROBLEM="no-interface: $IFACE has disappeared (driver or firmware)"
        return
    fi
    remember_driver

    if ! iw dev "$IFACE" link 2>/dev/null | grep -q '^Connected to'; then
        PROBLEM="not-associated: not joined to any network (operstate=$(cat "$SYSNET/$IFACE/operstate" 2>/dev/null))"
        return
    fi

    v4=$(ip -4 -o addr show dev "$IFACE" 2>/dev/null | awk '{print $4; exit}')
    v6=$(ip -6 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4; exit}')
    if [ -z "$v4" ] && [ -z "$v6" ]; then
        PROBLEM="no-address: joined the network but has no IP address (DHCP)"
        return
    fi
    if [ -z "$v4" ] && [ -n "$GATEWAY" ]; then
        PROBLEM="lost-ipv4: IPv4 lease gone, IPv6 only ($v6)"
        return
    fi

    gw=$(ip -4 route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}')
    if [ -n "$gw" ]; then GATEWAY=$gw; fi
    if [ -z "$GATEWAY" ]; then return; fi

    # Two tries: one lost ping on a busy network is not an outage.
    if ping -c1 -W2 -I "$IFACE" "$GATEWAY" >/dev/null 2>&1 ||
       ping -c1 -W3 -I "$IFACE" "$GATEWAY" >/dev/null 2>&1; then
        PING_TRUSTED=1
    elif [ "$PING_TRUSTED" = 1 ]; then
        PROBLEM="gateway-silent: joined, with an address, but $GATEWAY stopped answering"
    fi
    # A gateway that has never answered is one that ignores pings, not a
    # fault; it is simply not used as evidence.
}

wait_healthy() { # wait_healthy <seconds>
    local deadline=$(( $(date +%s) + $1 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        check
        if [ -z "$PROBLEM" ]; then return 0; fi
        sleep 5
    done
    return 1
}

# --------------------------------------------------------------------------
# Evidence
# --------------------------------------------------------------------------

section() { printf '\n----- %s\n' "$*"; }

capture() { # capture <file> <problem>
    {
        printf '===== Wi-Fi outage on %s\n' "$(hostname)"
        printf 'detected: %s\n' "$(date -Is)"
        printf 'problem:  %s\n' "$2"
        printf 'uptime:   %s\n' "$(uptime)"
        printf 'driver:   %s\n' "${DRIVER:-unknown}"

        section "interface"
        ip addr show dev "$IFACE" 2>&1
        section "routes"
        ip route 2>&1; ip -6 route 2>&1
        section "link (iw)"
        iw dev "$IFACE" link 2>&1
        iw dev "$IFACE" info 2>&1
        section "power save"
        iw dev "$IFACE" get power_save 2>&1
        section "/proc/net/wireless"
        cat /proc/net/wireless 2>&1
        section "rfkill"
        rfkill list 2>&1

        if have nmcli; then
            section "NetworkManager: devices"
            nmcli device status 2>&1
            section "NetworkManager: $IFACE"
            nmcli -f GENERAL,WIFI-PROPERTIES,IP4,IP6 device show "$IFACE" 2>&1
            section "NetworkManager: connections"
            nmcli -f NAME,TYPE,DEVICE,ACTIVE,AUTOCONNECT,AUTOCONNECT-RETRIES connection show 2>&1
        fi

        section "power supply (vcgencmd get_throttled; 0x0 is clean)"
        vcgencmd get_throttled 2>&1 || echo "vcgencmd not available"
        section "temperature"
        cat /sys/class/thermal/thermal_zone0/temp 2>&1
        section "wireless kernel modules"
        lsmod 2>&1 | grep -iE 'brcm|cfg80211|mac80211' || true

        # The kernel ring buffer is in memory and survives a volatile journal,
        # but not a driver reload; this is the moment to take it.
        section "kernel messages (last 200)"
        dmesg -T 2>&1 | tail -200
        section "NetworkManager and wpa_supplicant, last 30 minutes"
        journalctl -b --since "-30min" --no-pager \
            -u NetworkManager -u wpa_supplicant 2>&1 | tail -200

        # Can it still see the network it lost? Distinguishes "the access
        # point went away or changed channel" from "it is there and we will
        # not rejoin". Scanning needs the interface up, so this may fail.
        section "scan: networks visible now"
        timeout 20 iw dev "$IFACE" scan 2>&1 \
            | grep -E '^BSS|SSID:|signal:|DS Parameter set|freq:' | head -60
    } > "$1" 2>&1
}

prune_incidents() {
    ls -1t "$INCIDENTS"/*.log 2>/dev/null | tail -n +$((KEEP_INCIDENTS + 1)) | xargs -r rm -f
}

# --------------------------------------------------------------------------
# Recovery
# --------------------------------------------------------------------------

nm_connect() {
    if have nmcli; then nmcli --wait 30 device connect "$IFACE" 2>&1; fi
}

step_reassociate() {
    # Rejoining resets NetworkManager's own bookkeeping, including its
    # decision to stop retrying a connection that failed a few times -- the
    # commonest reason Wi-Fi goes down and stays down.
    if have nmcli; then
        nm_connect
    elif have wpa_cli; then
        wpa_cli -i "$IFACE" reassociate 2>&1
    fi
}

step_restart_interface() {
    if have nmcli; then
        nmcli radio wifi off 2>&1; sleep 3
        nmcli radio wifi on 2>&1;  sleep 5
        nm_connect
    else
        ip link set "$IFACE" down 2>&1; sleep 3
        ip link set "$IFACE" up 2>&1
    fi
}

step_reload_driver() {
    local drv=${DRIVER:-brcmfmac} m
    echo "reloading driver $drv"
    # Vendor helper modules (brcmfmac_wcc, brcmfmac_cyw ...) hold a reference
    # to the main one and must go first.
    for m in $(lsmod | awk -v d="$drv" '$1 != d && index($1, d "_") == 1 {print $1}'); do
        modprobe -r "$m" 2>&1
    done
    modprobe -r "$drv" 2>&1
    sleep 3
    modprobe "$drv" 2>&1
    sleep 10
    nm_connect
}

reboot_permitted() {
    local up now count
    if [ "$REBOOT" != yes ]; then
        log "  not rebooting: disabled in $CONF"
        return 1
    fi
    up=$(awk '{printf "%d", $1}' /proc/uptime)
    if [ "$up" -lt "$MIN_UPTIME_FOR_REBOOT" ]; then
        log "  not rebooting: up only ${up}s (waits until ${MIN_UPTIME_FOR_REBOOT}s)"
        return 1
    fi
    now=$(date +%s)
    count=$(awk -v n="$now" '$1 > n - 86400' "$REBOOTS" 2>/dev/null | wc -l)
    if [ "$count" -ge "$MAX_REBOOTS_PER_DAY" ]; then
        log "  not rebooting: already rebooted $count times in 24 hours"
        return 1
    fi
    return 0
}

handle_outage() {
    local start first incident step took
    start=$(date +%s)
    first=$PROBLEM
    incident="$INCIDENTS/$(date +%Y%m%d-%H%M%S).log"

    log "OUTAGE: $first"
    capture "$incident" "$first"
    log "  evidence: $incident"

    for step in reassociate restart-interface reload-driver; do
        log "  trying $step"
        printf '\n===== %s trying %s\n' "$(date -Is)" "$step" >> "$incident"
        "step_${step//-/_}" >> "$incident" 2>&1
        if wait_healthy "$SETTLE"; then
            took=$(( $(date +%s) - start ))
            log "RECOVERED by $step after ${took}s -- cause was $first"
            {
                printf '\n===== %s RECOVERED by %s after %ss\n' "$(date -Is)" "$step" "$took"
                iw dev "$IFACE" link 2>&1
                ip -4 addr show dev "$IFACE" 2>&1
            } >> "$incident"
            prune_incidents
            return
        fi
        printf '===== still down: %s\n' "$PROBLEM" >> "$incident"
    done

    # Nothing brought it back. Reboot if allowed; otherwise keep trying,
    # quietly, into the same incident file rather than a new one each time.
    while :; do
        if reboot_permitted; then
            log "REBOOTING: every recovery step failed -- cause was $first"
            printf '\n===== %s REBOOTING\n' "$(date -Is)" >> "$incident"
            date +%s >> "$REBOOTS"
            sync
            systemctl reboot
            sleep 120
        fi
        log "  still down; trying again in ${RETRY_WHILE_DOWN}s"
        sleep "$RETRY_WHILE_DOWN"
        check
        if [ -z "$PROBLEM" ]; then
            log "RECOVERED on its own after $(( $(date +%s) - start ))s -- cause was $first"
            return
        fi
        printf '\n===== %s retrying reload-driver (%s)\n' "$(date -Is)" "$PROBLEM" >> "$incident"
        step_reload_driver >> "$incident" 2>&1
        if wait_healthy "$SETTLE"; then
            log "RECOVERED by reload-driver (retry) after $(( $(date +%s) - start ))s -- cause was $first"
            return
        fi
    done
}

# --------------------------------------------------------------------------

report() {
    if [ ! -r "$LOG" ]; then echo "No log yet at $LOG."; exit 0; fi

    echo "== Outages, by what failed =="
    grep ' OUTAGE: ' "$LOG" | sed 's/.* OUTAGE: //; s/:.*//' | sort | uniq -c | sort -rn \
        | sed 's/^/  /' | grep . || echo "  none"

    echo
    echo "== What brought it back =="
    grep ' RECOVERED ' "$LOG" | sed 's/.* RECOVERED //; s/ after.*//; s/^by //' \
        | sort | uniq -c | sort -rn | sed 's/^/  /' | grep . || echo "  nothing yet"
    local n
    n=$(grep -c ' REBOOTING' "$LOG" 2>/dev/null || true)
    echo "  reboot: ${n:-0}"

    echo
    echo "== The last 15 events =="
    grep -E ' (OUTAGE|RECOVERED|REBOOTING|started)' "$LOG" | tail -15 | sed 's/^/  /'

    echo
    echo "== Evidence files, newest first =="
    ls -1t "$INCIDENTS"/*.log 2>/dev/null | head -10 | sed 's/^/  /' || echo "  none"
    cat <<'EOF'

Reading it:
  not-associated, fixed by reassociate   the network manager had given up
                                         rejoining, or the router dropped it
  not-associated, fixed by reload-driver the Wi-Fi firmware had stopped
  no-interface                           driver or firmware crash
  no-address                             joined, but DHCP failed: look at
                                         the router
  gateway-silent                         joined with an address but traffic
                                         stopped: firmware, or interference
Each evidence file begins with the kernel's messages at the moment of failure.
EOF
}

main() {
    mkdir -p "$INCIDENTS" "$STATEDIR"
    local fails=0
    remember_driver
    log "started: watching $IFACE every ${INTERVAL}s (driver ${DRIVER:-unknown}, reboot=$REBOOT)"
    while :; do
        check
        if [ -z "$PROBLEM" ]; then
            fails=0
        else
            fails=$((fails + 1))
            if [ "$fails" -ge "$CONFIRM" ]; then
                handle_outage
                fails=0
            fi
        fi
        sleep "$INTERVAL"
    done
}

case "${1:-}" in
    --report) report ;;
    --check)  check; echo "${PROBLEM:-healthy}" ;;
    "")       main ;;
    *)        echo "usage: $0 [--report|--check]" >&2; exit 1 ;;
esac
WIFIWATCH

    install_file /etc/systemd/system/ham-radio-pi-wifiwatch.service <<'WATCHUNIT'
[Unit]
Description=ham-radio-pi Wi-Fi watchdog: reconnects, and records why it dropped
After=network.target NetworkManager.service
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=/usr/local/sbin/ham-radio-pi-wifiwatch
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
WATCHUNIT
    ok "wifi watch every 20s; last-resort reboot: $WIFI_WATCHDOG_REBOOT"
else
    if [ -f /etc/systemd/system/ham-radio-pi-wifiwatch.service ]; then
        systemctl disable --now ham-radio-pi-wifiwatch.service >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/ham-radio-pi-wifiwatch.service
        changed "removed    the Wi-Fi watchdog"
    fi
fi


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
# Trusting the server's certificate
# --------------------------------------------------------------------------
#
# A Mumble server generates its own certificate, which no authority has
# signed, so a client meeting it for the first time raises a modal dialog
# asking whether to trust it. At the operator's end somebody clicks yes. At
# the radio there is nobody, and no screen: the dialog opens on a display
# that exists only inside Xvfb, Mumble waits on it forever, and all that can
# be seen from outside is a client that runs and never connects.
#
# A client that already holds the server's certificate digest skips the
# question (ServerHandler::setSslErrors calls proceedAnyway), so the digest
# is put there in advance. It is the SHA-1 of the DER form of the
# certificate, lower case hex, which is what Mumble compares against.

# Every database Mumble might be using, one per line.
#
# Guessing this path is how an earlier version of this script went wrong.
# Mumble tries its base path, then Qt's DataLocation, then ~/.config/Mumble,
# then the home directory, and uses the first that already holds a database.
# Qt's DataLocation is <organization>/<application>, and Mumble sets both to
# "Mumble", so it is ~/.local/share/Mumble/Mumble -- one level deeper than it
# looks. Write to the wrong file and every step reports success while Mumble
# reads a different one.
#
# So find what is really there rather than predict it, and write to all of
# them. A path is only chosen when there is no database at all, and then it
# is the one Qt would pick.
mumble_db_paths() {
    local found
    found=$(find "$OP_HOME" -maxdepth 5 \( -name 'mumble.sqlite' -o -name '.mumble.sqlite' \) \
            2>/dev/null || true)
    if [ -n "$found" ]; then
        printf '%s\n' "$found"
    else
        printf '%s\n' "$OP_HOME/.local/share/Mumble/Mumble/mumble.sqlite"
    fi
}

trust_server_cert() {
    local db digest der waited=0 group
    group=$(id -gn "$OP_USER")

    # The server has to be listening before its certificate can be read.
    if have ss; then
        while [ "$waited" -lt 30 ]; do
            if ss -lnt 2>/dev/null | grep -q ":$MUMBLE_PORT "; then break; fi
            sleep 1
            waited=$((waited + 1))
        done
    else
        sleep 3
    fi

    # Kept in a file rather than a pipeline, so that "no certificate at all"
    # can be told apart from one that happens to hash. An empty pipeline
    # hashes to da39a3ee..., the SHA-1 of nothing, which looks like a
    # perfectly good digest and would be stored as one.
    # The || true matters too: under pipefail a refused connection here would
    # otherwise end the whole script.
    der=$(mktemp)
    echo | openssl s_client -connect "127.0.0.1:$MUMBLE_PORT" 2>/dev/null \
         | openssl x509 -outform DER > "$der" 2>/dev/null || true

    if [ ! -s "$der" ]; then
        rm -f "$der"
        warn "Could not read the Mumble server's certificate. The radio's client"
        warn "will stop on a dialog asking whether to trust it, which nothing"
        warn "here can answer. Check that $MS_SERVICE is running, then re-run."
        return 0
    fi

    digest=$(sha1sum < "$der" | awk '{print $1}')
    rm -f "$der"

    if ! printf '%s' "$digest" | grep -qE '^[0-9a-f]{40}$'; then
        warn "The server's certificate did not hash to anything usable."
        return 0
    fi

    if ! have sqlite3; then
        warn "sqlite3 is not installed; cannot pre-trust the server certificate."
        return 0
    fi

    local wrote=0
    while IFS= read -r db; do
        [ -n "$db" ] || continue
        install -d -o "$OP_USER" -g "$group" -m 0755 "$(dirname "$db")"
        if write_client_db "$db" "$digest"; then wrote=$((wrote + 1)); fi
    done <<< "$(mumble_db_paths)"

    if [ "$wrote" = 0 ]; then
        warn "Could not write to any of Mumble's databases."
    fi
}

# Put the answers to both of the dialogs nobody can click into one database.
write_client_db() {
    local db=$1 digest=$2 pw_sql

    # Written as the operator, so the file Mumble owns stays owned by them.
    if sudo -u "$OP_USER" sqlite3 "$db" \
        "CREATE TABLE IF NOT EXISTS \`cert\` (\`id\` INTEGER PRIMARY KEY AUTOINCREMENT, \`hostname\` TEXT, \`port\` INTEGER, \`digest\` TEXT);
         CREATE UNIQUE INDEX IF NOT EXISTS \`cert_host_port\` ON \`cert\`(\`hostname\`,\`port\`);
         REPLACE INTO \`cert\` (\`hostname\`,\`port\`,\`digest\`) VALUES ('127.0.0.1',$MUMBLE_PORT,'$digest');" 2>/dev/null
    then
        ok "trusted    ${digest:0:16}... in $db"
    else
        warn "Could not write the server certificate digest to $db."
        return 1
    fi

    # A server password is stored in the client's own database rather than
    # put in the mumble:// URL. Mumble fills an empty password in from there
    # (Database::fuzzyMatch), so the password stays out of the service file
    # and out of every process list on the machine.
    if [ -n "$MUMBLE_SERVER_PASSWORD" ]; then
        pw_sql=${MUMBLE_SERVER_PASSWORD//\'/\'\'}   # SQL doubles a quote
        if sudo -u "$OP_USER" sqlite3 "$db" \
            "CREATE TABLE IF NOT EXISTS \`servers\` (\`id\` INTEGER PRIMARY KEY AUTOINCREMENT, \`name\` TEXT, \`hostname\` TEXT, \`port\` INTEGER DEFAULT 64738, \`username\` TEXT, \`password\` TEXT);
             DELETE FROM \`servers\` WHERE \`hostname\`='127.0.0.1' AND \`port\`=$MUMBLE_PORT AND \`username\`='$MUMBLE_RADIO_USER';
             INSERT INTO \`servers\` (\`name\`,\`hostname\`,\`port\`,\`username\`,\`password\`) VALUES ('${PI_HOSTNAME}','127.0.0.1',$MUMBLE_PORT,'$MUMBLE_RADIO_USER','$pw_sql');" 2>/dev/null
        then
            ok "stored     the server password for the radio's client"
        else
            warn "Could not store the server password in $db. The client will"
            warn "stop on a password dialog that nothing here can answer."
        fi
    fi
    return 0
}

# --------------------------------------------------------------------------
# Start everything
# --------------------------------------------------------------------------

head_ "Starting the station"

systemctl daemon-reload
systemctl enable rigctld.service mumble-radio.service >/dev/null 2>&1 || true
if [ "$WIFI_WATCHDOG" = yes ]; then
    systemctl enable ham-radio-pi-wifiwatch.service >/dev/null 2>&1 || true
    systemctl restart ham-radio-pi-wifiwatch.service || warn "the Wi-Fi watchdog did not start."
fi

systemctl restart "$MS_SERVICE" || warn "$MS_SERVICE did not start."
systemctl restart rigctld.service || warn "rigctld did not start."

# The radio's client will not connect until it trusts the server's
# certificate, and it cannot be asked. See trust_server_cert above.
trust_server_cert

systemctl restart mumble-radio.service || warn "mumble-radio did not start."

# The Mumble client waits five seconds for the server, and Mumble's Qt
# startup on a Zero 2W is not instant.
sleep 12

# "Running" is not the same as "connected": a Mumble stopped on a dialog no
# one can see, or one that cannot reach the server, is a live process that
# carries no audio. Wait for the client's own connection to appear.
say "waiting for the radio's client to reach the server"
CONNECTED=0
for _ in $(seq 1 20); do
    if have ss && ss -tn state established 2>/dev/null | grep -q ":$MUMBLE_PORT\b"; then
        CONNECTED=1; break
    fi
    sleep 3
done

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
if [ "$WIFI_WATCHDOG" = yes ]; then check_service ham-radio-pi-wifiwatch.service; fi
if [ -x "$RIGCTLD_BIN" ]; then ok "hamlib     $(hamlib_installed_version), $RIGCTLD_BIN"; fi

# Writing the digest somewhere is not the same as writing it where the
# client reads it. Ask the running process which file it actually opened.
verify_client_db() {
    local pid db fd target row
    pid=$(pgrep -x mumble 2>/dev/null | head -1) || true
    if [ -z "${pid:-}" ]; then return 0; fi
    for fd in /proc/"$pid"/fd/*; do
        target=$(readlink -f "$fd" 2>/dev/null) || continue
        case "$target" in
            *mumble.sqlite) db=$target; break ;;
        esac
    done
    if [ -z "${db:-}" ]; then return 0; fi
    row=$(sudo -u "$OP_USER" sqlite3 "$db" \
          "SELECT digest FROM cert WHERE hostname='127.0.0.1' AND port=$MUMBLE_PORT;" \
          2>/dev/null) || true
    if [ -n "$row" ]; then
        ok "verified   the client reads $db, and it holds the digest"
    else
        warn "The client has this database open:"
        warn "  $db"
        warn "and it does NOT hold the server's certificate digest, which is"
        warn "why it will not connect. Any other mumble.sqlite on this machine"
        warn "is a stray and can be deleted."
        FAILED=1
    fi
}
verify_client_db

RESTARTS=$(systemctl show -p NRestarts --value mumble-radio.service 2>/dev/null || echo 0)
if [ "${RESTARTS:-0}" -gt 1 ]; then
    warn "the Mumble client has restarted ${RESTARTS} times already, so it is"
    warn "starting and dying. journalctl -u mumble-radio -n 40 says why; a"
    warn "missing sound device is the usual reason."
    FAILED=1
fi

# Hamlib model 2 is "NET rigctl": rigctl talking to rigctld, which is exactly
# what the operator's Emacs does.
if FREQ=$(timeout 10 "$RIGCTL_BIN" -m 2 -r "127.0.0.1:$RIGCTLD_PORT" f 2>/dev/null); then
    ok "radio      answered: $FREQ Hz"
else
    warn "rigctld is up but the radio did not answer."
    warn "Check that it is switched on, on the right serial speed, and set to"
    warn "the CAT protocol Hamlib model $RIG_MODEL expects."
    FAILED=1
fi

if have ss && ss -lnt 2>/dev/null | grep -q ":$MUMBLE_PORT "; then
    ok "listening  Mumble server on port $MUMBLE_PORT"
else
    warn "Nothing is listening on Mumble's port $MUMBLE_PORT."
    FAILED=1
fi

if [ "$CONNECTED" = 1 ]; then
    ok "connected  the radio's client is on the server, so audio can flow"
else
    warn "The Mumble client is running but never reached the server, so no"
    warn "audio will pass. The last of its log:"
    journalctl -u mumble-radio.service -n 20 --no-pager 2>/dev/null | sed 's/^/     /' >&2 || true
    warn ""
    warn "Run it by hand to see what it says:"
    warn "  sudo systemctl stop mumble-radio"
    warn "  sudo -u $OP_USER HOME=$OP_HOME $MUMBLE_EXEC"
    warn ""
    warn "\"Could not load the Qt platform plugin\" means a missing library:"
    warn "  sudo apt install --reinstall mumble"
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
   Hamlib       $(hamlib_installed_version) -- ${HAMLIB_WANTED_WHY:-}
   Mumble       port $MUMBLE_PORT, TCP and UDP, up to $MUMBLE_USERS clients
   Radio client joins as "$MUMBLE_RADIO_USER", transmitting continuously
   Audio        in $AUDIO_CAPTURE
                out $AUDIO_PLAYBACK
   Reachable at ${PI_HOSTNAME}.local${IP:+ / $IP}
   Wi-Fi watch  $WIFI_WATCHDOG (last-resort reboot: $WIFI_WATCHDOG_REBOOT)
                after an outage:  sudo ham-radio-pi-wifiwatch --report

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
