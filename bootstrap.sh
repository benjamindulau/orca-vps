#!/usr/bin/env bash
# shellcheck disable=SC2016  # les sh -c '…' gardent volontairement leurs variables pour le shell appelé
# bootstrap.sh : transforme un VPS Ubuntu 26.04 neuf en serveur Orca distant,
# joignable uniquement par un tunnel WireGuard.
#
# Usage (en root, sur le VPS) :
#   sudo ./bootstrap.sh install [--only <phase>]
#   sudo ./bootstrap.sh lockdown
#   sudo ./bootstrap.sh verify
#   sudo ./bootstrap.sh add-peer <nom> [--pubkey <clé>] [--ip <adresse>]
#   sudo ./bootstrap.sh remove-peer <nom>
#   sudo ./bootstrap.sh pair [--mobile]
#   sudo ./bootstrap.sh gh-login
#   sudo ./bootstrap.sh claude-login
#   sudo ./bootstrap.sh update-orca [--force]
#
# Le fichier est autonome : il se copie seul sur le VPS, avec config.env.

# Refus de tourner sous sh/dash : le script utilise des here-strings.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "ERREUR : ce script exige Bash. Lance-le avec : sudo bash $0" >&2
  exit 1
fi

set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
STATE_DIR=/etc/orca-vps
STATE_CONFIG="$STATE_DIR/config.env"
PEERS_DIR="$STATE_DIR/peers"
CLIENTS_DIR="$STATE_DIR/clients"
LOCKDOWN_MARKER="$STATE_DIR/lockdown.done"
INSTALLED_SCRIPT=/usr/local/sbin/orca-vps
LOG_FILE=/var/log/orca-bootstrap.log
WG_DIR=/etc/wireguard
WG_IF=wg0
ORCA_RELEASES=https://github.com/stablyai/orca/releases
ORCA_TARBALL_DIR=/opt/orca-server
ORCA_UNIT=orca-serve.service
PHASES=(preflight system user ssh wireguard firewall orca claude git docker service summary)

# Empreintes SHA-256 des clés d'hôte de GitHub, publiées sur
# https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
# et par https://api.github.com/meta (relevées le 16 novembre 2026).
GITHUB_FINGERPRINTS=(
  "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU"
  "SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM"
  "SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s"
)

# Noms que le serveur Orca contacte de lui-même et qui ne sont ni GitHub ni
# Anthropic (relevé par capture réseau sur Orca 1.4.261) : le site de
# l'éditeur (nouveautés, statistiques et liste de blocage des plugins,
# notifications push), sa télémétrie, et le service de mise à jour des
# composants du navigateur embarqué.
DEFAULT_BLOCKED_HOSTS="orca.dev www.orca.dev onorca.dev www.onorca.dev push.onorca.dev us.i.posthog.com eu.i.posthog.com us-assets.i.posthog.com eu-assets.i.posthog.com redirector.gvt1.com"

CURRENT_PHASE="démarrage"
CONFIG_FILE=""
ORCA_UID=""
ORCA_HOME=""
TEE_PID=""
LAST_AS_USER=""

# --- Affichage, journal, erreurs ---------------------------------------------

log()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'ATTENTION : %s\n' "$*" >&2; }
die()  { printf '\nERREUR (%s) : %s\n' "$CURRENT_PHASE" "$*" >&2; exit 1; }

# Écrit sur le terminal sans passer par le journal : réservé aux secrets
# (clés privées, QR codes, liens d'appairage) et aux questions.
tty_out() { printf '%s\n' "$*" >&3; }

on_error() {
  local rc=$1 line=$2 cmd=$3
  # Dans un sous-shell, on laisse le shell principal rapporter l'erreur une seule fois.
  [ "$BASHPID" = "$$" ] || return 0
  case "$cmd" in runuser*) cmd="(sous $ORCA_USER) $LAST_AS_USER" ;; esac
  printf '\nERREUR pendant la phase « %s » (ligne %s, code %s). Commande en échec :\n    %s\n' \
    "$CURRENT_PHASE" "$line" "$rc" "$cmd" >&2
  printf 'Le script s'\''arrête ici. Il est idempotent : corrige la cause, puis relance-le.\n' >&2
  printf 'Journal : %s\n' "$LOG_FILE" >&2
}

on_exit() {
  local rc=$?
  if [ -n "$TEE_PID" ]; then
    exec 1>&3 2>&4
    wait "$TEE_PID" 2>/dev/null || true
  fi
  exit "$rc"
}

setup_logging() {
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE"
  exec 3>&1 4>&2
  exec > >(tee -a "$LOG_FILE") 2>&1
  TEE_PID=$!
  printf '\n===== %s : bootstrap.sh %s =====\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*"
}

# Laisse le journal rattraper la sortie avant d'écrire directement au terminal.
flush_output() { sleep 0.3; }

is_interactive() { [ -t 0 ] && [ -t 3 ]; }

# ask <variable> <question> [défaut]
ask() {
  local __var=$1 question=$2 default=${3:-} __answer=""
  flush_output
  if [ -n "$default" ]; then
    printf '%s [%s] : ' "$question" "$default" >&3
  else
    printf '%s : ' "$question" >&3
  fi
  read -r __answer || true
  [ -n "$__answer" ] || __answer="$default"
  printf -v "$__var" '%s' "$__answer"
}

# confirm <question> [o|n] : réponse par défaut en second argument.
confirm() {
  local question=$1 default=${2:-n} answer="" hint="[o/N]"
  [ "$default" = o ] && hint="[O/n]"
  is_interactive || { [ "$default" = o ]; return; }
  flush_output
  printf '%s %s ' "$question" "$hint" >&3
  read -r answer || true
  [ -n "$answer" ] || answer="$default"
  case "$answer" in o|O|oui|OUI|y|Y|yes) return 0 ;; *) return 1 ;; esac
}

# --- Configuration -------------------------------------------------------------

find_config() {
  if [ -f "$SCRIPT_DIR/config.env" ]; then
    CONFIG_FILE="$SCRIPT_DIR/config.env"
  elif [ -f "$STATE_CONFIG" ]; then
    CONFIG_FILE="$STATE_CONFIG"
  else
    CONFIG_FILE=""
  fi
}

load_config() {
  find_config
  if [ -n "$CONFIG_FILE" ]; then
    local mode
    mode="$(stat -c '%a' "$CONFIG_FILE")"
    case "$mode" in
      *00) ;;
      *) die "$CONFIG_FILE est lisible par d'autres comptes (mode $mode). Lance : chmod 600 $CONFIG_FILE" ;;
    esac
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi

  ORCA_USER="${ORCA_USER:-dev}"
  GIT_USER_NAME="${GIT_USER_NAME:-}"
  GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"
  # Plan d'adressage : un réseau commun à tous les VPS (WG_NET), une adresse
  # distincte par serveur, et pour chaque appareil la même adresse partout.
  # Un appareil réunit ainsi tous ses serveurs dans un seul tunnel, avec une
  # seule adresse. L'adresse du serveur est demandée par install si elle
  # n'est pas dans la configuration.
  WG_NET="${WG_NET:-10.8.0.0/16}"
  WG_SERVER_IP_CONFIG="${WG_SERVER_IP:-}"
  WG_PEERS_CONFIG="${WG_PEERS-__défaut__}"
  WG_PORT="${WG_PORT:-51820}"
  PUBLIC_ENDPOINT="${PUBLIC_ENDPOINT:-}"
  ORCA_PORT="${ORCA_PORT:-6768}"
  ORCA_INSTALL_METHOD="${ORCA_INSTALL_METHOD:-deb}"
  ORCA_VERSION="${ORCA_VERSION:-latest}"
  ORCA_TERMINAL_MEMORY_MAX="${ORCA_TERMINAL_MEMORY_MAX:-}"
  ORCA_CODE_DIR="${ORCA_CODE_DIR:-code}"
  ORCA_BLOCKED_HOSTS="${ORCA_BLOCKED_HOSTS-$DEFAULT_BLOCKED_HOSTS}"
  CLAUDE_AUTH="${CLAUDE_AUTH:-login}"
  CLAUDE_CODE_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN:-}"
  CLAUDE_DEFAULT_MODEL="${CLAUDE_DEFAULT_MODEL:-}"
  GH_TOKEN="${GH_TOKEN:-}"
  DOCKER_MODE="${DOCKER_MODE:-group}"
  SWAP_SIZE="${SWAP_SIZE:-4G}"
  TIMEZONE="${TIMEZONE:-Europe/Paris}"
  SSH_KEYS_FROM="${SSH_KEYS_FROM:-}"

  [[ "$ORCA_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "ORCA_USER invalide : $ORCA_USER"
  [ "$ORCA_USER" != root ] || die "ORCA_USER ne peut pas être root."
  valid_wg_net "$WG_NET" || die "WG_NET invalide : $WG_NET (attendu : un réseau privé comme 10.8.1.0/24, préfixe de /16 à /29)."
  derive_wg_settings
  is_port "$WG_PORT" || die "WG_PORT invalide : $WG_PORT"
  is_port "$ORCA_PORT" || die "ORCA_PORT invalide : $ORCA_PORT"
  case "$ORCA_INSTALL_METHOD" in deb|tarball) ;; *) die "ORCA_INSTALL_METHOD doit valoir deb ou tarball." ;; esac
  case "$CLAUDE_AUTH" in login|token) ;; *) die "CLAUDE_AUTH doit valoir login ou token." ;; esac
  case "$DOCKER_MODE" in group|rootless) ;; *) die "DOCKER_MODE doit valoir group ou rootless." ;; esac
  if [ "$CLAUDE_AUTH" = token ] && [ -z "$CLAUDE_CODE_OAUTH_TOKEN" ]; then
    die "CLAUDE_AUTH=token exige CLAUDE_CODE_OAUTH_TOKEN dans config.env."
  fi
  [ "${DO_NOT_TRACK:-}" = "" ] || warn "DO_NOT_TRACK est défini dans l'environnement : le script ne le transmet pas à Orca."
}

valid_wg_net() {
  local net=$1 prefix
  [[ "$net" =~ ^[0-9.]+/[0-9]+$ ]] && is_ipv4 "${net%/*}" || return 1
  prefix="${net#*/}"
  [ "$prefix" -ge 16 ] && [ "$prefix" -le 29 ] || return 1
  is_private_ipv4 "${net%/*}"
}

# Déduit de WG_NET l'adresse du serveur (première adresse) et celles des
# appareils par défaut (les deux suivantes), sauf valeurs explicites.
derive_wg_settings() {
  local base mask
  WG_PREFIX="${WG_NET#*/}"
  mask=$(( (0xFFFFFFFF << (32 - WG_PREFIX)) & 0xFFFFFFFF ))
  base=$(( $(ip_to_int "${WG_NET%/*}") & mask ))
  WG_NET="$(int_to_ip "$base")/$WG_PREFIX"
  WG_SERVER_IP="${WG_SERVER_IP_CONFIG:-$(int_to_ip $(( base + 1 )))}"
  if [ "$WG_PEERS_CONFIG" = "__défaut__" ]; then
    WG_PEERS="mac:$(int_to_ip $(( base + 2 ))) phone:$(int_to_ip $(( base + 3 )))"
  else
    WG_PEERS="$WG_PEERS_CONFIG"
  fi
  is_ipv4 "$WG_SERVER_IP" || die "WG_SERVER_IP invalide : $WG_SERVER_IP"
  ip_in_cidr "$WG_SERVER_IP" "$WG_NET" || die "WG_SERVER_IP ($WG_SERVER_IP) est hors de WG_NET ($WG_NET)."
}

# Demande l'adresse du serveur dans le tunnel à la première installation.
# Elle doit être propre à chaque VPS : la valeur se confirme, elle ne se
# suppose pas.
ensure_wg_server_ip() {
  local choice="" current
  [ -z "$WG_SERVER_IP_CONFIG" ] || return 0
  # Tunnel déjà en place : on garde son adresse.
  current="$(ip -4 -o addr show dev "$WG_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
  if [ -n "$current" ] && ip_in_cidr "$current" "$WG_NET"; then
    WG_SERVER_IP="$current"
  fi
  if [ ! -s "$WG_DIR/server.key" ] && is_interactive; then
    tty_out ""
    tty_out "Adresse de ce serveur dans le tunnel WireGuard (réseau $WG_NET)."
    tty_out "Elle doit être différente pour chacun de tes VPS : 10.8.0.1, 10.8.1.1, 10.8.2.1…"
    tty_out "Tes appareils gardent la même adresse sur tous les VPS ($WG_PEERS)."
    while :; do
      ask choice "  Adresse de ce serveur" "$WG_SERVER_IP"
      if is_ipv4 "$choice" && ip_in_cidr "$choice" "$WG_NET" && [[ " $WG_PEERS " != *":$choice "* ]]; then break; fi
      tty_out "  Valeur invalide : attendu une adresse de $WG_NET qui n'est pas celle d'un appareil."
    done
    WG_SERVER_IP="$choice"
  fi
  WG_SERVER_IP_CONFIG="$WG_SERVER_IP"
  set_config_value WG_NET "$WG_NET"
  set_config_value WG_SERVER_IP "$WG_SERVER_IP"
}

