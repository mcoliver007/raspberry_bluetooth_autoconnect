#!/bin/bash
# Assistant interactif de première configuration d'une enceinte/casque Bluetooth :
# découverte -> sélection -> nettoyage -> appairage -> trust -> connexion -> essai sonore.
set -u

SCAN_DURATION=8

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "Commande manquante: $1"; exit 1; }
}

need_cmd bluetoothctl
need_cmd pactl
need_cmd mkfifo

# wait_for_pactl_object / retry_pactl : la présence d'une carte/d'un sink
# dans `pactl list` ne garantit pas que son transport audio interne est déjà
# prêt juste après une connexion Bluetooth (même logique que bt-manager.sh).
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

# BlueZ ne garde en mémoire un appareil découvert (mais pas encore appairé)
# que temporairement : peu après l'arrêt du scan, l'objet est purgé et
# bluetoothctl pair/trust/connect répondent "not available". On garde donc
# le scan actif en tâche de fond (transport bredr, plus fiable que "auto"
# pour l'interface classique d'une enceinte en mode pairing) pendant toute
# la sélection interactive, et on ne l'arrête qu'au moment de lancer le
# pairing sur l'appareil choisi, pour ne pas laisser de trou de latence.
BT_FIFO=$(mktemp -u)
mkfifo "$BT_FIFO"
exec 3<>"$BT_FIFO"
bluetoothctl >/dev/null 2>&1 <&3 &
BT_CTL_PID=$!
cleanup_scan() {
    exec 3>&- 2>/dev/null
    rm -f "$BT_FIFO"
}
stop_scan() {
    echo "scan off" >&3
    echo "quit" >&3
    wait "$BT_CTL_PID" 2>/dev/null
    cleanup_scan
}
trap 'stop_scan' EXIT

{
    echo "menu scan"
    echo "transport bredr"
    echo "back"
    echo "scan on"
} >&3

echo "=== Découverte Bluetooth (${SCAN_DURATION}s, transport classique BR/EDR) ==="
sleep "$SCAN_DURATION"

mapfile -t ALL_LINES < <(bluetoothctl devices | sort -u)

DEVICES=()
for line in "${ALL_LINES[@]}"; do
    MAC=$(echo "$line" | awk '{print $2}')
    NAME=$(echo "$line" | cut -d' ' -f3-)
    if [[ "$NAME" == LE-* ]]; then
        DEVICES+=("$MAC"$'\t'"$NAME"$'\t'"LE")
    else
        DEVICES+=("$MAC"$'\t'"$NAME"$'\t'"classique")
    fi
done

if [ "${#DEVICES[@]}" -eq 0 ]; then
    echo "Aucun appareil détecté."
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
    echo "Sélection invalide."
    exit 1
fi

IFS=$'\t' read -r MAC NAME KIND <<< "${DEVICES[$CHOICE]}"
echo "Appareil sélectionné : $MAC ($NAME) [$KIND]"

if [ "$KIND" = "LE" ]; then
    echo "Attention : interface LE sélectionnée, l'audio A2DP échouera probablement."
fi

# BlueZ purge un appareil temporaire (découvert mais pas encore appairé) dès
# que la découverte s'arrête, pas après un délai — le scan doit donc rester
# actif pendant tout le pairing, pas seulement pendant la sélection. Une
# fois l'appareil réellement appairé, il n'est plus "temporaire" et le scan
# peut être arrêté sans risque (géré par le trap EXIT en fin de script).

echo
echo "=== Nettoyage d'un éventuel appairage précédent ==="
# bluetoothctl remove supprime l'objet device quel qu'il soit, appairé ou
# non — l'appeler sans condition supprimerait l'objet fraîchement découvert
# qu'on vient de trouver (juste avant de tenter de le pairer !). On ne
# nettoie donc que s'il existe vraiment un appairage précédent à effacer.
if bluetoothctl info "$MAC" 2>/dev/null | grep -q "Paired: yes"; then
    bluetoothctl remove "$MAC" >/dev/null 2>&1
else
    echo "Aucun appairage précédent à nettoyer."
fi

echo
echo "=== Appairage ==="
bluetoothctl pair "$MAC"

echo
echo "=== Confiance (trust) ==="
bluetoothctl trust "$MAC"

echo
echo "=== Connexion ==="
# La connexion immédiatement après le pairing peut échouer une fois
# (org.bluez.Error.Failed) le temps que la résolution des services SDP
# se termine vraiment côté BlueZ — on réessaie donc plutôt que d'échouer
# sur le premier essai.
CONNECTED=false
for attempt in 1 2 3; do
    bluetoothctl connect "$MAC"
    sleep 3
    if bluetoothctl info "$MAC" | grep -q "Connected: yes"; then
        CONNECTED=true
        break
    fi
    echo "Nouvelle tentative de connexion ($attempt/3)…"
done

if [ "$CONNECTED" != true ]; then
    echo "Échec de connexion à $MAC."
    exit 1
fi

echo "Connexion réussie à $MAC."

# L'appareil est maintenant appairé/connecté (plus "temporaire"), le scan
# peut être arrêté sans risque de le faire purger par bluetoothd.
trap - EXIT
stop_scan

SINK="bluez_sink.${MAC//:/_}.a2dp_sink"

echo
echo "=== Sélection du profil A2DP et du sink audio ==="
CARD="bluez_card.${MAC//:/_}"

wait_for_pactl_object cards "$CARD" || echo "Carte $CARD absente après 5s d'attente."
retry_pactl pactl set-card-profile "$CARD" a2dp-sink || echo "Échec de set-card-profile pour $CARD."

wait_for_pactl_object sinks "$SINK" || echo "Sink $SINK absent après 5s d'attente."
retry_pactl pactl set-default-sink "$SINK" || echo "Échec de set-default-sink pour $SINK."

if ! pactl list sinks short | grep -q "$SINK"; then
    echo "Le sink audio '$SINK' n'apparaît pas dans PulseAudio."
    exit 1
fi

echo
echo "=== Essai sonore sur $NAME ==="
pactl set-sink-mute "$SINK" 0
pactl set-sink-volume "$SINK" 80%

if command -v speaker-test >/dev/null 2>&1; then
    speaker-test -D "pulse" -t sine -f 440 -c 2 -l 1
elif command -v paplay >/dev/null 2>&1 && [ -f /usr/share/sounds/alsa/Front_Center.wav ]; then
    paplay --device="$SINK" /usr/share/sounds/alsa/Front_Center.wav
else
    echo "Aucun outil d'essai sonore trouvé (speaker-test ou paplay)."
    exit 1
fi

echo
echo "Terminé. Si tu n'as rien entendu, vérifie le volume de l'enceinte elle-même."
