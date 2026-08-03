# Histoire du projet

Ce document raconte le chemin parcouru pour arriver à la version actuelle
du dépôt : une reconnexion Bluetooth automatique réellement fiable sur
Raspberry Pi. Il est volontairement chronologique et détaillé — le README
donne l'usage courant, ce fichier donne le contexte et les leçons.

## 1. Le script bash de départ

Le projet a commencé simple : un script `bt-manager.sh` tournant en boucle,
qui scanne le Bluetooth avec `bluetoothctl`, se connecte à la première
enceinte préférée trouvée dans une liste de MAC, active le profil A2DP côté
PulseAudio, et surveille la connexion jusqu'à sa perte. Un service systemd
(`bt-manager.service`) le lance au boot et le relance en continu.

Les tout premiers bugs étaient triviaux mais bloquants :

- **Les commentaires inline cassaient le matching de MAC.** Le fichier de
  préférences autorise `AA:BB:CC:DD:EE:FF   # Nom de l'enceinte`, mais la
  lecture ligne à ligne du script comparait la ligne entière (MAC + texte
  du commentaire) au résultat du scan, qui ne matchait jamais. Correction :
  normaliser chaque ligne (`sed 's/#.*//' | xargs`) avant comparaison.
- **`logger` refusait un message commençant par des tirets**
  (`--------------------------------------------`), l'interprétant comme
  une option en ligne de commande. Correction : ajouter `--` avant l'argument
  du message.

## 2. La bataille avec PulseAudio et l'utilisateur système

Le problème le plus retors des débuts : la confirmation vocale et l'audio
en général ne sortaient jamais, ou de façon incohérente, alors que la
connexion Bluetooth elle-même réussissait.

- **Le service tournait en `User=root`.** Un service systemd lancé en root
  démarre sa propre instance PulseAudio isolée dans `/tmp/pulse-XXXX`,
  complètement déconnectée de la vraie session audio de l'utilisateur `pi`
  (celle qui a l'oreille sur le matériel réellement câblé/appairé).
  Correction : passer le service en `User=pi`, avec les capacités
  `CAP_NET_ADMIN`/`CAP_NET_RAW` nécessaires à `hciconfig` accordées via
  `AmbientCapabilities` plutôt que via un utilisateur root complet.
- **`XDG_RUNTIME_DIR` restait mal résolu même après ce changement.** Le
  réflexe naturel a été d'utiliser le spécificateur systemd `%U`, en
  pensant qu'il résolvait l'UID configuré par `User=`. Erreur : `%U` se
  résout à l'UID du **gestionnaire systemd** (root, pour un service
  système), pas à celui du service lui-même — cette resolution n'est fiable
  que pour des instances `systemd --user`. La correction finale a été de
  résoudre l'UID explicitement par nom d'utilisateur (`id -u pi`)
  directement dans le code, plutôt que de compter sur systemd pour le
  faire.

Ce motif — un outil qui parle à la "mauvaise" instance PulseAudio, jetable
ou orpheline, plutôt qu'à la session persistante réelle — est revenu
plusieurs fois par la suite sous des formes différentes (voir §6).

## 3. Le bug matériel : ERTM

Une fois l'audio correctement routé, un nouveau mur : la connexion
Bluetooth réussissait puis échouait quasi instantanément, avec dans les
logs de `bluetoothd` :

```
avdtp_connect_cb() ... Invalid exchange (52)
```

C'est un bug connu du contrôleur Bluetooth Broadcom embarqué du Raspberry
Pi : le mode ERTM (Enhanced Retransmission Mode) du protocole L2CAP est mal
supporté par certaines enceintes, faisant échouer la négociation AVDTP/A2DP
avant même d'avoir commencé. La correction ne se fait pas en userspace, mais
au niveau du module noyau :

```bash
echo "options bluetooth disable_ertm=Y" | sudo tee /etc/modprobe.d/bluetooth.conf
sudo reboot
```

Leçon retenue : tous les échecs Bluetooth ne se résolvent pas dans le
script applicatif — celui-ci finira par vérifier ce réglage au démarrage
et prévenir plutôt que d'échouer silencieusement.