# Ajoute ou remplace une valeur dans le fichier de configuration.
set_config_value() {
  local key=$1 value=$2 escaped tmp
  escaped="${value//\'/\'\\\'\'}"
  tmp="$(mktemp)"
  grep -v "^${key}=" "$CONFIG_FILE" > "$tmp" || true
  printf "%s='%s'\n" "$key" "$escaped" >> "$tmp"
  install -m 600 "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
}

# Crée le fichier de configuration s'il manque, demande l'identité Git si elle
# n'est pas renseignée, puis conserve une copie de référence dans /etc/orca-vps.
ensure_install_config() {
  install -d -m 700 "$STATE_DIR"
  if [ -z "$CONFIG_FILE" ]; then
    CONFIG_FILE="$STATE_CONFIG"
    install -m 600 /dev/null "$CONFIG_FILE"
    info "Aucun config.env trouvé : création de $CONFIG_FILE avec les valeurs par défaut."
  fi
  ensure_wg_server_ip
  if { [ -z "$GIT_USER_NAME" ] || [ -z "$GIT_USER_EMAIL" ]; } && id "$ORCA_USER" >/dev/null 2>&1; then
    # Serveur déjà configuré : on reprend l'identité Git en place.
    local current_name current_email
    current_name="$(runuser -u "$ORCA_USER" -- git config --global user.name 2>/dev/null || true)"
    current_email="$(runuser -u "$ORCA_USER" -- git config --global user.email 2>/dev/null || true)"
    if [ -n "$current_name" ] && [ -n "$current_email" ]; then
      GIT_USER_NAME="$current_name"
      GIT_USER_EMAIL="$current_email"
      set_config_value GIT_USER_NAME "$GIT_USER_NAME"
      set_config_value GIT_USER_EMAIL "$GIT_USER_EMAIL"
      info "Identité Git existante de $ORCA_USER reprise : $GIT_USER_NAME <$GIT_USER_EMAIL>."
    fi
  fi
  if [ -z "$GIT_USER_NAME" ] || [ -z "$GIT_USER_EMAIL" ]; then
    is_interactive || die "GIT_USER_NAME et GIT_USER_EMAIL sont obligatoires. Renseigne-les dans config.env, ou lance le script dans un terminal pour les saisir."
    tty_out ""
    tty_out "Identité Git de l'agent (le compte GitHub dédié, pas ton compte personnel) :"
    while [ -z "$GIT_USER_NAME" ]; do ask GIT_USER_NAME "  Nom affiché dans les commits"; done
    while [ -z "$GIT_USER_EMAIL" ]; do ask GIT_USER_EMAIL "  Adresse e-mail du compte agent"; done
    set_config_value GIT_USER_NAME "$GIT_USER_NAME"
    set_config_value GIT_USER_EMAIL "$GIT_USER_EMAIL"
  fi
  if [ "$CONFIG_FILE" != "$STATE_CONFIG" ]; then
    install -m 600 -o root -g root "$CONFIG_FILE" "$STATE_CONFIG"
  fi
}

# --- Outils --------------------------------------------------------------------

is_ipv4() {
  local ip=$1 a b c d
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]} c=${BASH_REMATCH[3]} d=${BASH_REMATCH[4]}
  [ "$a" -le 255 ] && [ "$b" -le 255 ] && [ "$c" -le 255 ] && [ "$d" -le 255 ]
}

is_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

ip_to_int() {
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  echo $(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))
}

int_to_ip() {
  printf '%d.%d.%d.%d' $(( ($1 >> 24) & 255 )) $(( ($1 >> 16) & 255 )) $(( ($1 >> 8) & 255 )) $(( $1 & 255 ))
}

# ip_in_cidr <ip> <réseau/préfixe>
ip_in_cidr() {
  local ip=$1 net=${2%/*} prefix=${2#*/} mask
  is_ipv4 "$ip" || return 1
  mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  [ $(( $(ip_to_int "$ip") & mask )) -eq $(( $(ip_to_int "$net") & mask )) ]
}

is_private_ipv4() {
  ip_in_cidr "$1" 10.0.0.0/8 || ip_in_cidr "$1" 172.16.0.0/12 || ip_in_cidr "$1" 192.168.0.0/16 || ip_in_cidr "$1" 100.64.0.0/10
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -q \
    -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

resolve_user() {
  id "$ORCA_USER" >/dev/null 2>&1 || die "utilisateur $ORCA_USER introuvable. Lance d'abord : $0 install"
  ORCA_UID="$(id -u "$ORCA_USER")"
  ORCA_HOME="$(getent passwd "$ORCA_USER" | cut -d: -f6)"
}

user_path() {
  printf '%s' "$ORCA_HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin"
}

# Exécute une commande sous l'utilisateur Orca, avec l'environnement nécessaire
# aux services utilisateur systemd (sans passer par su ni ssh).
as_user() {
  LAST_AS_USER="$*"
  runuser -u "$ORCA_USER" -- env -i \
    HOME="$ORCA_HOME" USER="$ORCA_USER" LOGNAME="$ORCA_USER" SHELL=/bin/bash \
    LANG="${LANG:-C.UTF-8}" TERM="${TERM:-dumb}" \
    XDG_RUNTIME_DIR="/run/user/$ORCA_UID" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$ORCA_UID/bus" \
    PATH="$(user_path)" \
    ORCA_TELEMETRY_DISABLED=1 \
    sh -c 'cd "$HOME" && exec "$@"' sh "$@"
}

# Écrit l'entrée standard dans un fichier de l'utilisateur Orca, sous son
# identité : root n'écrit jamais dans un dossier que l'agent contrôle.
# user_write <chemin> [mode]
user_write() {
  local dest=$1 mode=${2:-600}
  as_user sh -c 'umask 077; mkdir -p "$(dirname "$1")" && cat > "$1.tmp" && chmod "$2" "$1.tmp" && mv "$1.tmp" "$1"' sh "$dest" "$mode"
}

ensure_user_manager() {
  loginctl enable-linger "$ORCA_USER"
  systemctl start "user@$ORCA_UID.service"
  local _
  for _ in $(seq 1 15); do
    [ -S "/run/user/$ORCA_UID/bus" ] && return 0
    sleep 1
  done
  die "session systemd de $ORCA_USER indisponible (/run/user/$ORCA_UID/bus absent)."
}

# PID du processus qui écoute sur le port Orca (vide si personne).
port_pid() {
  ss -ltnpH "sport = :$ORCA_PORT" 2>/dev/null | grep -oP 'pid=\K[0-9]+' | head -n1 || true
}

orca_service_active() {
  as_user systemctl --user is-active --quiet "$ORCA_UNIT" 2>/dev/null
}

# Les sorties longues passent par une variable : avec pipefail, un lecteur
# qui s'arrête tôt (awk exit, grep -q, head) ferait échouer le tube (SIGPIPE).
ssh_port() {
  local out
  out="$(sshd -T 2>/dev/null)" || true
  awk '/^port /{print $2; exit}' <<<"$out"
}

detect_public_ip() {
  ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}'
}

public_endpoint() {
  if [ -n "$PUBLIC_ENDPOINT" ]; then printf '%s' "$PUBLIC_ENDPOINT"; else detect_public_ip; fi
}

# Adresse du client de la session SSH courante, y compris derrière sudo
# (qui efface SSH_CONNECTION) : on remonte les processus parents.
ssh_client_ip() {
  local conn="${SSH_CONNECTION:-}" pid=$$
  while [ -z "$conn" ] && [ "${pid:-0}" -gt 1 ]; do
    conn="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^SSH_CONNECTION=//p' | head -n1 || true)"
    pid="$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null || true)"
  done
  printf '%s' "${conn%% *}"
}

# --- WireGuard : appareils ----------------------------------------------------

peer_pubkey_var() {
  local name
  name="$(tr '[:lower:]-' '[:upper:]_' <<<"$1")"
  printf 'WG_PEER_%s_PUBKEY' "$name"
}

