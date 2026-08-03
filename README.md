# raspberry_bluetooth_autoconnect

Reconnexion automatique à une enceinte Bluetooth préférée sur Raspberry Pi
(connexion A2DP, confirmation vocale), dès le boot et à chaque perte de
connexion.

**Branche `claude/python-dbus-rewrite`** : réécriture expérimentale en
Python, parlant directement à `bluetoothd` via D-Bus au lieu de scripter
`bluetoothctl` en bash. `bluetoothctl` est un outil interactif pensé pour un
humain, pas pour être piloté par script (parsing de texte asynchrone, agent
SSP implicite non contrôlable) — voir `bluez_dbus.py` pour le détail du
raisonnement. Cette branche n'a pas encore été validée sur le matériel réel
(contrairement à `main`) ; ne pas merger avant test complet sur un Pi.

Nouvelle dépendance : `sudo apt install python3-dbus python3-gi`

## Fichiers du dépôt

| Fichier | Rôle |
|---|---|
| `bluez_dbus.py` | Module partagé : contrôleur BlueZ via D-Bus (découverte, pairing, trust, connexion), agent SSP unique auto-acceptant. |
| `bt_manager.py` | Boucle principale : connexion directe à la première enceinte préférée trouvée (sans scan préalable), activation du profil audio A2DP, confirmation vocale, puis surveillance jusqu'à la perte de connexion. Tourne en continu comme service systemd. |
| `bt-manager.service` | Unité systemd qui lance `bt_manager.py` au boot et le relance automatiquement (`Restart=always`). |
| `bt_setup.py` | Assistant interactif à lancer manuellement : diagnostics système, découverte, appairage (seulement si nécessaire), connexion, profil audio A2DP, essai sonore. À utiliser pour ajouter/déboguer une enceinte, pas pour l'usage courant. |
| `~/.config/bt-preferred.conf` (hors dépôt) | Liste des adresses MAC préférées, une par ligne, par ordre de priorité. Commentaires `#` et texte après `#` sur une ligne ignorés. |

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

# Appairer l'enceinte une première fois
./bt_setup.py

# Installer le service
sudo cp bt-manager.service /etc/systemd/system/bt-manager.service
sudo systemctl daemon-reload
sudo systemctl enable --now bt-manager
```

### Dépendance optionnelle : confirmation vocale

La confirmation vocale à la connexion utilise en priorité le serveur
[Piper TTS local](https://github.com/mcoliver007/raspberry_test_synthese_vocale)
(service `systemd --user piper-tts.service`, 100% offline, voix naturelle).
S'il n'est pas installé/démarré, `bt_manager.py` retombe automatiquement sur
`espeak-ng` (voix plus robotique mais sans dépendance), puis sur un simple bip
si `espeak-ng` n'est pas non plus disponible. Aucune des deux n'est requise
pour que la reconnexion Bluetooth fonctionne.

## Utilisation au quotidien

Le service tourne seul, sans intervention. Pour ajouter une nouvelle enceinte
ou une nouvelle MAC de secours, l'ajouter dans `bt-preferred.conf` (l'ordre
des lignes = ordre de priorité), puis relancer `bt_setup.py` pour l'appairer.

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

### La connexion Bluetooth réussit puis échoue aussitôt (`Failed to connect: org.bluez.Error.Failed`)

Regarder `journalctl -u bluetooth` au moment de l'échec :

- **`avdtp_connect_cb() ... Invalid exchange (52)`** : bug connu du
  contrôleur Bluetooth intégré du Raspberry Pi (mode ERTM/L2CAP mal
  supporté par certaines enceintes). Corriger une fois pour toutes :
  ```bash
  echo "options bluetooth disable_ertm=Y" | sudo tee /etc/modprobe.d/bluetooth.conf
  sudo reboot
  ```
- **État bloqué après une mise en veille de l'enceinte** (`Host is down`
  en boucle) : relancer `./bt_setup.py`, qui bascule automatiquement sur un
  `remove` + ré-appairage si la connexion échoue malgré un appairage existant.

### Aucun son ne sort de l'enceinte (Bluetooth connecté, mais muet)

1. **PulseAudio utilisé par le service est-il la vraie session de `pi` ?**
   ```bash
   sudo -u pi XDG_RUNTIME_DIR=/run/user/$(id -u pi) pactl info
   ```
   Le `Server String` doit être `/run/user/<uid>/pulse/native`, pas un
   chemin `/tmp/pulse-XXXX` (instance jetable et cassée, symptôme d'un
   `XDG_RUNTIME_DIR` mal résolu — voir Historique, point 4).

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

## Historique du développement — enseignements clés

Résumé des blocages majeurs rencontrés et de leur résolution (le détail
complet est dans l'historique des commits/PR) :

1. **Le fichier de préférences autorise des commentaires inline**
   (`MAC # nom`), mais la lecture ligne à ligne du script ne les retirait
   pas → la MAC entière incluant le commentaire ne matchait jamais le
   scan. Correction : normaliser chaque ligne (`sed 's/#.*//' | xargs`)
   avant comparaison.

