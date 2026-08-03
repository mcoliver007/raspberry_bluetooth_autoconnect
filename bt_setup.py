#!/usr/bin/env python3
"""Assistant interactif de configuration Bluetooth (réécriture D-Bus de
bt-setup.sh) : diagnostics système, découverte, appairage (seulement si
nécessaire), connexion, profil audio A2DP, essai sonore.

Contrairement à bt-setup.sh (bluetoothctl scripté en bash), ce script parle
directement à bluetoothd via D-Bus (voir bluez_dbus.py) : pas de parsing de
texte asynchrone, un seul agent SSP explicite (pas de risque de conflit),
des exceptions D-Bus propres en cas d'échec plutôt que des motifs de log à
deviner.

Dépendances supplémentaires par rapport à la version bash :
    sudo apt install python3-dbus python3-gi
"""
from __future__ import annotations

import os
import pwd
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bluez_dbus import BlueZController, PairingError  # noqa: E402

SCAN_DURATION = 8
PAIR_TIMEOUT = 15
CONNECT_TIMEOUT = 10
CONNECT_ATTEMPTS = 5
PAIR_ATTEMPTS = 2


def info(msg: str) -> None:
    print(f"  . {msg}")


def ok(msg: str) -> None:
    print(f"  [OK] {msg}")


def warn(msg: str) -> None:
    print(f"  [ATTENTION] {msg}")


def fail(msg: str) -> None:
    print(f"  [ERREUR] {msg}")


def run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True)


def check_system() -> None:
    print("=== Diagnostics système ===")

    # rfkill : le Bluetooth ne doit être bloqué ni matériellement ni logiciellement.
    rfkill = run(["rfkill", "list", "bluetooth"])
    if rfkill.returncode == 0:
        if "blocked: yes" in rfkill.stdout.lower():
            fail("Bluetooth bloqué par rfkill. Corrige avec: sudo rfkill unblock bluetooth")
            sys.exit(1)
        ok("rfkill : Bluetooth non bloqué")
    else:
        warn("rfkill absent ou en échec, vérification ignorée")

    # bluetoothd doit tourner.
    bt_status = run(["systemctl", "is-active", "bluetooth"])
    if bt_status.stdout.strip() != "active":
        fail("Le service bluetooth (bluetoothd) n'est pas actif : sudo systemctl start bluetooth")
        sys.exit(1)
    ok("bluetoothd : actif")

    # Bug ERTM/L2CAP connu du contrôleur Bluetooth du Pi (avdtp_connect_cb
    # Invalid exchange (52)) : corrigé par disable_ertm=Y + reboot.
    ertm_path = "/sys/module/bluetooth/parameters/disable_ertm"
    if os.path.exists(ertm_path):
        with open(ertm_path) as f:
            ertm = f.read().strip()
        if ertm == "Y":
            ok("disable_ertm=Y (fix ERTM actif)")
        else:
            warn(f"disable_ertm={ertm} (attendu Y) — un bug L2CAP connu du Pi peut")
            warn("faire échouer l'A2DP (avdtp_connect_cb Invalid exchange). Voir README.")

    if not os.path.isdir(os.environ.get("XDG_RUNTIME_DIR", "")):
        warn(f"{os.environ.get('XDG_RUNTIME_DIR')} n'existe pas — le linger systemd de")
        warn("pi est peut-être désactivé : sudo loginctl enable-linger pi")

    start_pulseaudio()
    print()


def start_pulseaudio() -> None:
    # Sans instance PulseAudio persistante déjà lancée (ex: bt-manager.service
    # arrêté pour un test manuel), les appels pactl déclenchent l'auto-spawn
    # par défaut de PulseAudio : une instance jetable qui s'éteint dès qu'elle
    # devient inactive, désenregistrant son endpoint A2DP en plein milieu de
    # la négociation. On démarre donc explicitement une instance persistante
    # (no-op si déjà lancée).
    subprocess.run(["pulseaudio", "--start"], capture_output=True)
    time.sleep(2)
    info_result = run(["pactl", "info"])
    if info_result.returncode != 0:
        fail(f"Impossible de joindre PulseAudio (XDG_RUNTIME_DIR={os.environ.get('XDG_RUNTIME_DIR')}).")
        sys.exit(1)
    server_string = ""
    for line in info_result.stdout.splitlines():
        if line.startswith("Server String:"):
            server_string = line.split(":", 1)[1].strip()
    if server_string.startswith("/tmp/pulse-"):
        warn(f"PulseAudio tourne sur une instance jetable ({server_string}), pas la")
        warn("session persistante de pi — les flux audio risquent de se couper.")
    else:
        ok(f"PulseAudio : {server_string}")
    modules = run(["pactl", "list", "modules", "short"])
    if "module-bluetooth-discover" not in modules.stdout:
        subprocess.run(["pactl", "load-module", "module-bluetooth-discover"], capture_output=True)


