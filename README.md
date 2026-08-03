# raspberry_bluetooth_autoconnect

Reconnexion automatique à une enceinte Bluetooth préférée sur un Raspberry
Pi : connexion A2DP dès le boot, reconnexion automatique à chaque perte de
signal, et confirmation vocale locale (offline) quand la connexion réussit.

Le projet parle directement à `bluetoothd` via D-Bus (voir `bluez_dbus.py`)
plutôt que de scripter `bluetoothctl` : les appels de méthode (pairing,
connexion) renvoient de vraies erreurs exploitables au lieu d'un texte à
parser, et un seul agent d'appairage est utilisé, explicitement, pour tout
le flux.

## Ce que ça fait

- Se connecte automatiquement à la première enceinte disponible dans une
  liste de préférences (par ordre de priorité), au démarrage du Pi et après
  toute perte de connexion.
- Active le bon profil audio A2DP côté PulseAudio et le sink correspondant.
- Joue une confirmation vocale ("Connexion à l'enceinte réussie.") une fois
  connecté, via un serveur de synthèse vocale local (Piper TTS) si présent,
  avec repli automatique sur `espeak-ng` puis sur un simple bip.
- Fournit un assistant interactif (`bt_setup.py`) pour appairer une nouvelle
  enceinte, avec des diagnostics système explicites (rfkill, bluetoothd,
  bug ERTM connu du Pi, état PulseAudio) et un essai sonore de validation.

## Fichiers du dépôt

| Fichier | Rôle |
|---|---|
| `bluez_dbus.py` | Module partagé : contrôleur BlueZ via D-Bus (découverte, pairing, trust, connexion), agent d'appairage unique auto-acceptant. |
| `bt_manager.py` | Boucle principale : connexion directe à la première enceinte préférée trouvée, activation du profil audio A2DP, confirmation vocale, puis surveillance jusqu'à la perte de connexion. Tourne en continu comme service systemd. |
| `bt-manager.service` | Unité systemd qui lance `bt_manager.py` au boot et le relance automatiquement (`Restart=always`). |
| `bt_setup.py` | Assistant interactif à lancer manuellement : diagnostics système, découverte, appairage (seulement si nécessaire), connexion, profil audio A2DP, essai sonore. À utiliser pour ajouter/déboguer une enceinte, pas pour l'usage courant. |
| `~/.config/bt-preferred.conf` (hors dépôt) | Liste des adresses MAC préférées, une par ligne, par ordre de priorité. Commentaires `#` et texte après `#` sur une ligne ignorés. |

Pour le récit complet des problèmes rencontrés et de la façon dont le
projet en est arrivé là, voir [`HISTORY.md`](HISTORY.md).

## Prérequis

- Un Raspberry Pi (testé sur Raspberry Pi OS / Raspbian Bullseye) avec
  Bluetooth intégré ou adaptateur USB.
- `bluez`, `pulseaudio` (+ `pulseaudio-module-bluetooth`), `python3-dbus`,
  `python3-gi`.
