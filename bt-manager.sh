#!/bin/bash
PREF_FILE="/home/pi/.config/bt-preferred.conf"
LOG_FILE="/var/log/bt-manager.log"

# Pointe pactl/pulseaudio vers la session PulseAudio réelle de l'utilisateur
# pi (déjà lancée à la connexion), au lieu d'en créer une jetable dans /tmp.
export XDG_RUNTIME_DIR="/run/user/$(id -u pi)"

# Serveur de synthèse vocale Piper TTS (dépôt raspberry_test_synthese_vocale,
# service systemd --user piper-tts.service). Voir son INSTRUCTIONS_IA.md pour
# le protocole et les règles d'écriture d'un texte qui se synthétise bien.
TTS_SOCKET_PATH="${TTS_SOCKET_PATH:-/tmp/piper_tts.sock}"

# speak <fast|read> <texte> : envoie le texte au serveur Piper TTS via son
# socket Unix. Retourne un code non nul si le serveur n'est pas joignable ou
# a répondu une erreur, pour permettre un repli côté appelant.
speak() {
    local mode="$1" text="$2"
    python3 - "$TTS_SOCKET_PATH" "$mode" "$text" <<'PYEOF' 2>/dev/null
import json
import socket
import sys

sock_path, mode, text = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.connect(sock_path)
        s.sendall((json.dumps({"mode": mode, "text": text}) + "\n").encode("utf-8"))
        resp = s.makefile("r").readline()
    data = json.loads(resp) if resp else {}
    sys.exit(0 if data.get("status") == "ok" else 1)
except OSError:
    sys.exit(1)
PYEOF
}

log() {
    echo "[bt-manager] $1" | tee -a "$LOG_FILE"
    logger -t bt-manager -- "$1"
}

# wait_for_pactl_object <cards|sinks> <nom> : attend qu'un objet PulseAudio
# apparaisse (jusqu'à 5s) avant d'agir dessus, plutôt que de tenter puis
# échouer sur un objet pas encore enregistré (ex: juste après une connexion
# Bluetooth ou un changement de profil de carte).
wait_for_pactl_object() {
    local kind="$1" name="$2"
    for attempt in 1 2 3 4 5; do
        pactl list "$kind" short | grep -q "$name" && return 0
        sleep 1
    done
    return 1
}