def wait_for_pactl_object(kind: str, name: str, attempts: int = 5) -> bool:
    for _ in range(attempts):
        result = run(["pactl", "list", kind, "short"])
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


def do_pair(bt: BlueZController, mac: str) -> bool:
    for attempt in range(1, PAIR_ATTEMPTS + 1):
        try:
            bt.pair(mac, timeout=PAIR_TIMEOUT)
            ok("Pairing réussi")
            return True
        except PairingError as exc:
            fail(f"pair a échoué : {exc.dbus_error_name}: {exc}")
            if attempt < PAIR_ATTEMPTS:
                warn(f"Nouvelle tentative de pairing ({attempt}/{PAIR_ATTEMPTS})…")
                time.sleep(2)
    fail(f"Pairing impossible après {PAIR_ATTEMPTS} tentatives.")
    info("Pistes possibles : l'enceinte n'est plus en mode pairing (LED),")
    info("ou elle a déjà atteint sa limite d'appareils connectés (multipoint).")
    return False


def do_connect(bt: BlueZController, mac: str) -> bool:
    for attempt in range(1, CONNECT_ATTEMPTS + 1):
        try:
            bt.connect(mac, timeout=CONNECT_TIMEOUT)
            ok(f"Connexion réussie ({attempt}/{CONNECT_ATTEMPTS})")
            return True
        except PairingError as exc:
            warn(f"connect a échoué ({exc.dbus_error_name}) — nouvelle tentative ({attempt}/{CONNECT_ATTEMPTS})…")
            time.sleep(2)
    return False


def setup_audio(mac: str, name: str) -> None:
    sink = f"bluez_sink.{mac.replace(':', '_')}.a2dp_sink"
    card = f"bluez_card.{mac.replace(':', '_')}"

    print()
    print("=== Sélection du profil A2DP et du sink audio ===")
    if not wait_for_pactl_object("cards", card):
        warn(f"Carte {card} absente après 5s d'attente.")
    success, error = retry_pactl(["pactl", "set-card-profile", card, "a2dp-sink"])
    if success:
        ok(f"Profil a2dp-sink activé sur {card}")
    else:
        detail = error or "(pas de message d'erreur)"
        warn(f"Échec de set-card-profile pour {card} : {detail}")

    if not wait_for_pactl_object("sinks", sink):
        warn(f"Sink {sink} absent après 5s d'attente.")
    success, error = retry_pactl(["pactl", "set-default-sink", sink])
    if success:
        ok(f"Sink par défaut : {sink}")
    else:
        detail = error or "(pas de message d'erreur)"
        warn(f"Échec de set-default-sink pour {sink} : {detail}")

    # Changer le sink par défaut ne redirige pas les flux audio déjà ouverts
    # (ex: le process aplay persistant d'un serveur TTS lancé bien avant
    # cette connexion) — on les déplace donc explicitement.
    moved = 0
    sink_inputs = run(["pactl", "list", "short", "sink-inputs"])
    for line in sink_inputs.stdout.splitlines():
        if not line.strip():
            continue
        input_id = line.split()[0]
        if subprocess.run(["pactl", "move-sink-input", input_id, sink], capture_output=True).returncode == 0:
            moved += 1
    if moved:
        info(f"{moved} flux audio existant(s) déplacé(s) vers {sink}")

    sinks_list = run(["pactl", "list", "sinks", "short"])
    if sink not in sinks_list.stdout:
        fail(f"Le sink audio '{sink}' n'apparaît pas dans PulseAudio.")
        info("Vérifie : pactl list cards short / pactl list sinks short")
        sys.exit(1)
    ok("Sink audio confirmé dans PulseAudio")

    print()
    print(f"=== Essai sonore sur {name} ===")
    subprocess.run(["pactl", "set-sink-mute", sink, "0"], capture_output=True)
    subprocess.run(["pactl", "set-sink-volume", sink, "80%"], capture_output=True)

    if subprocess.run(["which", "speaker-test"], capture_output=True).returncode == 0:
        subprocess.run(["speaker-test", "-D", "pulse", "-t", "sine", "-f", "440", "-c", "2", "-l", "1"])
    elif os.path.exists("/usr/share/sounds/alsa/Front_Center.wav"):
        subprocess.run(["paplay", f"--device={sink}", "/usr/share/sounds/alsa/Front_Center.wav"])
    else:
        fail("Aucun outil d'essai sonore trouvé (speaker-test ou paplay).")
        sys.exit(1)

    print()
    print("Terminé. Si tu n'as rien entendu, vérifie le volume de l'enceinte elle-même.")