## 4. La course PulseAudio après la connexion Bluetooth

Même une fois la connexion stable, une erreur intermittente persistait :
`Failure: No such entity` sur `pactl set-card-profile` ou
`set-default-sink`, juste après une connexion Bluetooth réussie.

La première intuition — attendre que l'objet (carte, sink) apparaisse dans
`pactl list` avant d'agir dessus — a réduit le problème sans l'éliminer :
la **présence** d'un objet dans la liste ne garantit pas que son transport
audio interne est prêt à accepter un changement de profil. La solution
robuste a été de réessayer la commande `pactl` **elle-même** plusieurs fois
(`retry_pactl`), plutôt que de se fier à un contrôle de présence préalable.

Ce même chapitre a aussi révélé un vrai bug de nommage, resté invisible
pendant tout le projet : le profil PulseAudio s'appelle `a2dp_sink` (avec
un *underscore*), pas `a2dp-sink` (avec un tiret). La commande demandait
donc, depuis la toute première version du script, un profil qui n'existe
pas — masqué par le fait que `module-bluetooth-discover` bascule le profil
automatiquement de son côté dès qu'il détecte la connexion A2DP, rendant le
son audible malgré l'échec de la commande manuelle. Le bug n'a été
découvert qu'après la réécriture en Python (§9), quand la capture du vrai
message d'erreur de `pactl` (au lieu de l'avaler silencieusement) a permis
de lire noir sur blanc `Failure: No such entity` et de comparer avec la
sortie de `pactl list cards`.

## 5. La quête de la synthèse vocale

Demande initiale simple : jouer une confirmation vocale à la connexion.
Le chemin pour y arriver a traversé plusieurs impasses :

1. **`espeak-ng`** : fonctionne, offline, mais une voix "de vieux robot"
   jugée inacceptable.
2. **`pico2wave`** (SVOX Pico) : package indisponible dans les dépôts
   Raspbian Bullseye pour cette architecture.
3. **Voix MBROLA** (`mbrola-fr4`) : le paquet `mbrola` lui-même est
   indisponible, et aucune voix française n'est packagée pour ce système.
4. **`gTTS`** (Google Translate TTS, non-officiel) : bonne qualité de voix,
   mais dépendance réseau, et l'API a cassé en cours de route ("Unable to
   find token seed" — Google avait changé le mécanisme de token de sa page
   de traduction). Une tentative de mise à jour du paquet pip (2.0.3 → 2.5.4)
   n'a rien changé : le nouveau token-scraping était cassé de la même façon.
   Cette piste a été abandonnée sans être résolue.
