# Notes techniques

Relevés faits le 16 novembre 2026 sur un VPS Ubuntu 26.04 amd64 (image cloud OpenStack), avec Orca 1.4.261 et Claude Code 2.1.325.

## Flux sortants du serveur Orca

Les sessions vont directement de l'appareil au VPS par le tunnel : l'appairage est direct, et le script ne propose jamais l'option `--relay`.

Le serveur Orca contacte en revanche de lui-même plusieurs services, même télémétrie coupée (capture réseau au démarrage du service) :

| Destination | Raison | Traitement |
| --- | --- | --- |
| `github.com`, `release-assets.githubusercontent.com` | Recherche de mises à jour d'Orca | Laissé |
| `orca.dev`, `onorca.dev` | Nouveautés, statistiques et liste de blocage des plugins, notifications push | Bloqué |
| `redirector.gvt1.com` (Google) | Mise à jour des composants du navigateur embarqué (paquet `.deb` seulement) | Bloqué |
| `*.posthog.com` | Télémétrie, déjà coupée par `ORCA_TELEMETRY_DISABLED=1` | Bloqué par précaution |

Le blocage passe par `/etc/hosts`. Après blocage, une capture de trois minutes ne montre plus que GitHub. Si cloud-init régénère `/etc/hosts` au démarrage, le bloc est aussi écrit dans son modèle.

`DO_NOT_TRACK` n'est volontairement pas défini : cette variable est soupçonnée de faire disparaître des modèles du sélecteur de Claude Code.

## Constats sur Ubuntu 26.04

- **Coreutils en Rust (uutils 0.8).** `base64 -w0`, `sha256sum --check`, `shred -u` et `install` se comportent comme attendu.
- **`sudo-rs`.** `sudo -l -U dev` répond « is not allowed to run sudo ». `sudo` efface `SSH_CONNECTION` : `lockdown` retrouve l'origine de la session en remontant les processus parents.
- **OpenSSH 10.2.** L'image cloud dépose `60-cloudimg-settings.conf` ; le script écrit `00-orca-vps.conf`, lu en premier. `ssh-keyscan` écrit des lignes de commentaire sur sa sortie standard.
- **Clés de `root`.** Certaines images posent sur `root` une clé à commande forcée qui renvoie vers un autre compte. Le script copie vers `dev` les clés du compte qui lance `sudo`, et écarte les clés à options.
- **Docker.** Le paquet `docker.io` 29.1.3 d'Ubuntu est retenu, avec `docker-compose-v2` et `docker-buildx` : aucun dépôt tiers. Le backend pare-feu est `iptables`. Un port publié sur `0.0.0.0` contourne `ufw` : il répondait depuis Internet sans la chaîne `DOCKER-USER`, et plus avec.
- **Docker rootless.** Fonctionne avec le paquet d'Ubuntu, une fois rendus visibles dans le `PATH` les scripts rangés dans `/usr/share/docker.io/contrib`. Les ports publiés sont alors des écoutes ordinaires, filtrées par `ufw`.
- **`gh` 2.46.** `gh auth status` répond 0 même sans jeton valide : le script interroge l'API pour savoir si `gh` est connecté.
- **Paquet Orca.** Le `.deb` et l'archive « serveur seul » s'installent sans erreur.
- **Environnement du service.** `orca-ide serve service install` ne fige que `PATH` dans l'unité systemd. Le script ajoute un drop-in qui charge `~/.config/orca-vps/service.env`.
- **Écoute d'Orca.** `0.0.0.0:6768`, en IPv4 seulement. Le service tourne avec `--refuse-public`.
- **AppArmor.** `wg` ne lit ses fichiers de configuration que sous `/etc/wireguard`.

## Tunnel et adresses

- L'application WireGuard n'active qu'un tunnel à la fois, sur ordinateur comme sur téléphone.
- macOS n'émet que depuis la première adresse d'un tunnel. Un appareil garde donc une seule adresse, la même sur tous les VPS, et chaque VPS a sa propre adresse dans un réseau commun.
- Le script reprend un serveur installé à la main : appareils déjà déclarés dans `wg0.conf`, adresse du tunnel, identité Git.

## Non vérifié

- arm64, Ubuntu 24.04, Hetzner Cloud et les VPS derrière un NAT.
- Le mode `token` de Claude Code dans Orca.
- Le filtrage IPv6 vu de l'extérieur.
- Le déclenchement de `wt-up` et `wt-down` par Orca lui-même (les scripts ont été testés à la main).

## Tests depuis un poste client

`sudo orca-vps verify` couvre ce qui se contrôle depuis le VPS. Le reste se lance depuis un appareil relié au tunnel :

1. Tunnel coupé : `nc -zv <ip-publique> 22` et `nc -zv <ip-publique> 6768` échouent après `lockdown`.
2. Tunnel actif : `ping 10.8.0.1` répond, et `ssh -a dev@10.8.0.1` ouvre une session.
3. Un agent lancé dans un worktree continue de travailler, ordinateur fermé.
4. La même session s'ouvre sur le téléphone et accepte une réponse.
5. Après `sudo reboot`, le tunnel, le service Orca et les appairages reviennent seuls.
