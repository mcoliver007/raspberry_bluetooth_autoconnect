#!/usr/bin/env python3
"""Boucle de reconnexion automatique à une enceinte Bluetooth préférée
(réécriture D-Bus de bt-manager.sh). Voir bluez_dbus.py pour le
raisonnement derrière cette approche plutôt que bluetoothctl scripté.

Contrairement à bt-manager.sh, cette version ne scanne même plus avant de
tenter une connexion : Connect() sur un appareil déjà appairé se fait par
page scan et ne nécessite pas d'avoir été détecté par un inquiry scan au
préalable (cf. le dernier fix apporté à la version bash).
"""
from __future__ import annotations

import json
import os
import pwd
import signal
import socket
import subprocess
import sys
import syslog
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bluez_dbus import BlueZController, PairingError  # noqa: E402

PREF_FILE = "/home/pi/.config/bt-preferred.conf"
LOG_FILE = "/var/log/bt-manager.log"
TTS_SOCKET_PATH = os.environ.get("TTS_SOCKET_PATH", "/tmp/piper_tts.sock")
CONNECT_FAIL_HINT_THRESHOLD = 3
CONNECT_TIMEOUT = 10
MAX_CONSECUTIVE_MONITOR_FAILURES = 3

_running = True


def _handle_term(signum, frame) -> None:
    global _running
    log("Arrêt demandé par systemd — bt-manager se termine proprement.")
    _running = False


signal.signal(signal.SIGTERM, _handle_term)


def log(msg: str) -> None:
    line = f"[bt-manager] {msg}"
    print(line, flush=True)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass
    try:
        syslog.syslog(msg)
    except OSError:
        pass


def speak(mode: str, text: str) -> bool:
    """Envoie le texte au serveur Piper TTS via son socket Unix. Retourne
    False si le serveur n'est pas joignable ou a répondu une erreur, pour
    permettre un repli côté appelant."""
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(5)
            s.connect(TTS_SOCKET_PATH)
            s.sendall((json.dumps({"mode": mode, "text": text}) + "\n").encode("utf-8"))
            resp = s.makefile("r").readline()
        data = json.loads(resp) if resp else {}
        return data.get("status") == "ok"
    except OSError:
        return False


def wait_for_pactl_object(kind: str, name: str, attempts: int = 5) -> bool:
    for _ in range(attempts):
        result = subprocess.run(["pactl", "list", kind, "short"], capture_output=True, text=True)
        if name in result.stdout:
            return True
        time.sleep(1)
    return False


def retry_pactl(cmd: list[str], attempts: int = 5) -> tuple[bool, str]:
    last_error = ""
    for _ in range(attempts):
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            return True, ""
        last_error = result.stderr.strip()
        time.sleep(1)
    return False, last_error


def read_preferred_macs() -> list[str]:
    macs = []
    try:
        with open(PREF_FILE) as f:
            for raw in f:
                mac = raw.split("#", 1)[0].strip()
                if mac:
                    macs.append(mac)
    except OSError:
        pass
    return macs


def start_pulseaudio() -> None:
    # --exit-idle-time=-1 : même cette instance persistante s'éteindrait
    # sinon d'elle-même après 20s (défaut PulseAudio) sans aucun client
    # connecté — exactement le trou dans lequel tombent nos propres appels
    # pactl (courts, déconnexion immédiate) suivis d'un délai de plusieurs
    # secondes avant que Kodi ne s'y connecte à son tour. PulseAudio
    # s'éteignant puis étant relancé par l'autospawn de Kodi, l'endpoint
    # A2DP est réenregistré à froid auprès de BlueZ, ce qui peut perturber
    # la connexion Bluetooth déjà établie (voir incident démarrage Kodi).
    subprocess.run(["pulseaudio", "--start", "--exit-idle-time=-1"], capture_output=True)
    time.sleep(2)
    modules = subprocess.run(["pactl", "list", "modules", "short"], capture_output=True, text=True)
    if "module-bluetooth-discover" not in modules.stdout:
        subprocess.run(["pactl", "load-module", "module-bluetooth-discover"], capture_output=True)
    log("Modules PulseAudio Bluetooth chargés.")