5. **Serveur [Piper TTS](https://github.com/mcoliver007/raspberry_test_synthese_vocale)
   local dédié** (projet séparé) : synthèse neuronale, 100% offline, qualité
   largement supérieure à `espeak-ng`. Intégré via un protocole JSON simple
   sur socket Unix (`{"mode": "fast", "text": "..."}` → `{"status": "ok"}`),
   avec repli automatique sur `espeak-ng` puis sur un bip si le serveur
   n'est pas joignable.

Leçon : pour un usage embarqué fiable sur le long terme, un moteur local
bat une dépendance à un service tiers non garanti dans le temps — même
gratuit, même bien documenté.

Un problème plus subtil est apparu une fois Piper intégré : la confirmation
vocale se jouait sans erreur, mais restait inaudible sur l'enceinte
fraîchement connectée. Le serveur Piper garde un process `aplay` **persistant**
ouvert pour toute sa durée de vie (contre le sink par défaut *au moment du
démarrage du service*, souvent bien avant qu'une enceinte Bluetooth ne soit
connectée). Changer le sink par défaut avec `pactl set-default-sink` ne
redirige pas les flux déjà ouverts — PulseAudio ne les migre pas tout seul.
Le correctif : déplacer explicitement tous les `sink-input` existants vers
le nouveau sink Bluetooth juste après l'avoir activé
(`pactl move-sink-input <id> <sink>`).

## 6. Les enceintes à double identité et la limite multipoint

Un incident réel sur le terrain a révélé deux comportements d'enceintes
Bluetooth mal compris au départ :

- **Double identité BLE / BR-EDR.** Une Bose Flex SoundLink annonce deux
  adresses Bluetooth distinctes : une classique BR/EDR (utilisée pour
  l'audio A2DP) et une BLE annexe, préfixée `LE-` dans les scans, pour son
  application de contrôle. Sélectionner la mauvaise MAC (la `LE-*`) lors de
  l'appairage manuel condamne l'audio à ne jamais fonctionner. Pire :
  l'interface classique **n'est visible au scan que pendant que l'enceinte
  est explicitement en mode pairing** (LED clignotante) — une fois
  connectée ou simplement allumée hors pairing, elle n'annonce plus son
  adresse classique du tout.
- **Limite multipoint.** Beaucoup d'enceintes (dont celle-ci) n'acceptent
  que 2 appareils connectés simultanément. Si l'enceinte est déjà "pleine"
  (téléphone + PC, par exemple), le Pi ne peut tout simplement pas se
  connecter tant qu'un des deux slots n'est pas libéré — sans qu'aucun
  message d'erreur ne le dise explicitement. Le diagnostic s'est fait à la
  main (déconnecter un appareil connu, réessayer) avant qu'un indice de log
  explicite soit ajouté au script : après plusieurs échecs de connexion
  consécutifs sur une MAC pourtant détectée, un message suggère
  explicitement de vérifier cette limite.

## 7. Le scan bluetoothctl, structurellement peu fiable

En creusant l'échec de découverte de l'interface classique, un fait plus
général est apparu : `bluetoothctl scan on` (mode "auto" par défaut) ne
détecte pas de façon fiable l'interface BR/EDR classique d'une enceinte,
même en plein mode pairing. `hcitool scan` (inquiry BR/EDR direct) la
trouvait de façon nettement plus systématique — mais cette commande ne fait
pas connaître l'appareil à `bluetoothd` (elle scanne au niveau radio, en
dehors du daemon), ce qui faisait échouer le pairing juste après avec
`Device ... not available`.

La correction a été de forcer `bluetoothctl` lui-même à scanner en
transport `bredr` explicite (au lieu du mode "auto" par défaut), via sa
sous-commande `menu scan` / `transport bredr` — cette fois, la découverte
passe bien par `bluetoothd`, qui enregistre réellement l'appareil.

Deux autres pièges de timing sont apparus juste après :

- **BlueZ purge un appareil "temporaire"** (découvert mais pas encore
  appairé) **dès que la découverte s'arrête** — pas après un délai. Arrêter
  le scan avant même de lancer le pairing (pour "faire propre") supprimait
  donc l'objet qu'on s'apprêtait à appairer. Le scan doit rester actif
  jusqu'à ce que l'appareil soit réellement connecté.
- **`bluetoothctl remove` supprime l'objet device, appairé ou non.** Un
  appel systématique de nettoyage avant le pairing (pour effacer un
  éventuel ancien appairage) est resté inoffensif tant que la découverte
  ne fonctionnait pas vraiment — puis, une fois la découverte corrigée
  ci-dessus, est devenu activement destructeur : il supprimait l'appareil
  qu'on venait tout juste de découvrir, juste avant de le pairer. La
  correction : ne nettoyer que si l'appareil est réellement déjà appairé
  (`Paired: yes`).

## 8. PulseAudio jetable vs persistant, deuxième round

Le même motif qu'au §2 est réapparu sous une forme différente : sans
instance PulseAudio persistante déjà lancée (par exemple parce que le
service avait été arrêté pour un test manuel), les appels `pactl` d'un
script utilitaire déclenchent l'auto-spawn par défaut de PulseAudio — une
instance jetable qui s'éteint dès qu'elle devient inactive, désenregistrant
au passage son endpoint A2DP en plein milieu d'une négociation. Le
correctif a été systématique : démarrer explicitement une instance
persistante (`pulseaudio --start`) et vérifier le `Server String` avant
d'agir, dans chaque script qui touche à l'audio — pas seulement dans le
service principal.

## 9. Le constat : bluetoothctl n'est pas fait pour être scripté

Après cette accumulation de correctifs bash, un dernier problème a mis le
doigt sur une limite structurelle plutôt qu'un simple bug : lancer
`bluetoothctl pair`/`trust`/`connect` comme des commandes séparées, en
parallèle d'une session de scan déjà active en tâche de fond, provoquait
des échecs d'authentification intermittents (`AuthenticationCanceled`,
`AuthenticationFailed`) sans cause évidente dans les logs.