valid_peer_name() { [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; }
valid_wg_key()    { [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]; }

client_config() {
  local ip=$1 private_key=$2
  cat <<EOF
[Interface]
PrivateKey = $private_key
Address = $ip/32

[Peer]
PublicKey = $(cat "$WG_DIR/server.pub")
Endpoint = $(public_endpoint):$WG_PORT
AllowedIPs = $WG_SERVER_IP/32
PersistentKeepalive = 25
EOF
}

# Serveur installé à la main : reprend les appareils déjà déclarés dans
# wg0.conf, avec leurs clés et leurs adresses, pour ne couper aucun accès.
# Le nom vient de WG_PEERS quand l'adresse correspond.
adopt_existing_peers() {
  local conf="$WG_DIR/$WG_IF.conf" ip key name entry count=0
  [ -f "$conf" ] || return 0
  [ -z "$(find "$PEERS_DIR" -type f 2>/dev/null)" ] || return 0
  while read -r ip key; do
    if [ -z "$ip" ] || ! valid_wg_key "$key"; then continue; fi
    name="appareil-${ip//./-}"
    for entry in $WG_PEERS; do
      [ "${entry#*:}" != "$ip" ] || name="${entry%%:*}"
    done
    ( umask 077; printf '%s %s\n' "$ip" "$key" > "$PEERS_DIR/$name" )
    info "Appareil $name repris de $WG_IF.conf ($ip, clé conservée)."
    count=$((count + 1))
  done < <(awk '
    function flush() { if (key != "" && ip != "") print ip, key; key = ""; ip = "" }
    /^\[/ { flush(); inpeer = ($0 ~ /^\[Peer\]/) }
    inpeer && /^PublicKey[ \t]*=/ { key = $3 }
    inpeer && /^AllowedIPs[ \t]*=/ { split($3, a, "[/,]"); ip = a[1] }
    END { flush() }' "$conf")
  [ "$count" -eq 0 ] || cp -p "$conf" "$conf.avant-orca-vps"
}

# ensure_peer <nom> <ip> [clé publique] : crée l'appareil s'il n'existe pas.
# Ne régénère jamais une clé existante.
ensure_peer() {
  local name=$1 ip=$2 pubkey=${3:-} state="$PEERS_DIR/$1" other private_key
  valid_peer_name "$name" || die "nom d'appareil invalide : $name"
  if ! is_ipv4 "$ip" || ! ip_in_cidr "$ip" "$WG_NET"; then die "adresse $ip de l'appareil $name hors de $WG_NET."; fi
  [ "$ip" != "$WG_SERVER_IP" ] || die "l'appareil $name ne peut pas prendre l'adresse du serveur."
  [ -z "$pubkey" ] || valid_wg_key "$pubkey" || die "clé publique invalide pour l'appareil $name."
  install -d -m 700 "$PEERS_DIR" "$CLIENTS_DIR"

  if [ -f "$state" ]; then
    local cur_ip cur_key
    read -r cur_ip cur_key < "$state"
    if ! ip_in_cidr "$cur_ip" "$WG_NET"; then
      # Le sous-réseau a changé : l'appareil garde ses clés et prend sa
      # nouvelle adresse. Sa configuration est à réimporter.
      info "Appareil $name : adresse $cur_ip hors de $WG_NET, remplacée par $ip (clés conservées, configuration à réimporter)."
      printf '%s %s\n' "$ip" "$cur_key" > "$state"
      if [ -f "$CLIENTS_DIR/$name.conf" ]; then
        private_key="$(sed -n 's/^PrivateKey = //p' "$CLIENTS_DIR/$name.conf")"
        ( umask 077; client_config "$ip" "$private_key" > "$CLIENTS_DIR/$name.conf" )
      fi
      cur_ip="$ip"
    fi
    if [ -n "$pubkey" ] && [ "$pubkey" != "$cur_key" ]; then
      info "Appareil $name : clé publique remplacée par celle de la configuration."
      printf '%s %s\n' "$cur_ip" "$pubkey" > "$state"
      rm -f "$CLIENTS_DIR/$name.conf"
    else
      info "Appareil $name : déjà présent ($cur_ip), clé conservée."
    fi
    return 0
  fi

  for other in "$PEERS_DIR"/*; do
    [ -f "$other" ] || continue
    if [ "$(cut -d' ' -f1 "$other")" = "$ip" ]; then
      die "l'adresse $ip est déjà prise par l'appareil $(basename "$other")."
    fi
  done

  if [ -n "$pubkey" ]; then
    info "Appareil $name : $ip, clé publique fournie (aucune clé privée sur le serveur)."
  else
    private_key="$(wg genkey)"
    pubkey="$(wg pubkey <<<"$private_key")"
    ( umask 077; client_config "$ip" "$private_key" > "$CLIENTS_DIR/$name.conf" )
    info "Appareil $name : $ip, clés générées sur le serveur ($CLIENTS_DIR/$name.conf)."
  fi
  ( umask 077; printf '%s %s\n' "$ip" "$pubkey" > "$state" )
}

next_free_peer_ip() {
  local base i candidate used
  base="$(ip_to_int "${WG_NET%/*}")"
  used=" $WG_SERVER_IP $(cat "$PEERS_DIR"/* 2>/dev/null | cut -d' ' -f1 | tr '\n' ' ')"
  for i in $(seq 2 254); do
    candidate="$(int_to_ip $(( base + i )))"
    ip_in_cidr "$candidate" "$WG_NET" || break
    case "$used" in *" $candidate "*) ;; *) printf '%s' "$candidate"; return 0 ;; esac
  done
  die "plus d'adresse libre dans $WG_NET."
}

render_wg_conf() {
  local state ip key
  cat <<EOF
# Géré par orca-vps (bootstrap.sh). Ne pas modifier à la main :
# ajoute un appareil avec « orca-vps add-peer <nom> ».
[Interface]
Address = $WG_SERVER_IP/$WG_PREFIX
ListenPort = $WG_PORT
PrivateKey = $(cat "$WG_DIR/server.key")
EOF
  for state in "$PEERS_DIR"/*; do
    [ -f "$state" ] || continue
    read -r ip key < "$state"
    printf '\n# %s\n[Peer]\nPublicKey = %s\nAllowedIPs = %s/32\n' "$(basename "$state")" "$key" "$ip"
  done
}

# Réécrit wg0.conf à partir de l'état, et l'applique sans couper le tunnel.
apply_wg_conf() {
  local tmp
  tmp="$(mktemp)"
  render_wg_conf > "$tmp"
  if [ -f "$WG_DIR/$WG_IF.conf" ] && cmp -s "$tmp" "$WG_DIR/$WG_IF.conf"; then
    rm -f "$tmp"
    info "$WG_IF.conf inchangé."
  else
    install -m 600 "$tmp" "$WG_DIR/$WG_IF.conf"
    rm -f "$tmp"
    info "$WG_IF.conf écrit."
    if ip link show "$WG_IF" >/dev/null 2>&1; then
      if grep -q " $WG_SERVER_IP/$WG_PREFIX " <<<"$(ip -4 -o addr show dev "$WG_IF")"; then
        wg syncconf "$WG_IF" <(wg-quick strip "$WG_IF")
        info "Configuration appliquée à chaud."
      else
        # L'adresse du serveur a changé : l'interface doit être recréée.
        systemctl restart "wg-quick@$WG_IF"
        info "Adresse du tunnel modifiée : interface $WG_IF relancée."
      fi
    fi
  fi
  systemctl enable --now "wg-quick@$WG_IF" >/dev/null 2>&1 || systemctl enable --now "wg-quick@$WG_IF"
}

# Affiche la configuration d'un appareil sur le terminal, jamais dans le journal.
show_peer() {
  local name=$1 conf="$CLIENTS_DIR/$1.conf" ip key
  read -r ip key < "$PEERS_DIR/$name"
  flush_output
  tty_out ""
  tty_out "----- Appareil « $name » ($ip) -----"
  if [ -f "$conf" ]; then
    tty_out "Configuration complète (contient la clé privée de l'appareil) :"
    tty_out ""
    cat "$conf" >&3
    tty_out ""
    tty_out "QR code à scanner depuis l'application WireGuard du téléphone :"
    qrencode -t ansiutf8 < "$conf" >&3
  else
    tty_out "La clé privée de cet appareil n'est pas sur le serveur."
    tty_out ""
    tty_out "Cas 1 : l'appareil a déjà un tunnel WireGuard (autre VPS Orca). L'application n'active"
    tty_out "qu'un tunnel à la fois : ajoute ce serveur au tunnel existant. Sa ligne Address doit"
    tty_out "valoir $ip/32, la même adresse que sur tes autres VPS. Ajoute ce bloc à la fin :"
    tty_out ""
    client_config "$ip" "" | sed -n '/^\[Peer\]/,$p' >&3
    tty_out ""
    tty_out "Cas 2 : nouveau tunnel. Configuration à saisir, en gardant sa propre ligne PrivateKey :"
    tty_out ""
    client_config "$ip" "<clé privée de l'appareil, déjà présente dans l'application>" >&3
  fi
  tty_out "-----"
}

# Propose de supprimer la copie serveur d'une clé privée cliente.
offer_key_deletion() {
  local name=$1 conf="$CLIENTS_DIR/$1.conf"
  [ -f "$conf" ] || return 0
  if confirm "La configuration de « $name » est-elle importée sur l'appareil ? Supprimer sa clé privée du serveur ?" n; then
    shred -u "$conf" 2>/dev/null || rm -f "$conf"
    info "Clé privée de $name supprimée du serveur."
  else
    info "Clé privée de $name conservée dans $conf. Relance « orca-vps add-peer $name » pour l'afficher puis la supprimer."
  fi
}

# --- Orca : installation -------------------------------------------------------

orca_bin() {
  if [ "$ORCA_INSTALL_METHOD" = tarball ]; then printf '%s' "$ORCA_TARBALL_DIR/bin/orca-ide"; else printf '%s' /usr/bin/orca-ide; fi
}

orca_installed_version() {
  if [ "$ORCA_INSTALL_METHOD" = tarball ]; then
    [ -x "$ORCA_TARBALL_DIR/bin/orca-ide" ] && "$ORCA_TARBALL_DIR/bin/orca-ide" --version 2>/dev/null || true
  else
    dpkg-query -W -f='${Version}' orca-ide 2>/dev/null || true
  fi
}

orca_release_base() {
  if [ "$ORCA_VERSION" = latest ]; then
    printf '%s' "$ORCA_RELEASES/latest/download"
  else
    printf '%s' "$ORCA_RELEASES/download/v${ORCA_VERSION#v}"
  fi
}

url_exists() { curl -fsSIL --max-time 30 -o /dev/null "$1" 2>/dev/null; }

# Lit le manifeste de la release : renseigne ORCA_MANIFEST et ORCA_TARGET.
orca_read_manifest() {
  local base manifest_name deb_arch
  base="$(orca_release_base)"
  deb_arch="$(dpkg --print-architecture)"
  case "$deb_arch" in
    amd64) manifest_name="latest-linux.yml" ;;
    arm64) manifest_name="latest-linux-arm64.yml" ;;
    *) die "architecture non prise en charge : $deb_arch" ;;
  esac
  ORCA_MANIFEST="$(curl -fsSL --max-time 60 "$base/$manifest_name")" || die "impossible de lire $base/$manifest_name."
  ORCA_TARGET="$(awk '/^version:/{print $2; exit}' <<<"$ORCA_MANIFEST")"
  [ -n "$ORCA_TARGET" ] || die "version introuvable dans $manifest_name."
}

orca_install_deb() {
  local base deb deb_arch workdir expected actual
  base="$(orca_release_base)"
  deb_arch="$(dpkg --print-architecture)"
  deb="orca-ide_${ORCA_TARGET}_${deb_arch}.deb"
  url_exists "$base/$deb" || die "le paquet $deb est absent de la release ($base). Réessaie plus tard ou épingle ORCA_VERSION."
  workdir="$(mktemp -d)"
  info "Téléchargement de $deb"
  curl -fL --silent --show-error --max-time 900 -o "$workdir/$deb" "$base/$deb"
  expected="$(awk -v f="$deb" 'index($0,f){getline; print $2; exit}' <<<"$ORCA_MANIFEST")"
  actual="$(openssl dgst -sha512 -binary "$workdir/$deb" | base64 -w0)"
  [ -n "$expected" ] || { rm -rf "$workdir"; die "somme SHA-512 attendue introuvable pour $deb."; }
  [ "$expected" = "$actual" ] || { rm -rf "$workdir"; die "somme SHA-512 différente pour $deb : paquet non installé."; }
  info "Somme SHA-512 vérifiée."
  chmod 755 "$workdir"
  apt_install "$workdir/$deb"
  rm -rf "$workdir"
}

orca_install_tarball() {
  local base arch tarball workdir
  base="$(orca_release_base)"
  case "$(dpkg --print-architecture)" in amd64) arch=x64 ;; arm64) arch=arm64 ;; esac
  tarball="orca-server-linux-$arch.tar.gz"
  if ! url_exists "$base/$tarball" || ! url_exists "$base/orca-server-sha256sums.txt"; then
    warn "l'archive serveur $tarball est absente de la release $ORCA_TARGET : repli sur le paquet .deb."
    ORCA_INSTALL_METHOD=deb
    orca_install_deb
    return 0
  fi
  workdir="$(mktemp -d)"
  info "Téléchargement de $tarball"
  curl -fL --silent --show-error --max-time 900 -o "$workdir/$tarball" "$base/$tarball"
  curl -fsSL --max-time 60 -o "$workdir/sums.txt" "$base/orca-server-sha256sums.txt"
  grep -F " $tarball" "$workdir/sums.txt" > "$workdir/sum.txt" || { rm -rf "$workdir"; die "somme SHA-256 introuvable pour $tarball."; }
  ( cd "$workdir" && sha256sum --check --quiet sum.txt ) || { rm -rf "$workdir"; die "somme SHA-256 différente pour $tarball : archive non installée."; }
  info "Somme SHA-256 vérifiée."
  rm -rf "$ORCA_TARBALL_DIR.new"
  install -d -m 755 "$ORCA_TARBALL_DIR.new"
  tar -xzf "$workdir/$tarball" -C "$ORCA_TARBALL_DIR.new" --strip-components=1 --no-same-owner
  rm -rf "$workdir" "$ORCA_TARBALL_DIR.old"
  [ ! -d "$ORCA_TARBALL_DIR" ] || mv "$ORCA_TARBALL_DIR" "$ORCA_TARBALL_DIR.old"
  mv "$ORCA_TARBALL_DIR.new" "$ORCA_TARBALL_DIR"
  rm -rf "$ORCA_TARBALL_DIR.old"
  ln -sfn "$ORCA_TARBALL_DIR/bin/orca-ide" /usr/local/bin/orca-ide
}

orca_install_package() {
  if [ "$ORCA_INSTALL_METHOD" = tarball ]; then orca_install_tarball; else orca_install_deb; fi
  command -v orca-ide >/dev/null || die "orca-ide introuvable après l'installation."
}

# --- Orca : service ------------------------------------------------------------

# Écrit l'environnement du service. systemd ne lit pas l'environnement de
# l'appel « service install » (seul PATH y est figé) : on passe par un
# fichier d'environnement référencé par un drop-in de l'unité.
write_service_env() {
  local dropin="$ORCA_HOME/.config/systemd/user/$ORCA_UNIT.d/10-orca-vps.conf"
  {
    printf '# Géré par orca-vps (bootstrap.sh).\n'
    printf 'PATH=%s\n' "$(user_path)"
    printf 'ORCA_TELEMETRY_DISABLED=1\n'
    [ -z "$ORCA_TERMINAL_MEMORY_MAX" ] || printf 'ORCA_TERMINAL_MEMORY_MAX=%s\n' "$ORCA_TERMINAL_MEMORY_MAX"
    [ "$DOCKER_MODE" != rootless ] || printf 'DOCKER_HOST=unix:///run/user/%s/docker.sock\n' "$ORCA_UID"
  } | user_write "$ORCA_HOME/.config/orca-vps/service.env" 600
  {
    printf '# Géré par orca-vps (bootstrap.sh).\n[Service]\n'
    printf 'UnsetEnvironment=DO_NOT_TRACK\n'
    printf 'EnvironmentFile=%s\n' "$ORCA_HOME/.config/orca-vps/service.env"
    printf 'EnvironmentFile=-%s\n' "$ORCA_HOME/.config/orca-vps/claude.env"
  } | user_write "$dropin" 644
}

service_fingerprint() {
  cat "$ORCA_HOME/.config/systemd/user/$ORCA_UNIT" \
      "$ORCA_HOME/.config/systemd/user/$ORCA_UNIT.d/10-orca-vps.conf" \
      "$ORCA_HOME/.config/orca-vps/service.env" 2>/dev/null | sha256sum | cut -d' ' -f1
  # Le jeton éventuel compte dans l'empreinte sans jamais être affiché.
  sha256sum "$ORCA_HOME/.config/orca-vps/claude.env" 2>/dev/null | cut -d' ' -f1 || true
}

stop_stray_server() {
  local pid _
  pid="$(port_pid)"
  [ -n "$pid" ] || return 0
  info "Arrêt du processus $pid qui écoute sur le port $ORCA_PORT (serveur lancé à la main)."
  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 20); do
    [ -z "$(port_pid)" ] && return 0
    sleep 1
  done
  die "le port $ORCA_PORT est toujours occupé (pid $(port_pid))."
}

wait_for_orca_port() {
  local _
  for _ in $(seq 1 30); do
    [ -n "$(port_pid)" ] && return 0
    sleep 1
  done
  as_user journalctl --user -u "$ORCA_UNIT" -n 30 --no-pager 2>/dev/null || true
  die "le serveur Orca n'écoute pas sur le port $ORCA_PORT après 30 s."
}

# Une installation manuelle a pu définir DO_NOT_TRACK pour l'utilisateur :
# on le retire de sa session systemd et de ses fichiers de shell, sinon les
# terminaux d'Orca le transmettent à Claude Code.
purge_do_not_track() {
  local file
  for file in "$ORCA_HOME"/.config/environment.d/*.conf "$ORCA_HOME/.bashrc" "$ORCA_HOME/.profile" "$ORCA_HOME/.bash_profile"; do
    [ -f "$file" ] || continue
    grep -q 'DO_NOT_TRACK=' "$file" || continue
    as_user sed -i -E \
      -e '/^[[:space:]]*(export[[:space:]]+)?DO_NOT_TRACK=[^[:space:]]*[[:space:]]*$/d' \
      -e 's/[[:space:]]+DO_NOT_TRACK=[^[:space:]]*//g' "$file"
    info "DO_NOT_TRACK retiré de $file."
  done
  as_user systemctl --user unset-environment DO_NOT_TRACK 2>/dev/null || true
  return 0
}

# Vrai si la session systemd de l'utilisateur voit déjà le groupe docker.
# Elle garde les groupes qu'elle avait à son démarrage : un ajout ultérieur
# au groupe n'atteint ses services qu'après une relance de la session.
manager_has_docker_group() {
  local gid pid
  [ "$DOCKER_MODE" = group ] || return 0
  gid="$(getent group docker | cut -d: -f3)"
  [ -n "$gid" ] || return 0
  grep -qx "$gid" <<<"$(id -G "$ORCA_USER" | tr ' ' '\n')" || return 0
  pid="$(systemctl show "user@$ORCA_UID.service" -p MainPID --value 2>/dev/null || true)"
  [ -n "$pid" ] && [ "$pid" != 0 ] || return 0
  grep -qx "$gid" <<<"$(grep -E '^Groups:' "/proc/$pid/status" | tr -s '[:space:]' '\n')"
}

# À appeler service Orca arrêté. Relancer la session ferme tous les
# processus de l'utilisateur : on ne le fait pas sous des agents en cours,
# sauf demande explicite (update-orca, après confirmation).
refresh_user_manager_groups() {
  local running
  manager_has_docker_group && return 0
  running="$(pgrep -c -u "$ORCA_USER" -x claude || true)"
  if [ "${running:-0}" -gt 0 ] && [ "${ALLOW_SESSION_RESTART:-0}" -ne 1 ]; then
    warn "le service Orca ne verra pas le groupe docker : $running session(s) Claude en cours empêchent de relancer la session de $ORCA_USER. Quand elles sont finies : orca-vps update-orca --force."
    return 0
  fi
  info "Session systemd de $ORCA_USER relancée pour prendre le groupe docker (ses terminaux ouverts sont fermés)."
  systemctl restart "user@$ORCA_UID.service"
  ensure_user_manager
}

install_orca_service() {
  local args=(serve service install --port "$ORCA_PORT" --refuse-public)
  [ "$ORCA_INSTALL_METHOD" != tarball ] || args+=(--command "$ORCA_TARBALL_DIR/bin/orca-ide")
  ensure_user_manager
  purge_do_not_track
  refresh_user_manager_groups
  write_service_env
  as_user orca-ide "${args[@]}"
  as_user systemctl --user daemon-reload
  wait_for_orca_port
}

# --- Phases de install ---------------------------------------------------------

phase_preflight() {
  local arch ram_gb version_id=""
  # shellcheck disable=SC1091
  [ -r /etc/os-release ] && version_id="$(. /etc/os-release && printf '%s %s' "${ID:-}" "${VERSION_ID:-}")"
  case "$version_id" in
    "ubuntu 26.04") info "Système : Ubuntu 26.04." ;;
    "ubuntu 24.04") warn "Ubuntu 24.04 : pris en charge au mieux, la cible est Ubuntu 26.04." ;;
    *) die "système non pris en charge : ${version_id:-inconnu}. Ubuntu 26.04 attendu." ;;
  esac
  local virt
  virt="$(systemd-detect-virt --container 2>/dev/null || true)"
  case "$virt" in
    ""|none) ;;
    *) die "ce serveur est un conteneur ($virt), pas une machine virtuelle : WireGuard et Docker ont besoin de leur propre noyau. Prends un VPS KVM." ;;
  esac
  arch="$(dpkg --print-architecture)"
  case "$arch" in amd64|arm64) info "Architecture : $arch." ;; *) die "architecture non prise en charge : $arch." ;; esac
  ram_gb="$(awk '/^MemTotal:/{printf "%d", ($2 / 1024 / 1024) + 0.5}' /proc/meminfo)"
  info "Mémoire vive : ${ram_gb} Go."
  [ "$ram_gb" -ge 8 ] || warn "moins de 8 Go de RAM : plusieurs agents et Docker risquent de manquer de mémoire."
  curl -fsSI --max-time 15 -o /dev/null https://github.com || die "pas d'accès réseau sortant vers https://github.com."
  info "Accès réseau sortant : OK."
  local iface net
  while read -r iface net; do
    [ "$iface" != "$WG_IF" ] || continue
    if ip_in_cidr "${net%/*}" "$WG_NET" || ip_in_cidr "${WG_NET%/*}" "$net"; then
      die "WG_NET ($WG_NET) chevauche le réseau $net de l'interface $iface. Choisis un autre sous-réseau."
    fi
  done < <(ip -4 -o addr show | awk '{print $2, $4}')
  info "Configuration : $CONFIG_FILE"
  if [ "$SCRIPT_PATH" != "$INSTALLED_SCRIPT" ]; then
    install -m 700 -o root -g root "$SCRIPT_PATH" "$INSTALLED_SCRIPT"
    info "Script copié dans $INSTALLED_SCRIPT (commande « orca-vps »)."
  fi
}

