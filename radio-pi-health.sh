#!/usr/bin/env bash
#
# radio-pi-health.sh --- one line of vital signs, once a minute, to a file
# that survives a lockup.
#
# A station that fails after several hours, apparently at random, will not be
# diagnosed by looking at it afterwards: whatever went wrong has already
# happened, and on this Pi the journal is kept in RAM and is gone. This writes
# the things that matter to disk as it goes, so the last line before the gap
# says what the machine was doing when it stopped.
#
#     sudo bash radio-pi-health.sh --install     # every minute, from now on
#     sudo bash radio-pi-health.sh --uninstall   # stop, once the fault is found
#     sudo bash radio-pi-health.sh               # write one line now
#     radio-pi-health.sh --report                # read the log back
#
# It writes about 100 bytes a minute, 140KB a day. That is more writing to the
# SD card than the station's own settings allow for, which is a fair trade
# while hunting a fault and worth undoing afterwards.

set -uo pipefail

LOG=/var/log/ham-radio-pi-health.log
UNIT=/etc/systemd/system/ham-radio-pi-health.service
TIMER=/etc/systemd/system/ham-radio-pi-health.timer

# --------------------------------------------------------------------------

collect() {
    local now uptime_s load mem_av swap_used temp throttled wifi sig services

    now=$(date -Is)
    uptime_s=$(awk '{printf "%d", $1}' /proc/uptime 2>/dev/null || echo 0)
    load=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo "?")

    # MemAvailable is the honest figure: free plus what can be reclaimed.
    mem_av=$(awk '/MemAvailable/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    swap_used=$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{printf "%d", (t-f)/1024}' \
                /proc/meminfo 2>/dev/null || echo 0)

    if [ -r /sys/class/thermal/thermal_zone0/temp ]; then
        temp=$(awk '{printf "%.1f", $1/1000}' /sys/class/thermal/thermal_zone0/temp)
    else
        temp="?"
    fi

    # The Pi's own account of its power supply. 0x0 is clean; bit 0 means the
    # voltage is low NOW, bit 16 means it has been low at some point since
    # boot. Undervoltage is the usual reason a Pi stops at random.
    if command -v vcgencmd >/dev/null 2>&1; then
        throttled=$(vcgencmd get_throttled 2>/dev/null | cut -d= -f2)
    else
        throttled="n/a"
    fi

    # Wi-Fi: is the link up at all, and how strong.
    wifi=$(cat /sys/class/net/wlan0/operstate 2>/dev/null || echo "none")
    if command -v iw >/dev/null 2>&1; then
        sig=$(iw dev wlan0 link 2>/dev/null | awk '/signal/ {print $2}')
        sig=${sig:-?}
    else
        sig="?"
    fi

    services=""
    for s in "mumble-server:server" "rigctld:rigctld" "mumble-radio:client"; do
        if systemctl is-active --quiet "${s%%:*}" 2>/dev/null; then
            services="${services}${services:+,}${s##*:}=up"
        else
            services="${services}${services:+,}${s##*:}=DOWN"
        fi
    done

    printf '%s up=%ss load=%s memfree=%sM swap=%sM temp=%sC throttled=%s wifi=%s/%sdBm %s\n' \
        "$now" "$uptime_s" "$load" "$mem_av" "$swap_used" "$temp" \
        "$throttled" "$wifi" "$sig" "$services"
}

install_timer() {
    [ "$(id -u)" = 0 ] || { echo "Run this with sudo." >&2; exit 1; }

    install -m 0755 "$0" /usr/local/sbin/radio-pi-health.sh

    cat > "$UNIT" <<UNITEOF
[Unit]
Description=ham-radio-pi vital signs

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/radio-pi-health.sh
UNITEOF

    cat > "$TIMER" <<TIMEREOF
[Unit]
Description=ham-radio-pi vital signs, every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
TIMEREOF

    touch "$LOG"
    chmod 0644 "$LOG"
    systemctl daemon-reload
    systemctl enable --now ham-radio-pi-health.timer

    # A marker, so a restart is obvious in the log.
    printf '%s ---- health logging started, uptime %ss ----\n' \
        "$(date -Is)" "$(awk '{printf "%d", $1}' /proc/uptime)" >> "$LOG"

    echo "Logging to $LOG, once a minute."
    echo "After a lockup:  sudo bash $0 --report"
}

uninstall_timer() {
    [ "$(id -u)" = 0 ] || { echo "Run this with sudo." >&2; exit 1; }
    systemctl disable --now ham-radio-pi-health.timer >/dev/null 2>&1
    rm -f "$UNIT" "$TIMER" /usr/local/sbin/radio-pi-health.sh
    systemctl daemon-reload
    echo "Stopped. $LOG is left where it is."
}

report() {
    [ -r "$LOG" ] || { echo "No log at $LOG yet." >&2; exit 1; }

    echo "== Restarts: uptime going backwards means it stopped and came back =="
    echo "   (the line BEFORE each one is the last thing it recorded)"
    awk '
        {
            up = 0
            for (i = 1; i <= NF; i++) if ($i ~ /^up=/) { v = $i; sub(/up=/, "", v); sub(/s$/, "", v); up = v + 0 }
            if (NR > 1 && up < lastup) printf "  ---- restarted ----\n  %s\n  %s\n", lastline, $0
            lastup = up; lastline = $0
        }
        END { if (NR < 2) print "  not enough data yet" }
    ' "$LOG"

    echo
    echo "== Any undervoltage ever seen =="
    grep -v 'throttled=0x0' "$LOG" | grep -v 'throttled=n/a' | tail -20 \
        || echo "  none recorded"

    echo
    echo "== Lowest free memory recorded =="
    awk '{for (i=1;i<=NF;i++) if ($i ~ /^memfree=/) {v=$i; sub(/memfree=/,"",v); sub(/M$/,"",v);
         if (min=="" || v+0 < min+0) {min=v; line=$0}}} END {print "  " min "M at:"; print "  " line}' "$LOG"

    echo
    echo "== Last 15 lines before now =="
    tail -15 "$LOG" | sed 's/^/  /'
}

case "${1:-}" in
    --install)   install_timer ;;
    --uninstall) uninstall_timer ;;
    --report)    report ;;
    "")          collect >> "$LOG" 2>/dev/null || collect ;;
    *)           echo "usage: $0 [--install|--uninstall|--report]" >&2; exit 1 ;;
esac