L'explication la plus probable : chaque invocation de `bluetoothctl`
démarre son propre agent d'appairage par défaut. Deux agents actifs en
même temps peuvent se disputer la confirmation SSP (Secure Simple Pairing)
pendant la négociation, et `bluetoothctl` — outil interactif pensé pour un
humain devant un terminal — n'est simplement pas conçu pour ce genre
d'usage concurrent scripté. Ses réponses sont du texte asynchrone à parser,
sans code de retour exploitable ni garantie sur l'agent actif.

Décision : réécrire entièrement la partie Bluetooth en parlant directement
à `bluetoothd` via son API D-Bus, en Python (`bluez_dbus.py`, `bt_manager.py`,
`bt_setup.py`), plutôt que de continuer à durcir des scripts bash autour
d'un outil interactif détourné de son usage. Le modèle retenu — un agent
D-Bus unique, explicite, et des appels `Pair()`/`Connect()` asynchrones
pilotés par une boucle GLib — est celui des scripts de référence du dépôt
BlueZ lui-même (`test/simple-agent`, `test/test-device`) : un appel
strictement bloquant empêcherait l'agent de répondre aux callbacks SSP
pendant la négociation, provoquant un deadlock.

Cette réécriture a aussi permis une simplification bienvenue : `Connect()`
sur un appareil déjà appairé se fait par *page scan*, pas par *inquiry* — il
n'y a donc plus besoin de scanner du tout avant de tenter une reconnexion
automatique (contrairement à la version bash, qui conditionnait
initialement chaque tentative de connexion à une détection préalable au
scan, source de ratés quand ce dernier manquait l'enceinte).

## 10. La validation sur le matériel réel

La réécriture Python a été testée sur le même Raspberry Pi et la même
enceinte Bose Flex SoundLink que tout le reste du projet : pairing, trust
et connexion ont réussi du premier coup, sans aucune retry — signe que la
suppression du conflit d'agents avait bien réglé le problème racine des
`AuthenticationCanceled` intermittents. C'est ce premier test qui a aussi
mis en lumière le bug de nommage `a2dp_sink`/`a2dp-sink` décrit au §4,
resté invisible pendant toute la vie de la version bash faute de capturer
le vrai message d'erreur de `pactl`.

Une fois ce dernier correctif appliqué et le service de reconnexion
automatique validé en conditions réelles (boot, perte de connexion,
confirmation vocale), la réécriture a remplacé définitivement les scripts
bash comme version officielle du dépôt.

## Enseignements transverses

- **Un message d'erreur avalé ne peut jamais être diagnostiqué.** Plusieurs
  bugs de ce projet (le nommage `a2dp_sink`, en particulier) sont restés
  invisibles pendant des semaines simplement parce qu'une redirection
  `2>/dev/null` ou un `capture_output=True` sans lecture masquait le
  message d'erreur réel. Toujours capturer et afficher l'erreur exacte en
  cas d'échec, même (surtout) dans un script "qui marche quand même" par
  ailleurs.
- **La présence d'un objet dans une liste ne garantit pas qu'il est prêt à
  l'usage** (cartes/sinks PulseAudio, appareils Bluetooth temporaires). Un
  contrôle de présence n'est jamais un substitut à un retry sur l'action
  elle-même.
- **Un outil interactif reste un outil interactif**, même scripté avec
  soin : `bluetoothctl` a fini par être remplacé plutôt que patché
  indéfiniment, une fois la limite structurelle (agents concurrents)
  identifiée.
- **Les environnements systemd/PulseAudio ont leurs propres pièges** de
  résolution d'utilisateur/session (`%U`, auto-spawn, instances jetables)
  qui n'ont rien à voir avec la logique métier du script, mais qui la font
  échouer de façon très déroutante si on ne les connaît pas.