def activate_a2dp(mac: str) -> None:
    card = f"bluez_card.{mac.replace(':', '_')}"
    sink = f"bluez_sink.{mac.replace(':', '_')}.a2dp_sink"

    # La carte Bluetooth met quelques secondes à s'enregistrer dans
    # PulseAudio après la connexion.
    if not wait_for_pactl_object("cards", card):
        log(f"DEBUG: carte {card} absente après 5s")
    success, error = retry_pactl(["pactl", "set-card-profile", card, "a2dp_sink"])
    if not success:
        detail = error or "(pas de message d'erreur)"
        log(f"DEBUG: échec set-card-profile pour {card} : {detail}")

    # Le sink A2DP n'apparaît qu'après le changement de profil de la carte.
    if not wait_for_pactl_object("sinks", sink):
        log(f"DEBUG: sink {sink} absent après 5s")
    success, error = retry_pactl(["pactl", "set-default-sink", sink])
    if not success:
        detail = error or "(pas de message d'erreur)"
        log(f"DEBUG: échec set-default-sink pour {sink} : {detail}")

    # Changer le sink par défaut ne redirige pas les flux audio déjà ouverts
    # (ex: le process aplay persistant d'un serveur TTS lancé avant cette
    # connexion) — on les déplace donc explicitement.
    moved = 0
    sink_inputs = subprocess.run(["pactl", "list", "short", "sink-inputs"], capture_output=True, text=True)
    for line in sink_inputs.stdout.splitlines():
        if not line.strip():
            continue
        input_id = line.split()[0]
        if subprocess.run(["pactl", "move-sink-input", input_id, sink], capture_output=True).returncode == 0:
            moved += 1
    if moved:
        log(f"DEBUG: {moved} flux audio existant(s) déplacé(s) vers {sink}")

    log(f"Profil A2DP activé pour {mac}")

    # Confirmation vocale via le serveur Piper TTS local (mode "fast").
    # Repli sur espeak-ng puis un bip si le serveur n'est pas joignable.
    if speak("fast", "Connexion à l'enceinte réussie."):
        log("DEBUG: confirmation vocale jouée via Piper TTS")
    elif subprocess.run(["which", "espeak-ng"], capture_output=True).returncode == 0:
        log("DEBUG: serveur Piper TTS indisponible, repli sur espeak-ng")
        wav_path = tempfile.mktemp(suffix=".wav")
        subprocess.run(
            ["espeak-ng", "-v", "fr", "-w", wav_path, "Connexion à l'enceinte réussie"],
            capture_output=True,
        )
        subprocess.run(["paplay", f"--device={sink}", wav_path], capture_output=True)
        os.remove(wav_path)
    elif os.path.exists("/usr/share/sounds/alsa/Front_Center.wav"):
        subprocess.run(
            ["paplay", f"--device={sink}", "/usr/share/sounds/alsa/Front_Center.wav"],
            capture_output=True,
        )


def main() -> None:
    os.environ["XDG_RUNTIME_DIR"] = f"/run/user/{pwd.getpwnam('pi').pw_uid}"

    log("bt-manager démarré.")
    start_pulseaudio()

    bt = BlueZController()
    if not bt.adapter_powered():
        bt.set_adapter_powered(True)
        time.sleep(1)

    connect_fails: dict[str, int] = {}

    while _running:
        log("--------------------------------------------")
        connected_mac = None

        for mac in read_preferred_macs():
            log(f"Tentative de connexion directe : {mac}")
            try:
                bt.connect(mac, timeout=CONNECT_TIMEOUT)
            except PairingError as exc:
                log(f"Échec de connexion à {mac} ({exc.dbus_error_name})")
                connect_fails[mac] = connect_fails.get(mac, 0) + 1
                if connect_fails[mac] >= CONNECT_FAIL_HINT_THRESHOLD:
                    log(
                        f"PISTE : {mac} refuse la connexion depuis "
                        f"{connect_fails[mac]} tentatives consécutives — vérifier si "
                        "l'enceinte a déjà atteint sa limite d'appareils connectés "
                        "simultanément (multipoint, souvent 2 max sur ce type "
                        "d'enceinte). Déconnecter un autre appareil et réessayer."
                    )
                continue

            log(f"Connexion réussie : {mac}")
            connect_fails[mac] = 0
            activate_a2dp(mac)
            connected_mac = mac
            break

        if connected_mac:
            log(f"Surveillance de la connexion à {connected_mac}")
            # Un pic de charge CPU peut ralentir D-Bus/bluetoothd le temps
            # d'un cycle et faire échouer ce check ponctuellement sans que
            # l'enceinte soit réellement déconnectée : on exige plusieurs
            # échecs consécutifs avant de déclarer la perte.
            consecutive_failures = 0
            while _running:
                if bt.is_connected(connected_mac):
                    consecutive_failures = 0
                    time.sleep(5)
                    continue
                consecutive_failures += 1
                log(
                    f"DEBUG: vérification de connexion en échec pour {connected_mac} "
                    f"({consecutive_failures}/{MAX_CONSECUTIVE_MONITOR_FAILURES})"
                )
                if consecutive_failures >= MAX_CONSECUTIVE_MONITOR_FAILURES:
                    break
                time.sleep(2)
            if _running:
                log(f"Enceinte perdue : {connected_mac} — tentative de reconnexion dans 10s")
                time.sleep(10)
        else:
            log("Aucune enceinte préférée connectée — nouvelle tentative dans 10s")
            time.sleep(10)

    sys.exit(0)


if __name__ == "__main__":
    main()