2. **Le service tournait en `User=root`**, qui démarrait sa propre
   instance PulseAudio isolée, distincte de la vraie session audio de
   l'utilisateur `pi` (celle réellement connectée au matériel/à
   l'enceinte). Bascule du service en `User=pi`, avec les capacités
   `CAP_NET_ADMIN`/`CAP_NET_RAW` nécessaires à `hciconfig` accordées via
   `AmbientCapabilities` plutôt que par un utilisateur root complet.

3. **`XDG_RUNTIME_DIR` mal résolu même après le passage en `User=pi`** :
   le spécificateur systemd `%U` (qu'on pensait résoudre l'UID de
   `User=`) se résout en réalité à l'UID du **gestionnaire systemd**
   (root, pour un service système), pas à celui configuré par `User=`.
   Leçon : `%U`/`%u` ne sont fiables que pour des instances
   `systemd --user`. Correction : résolution explicite de l'UID par nom
   d'utilisateur (`id -u pi`) directement dans le script.

4. **Connexion A2DP échouant systématiquement avec
   `avdtp_connect_cb() ... Invalid exchange (52)`** : bug connu du
   contrôleur Bluetooth Broadcom embarqué du Pi avec le mode ERTM
   (Enhanced Retransmission Mode) du L2CAP, incompatible avec certaines
   enceintes. Correction au niveau noyau (`disable_ertm=Y`), hors du
   contrôle du script applicatif — rappel que certains échecs Bluetooth
   ne se résolvent pas en userspace.

5. **Course entre la connexion Bluetooth et l'enregistrement de la
   carte/du sink côté PulseAudio** (`Failure: No such entity` sur
   `set-card-profile`/`set-default-sink`) : la présence d'un objet dans
   `pactl list` ne garantit pas que son transport audio interne est
   réellement prêt. Une simple attente/vérification de présence ne
   suffisait pas ; la solution robuste a été de réessayer la commande
   `pactl` elle-même (`retry_pactl`) plutôt que de se fier à un
   contrôle préalable dans une liste.

6. **Recherche de la meilleure qualité de synthèse vocale offline** :
   `espeak-ng` seul (voix très robotique) → tentative `pico2wave` puis
   voix MBROLA (indisponibles sur ce Raspberry Pi OS/architecture) →
   `gTTS` (bonne qualité, mais dépendance réseau et API non-officielle de
   Google Traduction, cassée une première fois par un changement côté
   Google avant même la mise en prod) → adoption finale d'un **serveur
   Piper TTS local dédié** (projet séparé, voix neuronale, 100% offline).
   Leçon : pour un usage embarqué fiable sur le long terme, préférer un
   moteur local à une dépendance à un service tiers non garanti dans le
   temps.

7. **Enceintes à double identité Bluetooth (BLE + BR/EDR)** : Bose (et
   d'autres) diffusent une interface `LE-*` (app de contrôle) en plus de
   l'interface classique utilisée pour l'audio A2DP — source de confusion
   lors de l'appairage manuel si la mauvaise MAC est sélectionnée.
