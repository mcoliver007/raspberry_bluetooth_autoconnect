#!/bin/bash
PREF_FILE="/home/pi/.config/bt-preferred.conf"
LOG_FILE="/var/log/bt-manager.log"

log() {
    echo "[bt-manager] $1" | tee -a "$LOG_FILE"
    logger -t bt-manager "$1"
}

trap 'log "Arrêt demandé par systemd — bt-manager se termine proprement."; exit 0' TERM

log "bt-manager démarré."
log "DEBUG: PATH=$PATH"
log "DEBUG: test bluetoothctl=$(which bluetoothctl)"
log "DEBUG: test hciconfig=$(which hciconfig)"

# PulseAudio
pulseaudio --start
sleep 2
pactl load-module module-bluetooth-discover
pactl load-module module-bluetooth-profiles
pactl load-module module-bluetooth-policy
log "Modules PulseAudio Bluetooth chargés."

while true; do
    log "--------------------------------------------"
    log "Scan Bluetooth (via bluetoothctl)…"

    # État complet de HCI0
    log "DEBUG: état HCI0 avant scan :"
    /usr/bin/hciconfig hci0 | tee -a "$LOG_FILE"

    # Si HCI0 est DOWN → on le remonte
    if ! /usr/bin/hciconfig hci0 | grep -q "UP RUNNING"; then
        log "DEBUG: HCI0 DOWN — tentative de remise en route…"
        /usr/bin/hciconfig hci0 up
        sleep 1
        /usr/bin/hciconfig hci0 | tee -a "$LOG_FILE"
    fi

    # Vérifier si bluetoothd tourne
    log "DEBUG: état de bluetoothd :"
    systemctl status bluetooth | sed -n '1,20p' | tee -a "$LOG_FILE"

    # Vérifier si PulseAudio tourne
    log "DEBUG: état de PulseAudio :"
    pactl info | tee -a "$LOG_FILE"

    # Attendre que HCI0 soit UP
    while ! /usr/bin/hciconfig hci0 | grep -q "UP RUNNING"; do
        log "DEBUG: HCI0 toujours DOWN — attente…"
        sleep 1
    done

    log "DEBUG: lancement du scan bluetoothctl…"
    # bluetoothctl pilote bluetoothd directement (pas de conflit mgmt),
    # et son mode "scan on" écrit ligne par ligne même en pipe.
    stdbuf -oL -eL bluetoothctl --timeout 8 scan on >> "$LOG_FILE" 2>&1

    # Liste des appareils connus/vus par bluetoothd après le scan
    DEVICES=$(bluetoothctl devices)
    log "DEBUG: résultat brut du scan :"
    echo "$DEVICES" | tee -a "$LOG_FILE"

    if [ -z "$DEVICES" ]; then
        log "Scan Bluetooth vide (aucun appareil détecté)."
        sleep 5
        continue
    fi

    log "Appareils détectés :"
    IFS=$'\n'
    for line in $DEVICES; do
        # Format bluetoothctl: "Device XX:XX:XX:XX:XX:XX Nom de l'appareil"
        MAC=$(echo "$line" | awk '{print $2}')
        NAME=$(echo "$line" | cut -d' ' -f3-)
        [ -z "$NAME" ] && NAME="(sans nom)"
        log " - $MAC  ($NAME)"
    done

    CONNECTED=false
    # Lecture du fichier de préférences
    while read MAC; do
        [[ "$MAC" =~ ^#.*$ || -z "$MAC" ]] && continue
        log "DEBUG: test de la MAC préférée : $MAC"
        if echo "$DEVICES" | grep -qi "$MAC"; then
            log "Enceinte préférée détectée : $MAC"
            bluetoothctl connect $MAC
            sleep 3
            if bluetoothctl info $MAC | grep -q "Connected: yes"; then
                log "Connexion réussie : $MAC"
                pactl set-card-profile bluez_card.${MAC//:/_} a2dp-sink
                pactl set-default-sink bluez_sink.${MAC//:/_}.a2dp_sink
                log "Profil A2DP activé pour $MAC"
                CONNECTED=true
                break
            else
                log "Échec de connexion à $MAC"
            fi
        else
            log "DEBUG: MAC préférée $MAC non trouvée dans le scan"
        fi
    done < "$PREF_FILE"

    if [ "$CONNECTED" = true ]; then
        log "Surveillance de la connexion à $MAC"
        while bluetoothctl info $MAC | grep -q "Connected: yes"; do
            sleep 5
        done
        log "Enceinte perdue : $MAC — tentative de reconnexion dans 10s"
        sleep 10
    else
        log "Aucune enceinte préférée trouvée — nouvelle tentative dans 10s"
        sleep 10
    fi
done
