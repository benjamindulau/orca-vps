# orca-vps

`bootstrap.sh` transforme un VPS Ubuntu neuf en serveur [Orca](https://www.onorca.dev) distant, joignable uniquement par un tunnel WireGuard. Les agents Claude Code tournent sur le VPS et se pilotent depuis un ordinateur et un téléphone.

À la fin de la procédure :

- seul le port UDP de WireGuard est ouvert sur Internet ; SSH, Orca et Docker ne répondent que par le tunnel ;
- Orca tourne en service sous un compte sans privilèges (`dev`) ;
- Claude Code et `gh` sont authentifiés, Docker est installé ;
- un ordinateur et un téléphone sont reliés au VPN et appairés dans Orca ;
- aucun flux ne passe par l'éditeur d'Orca (ni relais, ni compte, ni télémétrie).

## Prérequis

- Un VPS **Ubuntu 26.04** (machine virtuelle KVM, amd64 ou arm64, 8 Go de RAM conseillés).
- Un accès SSH **par clé** à `root` ou à un compte `sudo`.
- Un **compte GitHub dédié à l'agent**, distinct du compte personnel.
- Sur l'ordinateur : [WireGuard](https://www.wireguard.com/install/) et Orca. Sur le téléphone : WireGuard et Orca Mobile.
- Si l'hébergeur a un pare-feu réseau : y ouvrir le port **UDP 51820**.

## Installation complète

### 1. Lancer l'installation

```bash
ssh -a <compte>@<ip-publique>
curl -fsSLO https://raw.githubusercontent.com/benjamindulau/orca-vps/main/bootstrap.sh
sudo bash bootstrap.sh install
```

Le script pose deux questions, puis installe tout (5 à 10 minutes) :

| Question | Réponse |
| --- | --- |
| Adresse de ce serveur dans le tunnel | `10.8.0.1` pour un premier VPS, puis `10.8.1.1`, `10.8.2.1`… Une adresse différente par VPS. |
| Identité Git de l'agent | Nom et e-mail du compte GitHub de l'agent. |

> Ne pas lancer le script par `curl … | bash` : il a besoin du terminal pour poser ses questions.

### 2. Relier l'ordinateur et le téléphone au VPN

À la fin de l'installation, le script affiche la configuration WireGuard de deux appareils, `mac` (l'ordinateur) et `phone` :

- **Ordinateur** : copier la configuration affichée dans un fichier `orca.conf`, l'importer dans WireGuard, activer le tunnel.
- **Téléphone** : dans WireGuard, « Scanner un QR code », puis activer le tunnel.

Répondre `o` à la question qui suit pour supprimer la clé privée du serveur.

> Pour réafficher une configuration : `sudo orca-vps add-peer mac` ou `sudo orca-vps add-peer phone`.
>
> Si l'appareil a déjà un tunnel vers un autre VPS Orca, voir [Plusieurs VPS](#plusieurs-vps).

### 3. Authentifier GitHub

Accepter la question « Connecter GitHub (gh) maintenant ? », ou lancer plus tard :

```bash
sudo orca-vps gh-login
```

1. Accepter l'envoi de la clé SSH proposé par `gh` : `git clone` et `git push` passent par cette clé.
2. Copier le code affiché et le saisir sur <https://github.com/login/device>, connecté avec le **compte de l'agent**.

### 4. Authentifier Claude Code

Accepter la question « Connecter Claude Code maintenant ? », ou lancer plus tard :

```bash
sudo orca-vps claude-login
```

Ouvrir l'URL affichée dans un navigateur, puis coller le code dans le terminal.

### 5. Fermer SSH côté Internet

Se reconnecter **par le tunnel**, à l'adresse choisie à l'étape 1, puis verrouiller :

```bash
ssh -a <compte>@10.8.0.1
sudo orca-vps lockdown
```

> `lockdown` refuse d'agir si la session SSH ne vient pas du tunnel. En cas de perte d'accès par la suite : console web de l'hébergeur, puis `ufw allow 22/tcp`.

