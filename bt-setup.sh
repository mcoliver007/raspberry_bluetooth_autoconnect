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

echo "=== Découverte des appareils Bluetooth (${SCAN_DURATION}s) ==="
stdbuf -oL -eL bluetoothctl --timeout "$SCAN_DURATION" scan on >/dev/null 2>&1

mapfile -t DEVICES < <(bluetoothctl devices | sort -u)

if [ "${#DEVICES[@]}" -eq 0 ]; then
    echo "Aucun appareil détecté."
    exit 1
fi

echo
echo "Appareils détectés :"
for i in "${!DEVICES[@]}"; do
    MAC=$(echo "${DEVICES[$i]}" | awk '{print $2}')
    NAME=$(echo "${DEVICES[$i]}" | cut -d' ' -f3-)
    printf "  [%d] %s  (%s)\n" "$i" "$MAC" "$NAME"
done

echo
read -rp "Sélectionne le numéro de l'appareil à configurer : " CHOICE

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -ge "${#DEVICES[@]}" ]; then
    echo "Sélection invalide."
    exit 1
fi

MAC=$(echo "${DEVICES[$CHOICE]}" | awk '{print $2}')
NAME=$(echo "${DEVICES[$CHOICE]}" | cut -d' ' -f3-)
echo "Appareil sélectionné : $MAC ($NAME)"

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
