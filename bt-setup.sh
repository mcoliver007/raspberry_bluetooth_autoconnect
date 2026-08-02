#!/bin/bash
# Assistant interactif de configuration Bluetooth : diagnostics système,
# découverte, appairage (seulement si nécessaire), connexion, profil audio
# A2DP, essai sonore. Chaque étape vérifie son propre résultat et affiche
# un diagnostic clair en cas d'échec ou de conflit connu (agents
# bluetoothctl concurrents, PulseAudio jetable, ERTM désactivé, rfkill,
# limite multipoint...).
set -u

SCAN_DURATION=8
PAIR_TIMEOUT=15
CONNECT_TIMEOUT=10
CONNECT_ATTEMPTS=5

info() { echo "  . $*"; }
ok()   { echo "  [OK] $*"; }
warn() { echo "  [ATTENTION] $*"; }
fail() { echo "  [ERREUR] $*"; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || { fail "Commande manquante: $1"; exit 1; }
}

need_cmd bluetoothctl
need_cmd pactl
need_cmd mkfifo
need_cmd hciconfig

# Fixe la session PulseAudio ciblée par pactl à celle de l'utilisateur pi,
# plutôt que de dépendre de l'environnement de la session interactive
# (ex: SSH sans XDG_RUNTIME_DIR défini), qui peut faire spawn une instance
# PulseAudio jetable et instable au lieu de la vraie session persistante.
export XDG_RUNTIME_DIR="/run/user/$(id -u pi)"

echo "=== Diagnostics système ==="

# rfkill : le Bluetooth ne doit être bloqué ni matériellement ni logiciellement.
if command -v rfkill >/dev/null 2>&1; then
    if rfkill list bluetooth 2>/dev/null | grep -qiE "(Soft|Hard) blocked: yes"; then
        fail "Bluetooth bloqué par rfkill. Corrige avec: sudo rfkill unblock bluetooth"
        exit 1
    fi
    ok "rfkill : Bluetooth non bloqué"
else
    warn "rfkill absent, vérification ignorée"
fi

# hci0 doit être UP RUNNING, sinon rien n'est possible.
if ! hciconfig hci0 2>/dev/null | grep -q "UP RUNNING"; then
    warn "hci0 n'est pas UP — tentative de remise en route (sudo hciconfig hci0 up)"
    sudo hciconfig hci0 up 2>/dev/null
    sleep 1
    if ! hciconfig hci0 2>/dev/null | grep -q "UP RUNNING"; then
        fail "hci0 toujours down. Vérifie le contrôleur Bluetooth (dmesg, hciconfig -a)."
        exit 1
    fi
fi
ok "hci0 : UP RUNNING"

# bluetoothd doit tourner.
if ! systemctl is-active --quiet bluetooth; then
    fail "Le service bluetooth (bluetoothd) n'est pas actif : sudo systemctl start bluetooth"
    exit 1
fi
ok "bluetoothd : actif"

# Bug ERTM/L2CAP connu du contrôleur Bluetooth du Pi (avdtp_connect_cb
# Invalid exchange (52)) : corrigé par disable_ertm=Y dans
# /etc/modprobe.d/bluetooth.conf + reboot. On vérifie qu'il est bien actif.
if [ -r /sys/module/bluetooth/parameters/disable_ertm ]; then
    ERTM=$(cat /sys/module/bluetooth/parameters/disable_ertm)
    if [ "$ERTM" = "Y" ]; then
        ok "disable_ertm=Y (fix ERTM actif)"
    else
        warn "disable_ertm=$ERTM (attendu Y) — un bug L2CAP connu du Pi peut faire"
        warn "échouer l'A2DP (avdtp_connect_cb Invalid exchange). Voir README."
    fi
fi

if [ ! -d "$XDG_RUNTIME_DIR" ]; then
    warn "$XDG_RUNTIME_DIR n'existe pas — le linger systemd de pi est peut-être"
    warn "désactivé : sudo loginctl enable-linger pi"
fi

# Sans instance PulseAudio persistante déjà lancée (ex: bt-manager.service
# arrêté pour ce test manuel), les appels pactl ci-dessous déclenchent
# l'auto-spawn par défaut de PulseAudio : une instance jetable qui s'éteint
# dès qu'elle devient inactive, désenregistrant au passage son endpoint
# A2DP en plein milieu de la négociation. On démarre donc explicitement une
# instance persistante, comme le fait bt-manager.sh (no-op si déjà lancée).
pulseaudio --start 2>/dev/null
sleep 2
if ! pactl info >/dev/null 2>&1; then
    fail "Impossible de joindre PulseAudio (XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR)."
    exit 1
