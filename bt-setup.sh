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
need_cmd hcitool
need_cmd sudo

echo "=== Découverte Bluetooth classique (BR/EDR) ==="
# hcitool nécessite les capacités CAP_NET_ADMIN/CAP_NET_RAW ; on l'exécute
# via sudo pour cette seule commande, plutôt que de lancer tout le script en
# root — ce qui casserait l'accès à la session PulseAudio réelle de l'utilisateur.
# bluetoothctl "scan on" est peu fiable pour détecter l'interface classique
# d'une enceinte (certaines n'annoncent leur MAC BR/EDR que pendant une
# fenêtre courte de leur mode pairing, parfois manquée). hcitool scan fait
# une inquiry classique directe, plus fiable ici ; on la répète plusieurs
# fois car la fenêtre d'annonce peut être ratée une fois sur deux.
declare -A BREDR_NAMES
for attempt in $(seq 1 "$BREDR_SCAN_ATTEMPTS"); do
    echo "  tentative $attempt/$BREDR_SCAN_ATTEMPTS…"
    while IFS=$'\t' read -r MAC NAME; do
        [ -z "$MAC" ] && continue
        [ "$NAME" = "n/a" ] && continue
        BREDR_NAMES["$MAC"]="$NAME"
    done < <(sudo hcitool scan --flush 2>/dev/null | tail -n +2)
done

echo
echo "=== Découverte Bluetooth basse consommation (BLE, pour information) ==="
stdbuf -oL -eL bluetoothctl --timeout "$SCAN_DURATION" scan on >/dev/null 2>&1
mapfile -t LE_LINES < <(bluetoothctl devices | sort -u)

DEVICES=()
for MAC in "${!BREDR_NAMES[@]}"; do
    DEVICES+=("$MAC"$'\t'"${BREDR_NAMES[$MAC]}"$'\t'"classique")
done
for line in "${LE_LINES[@]}"; do
    MAC=$(echo "$line" | awk '{print $2}')
    NAME=$(echo "$line" | cut -d' ' -f3-)
    # Ne pas dupliquer une MAC déjà trouvée en classique
    [ -n "${BREDR_NAMES[$MAC]:-}" ] && continue
    DEVICES+=("$MAC"$'\t'"$NAME"$'\t'"LE")
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