phase_system() {
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a
  apt-get update -q -o DPkg::Lock::Timeout=300
  apt-get upgrade -y -q -o DPkg::Lock::Timeout=300 \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
  apt_install git curl ca-certificates openssl ufw wireguard qrencode jq unattended-upgrades iproute2 \
    adduser openssh-client iptables

  # Correctifs de sécurité automatiques, sans redémarrage automatique
  # (un redémarrage couperait les agents en cours).
  cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  cat > /etc/apt/apt.conf.d/52orca-vps <<'EOF'
// Géré par orca-vps (bootstrap.sh).
Unattended-Upgrade::Automatic-Reboot "false";
EOF
  systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

  if [ "$(timedatectl show -p Timezone --value)" != "$TIMEZONE" ]; then
    timedatectl set-timezone "$TIMEZONE"
  fi
  info "Fuseau horaire : $TIMEZONE."

  if [ "$SWAP_SIZE" = 0 ]; then
    info "Fichier d'échange : désactivé par SWAP_SIZE=0."
  elif [ -n "$(swapon --noheadings --show=NAME)" ] || [ -e /swapfile ]; then
    info "Fichier d'échange : déjà présent."
  else
    # Certains systèmes de fichiers (btrfs, zfs) refusent ce fichier : on continue sans.
    if fallocate -l "$SWAP_SIZE" /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile; then
      grep -q '^/swapfile ' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
      info "Fichier d'échange : $SWAP_SIZE créé."
    else
      rm -f /swapfile
      warn "fichier d'échange non créé sur ce système de fichiers : l'installation continue sans (SWAP_SIZE=0 pour ne plus essayer)."
    fi
  fi
}

# Clés SSH utilisables pour une connexion directe : on écarte les lignes à
# options (par exemple la commande forcée que certaines images cloud posent
# sur root pour renvoyer vers un autre compte).
usable_ssh_keys() {
  local file
  for file in "$@"; do
    [ -r "$file" ] || continue
    grep -E '^(ssh-(ed25519|rsa)|ecdsa-sha2-[a-z0-9-]+|sk-[a-z0-9@.-]+) ' "$file" || true
  done | awk '!seen[$2]++'
}

admin_key_files() {
  local files=()
  [ -z "$SSH_KEYS_FROM" ] || files+=("$SSH_KEYS_FROM")
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    files+=("$(getent passwd "$SUDO_USER" | cut -d: -f6)/.ssh/authorized_keys")
  fi
  files+=(/root/.ssh/authorized_keys)
  printf '%s\n' "${files[@]}"
}

phase_user() {
  local keys
  if id "$ORCA_USER" >/dev/null 2>&1; then
    info "Utilisateur $ORCA_USER : déjà présent."
  else
    adduser --disabled-password --gecos "" "$ORCA_USER" >/dev/null
    info "Utilisateur $ORCA_USER créé, sans mot de passe."
  fi
  resolve_user
  local group
  for group in sudo admin wheel adm lxd; do
    if id -nG "$ORCA_USER" | tr ' ' '\n' | grep -qx "$group"; then
      die "$ORCA_USER appartient au groupe $group : ce compte ne doit avoir aucun droit d'administration."
    fi
  done
  ensure_user_manager
  if [ -s "$ORCA_HOME/.ssh/authorized_keys" ]; then
    info "Clés autorisées de $ORCA_USER : déjà en place, non modifiées."
  else
    mapfile -t key_files < <(admin_key_files)
    keys="$(usable_ssh_keys "${key_files[@]}")"
    [ -n "$keys" ] || die "aucune clé SSH utilisable trouvée (${key_files[*]}). Si l'hébergeur t'a donné un mot de passe, installe d'abord ta clé depuis ton Mac (ssh-copy-id <compte>@<ip>), ou renseigne SSH_KEYS_FROM dans config.env."
    as_user sh -c 'umask 077; mkdir -p "$HOME/.ssh"'
    printf '%s\n' "$keys" | user_write "$ORCA_HOME/.ssh/authorized_keys" 600
    info "Clés autorisées copiées vers $ORCA_USER ($(wc -l <<<"$keys") clé(s))."
  fi
  info "Session systemd de $ORCA_USER persistante (linger)."
}

phase_ssh() {
  local conf=/etc/ssh/sshd_config.d/00-orca-vps.conf tmp keys
  mapfile -t key_files < <(admin_key_files)
  keys="$(usable_ssh_keys "${key_files[@]}" "$ORCA_HOME/.ssh/authorized_keys")"
  [ -n "$keys" ] || die "aucune clé SSH utilisable : le mot de passe n'est pas désactivé, pour ne pas te bloquer dehors. Installe ta clé depuis ton Mac (ssh-copy-id <compte>@<ip>), puis relance."
  install -d -m 755 /run/sshd
  # Le fichier commence par 00 : sshd retient la première valeur lue, donc
  # ces réglages l'emportent sur un fichier déposé par cloud-init.
  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
# Géré par orca-vps (bootstrap.sh).
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
PermitEmptyPasswords no
EOF
  if [ -f "$conf" ] && cmp -s "$tmp" "$conf"; then
    rm -f "$tmp"
    info "Durcissement SSH : déjà en place."
  else
    install -m 644 "$tmp" "$conf"
    rm -f "$tmp"
    if ! sshd -t; then
      rm -f "$conf"
      die "sshd -t refuse la configuration : fichier retiré, SSH inchangé."
    fi
    if systemctl is-active --quiet ssh.service; then systemctl reload ssh.service; fi
    info "Durcissement SSH appliqué ($conf)."
  fi
  local effective
  effective="$(sshd -T)"
  grep -qx 'passwordauthentication no' <<<"$effective" || die "sshd accepte encore les mots de passe (voir sshd -T)."
  grep -qx 'kbdinteractiveauthentication no' <<<"$effective" || die "sshd accepte encore l'authentification interactive."
  grep -qxE 'permitrootlogin (prohibit-password|without-password|no)' <<<"$effective" || die "root peut encore se connecter par mot de passe."
  info "sshd : clé uniquement, mot de passe refusé (port $(ssh_port), inchangé)."
}