### 6. Appairer l'ordinateur dans Orca

```bash
sudo orca-vps pair
```

Coller le lien affiché dans Orca : Settings → Remote Orca Servers → Add Server.

### 7. Appairer le téléphone dans Orca

```bash
sudo orca-vps pair --mobile
```

Scanner le QR code dans Orca Mobile. Refuser Orca Relay et la connexion à un compte.

> Android : Orca Mobile se télécharge sur `onorca.dev/download/android`. Activer « VPN permanent » pour WireGuard dans les paramètres système.

### 8. Contrôler

```bash
sudo orca-vps verify
```

Attendu : `0 échec(s), 0 avertissement(s)`.

### 9. Ajouter un projet

Dans Orca, ajouter un projet en choisissant ce serveur, cloner avec l'**URL SSH** du dépôt, dossier parent `/home/dev/code`.

## Commandes

Sur le VPS, en root. Après l'installation, le script s'appelle `orca-vps`.

| Commande | Rôle |
| --- | --- |
| `install [--only <phase>]` | Installe tout. Peut être relancée sans risque : aucune clé n'est régénérée. |
| `lockdown` | Ferme SSH côté Internet. |
| `verify` | Contrôle l'installation, une ligne par test. |
| `add-peer <nom> [--pubkey <clé>] [--ip <adresse>]` | Ajoute un appareil au VPN, ou réaffiche sa configuration. |
| `remove-peer <nom>` | Révoque un appareil (perdu, remplacé). |
| `pair [--mobile]` | Appaire un ordinateur ou un téléphone dans Orca. |
| `gh-login` | Authentifie `gh` et envoie la clé SSH de l'agent. |
| `claude-login` | Authentifie Claude Code. |
| `update-orca [--force]` | Met Orca à jour et relance le service. |

Journal : `/var/log/orca-bootstrap.log` (sans aucun secret).

## Mise à jour d'Orca

```bash
sudo orca-vps update-orca
```

Mettre à jour Orca sur l'ordinateur et le téléphone en même temps : client et serveur doivent rester compatibles. La mise à jour depuis l'application n'est pas disponible pour ce type de serveur.

## Configuration

Sans fichier de configuration, le script pose ses questions et prend les valeurs par défaut. Pour tout régler, ou installer sans question :

```bash
cp config.example.env config.env   # à côté de bootstrap.sh
chmod 600 config.env
```

Tous les paramètres sont décrits dans [`config.example.env`](config.example.env) : compte, tunnel, version et mode d'installation d'Orca, authentification par jeton (`CLAUDE_AUTH=token`, `GH_TOKEN`), Docker rootless, fichier d'échange, fuseau horaire. Après l'installation, la configuration de référence est `/etc/orca-vps/config.env`.

## Plusieurs VPS

Tous les VPS partagent le même réseau de tunnel (`10.8.0.0/16`). Chaque VPS y a sa propre adresse, et chaque appareil garde la même adresse partout (`10.8.0.2` pour `mac`, `10.8.0.3` pour `phone`).

L'application WireGuard n'active qu'un tunnel à la fois : pour un appareil déjà relié à un VPS, ajouter le nouveau serveur **au tunnel existant** plutôt que d'en créer un second.

1. Relever la clé publique du tunnel existant (section « Interface » dans WireGuard).
2. Sur le nouveau VPS :

   ```bash
   sudo orca-vps add-peer mac --pubkey <clé publique>
   ```

3. Dans WireGuard, modifier le tunnel existant et y ajouter le bloc `[Peer]` affiché par le script.

Les VPS ne se voient pas entre eux.

## Sécurité