fi
SERVER_STRING=$(pactl info 2>/dev/null | awk -F': ' '/Server String/{print $2}')
if [[ "$SERVER_STRING" == /tmp/pulse-* ]]; then
    warn "PulseAudio tourne sur une instance jetable ($SERVER_STRING), pas la"
    warn "session persistante de pi — les flux audio risquent de se couper."
else
    ok "PulseAudio : $SERVER_STRING"
fi
pactl list modules short | grep -q module-bluetooth-discover || pactl load-module module-bluetooth-discover

# Deux agents bluetoothctl actifs en même temps peuvent se marcher dessus
# sur la confirmation SSP pendant un pairing (symptôme observé :
# AuthenticationCanceled/Failed intermittents). On garde tout le flux
# (scan + pair + trust + connect) dans une seule session ci-dessous, mais
# on ne peut rien faire contre un bluetoothctl externe déjà ouvert ailleurs
# — on se contente de prévenir.
EXISTING_BTCTL=$(pgrep -c bluetoothctl 2>/dev/null || echo 0)
if [ "$EXISTING_BTCTL" -gt 0 ]; then
    warn "$EXISTING_BTCTL processus bluetoothctl déjà en cours ailleurs — risque de"
    warn "conflit d'agent SSP si un pairing traîne. Ferme-les si le pairing échoue"
    warn "de façon suspecte (pkill bluetoothctl, en dehors de ce script)."
fi

echo

# wait_for_pactl_object / retry_pactl : la présence d'une carte/d'un sink
# dans `pactl list` ne garantit pas que son transport audio interne est déjà
# prêt juste après une connexion Bluetooth.
wait_for_pactl_object() {
    local kind="$1" name="$2"
    for attempt in 1 2 3 4 5; do
        pactl list "$kind" short | grep -q "$name" && return 0
        sleep 1
    done
    return 1
}

retry_pactl() {
    for attempt in 1 2 3 4 5; do
        "$@" 2>/dev/null && return 0
        sleep 1
    done
    return 1
}

# --- Session bluetoothctl unique, persistante, pour tout le flux ---
#
# BlueZ purge un appareil temporaire (découvert mais pas encore appairé) dès
# que la découverte s'arrête (pas après un délai) : le scan doit rester actif
# pendant tout le pairing, pas seulement pendant la sélection.
#
# Faire tourner pair/trust/connect via des invocations bluetoothctl séparées
# (une par commande) fait démarrer un nouvel agent par défaut à chaque fois,
# en plus de celui de la session de scan déjà active : deux agents
# concurrents peuvent se disputer la confirmation SSP, provoquant des
# AuthenticationCanceled/Failed intermittents. Toutes les commandes
# (scan, pair, trust, connect) passent donc par une seule et même session
# bluetoothctl persistante, pilotée via ce named pipe.
BT_FIFO=$(mktemp -u)
mkfifo "$BT_FIFO"
BT_LOG=$(mktemp)
exec 3<>"$BT_FIFO"
bluetoothctl <&3 >"$BT_LOG" 2>&1 &
BT_CTL_PID=$!

cleanup_bt() {
    exec 3>&- 2>/dev/null
    rm -f "$BT_FIFO" "$BT_LOG"
}
stop_bt_session() {
    echo "scan off" >&3 2>/dev/null
    echo "quit" >&3 2>/dev/null
    wait "$BT_CTL_PID" 2>/dev/null
    cleanup_bt
}
trap 'stop_bt_session' EXIT

# send_bt <commande> : envoie une commande à la session persistante.
send_bt() {
    echo "$*" >&3
}

# LOG_LINE_MARK : position dans BT_LOG à partir de laquelle chercher la
# réponse à la prochaine commande, pour ignorer le bruit des commandes
# précédentes lors d'un grep de motif de succès/échec.
LOG_LINE_MARK=0
mark_log() {
    LOG_LINE_MARK=$(wc -l < "$BT_LOG")
}

# send_and_wait <commande> <motif succès> <motif échec (grep -E, optionnel)> <timeout s>
# Renvoie 0 si le motif de succès apparaît, 1 si le motif d'échec apparaît
# en premier, 2 en cas de timeout. Affiche le contexte capturé en cas
# d'échec ou de timeout pour que l'utilisateur voie ce qui a bloqué.
send_and_wait() {
    local cmd="$1" success="$2" failure="$3" timeout="$4"
    local start deadline seen
    mark_log
    send_bt "$cmd"
    start=$(date +%s)
    deadline=$((start + timeout))
    while true; do
        seen=$(tail -n +"$((LOG_LINE_MARK + 1))" "$BT_LOG")
        if echo "$seen" | grep -q -- "$success"; then
            LOG_LINE_MARK=$(wc -l < "$BT_LOG")
            return 0
        fi
        if [ -n "$failure" ] && echo "$seen" | grep -qE -- "$failure"; then
            fail "$cmd a échoué :"
            echo "$seen" | sed 's/^/      /'
            LOG_LINE_MARK=$(wc -l < "$BT_LOG")
            return 1
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            fail "$cmd : pas de réponse claire après ${timeout}s :"
            echo "$seen" | sed 's/^/      /'
            LOG_LINE_MARK=$(wc -l < "$BT_LOG")
            return 2
        fi
        sleep 0.3
    done
}