phase_wireguard() {
  local entry name ip var endpoint
  install -d -m 700 "$WG_DIR" "$PEERS_DIR" "$CLIENTS_DIR"
  if [ -s "$WG_DIR/server.key" ]; then
    info "Clé du serveur : déjà présente, conservée."
  else
    ( umask 077; wg genkey > "$WG_DIR/server.key" )
    info "Clé du serveur générée."
  fi
  ( umask 077; wg pubkey < "$WG_DIR/server.key" > "$WG_DIR/server.pub" )
  adopt_existing_peers
  endpoint="$(public_endpoint)"
  [ -n "$endpoint" ] || die "adresse publique introuvable. Renseigne PUBLIC_ENDPOINT dans config.env."
  if [ -z "$PUBLIC_ENDPOINT" ] && is_private_ipv4 "$endpoint"; then
    # Chez certains hébergeurs (AWS, GCP, Oracle…), l'adresse publique n'est
    # pas portée par la machine : elle ne peut pas être devinée sans tiers.
    if is_interactive; then
      tty_out ""
      tty_out "L'adresse de ce serveur ($endpoint) est privée : il est derrière un NAT."
      while [ -z "$PUBLIC_ENDPOINT" ]; do ask PUBLIC_ENDPOINT "  Adresse IP publique ou nom DNS du VPS (celle de ta commande ssh)"; done
      [[ "$PUBLIC_ENDPOINT" =~ ^[A-Za-z0-9.:-]+$ ]] || die "PUBLIC_ENDPOINT invalide : $PUBLIC_ENDPOINT"
      set_config_value PUBLIC_ENDPOINT "$PUBLIC_ENDPOINT"
      [ "$CONFIG_FILE" = "$STATE_CONFIG" ] || install -m 600 -o root -g root "$CONFIG_FILE" "$STATE_CONFIG"
      endpoint="$PUBLIC_ENDPOINT"
    else
      die "l'adresse détectée ($endpoint) est privée : le VPS est derrière un NAT. Renseigne PUBLIC_ENDPOINT dans config.env."
    fi
  fi
  info "Adresse publique des configurations clientes : $endpoint:$WG_PORT"
  for entry in $WG_PEERS; do
    name="${entry%%:*}"
    ip="${entry#*:}"
    [ "$name" != "$entry" ] || die "WG_PEERS : entrée « $entry » invalide, format attendu nom:adresse."
    var="$(peer_pubkey_var "$name")"
    ensure_peer "$name" "$ip" "${!var:-}"
  done
  # Appareils ajoutés par add-peer et restés hors du sous-réseau après un
  # changement de WG_NET : ils prennent la première adresse libre.
  local state
  for state in "$PEERS_DIR"/*; do
    [ -f "$state" ] || continue
    if ! ip_in_cidr "$(cut -d' ' -f1 "$state")" "$WG_NET"; then
      ensure_peer "$(basename "$state")" "$(next_free_peer_ip)"
    fi
  done
  apply_wg_conf
  ip link show "$WG_IF" >/dev/null 2>&1 || die "l'interface $WG_IF n'est pas montée."
  info "Tunnel $WG_IF actif sur $WG_SERVER_IP/$WG_PREFIX, port UDP $WG_PORT."
}

phase_firewall() {
  local port
  port="$(ssh_port)"
  [ -n "$port" ] || die "port SSH introuvable (sshd -T)."
  sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
  grep -q '^IPV6=yes' /etc/default/ufw || printf 'IPV6=yes\n' >> /etc/default/ufw
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  if [ -f "$LOCKDOWN_MARKER" ]; then
    info "SSH déjà fermé côté Internet (lockdown fait) : la règle publique n'est pas recréée."
  else
    ufw allow "$port/tcp" >/dev/null
  fi
  ufw allow "$WG_PORT/udp" >/dev/null
  ufw allow in on "$WG_IF" >/dev/null
  # Contrôle avant activation : SSH doit rester joignable.
  if [ -f "$LOCKDOWN_MARKER" ]; then
    grep -qx "ufw allow in on $WG_IF" <<<"$(ufw show added)" || die "règle du tunnel absente : pare-feu non activé."
  else
    grep -qx "ufw allow $port/tcp" <<<"$(ufw show added)" || die "règle SSH absente de « ufw show added » : pare-feu non activé."
  fi
  ufw --force enable >/dev/null
  if [ -f "$LOCKDOWN_MARKER" ]; then
    info "Pare-feu actif : refus par défaut (IPv4 et IPv6), WireGuard $WG_PORT/udp, tout sur $WG_IF. SSH fermé côté Internet."
  else
    info "Pare-feu actif : refus par défaut (IPv4 et IPv6), SSH $port/tcp, WireGuard $WG_PORT/udp, tout sur $WG_IF."
  fi
}

# Écrit (ou retire) le bloc des noms bloqués dans un fichier hosts.
write_hosts_block() {
  local file=$1 tmp host
  tmp="$(mktemp)"
  sed '/^# >>> orca-vps >>>$/,/^# <<< orca-vps <<<$/d' "$file" > "$tmp"
  if [ -n "$ORCA_BLOCKED_HOSTS" ]; then
    {
      printf '# >>> orca-vps >>>\n'
      printf '# Noms rendus injoignables : aucun flux vers l'\''éditeur d'\''Orca (voir le README).\n'
      for host in $ORCA_BLOCKED_HOSTS; do
        printf '0.0.0.0 %s\n:: %s\n' "$host" "$host"
      done
      printf '# <<< orca-vps <<<\n'
    } >> "$tmp"
  fi
  if ! cmp -s "$tmp" "$file"; then cat "$tmp" > "$file"; fi
  rm -f "$tmp"
}

block_vendor_hosts() {
  local template=/etc/cloud/templates/hosts.debian.tmpl host
  for host in $ORCA_BLOCKED_HOSTS; do
    [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || die "ORCA_BLOCKED_HOSTS : nom invalide « $host »."
  done
  write_hosts_block /etc/hosts
  # Si cloud-init régénère /etc/hosts à chaque démarrage, le bloc doit aussi
  # figurer dans son modèle, sinon il disparaît au premier redémarrage.
  if [ -f "$template" ] && grep -q 'manage_etc_hosts' /etc/hosts; then
    write_hosts_block "$template"
  fi
  if [ -n "$ORCA_BLOCKED_HOSTS" ]; then
    info "Noms bloqués dans /etc/hosts : $(wc -w <<<"$ORCA_BLOCKED_HOSTS") (éditeur d'Orca, télémétrie, mise à jour du navigateur embarqué)."
  else
    info "Aucun nom bloqué (ORCA_BLOCKED_HOSTS vide)."
  fi
}

phase_orca() {
  local installed
  block_vendor_hosts
  installed="$(orca_installed_version)"
  if [ -n "$installed" ] && { [ "$ORCA_VERSION" = latest ] || [ "${ORCA_VERSION#v}" = "$installed" ]; }; then
    info "Orca $installed déjà installé (méthode $ORCA_INSTALL_METHOD). Mise à jour : orca-vps update-orca."
    return 0
  fi
  orca_read_manifest
  info "Version à installer : $ORCA_TARGET (méthode $ORCA_INSTALL_METHOD)."
  orca_install_package
  info "Orca $(orca_installed_version) installé : $(command -v orca-ide)."
}

phase_claude() {
  local settings="$ORCA_HOME/.claude/settings.json" current
  if [ -x "$ORCA_HOME/.local/bin/claude" ]; then
    info "Claude Code : déjà installé."
  else
    as_user bash -c 'set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash'
  fi
  [ -x "$ORCA_HOME/.local/bin/claude" ] || die "claude introuvable dans $ORCA_HOME/.local/bin après l'installation."
  info "Claude Code $(as_user claude --version 2>/dev/null | head -n1)."

  # ~/.local/bin dans le PATH des shells, et jeton éventuel.
  local block rc
  block="$(cat <<'EOF'
# >>> orca-vps >>>
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac
if [ -r "$HOME/.config/orca-vps/claude.env" ]; then set -a; . "$HOME/.config/orca-vps/claude.env"; set +a; fi
# <<< orca-vps <<<
EOF
)"
  for rc in .profile .bashrc; do
    if ! grep -q '^# >>> orca-vps >>>' "$ORCA_HOME/$rc" 2>/dev/null; then
      printf '\n%s\n' "$block" | as_user sh -c 'cat >> "$1"' sh "$ORCA_HOME/$rc"
    fi
  done

  if [ "$CLAUDE_AUTH" = token ]; then
    printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\n' "$CLAUDE_CODE_OAUTH_TOKEN" | user_write "$ORCA_HOME/.config/orca-vps/claude.env" 600
    info "Jeton Claude écrit dans l'environnement de $ORCA_USER (mode 600)."
  else
    as_user rm -f "$ORCA_HOME/.config/orca-vps/claude.env"
  fi

  if [ -n "$CLAUDE_DEFAULT_MODEL" ]; then
    current="$(cat "$settings" 2>/dev/null || true)"
    [ -n "$current" ] || current='{}'
    jq --arg m "$CLAUDE_DEFAULT_MODEL" '.model = $m' <<<"$current" | user_write "$settings" 600
    info "Modèle par défaut : $CLAUDE_DEFAULT_MODEL."
  fi
}

claude_logged_in() {
  [ "$CLAUDE_AUTH" = token ] && return 0
  as_user claude auth status >/dev/null 2>&1
}

# « gh auth status » de la version d'Ubuntu répond 0 même sans jeton valide :
# on interroge l'API, qui ne répond que si le jeton est accepté.
gh_logged_in() { as_user gh api user --jq .login >/dev/null 2>&1; }

# Vrai si GitHub reconnaît la clé SSH de l'agent.
agent_key_on_github() {
  grep -q 'successfully authenticated' <<<"$(as_user ssh -T -o BatchMode=yes -o ConnectTimeout=15 git@github.com </dev/null 2>&1 || true)"
}

# Connecte la CLI GitHub (gh) sous l'utilisateur Orca : les agents s'en
# servent pour les pull requests et les issues. Git, lui, passe par la clé
# SSH de l'agent, que cette commande peut ajouter au compte.
cmd_gh_login() {
  CURRENT_PHASE=gh-login
  resolve_user
  command -v gh >/dev/null || die "gh n'est pas installé. Lance : $0 install --only git"
  if gh_logged_in; then
    info "gh est déjà connecté."
  else
    is_interactive || die "gh-login a besoin d'un terminal (ou de GH_TOKEN dans config.env)."
    tty_out ""
    tty_out "Connexion de gh sous $ORCA_USER, avec le compte GitHub de l'agent (pas ton compte personnel)."
    tty_out "1. gh propose d'envoyer la clé SSH de l'agent au compte : accepte, git s'en sert pour cloner et pousser."
    tty_out "2. Copie le code affiché, puis ouvre https://github.com/login/device sur ton Mac."
    flush_output
    as_user gh auth login --hostname github.com --git-protocol ssh --web >&3 2>&4
    gh_logged_in || die "gh n'est pas authentifié."
    as_user gh config set git_protocol ssh
  fi
  info "gh connecté au compte : $(as_user gh api user --jq .login 2>/dev/null || true)"
  if agent_key_on_github; then
    info "Clé SSH de l'agent reconnue par GitHub."
  else
    info "La clé SSH de l'agent n'est pas sur le compte : ajoute-la (Settings → SSH and GPG keys), sinon git clone et git push échoueront."
  fi
}

phase_git() {
  local key="$ORCA_HOME/.ssh/id_ed25519" scan line fp kept=""
  as_user sh -c 'umask 077; mkdir -p "$HOME/.ssh"'
  if [ -f "$key" ]; then
    info "Clé SSH de l'agent : déjà présente, conservée."
  else
    as_user ssh-keygen -q -t ed25519 -C "agent@$(hostname)" -f "$key" -N ""
    info "Clé SSH de l'agent générée."
  fi
  as_user git config --global user.name "$GIT_USER_NAME"
  as_user git config --global user.email "$GIT_USER_EMAIL"
  info "Identité Git : $GIT_USER_NAME <$GIT_USER_EMAIL>."

  if grep -qE '^[[:space:]]*Host[[:space:]]+github\.com' "$ORCA_HOME/.ssh/config" 2>/dev/null; then
    info "Fichier .ssh/config : bloc github.com déjà présent."
  else
    {
      cat "$ORCA_HOME/.ssh/config" 2>/dev/null || true
      cat <<'EOF'
Host github.com
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  IdentityAgent none
EOF
    } | user_write "$ORCA_HOME/.ssh/config" 600
  fi

  if as_user ssh-keygen -F github.com -f "$ORCA_HOME/.ssh/known_hosts" >/dev/null 2>&1; then
    info "Clé d'hôte de GitHub : déjà enregistrée."
  else
    # ssh-keyscan n'est pas authentifié : on ne garde que les clés dont
    # l'empreinte figure dans la liste publiée par GitHub.
    scan="$(ssh-keyscan -T 15 -t ed25519,ecdsa,rsa github.com 2>/dev/null || true)"
    while IFS= read -r line; do
      case "$line" in ""|"#"*) continue ;; esac
      fp="$(ssh-keygen -lf - <<<"$line" 2>/dev/null | awk '{print $2}' || true)"
      if printf '%s\n' "${GITHUB_FINGERPRINTS[@]}" | grep -qxF "$fp"; then
        kept+="$line"$'\n'
      else
        warn "clé d'hôte github.com ignorée : empreinte $fp absente de la liste publiée par GitHub."
      fi
    done <<<"$scan"
    [ -n "$kept" ] || die "aucune clé d'hôte de github.com ne correspond aux empreintes publiées par GitHub."
    {
      cat "$ORCA_HOME/.ssh/known_hosts" 2>/dev/null || true
      printf '%s' "$kept"
    } | user_write "$ORCA_HOME/.ssh/known_hosts" 600
    info "Clé d'hôte de GitHub vérifiée et enregistrée ($(grep -c . <<<"$kept") clé(s))."
  fi
  # CLI GitHub : paquet d'Ubuntu, pas de dépôt tiers.
  command -v gh >/dev/null || apt_install gh
  gh_logged_in || as_user gh config set git_protocol ssh
  if [ -n "$GH_TOKEN" ] && ! gh_logged_in; then
    printf '%s\n' "$GH_TOKEN" | as_user gh auth login --hostname github.com --git-protocol ssh --with-token
    info "gh connecté avec le jeton de la configuration."
  fi
  info "CLI GitHub : $(gh --version | head -n1)."
  as_user mkdir -p "$ORCA_HOME/$ORCA_CODE_DIR"
  info "Dossier des projets : $ORCA_HOME/$ORCA_CODE_DIR"
}

# Garde-fou : Docker publie ses ports par des règles NAT qui passent avant
# ufw. Cette chaîne refuse tout trafic vers un conteneur qui n'arrive ni par
# le tunnel ni d'un autre conteneur, même si un port est publié sur 0.0.0.0.
write_docker_guard() {
  local script=/usr/local/sbin/orca-vps-docker-guard unit=/etc/systemd/system/orca-vps-docker-guard.service tmp_script tmp_unit
  tmp_script="$(mktemp)"
  tmp_unit="$(mktemp)"
  cat > "$tmp_script" <<EOF
#!/bin/sh
# Géré par orca-vps (bootstrap.sh).
set -e
for ipt in iptables ip6tables; do
  command -v "\$ipt" >/dev/null 2>&1 || continue
  "\$ipt" -w -N DOCKER-USER 2>/dev/null || true
  "\$ipt" -w -F DOCKER-USER
  "\$ipt" -w -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
  "\$ipt" -w -A DOCKER-USER -i $WG_IF -j RETURN
  "\$ipt" -w -A DOCKER-USER -i docker0 -j RETURN
  "\$ipt" -w -A DOCKER-USER -i br-+ -j RETURN
  "\$ipt" -w -A DOCKER-USER -j DROP
done
EOF
  cat > "$tmp_unit" <<'EOF'
[Unit]
Description=orca-vps : interdit l'accès public aux ports publiés par Docker
Before=docker.service
After=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/orca-vps-docker-guard

[Install]
WantedBy=multi-user.target docker.service
EOF
  # Relancé seulement s'il change ou si la chaîne a disparu : une relance de
  # install ne touche pas à Docker.
  if ! cmp -s "$tmp_script" "$script" || ! cmp -s "$tmp_unit" "$unit"; then
    install -m 755 "$tmp_script" "$script"
    install -m 644 "$tmp_unit" "$unit"
    systemctl daemon-reload
    systemctl reenable orca-vps-docker-guard.service >/dev/null 2>&1
    systemctl restart orca-vps-docker-guard.service
  elif ! grep -q -- '-j DROP' <<<"$(iptables -w -S DOCKER-USER 2>/dev/null)"; then
    systemctl restart orca-vps-docker-guard.service
  fi
  rm -f "$tmp_script" "$tmp_unit"
}

phase_docker() {
  local daemon=/etc/docker/daemon.json current desired restart=0
  if [ "$DOCKER_MODE" = rootless ]; then
    phase_docker_rootless
    return 0
  fi
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    info "Docker $(docker --version | awk '{print $3}' | tr -d ,) et Compose : déjà installés."
  else
    apt_install docker.io docker-compose-v2 docker-buildx
  fi

  install -d -m 755 /etc/docker /etc/systemd/system/docker.service.d
  current="$(cat "$daemon" 2>/dev/null || true)"
  [ -n "$current" ] || current='{}'
  desired="$(jq --arg ip "$WG_SERVER_IP" '. + {"ip": $ip, "live-restore": true}' <<<"$current")"
  if [ "$(jq -S . <<<"$current")" != "$(jq -S . <<<"$desired")" ] || [ ! -f "$daemon" ]; then
    printf '%s\n' "$desired" > "$daemon"
    restart=1
  fi
  local dropin=/etc/systemd/system/docker.service.d/10-orca-vps.conf tmp
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# Géré par orca-vps (bootstrap.sh) : Docker lie ses ports publiés à l'adresse
# du tunnel, qui doit donc exister avant lui.
[Unit]
After=wg-quick@$WG_IF.service
Wants=wg-quick@$WG_IF.service
EOF
  if ! cmp -s "$tmp" "$dropin"; then install -m 644 "$tmp" "$dropin"; restart=1; fi
  rm -f "$tmp"
  systemctl daemon-reload
  write_docker_guard
  if [ "$restart" -eq 1 ]; then
    systemctl reset-failed docker.service 2>/dev/null || true
    systemctl restart docker
    info "Docker redémarré : ports publiés liés par défaut à $WG_SERVER_IP."
  fi
  systemctl enable --now docker >/dev/null 2>&1

  if id -nG "$ORCA_USER" | tr ' ' '\n' | grep -qx docker; then
    info "$ORCA_USER : déjà membre du groupe docker."
  else
    usermod -aG docker "$ORCA_USER"
    info "$ORCA_USER ajouté au groupe docker (équivalent root sur cette machine, voir le README)."
    # La session systemd de l'utilisateur doit redémarrer pour voir le groupe.
    if orca_service_active; then
      warn "le service Orca tourne déjà : il ne verra le groupe docker qu'après « orca-vps update-orca --force » ou un redémarrage du VPS."
    else
      systemctl restart "user@$ORCA_UID.service"
      ensure_user_manager
    fi
  fi
}

phase_docker_rootless() {
  apt_install docker.io docker-compose-v2 docker-buildx uidmap rootlesskit slirp4netns dbus-user-session
  local setuptool
  setuptool="$(command -v dockerd-rootless-setuptool.sh || true)"
  [ -n "$setuptool" ] || setuptool="$(grep 'dockerd-rootless-setuptool.sh' <<<"$(dpkg -L docker.io)" | head -n1 || true)"
  [ -n "$setuptool" ] || die "dockerd-rootless-setuptool.sh introuvable dans le paquet docker.io : le mode rootless n'est pas disponible avec cette source. Utilise DOCKER_MODE=group."
  # Le paquet Ubuntu range ces scripts hors du PATH, où l'outil les attend.
  ln -sfn "$setuptool" /usr/local/bin/dockerd-rootless-setuptool.sh
  ln -sfn "$(dirname "$setuptool")/dockerd-rootless.sh" /usr/local/bin/dockerd-rootless.sh
  ln -sfn "$(command -v docker)" /usr/local/bin/docker
  setuptool=/usr/local/bin/dockerd-rootless-setuptool.sh
  # Le démon système ne sert pas en mode rootless.
  systemctl disable --now docker.service docker.socket >/dev/null 2>&1 || true
  if id -nG "$ORCA_USER" | tr ' ' '\n' | grep -qx docker; then
    gpasswd -d "$ORCA_USER" docker >/dev/null
  fi
  ensure_user_manager
  if as_user systemctl --user is-active --quiet docker.service 2>/dev/null; then
    info "Docker rootless : déjà actif."
  else
    as_user sh "$setuptool" install
    as_user systemctl --user enable --now docker.service
  fi
  local rc
  for rc in .profile .bashrc; do
    if ! grep -q '^# >>> orca-vps docker >>>' "$ORCA_HOME/$rc" 2>/dev/null; then
      printf '\n# >>> orca-vps docker >>>\nexport DOCKER_HOST=unix:///run/user/%s/docker.sock\n# <<< orca-vps docker <<<\n' "$ORCA_UID" \
        | as_user sh -c 'cat >> "$1"' sh "$ORCA_HOME/$rc"
    fi
  done
  info "Docker rootless actif pour $ORCA_USER (ports publiés filtrés par ufw)."
}

phase_service() {
  local before after
  resolve_user
  ensure_user_manager
  purge_do_not_track
  before="$(service_fingerprint)"
  write_service_env
  after="$(service_fingerprint)"
  if orca_service_active && [ "$before" = "$after" ] && [ -n "$(port_pid)" ] && manager_has_docker_group \
     && grep -q -- "--port $ORCA_PORT" "$ORCA_HOME/.config/systemd/user/$ORCA_UNIT" 2>/dev/null; then
    info "Service Orca : déjà actif sur le port $ORCA_PORT, non relancé."
    return 0
  fi
  if orca_service_active; then
    info "Configuration du service modifiée : réinstallation."
    as_user orca-ide serve service uninstall >/dev/null 2>&1 || true
  fi
  stop_stray_server
  install_orca_service
  info "Service Orca actif : écoute sur $(ss -ltnH "sport = :$ORCA_PORT" | awk '{print $4}' | paste -sd' ' -)."
}

phase_summary() {
  local state name step=1 port
  resolve_user
  port="$(ssh_port)"
  log "Bilan"
  info "Adresse du serveur dans le tunnel : $WG_SERVER_IP (Orca : port $ORCA_PORT)"
  info "Point d'accès WireGuard : $(public_endpoint):$WG_PORT/udp"
  info "Clé publique WireGuard du serveur : $(cat "$WG_DIR/server.pub")"
  info "Configurations WireGuard des appareils : $CLIENTS_DIR/ (clés générées sur le serveur)"
  info "Journal : $LOG_FILE"
  printf '\nClé publique SSH de l'\''agent, à ajouter au compte GitHub de l'\''agent :\n\n    %s\n' "$(cat "$ORCA_HOME/.ssh/id_ed25519.pub")"

  if is_interactive; then
    for state in "$PEERS_DIR"/*; do
      [ -f "$state" ] || continue
      name="$(basename "$state")"
      if [ -f "$CLIENTS_DIR/$name.conf" ]; then
        show_peer "$name"
        offer_key_deletion "$name"
      fi
    done
    if ! gh_logged_in && confirm "Connecter GitHub (gh) maintenant, avec le compte de l'agent ?" o; then
      cmd_gh_login || warn "connexion GitHub non terminée : relance « orca-vps gh-login »."
      CURRENT_PHASE=summary
    fi
    if ! claude_logged_in && confirm "Connecter Claude Code maintenant (URL à ouvrir sur ton Mac, code à coller ici) ?" o; then
      cmd_claude_login || warn "connexion Claude non terminée : relance « orca-vps claude-login »."
    fi
  fi

  printf '\nÉtapes manuelles restantes :\n\n'
  printf '  %s. Importer la configuration WireGuard sur chaque appareil, puis activer le tunnel :\n' "$step"; step=$((step + 1))
  for state in "$PEERS_DIR"/*; do
    [ -f "$state" ] || continue
    printf '       sudo orca-vps add-peer %s    (affiche la configuration%s)\n' "$(basename "$state")" \
      "$([ -f "$CLIENTS_DIR/$(basename "$state").conf" ] && printf ' et le QR code, puis propose de supprimer la clé privée' || true)"
  done
  if [ ! -f "$LOCKDOWN_MARKER" ]; then
    printf '  %s. Fermer SSH côté Internet, depuis une session ouverte par le tunnel :\n' "$step"; step=$((step + 1))
    printf '       ssh -a <compte admin>@%s    puis    sudo orca-vps lockdown\n' "$WG_SERVER_IP"
  fi
  if ! gh_logged_in; then
    printf '  %s. Connecter GitHub (gh) avec le compte de l'\''agent :    sudo orca-vps gh-login\n' "$step"; step=$((step + 1))
    printf '       (gh propose aussi d'\''envoyer la clé SSH ci-dessus au compte)\n'
  elif ! agent_key_on_github; then
    printf '  %s. Ajouter la clé SSH ci-dessus au compte GitHub de l'\''agent (Settings → SSH and GPG keys).\n' "$step"; step=$((step + 1))
  fi
  if ! claude_logged_in; then
    printf '  %s. Connecter Claude Code :    sudo orca-vps claude-login\n' "$step"; step=$((step + 1))
  fi
  printf '  %s. Appairer le Mac, puis le téléphone (tunnel actif sur l'\''appareil) :\n' "$step"; step=$((step + 1))
  printf '       sudo orca-vps pair            lien à coller dans Settings → Remote Orca Servers → Add Server\n'
  printf '       sudo orca-vps pair --mobile   QR code pour Orca Mobile\n'
  printf '  %s. Régler les appareils : voir la section « Réglages côté appareils » du README.\n' "$step"
  printf '\nSi ton hébergeur a un pare-feu réseau (Hetzner Cloud Firewall, groupes de sécurité…), ouvre-y le port UDP %s.\n' "$WG_PORT"
  printf 'Contrôle à tout moment : sudo orca-vps verify\n'
  if [ -f /var/run/reboot-required ]; then
    printf '\nUn redémarrage est demandé par une mise à jour du système (noyau) : sudo reboot, quand aucun agent ne tourne.\n'
  fi
  printf 'Secours si le tunnel tombe après lockdown : console web de l'\''hébergeur, puis « ufw allow %s/tcp ».\n' "$port"
}

run_phase() {
  CURRENT_PHASE=$1
  log "Phase : $1"
  "phase_$1"
}

cmd_install() {
  local only="" phase
  while [ $# -gt 0 ]; do
    case "$1" in
      --only) only="${2:-}"; [ -n "$only" ] || die "--only attend un nom de phase."; shift 2 ;;
      *) die "option inconnue pour install : $1" ;;
    esac
  done
  if [ -n "$only" ]; then
    printf '%s\n' "${PHASES[@]}" | grep -qx "$only" || die "phase inconnue : $only. Phases : ${PHASES[*]}"
  fi
  ensure_install_config
  if [ -n "$only" ]; then
    case "$only" in preflight|system|user) ;; *) resolve_user ;; esac
    run_phase "$only"
  else
    for phase in "${PHASES[@]}"; do
      run_phase "$phase"
    done
  fi
}

# --- lockdown -------------------------------------------------------------------

cmd_lockdown() {
  local port client now recent=0 key ts
  CURRENT_PHASE=lockdown
  port="$(ssh_port)"
  [ -n "$port" ] || die "port SSH introuvable (sshd -T)."
  grep -q '^Status: active' <<<"$(ufw status)" || die "ufw n'est pas actif. Lance d'abord : orca-vps install"
  grep -qx "ufw allow in on $WG_IF" <<<"$(ufw show added)" || die "la règle « allow in on $WG_IF » est absente : SSH resterait injoignable."

  now="$(date +%s)"
  while read -r key ts; do
    [ -n "$key" ] || continue
    if [ "${ts:-0}" -gt 0 ] && [ $(( now - ts )) -le 180 ]; then recent=1; fi
  done < <(wg show "$WG_IF" latest-handshakes 2>/dev/null || true)
  [ "$recent" -eq 1 ] || die "aucun appareil n'a échangé avec le serveur depuis moins de 3 minutes (wg show). Active le tunnel sur ton appareil, puis relance."

  client="$(ssh_client_ip)"
  [ -n "$client" ] || die "session SSH introuvable. Lance lockdown depuis une session SSH ouverte par le tunnel : ssh <compte>@$WG_SERVER_IP"
  ip_in_cidr "$client" "$WG_NET" || die "cette session SSH vient de $client, pas du tunnel ($WG_NET). Reconnecte-toi avec : ssh <compte>@$WG_SERVER_IP"
  info "Tunnel vérifié : échange récent, et session SSH venant de $client."

  ufw --force delete allow "$port/tcp" >/dev/null 2>&1 || true
  ufw --force delete allow "$port" >/dev/null 2>&1 || true
  ufw --force delete allow OpenSSH >/dev/null 2>&1 || true
  ufw --force delete limit "$port/tcp" >/dev/null 2>&1 || true
  if grep -E "^ufw (allow|limit) " <<<"$(ufw show added)" | grep -vE " on $WG_IF( |$)" | grep -qE "(^| )($port(/tcp)?|OpenSSH)( |$)"; then
    die "une règle ouvre encore le port SSH côté Internet : vérifie « ufw status numbered »."
  fi
  install -d -m 700 "$STATE_DIR"
  date '+%Y-%m-%d %H:%M:%S' > "$LOCKDOWN_MARKER"
  log "SSH est fermé côté Internet"
  info "Accès désormais : ssh <compte>@$WG_SERVER_IP, tunnel WireGuard actif."
  info "Secours si le tunnel tombe : console web de l'hébergeur, puis « ufw allow $port/tcp »."
  info "Contrôle depuis ton Mac, tunnel coupé : nc -zv -G 5 $(public_endpoint) $port   (doit échouer)"
}

# --- verify ---------------------------------------------------------------------

VERIFY_FAILED=0
VERIFY_WARNED=0
ok()      { printf '  [  OK  ] %s\n' "$*"; }
ko()      { printf '  [ÉCHEC ] %s\n' "$*"; VERIFY_FAILED=$((VERIFY_FAILED + 1)); }
# verdict <code retour> <message si succès> <message si échec>
verdict() { if [ "$1" -eq 0 ]; then ok "$2"; else ko "$3"; fi; }
caution() { printf '  [AVERT.] %s\n' "$*"; VERIFY_WARNED=$((VERIFY_WARNED + 1)); }

verify_listeners() {
  local proto addr port unexpected="" sshp line owner hint=""
  sshp="$(ssh_port)"
  while read -r proto _ _ _ line _ owner; do
    # En mode rootless, les ports publiés sont des écoutes ordinaires de
    # rootlesskit : ufw les filtre, seul le tunnel les atteint.
    if [ "$DOCKER_MODE" = rootless ]; then
      case "$owner" in *rootlesskit*|*slirp4netns*) continue ;; esac
    fi
    addr="${line%:*}"
    port="${line##*:}"
    addr="${addr%%%*}"
    case "$addr" in
      127.*|"[::1]"|"$WG_SERVER_IP") continue ;;
    esac
    case "$proto:$port" in
      "tcp:$sshp"|"tcp:$ORCA_PORT"|"udp:$WG_PORT"|udp:68|udp:546) continue ;;
    esac
    unexpected+=" $proto/$line"
  done < <(ss -H -lntup)
  [ "$DOCKER_MODE" != group ] || hint=" (un port Docker publié sur 0.0.0.0 reste bloqué par le garde-fou, mais corrige le compose)"
  if [ -z "$unexpected" ]; then
    ok "Écoutes réseau : rien hors SSH, Orca et WireGuard"
  else
    ko "Écoutes réseau inattendues :$unexpected$hint"
  fi
}

verify_firewall() {
  local status rules extra="" rule sshp
  sshp="$(ssh_port)"
  status="$(ufw status verbose 2>/dev/null || true)"
  if grep -q '^Status: active' <<<"$status" && grep -q 'deny (incoming)' <<<"$status"; then
    ok "Pare-feu actif, refus par défaut en entrée"
  else
    ko "Pare-feu inactif ou sans refus par défaut en entrée"
  fi
  grep -q '^IPV6=yes' /etc/default/ufw; verdict $? "Pare-feu : IPv6 filtré" "Pare-feu : IPv6 non filtré (IPV6=yes absent de /etc/default/ufw)"
  rules="$(ufw show added | grep '^ufw ' || true)"
  grep -qx "ufw allow $WG_PORT/udp" <<<"$rules"; verdict $? "Règle WireGuard $WG_PORT/udp" "Règle WireGuard $WG_PORT/udp absente"
  grep -qx "ufw allow in on $WG_IF" <<<"$rules"; verdict $? "Règle « tout sur $WG_IF »" "Règle « allow in on $WG_IF » absente"
  while IFS= read -r rule; do
    case "$rule" in
      "ufw allow $WG_PORT/udp"|"ufw allow in on $WG_IF"|"") ;;
      "ufw allow $sshp/tcp"|"ufw allow OpenSSH") ;;
      *) extra+=" [$rule]" ;;
    esac
  done <<<"$rules"
  if [ -z "$extra" ]; then ok "Pare-feu : aucune règle hors de celles prévues"; else ko "Pare-feu : règles inattendues :$extra"; fi
  if grep -qxE "ufw allow ($sshp/tcp|OpenSSH)" <<<"$rules"; then
    caution "SSH ($sshp/tcp) encore ouvert sur Internet : lance « orca-vps lockdown » depuis le tunnel"
  else
    ok "SSH fermé côté Internet (joignable par le tunnel seulement)"
  fi
}

cmd_verify() {
  local out pid env_dump peers groups
  CURRENT_PHASE=verify
  # Un contrôle qui échoue est un résultat, pas une erreur du script.
  trap - ERR
  set +e
  resolve_user
  log "Contrôles"

  # Tunnel
  if ip link show "$WG_IF" >/dev/null 2>&1; then
    peers="$(wg show "$WG_IF" peers | grep -c .)"
    if [ "$peers" -eq "$(find "$PEERS_DIR" -type f 2>/dev/null | grep -c .)" ] && [ "$peers" -gt 0 ]; then
      ok "Tunnel $WG_IF actif, $peers appareil(s) déclaré(s)"
    else
      ko "Tunnel $WG_IF actif mais $peers appareil(s) chargé(s), différent de l'état enregistré"
    fi
  else
    ko "Tunnel $WG_IF absent"
  fi
  systemctl is-enabled --quiet "wg-quick@$WG_IF"; verdict $? "Tunnel relancé au démarrage" "wg-quick@$WG_IF n'est pas activé au démarrage"

  verify_firewall
  verify_listeners

  # SSH
  out="$(sshd -T 2>/dev/null)"
  if grep -qx 'passwordauthentication no' <<<"$out" && grep -qx 'kbdinteractiveauthentication no' <<<"$out"; then
    ok "SSH : clé uniquement, mot de passe refusé"
  else
    ko "SSH : l'authentification par mot de passe est encore possible"
  fi

  # Compte sans privilèges
  groups="$(id -nG "$ORCA_USER")"
  if tr ' ' '\n' <<<"$groups" | grep -qxE 'sudo|admin|wheel|adm|lxd'; then
    ko "Compte $ORCA_USER : membre d'un groupe d'administration ($groups)"
  elif grep -qiE 'not allowed|n.est pas autorisé' <<<"$(sudo -n -l -U "$ORCA_USER" 2>&1)"; then
    ok "Compte $ORCA_USER : aucun droit sudo (groupes : $groups)"
  else
    ko "Compte $ORCA_USER : sudo -l ne confirme pas l'absence de droits"
  fi
  if [ "$(loginctl show-user "$ORCA_USER" -p Linger --value 2>/dev/null)" = yes ]; then ok "Persistance : Linger=yes"; else ko "Persistance : linger désactivé pour $ORCA_USER"; fi

  # Orca
  if orca_service_active; then ok "Service Orca actif ($(orca_installed_version))"; else ko "Service Orca inactif"; fi
  as_user systemctl --user is-enabled --quiet "$ORCA_UNIT" 2>/dev/null; verdict $? "Service Orca relancé au démarrage" "Service Orca non activé au démarrage"
  pid="$(port_pid)"
  if [ -n "$pid" ]; then
    ok "Port Orca $ORCA_PORT en écoute ($(ss -ltnH "sport = :$ORCA_PORT" | awk '{print $4}' | paste -sd' ' -))"
    env_dump="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null)"
    grep -qx 'ORCA_TELEMETRY_DISABLED=1' <<<"$env_dump"; verdict $? "Service : ORCA_TELEMETRY_DISABLED=1" "Service : ORCA_TELEMETRY_DISABLED=1 absent de l'environnement"
    grep -E '^PATH=' <<<"$env_dump" | grep -q "$ORCA_HOME/.local/bin"; verdict $? "Service : PATH contient ~/.local/bin" "Service : ~/.local/bin absent du PATH"
    if grep -q '^DO_NOT_TRACK=' <<<"$env_dump"; then ko "Service : DO_NOT_TRACK est défini (à retirer)"; else ok "Service : DO_NOT_TRACK non défini"; fi
    if grep -qs 'DO_NOT_TRACK=' "$ORCA_HOME/.bashrc" "$ORCA_HOME/.profile" "$ORCA_HOME"/.config/environment.d/*.conf; then
      ko "Shells de $ORCA_USER : DO_NOT_TRACK est défini (orca-vps install --only service)"
    else
      ok "Shells de $ORCA_USER : DO_NOT_TRACK non défini"
    fi
    if [ "$DOCKER_MODE" = group ]; then
      if grep -E '^Groups:' "/proc/$pid/status" | tr -s '[:space:]' '\n' | grep -qx "$(getent group docker | cut -d: -f3)"; then
        ok "Service : groupe docker visible par les agents"
      else
        ko "Service : lancé sans le groupe docker (orca-vps update-orca --force, ou redémarrage)"
      fi
    fi
  else
    ko "Port Orca $ORCA_PORT : personne n'écoute"
  fi

  # Flux vers l'éditeur
  local host blocked_ko=""
  for host in $ORCA_BLOCKED_HOSTS; do
    case "$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR == 1 {print $1}')" in
      0.0.0.0|"") ;;
      *) blocked_ko+=" $host" ;;
    esac
  done
  if [ -z "$ORCA_BLOCKED_HOSTS" ]; then
    caution "Aucun nom bloqué : le serveur Orca contacte le site de son éditeur (ORCA_BLOCKED_HOSTS vide)"
  elif [ -z "$blocked_ko" ]; then
    ok "Noms de l'éditeur d'Orca injoignables ($(wc -w <<<"$ORCA_BLOCKED_HOSTS") noms dans /etc/hosts)"
  else
    ko "Noms censés être bloqués mais joignables :$blocked_ko (orca-vps install --only orca)"
  fi

  # Claude Code
  out="$(as_user claude --version 2>/dev/null | head -n1)"
  if [ -n "$out" ]; then ok "Claude Code : $out"; else ko "Claude Code : commande claude introuvable pour $ORCA_USER"; fi
  if claude_logged_in; then ok "Claude Code : authentifié (mode $CLAUDE_AUTH)"; else caution "Claude Code : pas encore connecté (orca-vps claude-login)"; fi

  # Git
  out="$(as_user ssh -T -o BatchMode=yes -o ConnectTimeout=15 git@github.com </dev/null 2>&1)"
  if grep -q 'successfully authenticated' <<<"$out"; then
    ok "Identité Git : GitHub salue $(sed -n 's/^Hi \([^!]*\)!.*/\1/p' <<<"$out")"
  elif grep -qi 'permission denied' <<<"$out"; then
    caution "Identité Git : la clé SSH de l'agent n'est pas encore sur le compte GitHub (orca-vps gh-login peut l'ajouter)"
  else
    ko "Identité Git : connexion à GitHub impossible ($(head -n1 <<<"$out"))"
  fi
  if gh_logged_in; then
    ok "GitHub CLI : gh connecté ($(as_user gh api user --jq .login 2>/dev/null))"
  else
    caution "GitHub CLI : gh pas encore connecté (orca-vps gh-login)"
  fi
  if [ "$(as_user git config --global user.email 2>/dev/null)" = "$GIT_USER_EMAIL" ]; then ok "Identité Git : $GIT_USER_EMAIL"; else ko "Identité Git : user.email différent de la configuration"; fi

  # Docker
  if as_user sh -c '[ -z "$1" ] || export DOCKER_HOST="$1"; docker run --rm hello-world' sh \
       "$([ "$DOCKER_MODE" = rootless ] && printf 'unix:///run/user/%s/docker.sock' "$ORCA_UID")" >/dev/null 2>&1; then
    ok "Docker : hello-world sous $ORCA_USER (mode $DOCKER_MODE)"
  else
    ko "Docker : docker run hello-world échoue sous $ORCA_USER"
  fi
  if [ "$DOCKER_MODE" = group ]; then
    if [ "$(jq -r '.ip // empty' /etc/docker/daemon.json 2>/dev/null)" = "$WG_SERVER_IP" ]; then
      ok "Docker : ports publiés liés par défaut à $WG_SERVER_IP"
    else
      ko "Docker : adresse de liaison par défaut absente de daemon.json"
    fi
    if grep -q -- '-j DROP' <<<"$(iptables -w -S DOCKER-USER 2>/dev/null)"; then
      ok "Docker : garde-fou DOCKER-USER en place (accès public aux conteneurs refusé)"
    else
      ko "Docker : garde-fou DOCKER-USER absent (systemctl restart orca-vps-docker-guard)"
    fi
  fi

  # Mises à jour
  if grep -qs 'Unattended-Upgrade "1"' /etc/apt/apt.conf.d/20auto-upgrades; then ok "Correctifs de sécurité automatiques"; else ko "unattended-upgrades désactivé"; fi
  out="$(apt-config dump 2>/dev/null)"
  if grep -q 'Unattended-Upgrade::Automatic-Reboot "true"' <<<"$out"; then ko "Redémarrage automatique activé"; else ok "Redémarrage automatique désactivé"; fi

  printf '\nBilan : %s échec(s), %s avertissement(s).\n' "$VERIFY_FAILED" "$VERIFY_WARNED"
  printf 'Les tests à lancer depuis le Mac (ports fermés, reprise mobile, redémarrage) sont dans le README.\n'
  set -e
  [ "$VERIFY_FAILED" -eq 0 ]
}

