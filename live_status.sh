#!/usr/bin/bash

STATUS_FILE="/root/banip/f2b_status.txt"
COUNTER_CACHE="/root/banip/.daily_bytes_start"
PERSIST_FILE="/root/banip/.persistent_total"
TODAY=$(date '+%Y-%m-%d')

# 1. IP-Anzahl auslesen
IP_COUNT=$(ipset list f2b-iplistblock 2>/dev/null | grep "Number of entries" | awk '{print $4}')
[ -z "$IP_COUNT" ] && IP_COUNT="0"

# 2. Pakete und Bytes exakt aus iptables auslesen (nur die erste Regel des IPSets)
IPTABLES_STATS=$(iptables -L INPUT -v -n -x | grep "f2b-iplistblock" | head -n 1)
CURRENT_PACKETS=$(echo "$IPTABLES_STATS" | awk '{print $1}')
CURRENT_BYTES=$(echo "$IPTABLES_STATS" | awk '{print $2}')

[ -z "$CURRENT_PACKETS" ] && CURRENT_PACKETS="0"
[ -z "$CURRENT_BYTES" ] && CURRENT_BYTES="0"

# --- PERSISTENZ-SICHERUNG (Überlebt Fail2Ban- & Server-Neustarts) ---
if [ ! -f "$PERSIST_FILE" ]; then
    echo "0|0|0|0" > "$PERSIST_FILE"
fi

SAVED_DATA=$(cat "$PERSIST_FILE")
OFFSET_BYTES=$(echo "$SAVED_DATA" | cut -d'|' -f1)
OFFSET_PACKETS=$(echo "$SAVED_DATA" | cut -d'|' -f2)
LAST_KERNEL_BYTES=$(echo "$SAVED_DATA" | cut -d'|' -f3)
LAST_KERNEL_PACKETS=$(echo "$SAVED_DATA" | cut -d'|' -f4)

[ -z "$OFFSET_BYTES" ] && OFFSET_BYTES=0
[ -z "$OFFSET_PACKETS" ] && OFFSET_PACKETS=0
[ -z "$LAST_KERNEL_BYTES" ] && LAST_KERNEL_BYTES=0
[ -z "$LAST_KERNEL_PACKETS" ] && LAST_KERNEL_PACKETS=0

# Wenn der Kernel-Zähler kleiner ist als beim letzten Mal, gab es einen Reset/Neustart!
if [ "$CURRENT_BYTES" -lt "$LAST_KERNEL_BYTES" ]; then
    OFFSET_BYTES=$((OFFSET_BYTES + LAST_KERNEL_BYTES))
    OFFSET_PACKETS=$((OFFSET_PACKETS + LAST_KERNEL_PACKETS))
fi

# Gesamtsummen (Aktueller Kernel-Wert + kumulierter Offset)
BYTES=$((CURRENT_BYTES + OFFSET_BYTES))
PACKETS=$((CURRENT_PACKETS + OFFSET_PACKETS))

# Für den nächsten Durchlauf speichern
echo "$OFFSET_BYTES|$OFFSET_PACKETS|$CURRENT_BYTES|$CURRENT_PACKETS" > "$PERSIST_FILE"
# -----------------------------------------------------------------

# 3. Tages-Zähler Logik (für die gelbe Box "Heute")
RAW_BYTES="$BYTES"

if [ ! -f "$COUNTER_CACHE" ] || [ "$(cat "$COUNTER_CACHE" | cut -d'|' -f1)" != "$TODAY" ]; then
    echo "$TODAY|$RAW_BYTES" > "$COUNTER_CACHE"
    DAILY_BYTES=0
else
    START_BYTES=$(cat "$COUNTER_CACHE" | cut -d'|' -f2)
    [ -z "$START_BYTES" ] && START_BYTES=0
    DAILY_BYTES=$((RAW_BYTES - START_BYTES))
    [ "$DAILY_BYTES" -lt 0 ] && DAILY_BYTES=0
fi

# Funktion zur sauberen Formatierung von reinen Byte-Zahlen
format_bytes() {
    local b="$1"
    [ -z "$b" ] || [ "$b" -eq 0 ] 2>/dev/null && echo "0 Bytes" && return

    if [ "$b" -ge 1073741824 ]; then
        awk "BEGIN {printf \"%.2f GB\", $b / 1073741824}"
    elif [ "$b" -ge 1048576 ]; then
        awk "BEGIN {printf \"%.2f MB\", $b / 1048576}"
    elif [ "$b" -ge 1024 ]; then
        awk "BEGIN {printf \"%.2f KB\", $b / 1024}"
    else
        echo "$b Bytes"
    fi
}

READABLE_TOTAL=$(format_bytes "$BYTES")
READABLE_DAILY=$(format_bytes "$DAILY_BYTES")

# 4. In die Status-Datei schreiben
echo "IPs: $IP_COUNT | Gesamt: $READABLE_TOTAL | Heute (ab 0 Uhr): $READABLE_DAILY (Pakete: $PACKETS) | Upd: $(date '+%H:%M:%S')" > "$STATUS_FILE"

# Direkt ins KeyHelp-Hauptverzeichnis kopieren
cp /root/banip/f2b_status.txt /home/keyhelp/www/keyhelp/f2b_status.txt
chmod 644 /home/keyhelp/www/keyhelp/f2b_status.txt