# query_bt <commande> <délai s> : envoie une commande de lecture (info,
# devices...) à la session persistante et retourne sa sortie.
query_bt() {
    local cmd="$1" delay="${2:-2}"
    mark_log
    send_bt "$cmd"
    sleep "$delay"
    tail -n +"$((LOG_LINE_MARK + 1))" "$BT_LOG"
    LOG_LINE_MARK=$(wc -l < "$BT_LOG")
}

send_bt "menu scan"
send_bt "transport bredr"
send_bt "back"
send_bt "scan on"

echo "=== Découverte Bluetooth (${SCAN_DURATION}s, transport classique BR/EDR) ==="
sleep "$SCAN_DURATION"

mapfile -t ALL_LINES < <(query_bt "devices" 1 | grep '^Device ' | sort -u)

DEVICES=()
for line in "${ALL_LINES[@]}"; do
    [ -z "$line" ] && continue
    MAC=$(echo "$line" | awk '{print $2}')
    NAME=$(echo "$line" | cut -d' ' -f3-)
    if [[ "$NAME" == LE-* ]]; then
        DEVICES+=("$MAC"$'\t'"$NAME"$'\t'"LE")
    else
        DEVICES+=("$MAC"$'\t'"$NAME"$'\t'"classique")
    fi
done

if [ "${#DEVICES[@]}" -eq 0 ]; then
    fail "Aucun appareil détecté."
    exit 1
fi

echo
echo "Appareils détectés :"
for i in "${!DEVICES[@]}"; do
    IFS=$'\t' read -r MAC NAME KIND <<< "${DEVICES[$i]}"
    printf "  [%d] %s  (%s)  [%s]\n" "$i" "$MAC" "$NAME" "$KIND"
done
echo
echo "Note : seule l'interface [classique] permet l'audio A2DP. L'interface"
echo "[LE] est affichée à titre informatif (souvent un canal de contrôle"
echo "d'appli compagnon), la sélectionner échouera pour un usage audio."

echo
read -rp "Sélectionne le numéro de l'appareil à configurer : " CHOICE

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -ge "${#DEVICES[@]}" ]; then
    fail "Sélection invalide."
    exit 1
fi

IFS=$'\t' read -r MAC NAME KIND <<< "${DEVICES[$CHOICE]}"
echo "Appareil sélectionné : $MAC ($NAME) [$KIND]"

if [ "$KIND" = "LE" ]; then
    warn "Interface LE sélectionnée, l'audio A2DP échouera probablement."
fi

echo
echo "=== Appairage ==="
ALREADY_PAIRED=false
if query_bt "info $MAC" 2 | grep -q "Paired: yes"; then
    ALREADY_PAIRED=true
    ok "Déjà appairé — pairing/trust ignorés, connexion directe."
fi

if [ "$ALREADY_PAIRED" = false ]; then
    PAIR_OK=false
    for attempt in 1 2; do
        if send_and_wait "pair $MAC" "Pairing successful" \
            "(AuthenticationFailed|AuthenticationCanceled|AuthenticationRejected|org\.bluez\.Error)" \
            "$PAIR_TIMEOUT"; then
            PAIR_OK=true
            ok "Pairing réussi"
            break
        fi
        warn "Nouvelle tentative de pairing ($attempt/2)…"
        sleep 2
    done
    if [ "$PAIR_OK" = false ]; then
        fail "Pairing impossible après 2 tentatives."
        info "Pistes possibles : l'enceinte n'est plus en mode pairing (LED),"
        info "elle a déjà atteint sa limite d'appareils connectés (multipoint),"
        info "ou un autre bluetoothctl/agent interfère (voir avertissement plus haut)."
        exit 1
    fi

    if ! send_and_wait "trust $MAC" "trust succeeded" "org\.bluez\.Error" 5; then
        warn "trust n'a pas confirmé son succès, on continue quand même."
    else
        ok "Trust réussi"
    fi
fi

echo
echo "=== Connexion ==="
CONNECTED=false
for attempt in $(seq 1 "$CONNECT_ATTEMPTS"); do
    if send_and_wait "connect $MAC" "Connection successful" "org\.bluez\.Error" "$CONNECT_TIMEOUT"; then
        CONNECTED=true
        ok "Connexion réussie ($attempt/$CONNECT_ATTEMPTS)"
        break
    fi
    warn "Nouvelle tentative de connexion ($attempt/$CONNECT_ATTEMPTS)…"
    sleep 2