# --- add-peer, pair, claude-login ----------------------------------------------

cmd_add_peer() {
  local name="" pubkey="" ip=""
  CURRENT_PHASE=add-peer
  while [ $# -gt 0 ]; do
    case "$1" in
      --pubkey) pubkey="${2:-}"; shift 2 ;;
      --ip) ip="${2:-}"; shift 2 ;;
      -*) die "option inconnue pour add-peer : $1" ;;
      *) [ -z "$name" ] || die "un seul nom d'appareil attendu."; name=$1; shift ;;
    esac
  done
  [ -n "$name" ] || die "usage : $0 add-peer <nom> [--pubkey <clé publique>] [--ip <adresse>]"
  valid_peer_name "$name" || die "nom d'appareil invalide : $name"
  [ -s "$WG_DIR/server.key" ] || die "WireGuard n'est pas installé. Lance d'abord : $0 install"
  install -d -m 700 "$PEERS_DIR" "$CLIENTS_DIR"
  if [ ! -f "$PEERS_DIR/$name" ]; then
    [ -n "$ip" ] || ip="$(next_free_peer_ip)"
    ensure_peer "$name" "$ip" "$pubkey"
  elif [ -n "$pubkey" ]; then
    ensure_peer "$name" "$(cut -d' ' -f1 "$PEERS_DIR/$name")" "$pubkey"
  else
    info "Appareil $name : déjà présent, clé conservée."
  fi
  apply_wg_conf
  show_peer "$name"
  offer_key_deletion "$name"
}