- Optionnel : un serveur [Piper TTS local](https://github.com/mcoliver007/raspberry_test_synthese_vocale)
  pour une confirmation vocale de meilleure qualité, ou `espeak-ng` pour un
  repli plus simple.

## Installation

```bash
sudo apt install python3-dbus python3-gi

git clone <ce dépôt> /home/pi/raspberry_bluetooth_autoconnect
cd /home/pi/raspberry_bluetooth_autoconnect

# Fichier de préférences (créer le dossier si besoin)
mkdir -p /home/pi/.config
cat > /home/pi/.config/bt-preferred.conf <<'EOF'
AA:BB:CC:DD:EE:FF   # Nom de l'enceinte
EOF

# Appairer l'enceinte une première fois (mets-la en mode pairing avant de lancer)
./bt_setup.py

# Installer le service de reconnexion automatique
sudo cp bt-manager.service /etc/systemd/system/bt-manager.service
sudo systemctl daemon-reload
sudo systemctl enable --now bt-manager
```

### Confirmation vocale (optionnel)

La confirmation vocale à la connexion utilise en priorité le serveur
[Piper TTS local](https://github.com/mcoliver007/raspberry_test_synthese_vocale)
(service `systemd --user piper-tts.service`, 100% offline, voix naturelle).
S'il n'est pas installé/démarré, `bt_manager.py` retombe automatiquement sur
`espeak-ng` (voix plus robotique mais sans dépendance), puis sur un simple
bip si `espeak-ng` n'est pas non plus disponible. Aucune des deux n'est
requise pour que la reconnexion Bluetooth fonctionne.

## Utilisation au quotidien

Le service tourne seul, sans intervention. Pour ajouter une nouvelle
enceinte ou une nouvelle MAC de secours, l'ajouter dans `bt-preferred.conf`
(l'ordre des lignes = ordre de priorité), puis relancer `bt_setup.py` pour
l'appairer.

Logs en direct :
```bash
journalctl -u bt-manager -f
```

## Checks en cas de problème

### Rien ne se connecte / l'enceinte n'apparaît jamais

1. **Le service tourne et voit le contrôleur Bluetooth ?**
   ```bash
   systemctl status bt-manager
   hciconfig hci0
   ```
   Doit afficher `UP RUNNING`. Sinon : `sudo hciconfig hci0 up`.

2. **`bluetoothd` tourne ?**
   ```bash
   systemctl status bluetooth
   ```

3. **L'enceinte apparaît au scan manuel ?**
   ```bash
   bluetoothctl scan on
   ```
   Si absente : rapprocher l'enceinte, vérifier qu'elle n'est pas déjà
   connectée à un autre appareil, vérifier son mode appairage (fenêtre de
   connectabilité classique souvent courte, ~2 min — voir plus bas la
   remarque sur les enceintes à double interface BLE/BR-EDR).

4. **La MAC dans `bt-preferred.conf` est-elle la bonne ?**
   Certaines enceintes (Bose notamment) diffusent **deux identités
   Bluetooth distinctes** : une classique BR/EDR (utilisée pour l'audio
   A2DP) et une BLE annexe, préfixée `LE-` dans le scan, pour leur appli de
   contrôle. Utiliser la MAC de l'interface **classique** (sans `LE-`) dans
   `bt-preferred.conf` — l'interface `LE-` ne permet pas l'A2DP.

5. **L'enceinte a-t-elle atteint sa limite d'appareils connectés
   simultanément ?** Beaucoup d'enceintes (multipoint) n'acceptent que 2
   connexions actives à la fois. Si `bt-manager` échoue à répétition sur
   une enceinte pourtant détectée, déconnecte un autre appareil qui lui est
   déjà connecté et réessaie.

### La connexion Bluetooth réussit puis échoue aussitôt

Regarder `journalctl -u bluetooth` au moment de l'échec :

- **`avdtp_connect_cb() ... Invalid exchange (52)`** : bug connu du
  contrôleur Bluetooth intégré du Raspberry Pi (mode ERTM/L2CAP mal
  supporté par certaines enceintes). Corriger une fois pour toutes :
  ```bash
  echo "options bluetooth disable_ertm=Y" | sudo tee /etc/modprobe.d/bluetooth.conf
  sudo reboot
  ```
  `bt_setup.py` vérifie ce réglage automatiquement au démarrage.
- **État bloqué après une mise en veille de l'enceinte** : relancer
  `./bt_setup.py`, qui bascule automatiquement sur un `remove` +
  ré-appairage si la connexion échoue malgré un appairage existant.

### Aucun son ne sort de l'enceinte (Bluetooth connecté, mais muet)

1. **PulseAudio utilisé par le service est-il la vraie session de `pi` ?**
   ```bash
   sudo -u pi XDG_RUNTIME_DIR=/run/user/$(id -u pi) pactl info
   ```
   Le `Server String` doit être `/run/user/<uid>/pulse/native`, pas un
   chemin `/tmp/pulse-XXXX` (instance jetable et cassée, symptôme d'un
   `XDG_RUNTIME_DIR` mal résolu — voir `HISTORY.md`).

2. **Le sink Bluetooth existe et est actif ?**
   ```bash
   pactl list cards short   # doit lister bluez_card.<MAC>
   pactl list sinks short   # doit lister bluez_sink.<MAC>.a2dp_sink, état RUNNING
   pactl info | grep "Default Sink"
   ```

3. **Test direct du sink :**
   ```bash
   pactl set-default-sink bluez_sink.<MAC>.a2dp_sink
   speaker-test -D pulse -t sine -f 440 -c 2 -l 1
   ```

4. **Confirmation vocale muette mais reconnexion OK ?**
   Vérifier le serveur Piper : `systemctl --user status piper-tts.service`
   et `journalctl --user -u piper-tts.service`. En son absence, le script
   retombe sur `espeak-ng` silencieusement si celui-ci est absent aussi.