def main() -> None:
    # Fixe la session PulseAudio ciblée par pactl à celle de l'utilisateur pi,
    # plutôt que de dépendre de l'environnement de la session interactive.
    os.environ["XDG_RUNTIME_DIR"] = f"/run/user/{pwd.getpwnam('pi').pw_uid}"

    check_system()

    bt = BlueZController()
    if not bt.adapter_powered():
        warn("Adaptateur Bluetooth non alimenté (Powered=false) — activation…")
        bt.set_adapter_powered(True)
        time.sleep(1)
    ok("Adaptateur Bluetooth actif")

    print(f"=== Découverte Bluetooth ({SCAN_DURATION}s, transport classique BR/EDR) ===")
    # BlueZ purge un appareil temporaire (découvert mais pas encore appairé)
    # dès que la découverte s'arrête (pas après un délai) : le scan doit
    # donc rester actif pendant tout le pairing, pas seulement la sélection.
    bt.start_discovery("bredr")
    time.sleep(SCAN_DURATION)

    devices = bt.list_devices()
    if not devices:
        fail("Aucun appareil détecté.")
        bt.stop_discovery()
        sys.exit(1)

    print()
    print("Appareils détectés :")
    for i, d in enumerate(devices):
        kind = "LE" if d["name"].startswith("LE-") else "classique"
        print(f"  [{i}] {d['address']}  ({d['name']})  [{kind}]")
    print()
    print("Note : seule l'interface [classique] permet l'audio A2DP. L'interface")
    print("[LE] est affichée à titre informatif (souvent un canal de contrôle")
    print("d'appli compagnon), la sélectionner échouera pour un usage audio.")
    print()

    choice = input("Sélectionne le numéro de l'appareil à configurer : ").strip()
    if not choice.isdigit() or int(choice) >= len(devices):
        fail("Sélection invalide.")
        bt.stop_discovery()
        sys.exit(1)

    device = devices[int(choice)]
    mac, name = device["address"], device["name"]
    kind = "LE" if name.startswith("LE-") else "classique"
    print(f"Appareil sélectionné : {mac} ({name}) [{kind}]")
    if kind == "LE":
        warn("Interface LE sélectionnée, l'audio A2DP échouera probablement.")

    print()
    print("=== Appairage ===")
    already_paired = bt.is_paired(mac)
    if already_paired:
        ok("Déjà appairé — pairing/trust ignorés, connexion directe.")
    else:
        if not do_pair(bt, mac):
            bt.stop_discovery()
            sys.exit(1)
        try:
            bt.trust(mac)
            ok("Trust réussi")
        except Exception as exc:  # noqa: BLE001 - non bloquant
            warn(f"trust a échoué ({exc}), on continue quand même.")

    print()
    print("=== Connexion ===")
    connected = do_connect(bt, mac)

    # Si déjà appairé mais la connexion échoue quand même, la clé de liaison
    # est peut-être obsolète : on tente un fallback remove + re-pair, une fois.
    if not connected and already_paired:
        warn("Connexion impossible malgré un appairage existant — tentative de")
        warn("nettoyage (clé de liaison potentiellement obsolète) et ré-appairage.")
        bt.remove_device(mac)
        time.sleep(1)
        if do_pair(bt, mac):
            try:
                bt.trust(mac)
            except Exception:  # noqa: BLE001
                pass
            connected = do_connect(bt, mac)

    bt.stop_discovery()

    if not connected:
        fail(f"Échec de connexion à {mac} après {CONNECT_ATTEMPTS} tentatives.")
        info("Pistes possibles : limite d'appareils connectés simultanément")
        info("(multipoint, souvent 2 max) — déconnecte un autre appareil de")
        info("l'enceinte et réessaie ; ou bug ERTM (voir diagnostic plus haut) ;")
        info("ou regarde journalctl -u bluetooth -n 50 pour le détail exact.")
        sys.exit(1)

    ok(f"Connexion réussie à {mac}")
    setup_audio(mac, name)


if __name__ == "__main__":
    main()
