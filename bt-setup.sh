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

# On arrête le scan seulement maintenant, juste avant le pairing, pour
# laisser le moins de temps possible à bluetoothd pour purger l'objet
# éphémère de l'appareil choisi.
trap - EXIT
stop_scan

echo
echo "=== Nettoyage d'un éventuel appairage précédent ==="
bluetoothctl remove "$MAC" >/dev/null 2>&1

echo
echo "=== Appairage ==="
bluetoothctl pair "$MAC"

echo
echo "=== Confiance (trust) ==="
bluetoothctl trust "$MAC"

echo
echo "=== Connexion ==="
bluetoothctl connect "$MAC"
sleep 3

if ! bluetoothctl info "$MAC" | grep -q "Connected: yes"; then
    echo "Échec de connexion à $MAC."
    exit 1
fi

echo "Connexion réussie à $MAC."

SINK="bluez_sink.${MAC//:/_}.a2dp_sink"

echo
echo "=== Sélection du profil A2DP et du sink audio ==="
pactl set-card-profile "bluez_card.${MAC//:/_}" a2dp-sink 2>/dev/null
sleep 1
pactl set-default-sink "$SINK" 2>/dev/null

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
