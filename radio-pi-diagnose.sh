#!/usr/bin/env bash
#
# radio-pi-diagnose.sh --- why the radio's Mumble client is not connecting.
#
# Read-only: it changes nothing. Run it as root on the Pi, with the services
# running, and send the whole output.
#
#     sudo bash radio-pi-diagnose.sh
#
# The question it answers is the one that cannot be answered from anywhere
# else: which database the running client actually has open, and whether the
# server's certificate digest is in that database under the name and port the
# client is using.

set -uo pipefail

CONF=/etc/ham-radio-pi/setup.conf
OP_USER=radio
MUMBLE_PORT=64738

if [ -f "$CONF" ]; then
    # shellcheck source=/dev/null
    . "$CONF"
fi
OP_HOME=$(getent passwd "$OP_USER" | cut -d: -f6)
OP_HOME=${OP_HOME:-/home/$OP_USER}

rule() { printf '\n== %s ==\n' "$*"; }

rule "Versions"
mumble --version 2>&1 | head -2
dpkg-query -W -f='${Package} ${Version}\n' mumble mumble-server libhamlib-utils 2>/dev/null

rule "Services"
systemctl is-active mumble-server rigctld mumble-radio 2>&1 | paste -d' ' \
    <(printf 'mumble-server\nrigctld\nmumble-radio\n') - 2>/dev/null \
    || systemctl is-active mumble-server rigctld mumble-radio

rule "What the client is told to do"
grep -E '^(ExecStart|Environment|User)=' /etc/systemd/system/mumble-radio.service

rule "Its audio devices"
sed -n '/^\[alsa\]/,/^\[/p' "$OP_HOME/.config/Mumble/Mumble.conf" 2>/dev/null \
    | grep -E '^(input|output)=' || echo "no [alsa] section found"

rule "Every Mumble database on this machine"
find "$OP_HOME" -maxdepth 6 \( -name 'mumble.sqlite' -o -name '.mumble.sqlite' \) \
     -printf '%T+  %-10u  %10s  %p\n' 2>/dev/null || echo "none found"

rule "Which one the RUNNING client has open"
PID=$(pgrep -x mumble | head -1)
if [ -z "$PID" ]; then
    echo "mumble is not running"
else
    echo "mumble pid $PID"
    # /proc is always there, unlike lsof.
    for fd in /proc/"$PID"/fd/*; do
        target=$(readlink -f "$fd" 2>/dev/null) || continue
        case "$target" in
            *sqlite*) echo "  OPEN: $target" ;;
        esac
    done
fi

rule "The server's certificate, as a client sees it now"
DER=$(mktemp)
echo | openssl s_client -connect "127.0.0.1:$MUMBLE_PORT" 2>/dev/null \
     | openssl x509 -outform DER > "$DER" 2>/dev/null || true
if [ -s "$DER" ]; then
    WANT=$(sha1sum < "$DER" | awk '{print $1}')
    echo "port $MUMBLE_PORT digest: $WANT"
    openssl x509 -inform DER -in "$DER" -noout -subject -dates 2>/dev/null
else
    WANT=""
    echo "could not read a certificate from 127.0.0.1:$MUMBLE_PORT"
fi
rm -f "$DER"

rule "What each database says about that server"
if ! command -v sqlite3 >/dev/null 2>&1; then
    echo "sqlite3 is not installed -- apt install sqlite3 and run this again"
else
    while IFS= read -r db; do
        [ -n "$db" ] || continue
        echo "--- $db"
        sqlite3 "$db" \
            "SELECT hostname, port, digest FROM cert;" 2>&1 \
            | sed 's/^/    /' || true
        rows=$(sqlite3 "$db" "SELECT digest FROM cert WHERE hostname='127.0.0.1' AND port=$MUMBLE_PORT;" 2>/dev/null)
        if [ -n "$WANT" ]; then
            if [ "$rows" = "$WANT" ]; then
                echo "    => MATCHES the running server"
            elif [ -z "$rows" ]; then
                echo "    => no row for 127.0.0.1:$MUMBLE_PORT"
            else
                echo "    => MISMATCH: stored $rows, server is $WANT"
            fi
        fi
    done < <(find "$OP_HOME" -maxdepth 6 \( -name 'mumble.sqlite' -o -name '.mumble.sqlite' \) 2>/dev/null)
fi

rule "The client's own certificate"
ls -l "$OP_HOME/Documents/MumbleAutomaticCertificateBackup.p12" 2>/dev/null \
    || echo "no certificate backup file"
sed -n '/^\[net\]/,/^\[/p' "$OP_HOME/.config/Mumble/Mumble.conf" 2>/dev/null \
    | grep -c '^certificate=' | sed 's/^/certificate stored in Mumble.conf: /'

rule "Client log, last 25 lines"
journalctl -u mumble-radio -n 25 --no-pager 2>&1 | tail -25

rule "Server log, last 15 lines"
tail -15 /var/log/mumble-server/mumble-server.log 2>/dev/null \
    || echo "no server log at /var/log/mumble-server/mumble-server.log"

printf '\n== end ==\n\n'