cmd_remove_peer() {
  local name=${1:-}
  CURRENT_PHASE=remove-peer
  if [ -z "$name" ] || ! valid_peer_name "$name"; then die "usage : $0 remove-peer <nom>"; fi
  [ -f "$PEERS_DIR/$name" ] || die "appareil inconnu : $name"
  rm -f "$PEERS_DIR/$name"
  [ ! -f "$CLIENTS_DIR/$name.conf" ] || shred -u "$CLIENTS_DIR/$name.conf" 2>/dev/null || rm -f "$CLIENTS_DIR/$name.conf"
  apply_wg_conf
  info "Appareil $name retiré : sa clé n'ouvre plus le tunnel."
  case " $WG_PEERS " in
    *" $name:"*) warn "$name figure encore dans WG_PEERS : retire-le de config.env, sinon le prochain install le recréera avec de nouvelles clés." ;;
  esac
}

cmd_pair() {
  local args=(pair --address "$WG_SERVER_IP")
  CURRENT_PHASE=pair
  while [ $# -gt 0 ]; do
    case "$1" in
      --mobile) args+=(--mobile); shift ;;
      --rotate) args+=(--rotate); shift ;;
      *) die "option inconnue pour pair : $1 (jamais --relay : aucun flux ne doit passer par Orca)." ;;
    esac
  done
  resolve_user
  [ -n "$(port_pid)" ] || die "le serveur Orca ne tourne pas. Lance : $0 install --only service"
  info "Demande d'appairage au serveur Orca en marche (rien n'est relancé)."
  info "Le lien d'appairage vaut un mot de passe : il n'est pas écrit dans le journal."
  flush_output
  as_user orca-ide "${args[@]}" >&3 2>&4
}

