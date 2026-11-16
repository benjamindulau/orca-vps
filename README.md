# orca-vps

Un script unique, `bootstrap.sh`, qui transforme un VPS Ubuntu 26.04 neuf en serveur [Orca](https://www.onorca.dev) distant : les agents Claude Code tournent sur le VPS, et se pilotent depuis un Mac et un téléphone par un tunnel WireGuard.

État final, après `install` puis `lockdown` :

- Le seul port ouvert sur Internet est le port UDP de WireGuard. SSH, Orca et les ports Docker ne répondent que par le tunnel.
- Le serveur Orca tourne en service sous un compte sans privilèges (`dev`) et redémarre seul après un reboot.
- Claude Code, Docker et l'identité Git de l'agent sont installés.
- Aucun flux ne passe par l'éditeur d'Orca : ni relais, ni compte, ni notifications push, ni télémétrie. Voir [Ce qui sort du VPS](#ce-qui-sort-du-vps).

Le modèle est un VPS par projet, avec un seul serveur Orca par VPS.

## Installation

Il faut un VPS Ubuntu 26.04 (amd64 ou arm64, 8 Go de RAM conseillés) et un accès SSH par clé à `root` ou à un compte qui a `sudo`.

1. Connecte-toi au VPS, sans transfert d'agent SSH, et télécharge le script :

   ```bash
   ssh -a <compte>@<ip-publique>
   curl -fsSLO https://raw.githubusercontent.com/benjamindulau/orca-vps/main/bootstrap.sh
   ```

   Le script est autonome : tu peux aussi le copier depuis ton poste avec `scp bootstrap.sh <compte>@<ip-publique>:`. Pour une installation reproductible, remplace `main` par une étiquette ou un commit.

2. Lance l'installation :

   ```bash
   sudo bash bootstrap.sh install
   ```

   Ne le lance pas par `curl … | bash` : le script pose des questions et a besoin du terminal.

   Le script demande l'adresse du serveur dans le tunnel et l'identité Git de l'agent (nom et e-mail du compte GitHub dédié), installe tout, puis affiche la configuration WireGuard de chaque appareil et propose de connecter Claude Code. Compte 5 à 10 minutes.

3. Suis la liste numérotée que le script affiche à la fin. Elle reprend les [étapes manuelles](#étapes-manuelles) ci-dessous.

Le script ne dépend d'aucun hébergeur. Il lui faut une vraie machine virtuelle (KVM), pas un conteneur LXC ou OpenVZ, et une clé SSH déjà installée : si l'hébergeur ne t'a donné qu'un mot de passe, lance d'abord `ssh-copy-id <compte>@<ip-publique>` depuis ton Mac. Voir [Hébergeurs](#hébergeurs) pour les cas particuliers.

**Adresses du tunnel.** Tous les VPS partagent le même plan d'adressage, `10.8.0.0/16` par défaut. Chaque VPS y prend une adresse qui lui est propre (`10.8.0.1`, `10.8.1.1`, `10.8.2.1`…), demandée à l'installation. Chaque appareil garde la même adresse sur tous les VPS (`10.8.0.2` pour le Mac, `10.8.0.3` pour le téléphone). C'est ce qui permet de réunir plusieurs VPS dans un seul tunnel : voir [Plusieurs VPS dans un seul tunnel](#plusieurs-vps-dans-un-seul-tunnel). Ce README utilise `10.8.0.1` dans ses exemples : remplace-la par l'adresse de ton serveur, rappelée à la fin de `install`. Changer `WG_SERVER_IP` puis relancer `install` déplace le serveur en gardant les clés ; le bloc `[Peer]` des appareils est alors à corriger.

Pour une installation sans question, copie `config.example.env` en `config.env` à côté du script, renseigne-le, puis `chmod 600 config.env`. Le script refuse de démarrer si ce fichier est lisible par d'autres comptes.

Après l'installation, le script est aussi disponible sous le nom `orca-vps`, et sa configuration de référence est `/etc/orca-vps/config.env`.

## Étapes manuelles

Six étapes passent par un navigateur, un autre appareil ou un compte tiers. Le script les prépare et les rappelle à la fin de `install`.

1. **Importer la configuration WireGuard** sur le Mac et le téléphone, puis activer le tunnel. `sudo orca-vps add-peer <nom>` réaffiche la configuration et le QR code d'un appareil.
2. **Fermer SSH côté Internet.** Connecte-toi par le tunnel (`ssh -a <compte>@10.8.0.1`), puis lance `sudo orca-vps lockdown`.
3. **Connecter GitHub** avec le compte de l'agent : `sudo orca-vps gh-login` connecte la CLI `gh` (code à saisir sur `github.com/login/device`) et propose d'envoyer la clé SSH de l'agent au compte.
4. **Connecter Claude Code** : `sudo orca-vps claude-login` affiche une URL à ouvrir sur le Mac, puis attend le code à coller.
5. **Appairer le Mac, puis le téléphone**, tunnel actif sur l'appareil : `sudo orca-vps pair` donne le lien à coller dans Settings → Remote Orca Servers → Add Server, et `sudo orca-vps pair --mobile` le QR code pour Orca Mobile.
6. **Régler les appareils** : voir [Réglages côté appareils](#réglages-côté-appareils).

### Clés WireGuard des appareils

Par défaut, le serveur génère la paire de clés de chaque appareil, affiche la configuration une fois (texte et QR code), puis propose de supprimer la clé privée de son disque.

La voie recommandée évite que la clé privée d'un appareil existe sur le serveur : crée le tunnel dans l'application WireGuard de l'appareil (« Add Empty Tunnel » sur Mac), relève sa clé publique et fournis-la, soit dans `config.env` (`WG_PEER_MAC_PUBKEY`), soit avec `sudo orca-vps add-peer mac --pubkey <clé>`. Le script affiche alors le reste de la configuration à coller dans l'application.

### Plusieurs VPS dans un seul tunnel

L'application WireGuard n'active qu'un tunnel à la fois, sur Mac comme sur téléphone. Quand l'appareil a déjà un tunnel vers un autre VPS Orca, n'en crée pas un second : ajoute le nouveau serveur au tunnel existant.

1. Relève la clé publique du tunnel existant dans l'application WireGuard.
2. Fournis-la au nouveau VPS, soit dans `config.env` avant l'installation (`WG_PEER_MAC_PUBKEY`), soit après avec `sudo orca-vps add-peer mac --pubkey <clé publique>`. Le script affiche un bloc `[Peer]`.
3. Dans l'application, modifie le tunnel existant et colle ce bloc `[Peer]` à la fin. La ligne `Address` ne change pas.

Le tunnel garde une seule adresse et joint chaque VPS par l'adresse propre à ce VPS. Les VPS ne se voient pas entre eux : chacun n'accepte dans son tunnel que les adresses de tes appareils, et un appareil ne relaie rien.

Ne donne pas à un appareil une adresse différente par VPS : macOS n'émet que depuis la première adresse du tunnel, et les autres serveurs rejettent alors ses paquets.

`sudo orca-vps remove-peer <nom>` révoque un appareil perdu ou remplacé.

### GitHub : `gh` et clé SSH

Deux accès distincts, tous deux au nom du compte GitHub dédié à l'agent :

- **La CLI `gh`** sert aux agents pour les pull requests, les issues et l'API. Elle se connecte par `sudo orca-vps gh-login`, ou sans question avec un jeton `GH_TOKEN` dans `config.env`.
- **La clé SSH de l'agent** sert à `git clone`, `git pull` et `git push`. Elle est propre à ce VPS et se révoque dans GitHub sans toucher aux autres machines. Pendant `gh-login`, `gh` propose de l'envoyer au compte : accepte. Sinon, ajoute-la à la main (Settings → SSH and GPG keys).

Le jeton de `gh` et la clé SSH sont lisibles par les agents, et ouvrent tous les dépôts auxquels le compte agent est invité.

### Authentification de Claude Code

- **`CLAUDE_AUTH=login`, par défaut.** `orca-vps claude-login` lance `claude auth login` sous `dev`. Le jeton est stocké dans `~/.claude/.credentials.json` et se renouvelle seul. C'est le seul mode qui donne toutes les fonctions.
- **`CLAUDE_AUTH=token`.** Génère sur ton Mac un jeton d'un an avec `claude setup-token` et fournis-le dans `config.env`. Aucune étape manuelle, mais ce jeton ne sert qu'aux requêtes de modèle : ni Remote Control ni connecteurs claude.ai.

Dans les deux cas, le secret est lisible par tout processus de `dev`, donc par les agents.

## Commandes

Toutes se lancent en root, sur le VPS.

| Commande | Rôle |
| --- | --- |
| `install [--only <phase>]` | Toute l'installation, SSH encore ouvert sur Internet |
| `lockdown` | Ferme SSH côté Internet, après contrôle que le tunnel fonctionne |
| `verify` | Rejoue les contrôles et affiche une ligne par test |
| `add-peer <nom> [--pubkey <clé>] [--ip <adresse>]` | Ajoute un appareil WireGuard, ou réaffiche sa configuration |
| `remove-peer <nom>` | Révoque un appareil WireGuard |
| `pair [--mobile]` | Demande un appairage au serveur Orca en marche |
| `gh-login` | Connecte la CLI GitHub sous le compte des agents, et envoie leur clé SSH |
| `claude-login` | Connecte Claude Code sous le compte des agents |
| `update-orca [--force]` | Met Orca à jour et relance le service |

Phases de `install`, dans l'ordre : `preflight`, `system`, `user`, `ssh`, `wireguard`, `firewall`, `orca`, `claude`, `git`, `docker`, `service`, `summary`.

Le script est idempotent : le relancer ne régénère aucune clé, ne relance pas le service Orca s'il tourne déjà, et ne rouvre pas SSH après `lockdown`. Tout est journalisé dans `/var/log/orca-bootstrap.log`. Les secrets (clés privées, QR codes, liens d'appairage) ne vont qu'au terminal, jamais dans le journal.

`lockdown` refuse d'agir si aucun appareil n'a échangé avec le serveur depuis trois minutes, ou si la session SSH courante ne vient pas du tunnel.

Tous les paramètres sont décrits dans [`config.example.env`](config.example.env).

## Réglages côté appareils

- **Mac.** Coupe la télémétrie d'Orca dans Settings → Privacy. Ne crée pas de compte Orca. Connecte-toi au VPS sans transfert d'agent SSH (`ssh -a`).
- **Android.** Orca Mobile n'est pas sur le Play Store : l'APK se télécharge sur `onorca.dev/download/android`. WireGuard n'a pas d'option « à la demande » : active « VPN permanent » dans les paramètres système, sans « Bloquer les connexions sans VPN ».
- **Téléphone.** Refuse Orca Relay et la connexion à un compte, et laisse les notifications push désactivées.
- **Dans Orca.** Le serveur se choisit à l'ajout du projet, pas à la création du worktree. Clone avec l'URL SSH du dépôt (en HTTPS, le clone passe mais la poussée échoue) et saisis `/home/dev/code` comme dossier parent.
- **Versions.** Client et serveur doivent rester compatibles, et Orca publie presque chaque jour : mets à jour le Mac et le téléphone en même temps que le serveur (`sudo orca-vps update-orca`). La mise à jour depuis le Mac n'est pas disponible pour ce type de serveur, c'est normal.
- **Plusieurs VPS.** L'application WireGuard n'active qu'un tunnel à la fois : réunis les serveurs dans un seul tunnel, avec une adresse distincte par VPS (`WG_SERVER_IP=10.8.1.1`, `10.8.2.1`…). Voir [Plusieurs VPS dans un seul tunnel](#plusieurs-vps-dans-un-seul-tunnel).

## Ce qui sort du VPS

Le trafic des sessions va directement de l'appareil au VPS par le tunnel : l'appairage est direct, et le script ne propose jamais l'option `--relay`.

Le serveur Orca contacte en revanche de lui-même plusieurs services, relevés par capture réseau sur Orca 1.4.261 avec la télémétrie coupée :

| Destination | Raison | Traitement |
| --- | --- | --- |
| `github.com`, `release-assets.githubusercontent.com` | Recherche de mises à jour d'Orca | Laissé |
| `orca.dev`, `onorca.dev` | Nouveautés, statistiques et liste de blocage des plugins, notifications push | Bloqué |
| `redirector.gvt1.com` (Google) | Mise à jour des composants du navigateur embarqué (paquet `.deb` seulement) | Bloqué |
| `*.posthog.com` | Télémétrie, déjà coupée par `ORCA_TELEMETRY_DISABLED=1` | Bloqué par précaution |

Le blocage passe par `/etc/hosts` : ces noms deviennent injoignables pour toute la machine. Après blocage, une capture de trois minutes au démarrage du serveur ne montre plus que GitHub. La liste se règle avec `ORCA_BLOCKED_HOSTS` ; une chaîne vide ne bloque rien.

Conséquence à connaître : Orca ne reçoit plus la liste de blocage des plugins que son éditeur publie. N'installe sur ce serveur que des plugins que tu as choisis.

`DO_NOT_TRACK` n'est volontairement pas défini : cette variable est soupçonnée de faire disparaître des modèles du sélecteur de Claude Code.

## Sécurité

- **Pare-feu.** `ufw` refuse tout en entrée par défaut, en IPv4 et en IPv6. Règles restantes après `lockdown` : le port UDP de WireGuard, et tout le trafic entrant sur `wg0`.
- **SSH.** Clé uniquement, mot de passe refusé, joignable par le tunnel seulement.
- **Orca.** Le port `6768` écoute sur toutes les interfaces (l'appairage mobile l'exige), mais n'est joignable que par le tunnel. Le service tourne avec `--refuse-public`, qui refuse en plus toute adresse cliente publique.
- **Docker.** Les ports publiés sont liés par défaut à l'adresse du tunnel (`"ip"` dans `/etc/docker/daemon.json`). Docker contourne `ufw` pour ses ports publiés : une chaîne `DOCKER-USER` refuse donc tout trafic vers un conteneur qui n'arrive ni par le tunnel ni d'un autre conteneur, même si un compose publie un port sur `0.0.0.0`.
- **Compte `dev`.** Ni sudo, ni groupe d'administration. Son appartenance au groupe `docker` est la seule exception.
- **Clés.** Aucune clé personnelle sur le VPS. La seule clé Git est celle du compte agent, propre à cette machine.
- **Mises à jour.** Correctifs de sécurité installés automatiquement. Le redémarrage automatique reste désactivé, pour ne pas couper des agents en cours.

### Risques résiduels

- **Groupe `docker`.** Il équivaut à `root` sur la machine : un agent peut tout y faire. C'est accepté parce que le VPS est dédié à un seul projet. `DOCKER_MODE=rootless` supprime ce risque.
- **Blocage.** Si WireGuard tombe après `lockdown`, le seul accès est la console web de l'hébergeur. Depuis cette console : `ufw allow 22/tcp`.
- **Portée de la clé de l'agent.** Elle ouvre tous les dépôts auxquels le compte agent est invité, pas seulement celui du VPS. Elle se révoque dans GitHub, machine par machine.
- **Agents autonomes.** Les agents exécutent des commandes sous `dev` et lisent tout ce que `dev` peut lire, y compris le jeton Claude et la clé Git. N'y mets que des secrets de développement.
- **Hébergeur.** Il garde un accès physique au disque.

### Pare-feu de l'hébergeur

Le pare-feu réseau de l'hébergeur (Hetzner Cloud Firewall, par exemple) est une seconde couche recommandée. Le script ne le configure pas. Deux règles entrantes suffisent :

1. UDP `51820`, depuis partout : le tunnel WireGuard.
2. TCP `22`, depuis ton adresse IP seulement : à supprimer après `lockdown`.

## Hébergeurs

Le script s'adapte à l'image plutôt qu'à l'hébergeur :

- **Compte d'accès.** Il se lance en `root` directement (Hetzner) ou par `sudo` depuis le compte de l'image (`ubuntu` chez OVH). Les clés copiées vers `dev` sont celles du compte qui lance le script.
- **Adresse publique.** Elle est lue sur la machine. Si le VPS est derrière un NAT (AWS, GCP, Oracle…), le script le détecte et demande l'adresse publique, ou la lit dans `PUBLIC_ENDPOINT`.
- **Réseau privé.** Si le réseau du tunnel chevauche un réseau privé de l'hébergeur, le script s'arrête et demande un autre `WG_NET`.
- **`/etc/hosts` géré par cloud-init.** Le bloc des noms bloqués est aussi écrit dans le modèle de cloud-init, pour survivre aux redémarrages.
- **Pare-feu de l'hébergeur.** S'il existe (Hetzner Cloud Firewall, groupes de sécurité), il doit laisser passer le port UDP de WireGuard, sinon le tunnel ne monte pas.

Limite connue : une image qui arrive avec ses propres règles `iptables` (Oracle Cloud) peut bloquer WireGuard avant `ufw`. Retire ces règles avant l'installation.

## Tests depuis le Mac

`sudo orca-vps verify` couvre ce qui se contrôle depuis le VPS. Le reste se lance depuis le Mac :

1. **Tunnel coupé.** `nc -zv -G 5 <ip-publique> 22` et `nc -zv -G 5 <ip-publique> 6768` échouent tous les deux après `lockdown`.
2. **Tunnel actif.** `ping 10.8.0.1` répond, et `ssh -a dev@10.8.0.1` ouvre une session.
3. **Persistance.** Un agent lancé dans un worktree continue de travailler Mac fermé pendant deux minutes.
4. **Reprise mobile.** La même session s'ouvre sur le téléphone et accepte une réponse.
5. **Redémarrage.** Après `sudo reboot`, le tunnel, le service Orca et les appairages reviennent sans intervention.
6. **Idempotence.** Une seconde exécution de `install` ne modifie aucune clé et laisse les appareils appairés.
7. **Flux sortants.** Pendant une session, sur le VPS, `tcpdump -i any -n 'tcp and not port 22 and not net 10.8.0.0/24'` ne montre que GitHub et Anthropic.

## Modèles par projet

Le dossier [`templates/`](templates) donne à chaque worktree sa propre stack Docker. Ces fichiers se copient dans le dépôt de chaque projet, ils ne s'installent pas sur le VPS.

- **`bin/wt-up`** attribue un nom de projet Compose et des ports à partir de `ORCA_WORKSPACE_NAME`, les note dans `.wt.env`, puis lance `docker compose up -d`. Deux noms peuvent tomber sur le même port : le script avance jusqu'au premier port libre.
- **`bin/wt-down`** lance `docker compose down -v` pour ce même projet.
- **`orca.yaml`** branche les deux scripts sur `scripts.setup` et `scripts.archive`, avec `setupAgentStartupPolicy: wait-for-setup`.

Dans `compose.yaml`, publie chaque port sous la forme `"${WT_BIND}:${WEB_PORT}:80"`, et déclare les variables de port dans `PORT_VARS` en tête de `wt-up`. Ajoute `.wt.env` au `.gitignore` du projet.

## Dépannage

| Symptôme | Cause et parade |
| --- | --- |
| `orca: command not found` | Sous Linux, la commande s'appelle `orca-ide`. |
| `OrcadInstanceLockError`, `orcad_instance_lock_held` | Un second serveur a été lancé. N'utilise jamais `orca-ide serve` pour appairer : `sudo orca-vps pair`. |
| Le port 6768 est pris par un serveur lancé à la main | `sudo orca-vps install --only service` l'arrête et installe le service. |
| « Les mises à jour à distance ne sont pas disponibles pour ce serveur » | Normal. `sudo orca-vps update-orca`. |
| `Syntax error: redirection unexpected` | Le script a été lancé avec `sh`. Utilise `sudo bash bootstrap.sh`. |
| `ssh -T git@github.com` salue ton compte personnel | Transfert d'agent SSH actif. Connecte-toi avec `ssh -a` ; le script impose aussi `IdentitiesOnly` et `IdentityAgent none` pour `github.com`. |
| `claude` introuvable dans un terminal Orca | `sudo orca-vps verify` contrôle le `PATH` du service ; `sudo orca-vps update-orca --force` le réinstalle. |
| Archive serveur absente d'une release | `ORCA_INSTALL_METHOD=tarball` se replie seul sur le paquet `.deb`, avec un message. |
| `Connection refused` sur le port 22 pendant `install` | La mise à jour d'OpenSSH ferme le port une minute environ. La session en cours continue ; réessaie ensuite. |
| Plus d'accès après `lockdown` | Console web de l'hébergeur, puis `ufw allow 22/tcp`. |
| Un conteneur ne démarre pas au boot | Docker attend `wg-quick@wg0` : vérifie `systemctl status wg-quick@wg0`. |

Changer `DOCKER_MODE` ou `ORCA_INSTALL_METHOD` sur une machine déjà installée n'est pas pris en charge : recrée le VPS.

## Constats sur Ubuntu 26.04

Vérifications faites le 16 novembre 2026 sur un VPS Ubuntu 26.04 amd64 (image cloud OpenStack), avec Orca 1.4.261 et Claude Code 2.1.325.

- **Coreutils en Rust (uutils 0.8).** `base64 -w0`, `sha256sum --check`, `shred -u` et `install` se comportent comme attendu.
- **`sudo-rs`.** `sudo -l -U dev` répond « is not allowed to run sudo ». `sudo` efface `SSH_CONNECTION` : `lockdown` retrouve l'origine de la session en remontant les processus parents.
- **OpenSSH 10.2.** L'image cloud dépose `60-cloudimg-settings.conf` ; le script écrit `00-orca-vps.conf`, lu en premier. `ssh-keyscan` écrit désormais des lignes de commentaire sur sa sortie standard.
- **Clés de `root`.** Certaines images posent sur `root` une clé à commande forcée qui renvoie vers un autre compte. Le script copie vers `dev` les clés du compte qui lance `sudo`, et écarte les clés à options.
- **Docker.** Le paquet `docker.io` 29.1.3 d'Ubuntu est retenu, avec `docker-compose-v2` et `docker-buildx` : aucun dépôt tiers, et les correctifs passent par `unattended-upgrades`. Le backend pare-feu est `iptables`. L'adresse de liaison par défaut de `daemon.json` fonctionne. Un port publié sur `0.0.0.0` contourne bien `ufw` : il répondait depuis Internet sans la chaîne `DOCKER-USER`, et plus avec.
- **Docker rootless.** Fonctionne avec le paquet d'Ubuntu, à condition de rendre visibles dans le `PATH` les scripts rangés dans `/usr/share/docker.io/contrib`. Les ports publiés sont alors des écoutes ordinaires, filtrées par `ufw`.
- **Paquet Orca.** Le `.deb` s'installe sans erreur. L'archive « serveur seul » aussi, et `service install --command` l'accepte.
- **Environnement du service.** `orca-ide serve service install` ne fige que `PATH` dans l'unité systemd. Le script ajoute un drop-in qui charge `~/.config/orca-vps/service.env`.
- **Écoute d'Orca.** `0.0.0.0:6768`, en IPv4 seulement.
- **`orca-ide pair`.** Fonctionne contre le service, sans rien relancer.
- **AppArmor.** `wg` ne lit ses fichiers de configuration que sous `/etc/wireguard`.

Non vérifié : arm64, Ubuntu 24.04, Hetzner Cloud, le mode `token` de Claude Code dans Orca, le filtrage IPv6 vu de l'extérieur, et le déclenchement de `wt-up` et `wt-down` par Orca lui-même (les scripts ont été testés à la main).

## Développement

```bash
shellcheck bootstrap.sh templates/bin/wt-up templates/bin/wt-down
```

Le même contrôle tourne à chaque push (`.github/workflows/shellcheck.yml`). Valide toute modification sur un VPS jetable, recréé à neuf entre deux essais.
