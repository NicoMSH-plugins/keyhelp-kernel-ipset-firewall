#!/usr/bin/bash

# Quellen für Einzel-IPs und komplette Netz-Blöcke (CIDR)
ABUSE_URL="https://raw.githubusercontent.com/borestad/blocklist-abuseipdb/refs/heads/main/abuseipdb-s100-3d.ipv4"
NET_BLOCK_URL="https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset"

LOCAL_ABUSE="/root/banip/ipblocklist.txt"
LOCAL_NETS="/root/banip/netblocklist.txt"
CLEAN_FILE="/root/banip/clean_combined.txt"
SET_NAME="f2b-iplistblock"

# WICHTIG: timeout 604800 aktiviert die automatische Löschung nach genau 7 Tagen (604800 Sekunden)
# Falls das Set bereits ohne Timeout existiert, einmalig vorher 'ipset destroy f2b-iplistblock' ausführen.
/usr/sbin/ipset create "$SET_NAME" hash:net maxelem 1000000 timeout 604800 -exist 2>/dev/null

echo "$(date "+%Y-%m-%d %H:%M:%S") - Starte Import der Blocklisten (Einzel-IPs & Netze)..."

# 1. Listen herunterladen
/usr/bin/wget -q "$ABUSE_URL" -O "$LOCAL_ABUSE"
/usr/bin/wget -q "$NET_BLOCK_URL" -O "$LOCAL_NETS"

# 2. Bereinigen und Zusammenführen in eine gemeinsame temporäre Datei
> "$CLEAN_FILE"

# --- WICHTIG: Lokale DHCP-Broadcasts des Hosters erlauben ---
if ! /usr/sbin/iptables -C INPUT -p udp --sport 67 --dport 68 -j ACCEPT 2>/dev/null; then
    /usr/sbin/iptables -I INPUT 1 -p udp --sport 67 --dport 68 -j ACCEPT
fi
if ! /usr/sbin/iptables -C INPUT -p udp --sport 68 --dport 67 -j ACCEPT 2>/dev/null; then
    /usr/sbin/iptables -I INPUT 1 -p udp --sport 68 --dport 67 -j ACCEPT
fi

# --- Automatisch prüfen, ob iptables-Regel für das IPSet greift, sonst anlegen ---
if ! /usr/sbin/iptables -C INPUT -m set --match-set "$SET_NAME" src -j DROP 2>/dev/null; then
    /usr/sbin/iptables -I INPUT -m set --match-set "$SET_NAME" src -j DROP
fi

# AbuseIPDB bereinigen (Einzel-IPs)
if [ -f "$LOCAL_ABUSE" ] && [ -s "$LOCAL_ABUSE" ]; then
    /usr/bin/grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' "$LOCAL_ABUSE" >> "$CLEAN_FILE"
fi

# Loopback und private Netze ausschließen
if [ -f "$LOCAL_NETS" ] && [ -s "$LOCAL_NETS" ]; then
    /usr/bin/grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?' "$LOCAL_NETS" | grep -vE '^(127\.|172\.(1[6-9]|2[0-9]|3[0-1])\.)' >> "$CLEAN_FILE"
fi

# IPSet im Kernel befüllen, falls vorhanden
if /usr/sbin/ipset list "$SET_NAME" >/dev/null 2>&1; then
    
    # Vorherige Anzahl auslesen
    COUNT_BEFORE=$(/usr/sbin/ipset list "$SET_NAME" 2>/dev/null | grep "Number of entries:" | awk '{print $4}')
    [ -z "$COUNT_BEFORE" ] && COUNT_BEFORE=0
    
    TOTAL_IN_FILE=$(/usr/bin/wc -l < "$CLEAN_FILE")
    
    # Jede Zeile für ipset restore vorbereiten (inklusive Timeout-Wert für den Befehl)
    /usr/bin/sed -i "s/^/add $SET_NAME /" "$CLEAN_FILE"
    
    # Einlesen in den Kernel (-! ignoriert bereits vorhandene und aktualisiert deren Timeout)
    /usr/sbin/ipset restore -! < "$CLEAN_FILE"
    
    # Nachherige Anzahl ablesen
    COUNT_AFTER=$(/usr/sbin/ipset list "$SET_NAME" 2>/dev/null | grep "Number of entries:" | awk '{print $4}')
    [ -z "$COUNT_AFTER" ] && COUNT_AFTER=0
    
    ADDED_NOW=$((COUNT_AFTER - COUNT_BEFORE))
    
    if [ "$ADDED_NOW" -lt 0 ]; then
        # Wenn nach dem Hinzufügen der neue Total-Wert kleiner ist als vorher, 
        # bedeutet das, dass durch den Timeout (oder andere Bereinigungen) Einträge abgelaufen/entfernt wurden.
        REMOVED_COUNT=$(( -ADDED_NOW ))
        ADDED_NOW=0
    else
        REMOVED_COUNT=0
    fi

    SKIPPED=$((TOTAL_IN_FILE - ADDED_NOW))
    [ "$SKIPPED" -lt 0 ] && SKIPPED=0

    # --- Automatisch prüfen, ob iptables-Regel greift, sonst anlegen ---
    if ! /usr/sbin/iptables -C INPUT -m set --match-set "$SET_NAME" src -j DROP 2>/dev/null; then
        /usr/sbin/iptables -I INPUT -m set --match-set "$SET_NAME" src -j DROP
    fi

    echo "$(date "+%Y-%m-%d %H:%M:%S") - Kernel-IPSet erfolgreich aktualisiert."
    echo "   -> Gesamt in Liste: $TOTAL_IN_FILE"
    echo "   -> Neu eingetragen: $ADDED_NOW"
    echo "   -> Übersprungen (bereits vorhanden): $SKIPPED"
    echo "   -> Automatisch entfernt (abgelaufen): $REMOVED_COUNT"
    echo "   -> Total im Kernel: $COUNT_AFTER"
    
else
    echo "$(date "+%Y-%m-%d %H:%M:%S") - FEHLER: IPSet '$SET_NAME' existiert nicht."
fi

# 4. Aufräumen
/usr/bin/rm -f "$LOCAL_ABUSE" "$LOCAL_NETS" "$CLEAN_FILE"