cmd_claude_login() {
  CURRENT_PHASE=claude-login
  resolve_user
  [ "$CLAUDE_AUTH" = login ] || die "CLAUDE_AUTH=token : l'authentification passe par le jeton de config.env."
  is_interactive || die "claude-login a besoin d'un terminal : connecte-toi en SSH et relance la commande."
  tty_out ""
  tty_out "Connexion de Claude Code sous $ORCA_USER : ouvre l'URL affichée sur ton Mac, puis colle le code ici."
  flush_output
  as_user claude auth login >&3 2>&4
  claude_logged_in || die "Claude Code n'est pas authentifié."
  info "Claude Code est connecté."
}

# --- update-orca ---------------------------------------------------------------
# Reprend la logique du script update-orca.sh validé le 13 novembre 2026.

cmd_update_orca() {
  local force=0 installed running answer _
  CURRENT_PHASE=update-orca
  [ "${1:-}" != "--force" ] || force=1
  resolve_user

  log "Recherche de la version disponible"
  orca_read_manifest
  installed="$(orca_installed_version)"
  info "Installée : ${installed:-aucune}   Disponible : $ORCA_TARGET   (méthode $ORCA_INSTALL_METHOD)"
  if [ "$installed" = "$ORCA_TARGET" ] && [ "$force" -eq 0 ]; then
    info "Orca est déjà à jour. Rien à faire (--force pour réinstaller et relancer le service)."
    return 0
  fi

  running="$(pgrep -c -u "$ORCA_USER" -x claude || true)"
  if [ "${running:-0}" -gt 0 ] && [ "$force" -eq 0 ]; then
    info "$running session(s) Claude tournent sous $ORCA_USER."
    is_interactive || die "sessions actives : relance avec --force pour continuer quand même."
    confirm "Continuer la mise à jour ?" n || die "abandon à ta demande."
  fi

  log "Arrêt du serveur Orca"
  as_user orca-ide serve service uninstall >/dev/null 2>&1 || true
  stop_stray_server

  log "Installation d'Orca $ORCA_TARGET"
  orca_install_package

  log "Redémarrage en service sous $ORCA_USER"
  ALLOW_SESSION_RESTART=1
  install_orca_service

  as_user orca-ide serve service status || true
  printf '\n'
  info "Version installée : $(orca_installed_version)"
  info "Écoute            : $(ss -ltnH "sport = :$ORCA_PORT" | awk '{print $4}' | paste -sd' ' -)"
  info "Mise à jour terminée. Les clients appairés se reconnectent seuls."
  info "Client et serveur doivent rester compatibles : mets à jour Orca sur le Mac et le téléphone en même temps."
}

# --- Point d'entrée -------------------------------------------------------------

usage() {
  cat <<EOF
Usage : sudo $0 <commande>

  install [--only <phase>]   Installe tout (SSH reste ouvert sur Internet)
  lockdown                   Ferme SSH côté Internet, après contrôle du tunnel
  verify                     Rejoue les contrôles et affiche un bilan
  add-peer <nom> [--pubkey <clé>] [--ip <adresse>]
                             Ajoute un appareil WireGuard, ou réaffiche sa configuration
  remove-peer <nom>          Révoque un appareil WireGuard (perdu ou remplacé)
  pair [--mobile]            Demande un appairage au serveur Orca en marche
  gh-login                   Connecte la CLI GitHub (gh) et envoie la clé SSH de l'agent au compte
  claude-login               Connecte Claude Code sous l'utilisateur Orca
  update-orca [--force]      Met Orca à jour et relance le service

Phases de install : ${PHASES[*]}
Configuration : config.env à côté du script, sinon $STATE_CONFIG
EOF
}

main() {
  local cmd=${1:-}
  case "$cmd" in
    ""|-h|--help|help) usage; exit 0 ;;
    install|lockdown|verify|add-peer|remove-peer|pair|gh-login|claude-login|update-orca) shift ;;
    *) usage >&2; exit 2 ;;
  esac
  [ "$(id -u)" -eq 0 ] || { echo "ERREUR : lance ce script en root : sudo $0 $cmd" >&2; exit 1; }
  umask 022
  trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR
  trap on_exit EXIT
  setup_logging "$cmd"
  load_config
  case "$cmd" in
    install)      cmd_install "$@" ;;
    lockdown)     cmd_lockdown ;;
    verify)       cmd_verify ;;
    add-peer)     cmd_add_peer "$@" ;;
    remove-peer)  cmd_remove_peer "$@" ;;
    pair)         cmd_pair "$@" ;;
    gh-login)     cmd_gh_login ;;
    claude-login) cmd_claude_login ;;
    update-orca)  cmd_update_orca "$@" ;;
  esac
}

main "$@"
