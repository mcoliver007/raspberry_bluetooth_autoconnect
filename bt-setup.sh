#!/bin/bash
# Assistant interactif de première configuration d'une enceinte/casque Bluetooth :
# découverte -> sélection -> nettoyage -> appairage -> trust -> connexion -> essai sonore.
set -u

SCAN_DURATION=8
BREDR_SCAN_ATTEMPTS=4

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || { echo "Commande manquante: $1"; exit 1; }
}

need_cmd bluetoothctl
need_cmd pactl

# hcitool voit bien l'interface BR/EDR d'une enceinte au niveau radio, mais
# ne la fait pas connaître à bluetoothd : bluetoothctl pair/trust/connect
# répondent alors "not available" faute d'objet D-Bus enregistré. Il faut
# que la découverte passe par bluetoothctl lui-même pour que bluetoothd
# enregistre réellement l'appareil. Le scan "auto" par défaut de
# bluetoothctl favorise le LE et rate souvent la fenêtre d'annonce BR/EDR
# courte de certaines enceintes en mode pairing ; on force donc le
# transport en "bredr" pour une passe dédiée, répétée plusieurs fois.
echo "=== Découverte Bluetooth classique (BR/EDR) ==="
for attempt in $(seq 1 "$BREDR_SCAN_ATTEMPTS"); do
    echo "  tentative $attempt/$BREDR_SCAN_ATTEMPTS…"
    {
        echo "menu scan"
        echo "transport bredr"
        echo "back"
        echo "scan on"
        sleep "$SCAN_DURATION"
        echo "scan off"
        echo "quit"
    } | bluetoothctl >/dev/null 2>&1
done

echo
echo "=== Découverte Bluetooth basse consommation (BLE, pour information) ==="
stdbuf -oL -eL bluetoothctl --timeout "$SCAN_DURATION" scan on >/dev/null 2>&1

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