done

# Si l'appareil était déjà appairé mais refuse obstinément de se connecter,
# une clé de liaison obsolète peut être en cause : on tente un fallback
# remove + re-pair + reconnexion, une seule fois.
if [ "$CONNECTED" = false ] && [ "$ALREADY_PAIRED" = true ]; then
    warn "Connexion impossible malgré un appairage existant — tentative de"
    warn "nettoyage (clé de liaison potentiellement obsolète) et ré-appairage."
    send_bt "remove $MAC"
    sleep 1
    if send_and_wait "pair $MAC" "Pairing successful" \
        "(AuthenticationFailed|AuthenticationCanceled|AuthenticationRejected|org\.bluez\.Error)" \
        "$PAIR_TIMEOUT"; then
        send_and_wait "trust $MAC" "trust succeeded" "org\.bluez\.Error" 5 || true
        for attempt in $(seq 1 "$CONNECT_ATTEMPTS"); do
            if send_and_wait "connect $MAC" "Connection successful" "org\.bluez\.Error" "$CONNECT_TIMEOUT"; then
                CONNECTED=true
                ok "Connexion réussie après ré-appairage ($attempt/$CONNECT_ATTEMPTS)"
                break
            fi
            sleep 2
        done
    fi
fi

if [ "$CONNECTED" = false ]; then
    fail "Échec de connexion à $MAC après $CONNECT_ATTEMPTS tentatives."
    info "Pistes possibles : limite d'appareils connectés simultanément"
    info "(multipoint, souvent 2 max) — déconnecte un autre appareil de"
    info "l'enceinte et réessaie ; ou bug ERTM (voir diagnostic plus haut) ;"
    info "ou regarde journalctl -u bluetooth -n 50 pour le détail exact."
    exit 1
fi

# L'appareil est maintenant connecté (et appairé, donc plus "temporaire"),
# le scan peut être arrêté sans risque de le faire purger par bluetoothd.
trap - EXIT
stop_bt_session

SINK="bluez_sink.${MAC//:/_}.a2dp_sink"
CARD="bluez_card.${MAC//:/_}"

echo
echo "=== Sélection du profil A2DP et du sink audio ==="
wait_for_pactl_object cards "$CARD" || warn "Carte $CARD absente après 5s d'attente."
if retry_pactl pactl set-card-profile "$CARD" a2dp-sink; then
    ok "Profil a2dp-sink activé sur $CARD"
else
    warn "Échec de set-card-profile pour $CARD."
fi

wait_for_pactl_object sinks "$SINK" || warn "Sink $SINK absent après 5s d'attente."
if retry_pactl pactl set-default-sink "$SINK"; then
    ok "Sink par défaut : $SINK"
else
    warn "Échec de set-default-sink pour $SINK."
fi

# Changer le sink par défaut ne redirige pas les flux audio déjà ouverts
# (ex: le process aplay persistant d'un serveur TTS lancé bien avant cette
# connexion) — PulseAudio ne les migre pas tout seul vers un nouveau sink
# par défaut. On les déplace donc explicitement.
MOVED=0
while read -r INPUT_ID _; do
    [ -z "$INPUT_ID" ] && continue
    pactl move-sink-input "$INPUT_ID" "$SINK" 2>/dev/null && MOVED=$((MOVED + 1))
done < <(pactl list short sink-inputs)
[ "$MOVED" -gt 0 ] && info "$MOVED flux audio existant(s) déplacé(s) vers $SINK"

if ! pactl list sinks short | grep -q "$SINK"; then
    fail "Le sink audio '$SINK' n'apparaît pas dans PulseAudio."
    info "Vérifie : pactl list cards short / pactl list sinks short"
    exit 1
fi
ok "Sink audio confirmé dans PulseAudio"

echo
echo "=== Essai sonore sur $NAME ==="
pactl set-sink-mute "$SINK" 0
pactl set-sink-volume "$SINK" 80%

if command -v speaker-test >/dev/null 2>&1; then
    speaker-test -D "pulse" -t sine -f 440 -c 2 -l 1
elif command -v paplay >/dev/null 2>&1 && [ -f /usr/share/sounds/alsa/Front_Center.wav ]; then
    paplay --device="$SINK" /usr/share/sounds/alsa/Front_Center.wav
else
    fail "Aucun outil d'essai sonore trouvé (speaker-test ou paplay)."
    exit 1
fi

echo
echo "Terminé. Si tu n'as rien entendu, vérifie le volume de l'enceinte elle-même."