# retry_pactl <commande pactl...> : la présence d'une carte/d'un sink dans
# `pactl list` ne garantit pas que le transport audio interne (utilisé par
# set-card-profile/set-default-sink) est déjà prêt juste après une connexion
# Bluetooth. On réessaie donc la commande elle-même jusqu'à 5 fois plutôt que
# de se fier uniquement à wait_for_pactl_object.
retry_pactl() {
    for attempt in 1 2 3 4 5; do
        "$@" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

trap 'log "Arrêt demandé par systemd — bt-manager se termine proprement."; exit 0' TERM

# Compteur d'échecs de connexion consécutifs par MAC, pour repérer le cas
# "l'enceinte est bien détectée au scan mais refuse la connexion à
# répétition" — signature typique d'une enceinte multipoint (ex: Bose Flex
# SoundLink, limitée à 2 appareils connectés simultanément) déjà pleine.
declare -A CONNECT_FAILS
CONNECT_FAIL_HINT_THRESHOLD=3

log "bt-manager démarré."
log "DEBUG: PATH=$PATH"
log "DEBUG: test bluetoothctl=$(which bluetoothctl)"
log "DEBUG: test hciconfig=$(which hciconfig)"

# PulseAudio
pulseaudio --start
sleep 2
# module-bluetooth-discover charge et gère lui-même les profils/la politique
# Bluetooth ; les modules séparés module-bluetooth-profiles/-policy n'existent
# plus dans les versions récentes de PulseAudio.
pactl list modules short | grep -q module-bluetooth-discover || pactl load-module module-bluetooth-discover
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
    while read -r RAW_LINE; do
        # Retirer tout commentaire inline (# et ce qui suit), puis les espaces de bord
        MAC=$(echo "$RAW_LINE" | sed 's/#.*//' | xargs)
        [[ "$MAC" =~ ^#.*$ || -z "$MAC" ]] && continue

        # Le scan bluetoothctl (LE par défaut sur ce système) ne détecte pas
        # toujours l'interface BR/EDR classique d'une enceinte déjà appairée
        # — hors LE, l'absence dans $DEVICES n'est donc pas fiable pour
        # décider de tenter ou non la connexion. Une connexion Bluetooth
        # classique se fait par page scan et ne nécessite pas d'avoir été
        # détectée par un inquiry scan au préalable : on tente toujours la
        # connexion directement, scan ou pas.
        if echo "$DEVICES" | grep -qi "$MAC"; then
            log "Enceinte préférée détectée au scan : $MAC"
        else
            log "DEBUG: MAC préférée $MAC non détectée au scan — tentative de connexion directe quand même"
        fi
        bluetoothctl connect $MAC
        sleep 3
        if bluetoothctl info $MAC | grep -q "Connected: yes"; then
            log "Connexion réussie : $MAC"
            CARD="bluez_card.${MAC//:/_}"
            SINK="bluez_sink.${MAC//:/_}.a2dp_sink"

            # La carte Bluetooth met quelques secondes à s'enregistrer
            # dans PulseAudio après la connexion.
            wait_for_pactl_object cards "$CARD" || log "DEBUG: carte $CARD absente après 5s"
            retry_pactl pactl set-card-profile "$CARD" a2dp-sink || log "DEBUG: échec set-card-profile pour $CARD"

            # Le sink A2DP, lui, n'apparaît qu'après le changement de
            # profil de la carte ci-dessus.
            wait_for_pactl_object sinks "$SINK" || log "DEBUG: sink $SINK absent après 5s"
            retry_pactl pactl set-default-sink "$SINK" || log "DEBUG: échec set-default-sink pour $SINK"

            # Changer le sink par défaut ne redirige pas les flux audio déjà
            # ouverts (ex: le process aplay persistant du serveur Piper TTS,
            # lancé une seule fois au démarrage de piper-tts.service contre
            # l'ancien sink par défaut) — PulseAudio ne les migre pas tout
            # seul vers un nouveau sink par défaut. On les déplace donc
            # explicitement, sans quoi la confirmation vocale se joue sans
            # erreur mais sur l'ancienne sortie audio, pas sur l'enceinte.
            pactl list short sink-inputs | while read -r INPUT_ID _; do
                pactl move-sink-input "$INPUT_ID" "$SINK" 2>/dev/null
            done

            log "Profil A2DP activé pour $MAC"
            CONNECT_FAILS[$MAC]=0

            # Confirmation vocale sur l'enceinte fraîchement connectée, via
            # le serveur Piper TTS local (mode "fast" : phrase courte).
            # Repli sur espeak-ng puis un bip si le serveur n'est pas joignable.
            if speak fast "Connexion à l'enceinte réussie."; then
                log "DEBUG: confirmation vocale jouée via Piper TTS"
            elif command -v espeak-ng >/dev/null 2>&1; then
                log "DEBUG: serveur Piper TTS indisponible, repli sur espeak-ng"
                TTS_WAV=$(mktemp --suffix=.wav)
                espeak-ng -v fr -w "$TTS_WAV" "Connexion à l'enceinte réussie" 2>/dev/null
                paplay --device="$SINK" "$TTS_WAV"
                rm -f "$TTS_WAV"
            elif [ -f /usr/share/sounds/alsa/Front_Center.wav ]; then
                paplay --device="$SINK" /usr/share/sounds/alsa/Front_Center.wav
            fi

            CONNECTED=true
            break
        else
            log "Échec de connexion à $MAC"
            CONNECT_FAILS[$MAC]=$(( ${CONNECT_FAILS[$MAC]:-0} + 1 ))
            if [ "${CONNECT_FAILS[$MAC]}" -ge "$CONNECT_FAIL_HINT_THRESHOLD" ]; then
                log "PISTE : $MAC refuse la connexion depuis ${CONNECT_FAILS[$MAC]} tentatives consécutives — vérifier si l'enceinte a déjà atteint sa limite d'appareils connectés simultanément (multipoint, souvent 2 max sur ce type d'enceinte). Déconnecter un appareil déjà connecté à l'enceinte puis réessayer."
            fi
        fi
    done < "$PREF_FILE"

    if [ "$CONNECTED" = true ]; then
        log "Surveillance de la connexion à $MAC"
        # Un pic de charge CPU (ex: démarrage de Kodi sur un Pi 3B) peut
        # ralentir D-Bus/bluetoothd le temps d'un cycle et faire échouer ce
        # check ponctuellement sans que l'enceinte soit réellement
        # déconnectée. On exige plusieurs échecs consécutifs avant de
        # déclarer la perte, pour éviter de relancer un scan Bluetooth actif
        # (perturbateur pour une connexion A2DP en cours sur ce chipset)
        # à cause d'un simple hoquet transitoire.
        CONSECUTIVE_FAILURES=0
        MAX_CONSECUTIVE_FAILURES=3
        while true; do
            if bluetoothctl info $MAC | grep -q "Connected: yes"; then
                CONSECUTIVE_FAILURES=0
                sleep 5
                continue
            fi

            CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
            log "DEBUG: vérification de connexion en échec pour $MAC (${CONSECUTIVE_FAILURES}/${MAX_CONSECUTIVE_FAILURES})"
            if [ "$CONSECUTIVE_FAILURES" -ge "$MAX_CONSECUTIVE_FAILURES" ]; then
                break
            fi
            sleep 2
        done
        log "Enceinte perdue : $MAC — tentative de reconnexion dans 10s"
        sleep 10
    else
        log "Aucune enceinte préférée trouvée — nouvelle tentative dans 10s"
        sleep 10
    fi
done