- **Pare-feu** : `ufw` refuse tout en entrée (IPv4 et IPv6), sauf le port UDP de WireGuard et le trafic du tunnel.
- **SSH** : clé uniquement, joignable par le tunnel seulement après `lockdown`.
- **Compte `dev`** : sans sudo. Il fait tourner Orca, les agents, Claude Code, `gh` et Docker.
- **Docker** : les ports publiés sont liés à l'adresse du tunnel, et une chaîne `DOCKER-USER` bloque tout accès public à un conteneur, même publié sur `0.0.0.0`.
- **Flux sortants** : les noms de l'éditeur d'Orca, de sa télémétrie et du service de mise à jour du navigateur embarqué sont bloqués dans `/etc/hosts` (`ORCA_BLOCKED_HOSTS`). Orca ne reçoit donc plus la liste de blocage des plugins de son éditeur.
- **Mises à jour** : correctifs de sécurité automatiques, sans redémarrage automatique.

Risques résiduels :

- **Groupe `docker`** : il équivaut à `root` sur la machine. `DOCKER_MODE=rootless` supprime ce risque.
- **Agents** : ils lisent tout ce que `dev` peut lire, dont le jeton Claude, le jeton `gh` et la clé SSH. N'y mettre que des secrets de développement.
- **Compte GitHub de l'agent** : la clé et le jeton ouvrent tous les dépôts auxquels ce compte est invité.
- **Perte du tunnel** : après `lockdown`, le seul accès de secours est la console web de l'hébergeur.

## Stack Docker par worktree

[`templates/`](templates) contient de quoi donner à chaque worktree sa propre stack Docker. Ces fichiers se copient dans le dépôt de chaque projet :

- `bin/wt-up` : attribue des ports libres, les note dans `.wt.env`, lance `docker compose up -d` ;
- `bin/wt-down` : lance `docker compose down -v` ;
- `orca.yaml` : branche ces scripts sur la création et l'archivage d'un worktree.

Dans `compose.yaml`, publier les ports sous la forme `"${WT_BIND}:${WEB_PORT}:80"`, déclarer les variables dans `PORT_VARS` en tête de `wt-up`, et ajouter `.wt.env` au `.gitignore`.

## Dépannage

| Symptôme | Solution |
| --- | --- |
| `orca: command not found` | Sous Linux, la commande s'appelle `orca-ide`. |
| `Syntax error: redirection unexpected` | Lancer le script avec `bash`, pas `sh`. |
| `Connection refused` sur le port 22 pendant `install` | La mise à jour d'OpenSSH ferme le port une minute. La session en cours continue. |
| Le tunnel ne monte pas | Ouvrir le port UDP 51820 dans le pare-feu de l'hébergeur. |
| VPS derrière un NAT (AWS, GCP, Oracle) | Le script demande l'adresse publique, ou la lit dans `PUBLIC_ENDPOINT`. |
| L'hébergeur n'a donné qu'un mot de passe | Installer d'abord une clé : `ssh-copy-id <compte>@<ip-publique>`. |
| `OrcadInstanceLockError` | Un second serveur a été lancé. Pour appairer : `sudo orca-vps pair`, jamais `orca-ide serve`. |
| `ssh -T git@github.com` salue le compte personnel | Se connecter au VPS sans transfert d'agent : `ssh -a`. |
| Le clone passe mais la poussée échoue | Cloner avec l'URL SSH du dépôt, pas HTTPS. |
| « Les mises à jour à distance ne sont pas disponibles » | Normal : `sudo orca-vps update-orca`. |
| Plus d'accès après `lockdown` | Console web de l'hébergeur, puis `ufw allow 22/tcp`. |

Changer `DOCKER_MODE` ou `ORCA_INSTALL_METHOD` sur un VPS déjà installé n'est pas pris en charge : recréer le VPS.

## Pour aller plus loin

[`docs/notes-techniques.md`](docs/notes-techniques.md) détaille les flux sortants relevés, les constats sur Ubuntu 26.04 et ce qui n'a pas été vérifié.

## Développement

```bash
shellcheck bootstrap.sh templates/bin/wt-up templates/bin/wt-down
```

Le même contrôle tourne à chaque push. Valider toute modification sur un VPS jetable.
