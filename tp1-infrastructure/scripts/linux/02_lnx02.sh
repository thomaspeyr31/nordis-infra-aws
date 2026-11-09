#!/usr/bin/env bash
# =============================================================================
# Nom         : 02_lnx02.sh
# Auteur      : Thomas Peyrusaubes
# Date        : 2026-10-22
# Version     : 1.2-aws
# Projet      : Nordis Distribution - Module A2627_5066
# Description : Serveur applicatif LNX02 (DMZ, VLAN 20) :
#                 - intranet Nordis publié par nginx
#                 - paquets via le cache APT de LNX01, mises à jour de sécurité automatiques
#                 - journaux (système + accès nginx) envoyés au rsyslog central de LNX01
#                 - sudo réservé au groupe local sudo, SSH par clé uniquement
#                 - heure prise sur FW01 (chrony)
#               Non joint à l'AD : la DMZ ne doit pas pouvoir joindre les contrôleurs de domaine.
#               Différences avec la version Hyper-V :
#                 - plus de 00_preparation_clone.sh : nom, IP et DNS (FW01) viennent d'AWS ;
#                 - dépôts Debian passés en http pour passer par le cache de LNX01
#                   (images AWS : adresses dans /etc/apt/mirrors/*.list).
# Prérequis   : LNX01 prêt, règles FW01 DMZ -> LNX01 (3142, 514).
# Usage       : sudo ./02_lnx02.sh      (depuis le compte admin)
# Retour      : 0 = succès, 1 = erreur
# =============================================================================
set -Eeuo pipefail

# ---------- Variables ----------
SERVEUR_JOURNAUX="10.50.10.20"      # LNX01
PORT_SYSLOG=514
PROXY_APT="http://10.50.10.20:3142"
NTP_SERVEUR="10.50.0.20"           # FW01 (la DMZ ne joint pas les DC)
NOM_SITE="intranet"
NOM_SERVEUR="intranet.ad.nordis.test"
RACINE_WEB="/var/www/${NOM_SITE}"
ADMIN_LOCAL="${SUDO_USER:-}"
DOSSIER_LOGS="/var/log/nordis"
JOURNAL="${DOSSIER_LOGS}/02_lnx02.log"

# ---------- Fonctions ----------
mkdir -p "$DOSSIER_LOGS"
log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" | tee -a "$JOURNAL"; }
echec() { log ERREUR "Ligne $1 : commande en échec. Journal : $JOURNAL"; exit 1; }
trap 'echec $LINENO' ERR
[[ $EUID -eq 0 ]] || { echo "Lance ce script avec sudo."; exit 1; }
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8          # évite les avertissements perl dus à la langue envoyée par le Mac

log INFO "===== LNX02 : démarrage ====="

# ---------- 1. Cache APT (LNX01) + paquets ----------
# Dépôts en http : apt-cacher-ng ne relaie que du http (paquets vérifiés par signature GPG)
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list /etc/apt/mirrors/*.list; do
    if [[ -f "$f" ]]; then sed -i 's|https://|http://|g' "$f"; fi
done
echo "Acquire::http::Proxy \"${PROXY_APT}\";" > /etc/apt/apt.conf.d/01proxy
if ! apt-get update -qq; then
    log ERREUR "apt via $PROXY_APT impossible : vérifie LNX01 et la règle FW01 DMZ -> 10.50.10.20:3142"
    exit 1
fi
apt-get install -y -qq nginx rsyslog chrony unattended-upgrades apt-listchanges sudo >/dev/null
log OK "Paquets installés via le cache $PROXY_APT"

# ---------- 1 bis. Heure ----------
sed -i -E 's/^((pool|server) .*)/# \1/' /etc/chrony/chrony.conf
mkdir -p /etc/chrony/sources.d
echo "server ${NTP_SERVEUR} iburst" > /etc/chrony/sources.d/nordis.sources
systemctl restart chrony
log OK "chrony : $NTP_SERVEUR (FW01)"

# ---------- 2. Mises à jour de sécurité ----------
# shellcheck disable=SC1091
. /etc/os-release
if ! grep -rqs "debian-security" /etc/apt/sources.list /etc/apt/sources.list.d/; then
    echo "deb http://security.debian.org/debian-security ${VERSION_CODENAME}-security main" \
        > /etc/apt/sources.list.d/securite.list
fi
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl enable --now unattended-upgrades >/dev/null
log OK "unattended-upgrades actif"

# ---------- 3. Intranet nginx ----------
mkdir -p "$RACINE_WEB"
cat > "${RACINE_WEB}/index.html" <<'EOF'
<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Intranet Nordis</title>
  <style>
    body { margin: 0; font-family: system-ui, sans-serif; background: #f4f5f7; color: #16202b; }
    header { background: #16202b; color: #fff; padding: 24px 32px; }
    header span { color: #f2b53a; }
    main { max-width: 860px; margin: 32px auto; padding: 0 16px; }
    .grille { display: grid; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); gap: 16px; }
    .carte { background: #fff; border-radius: 10px; padding: 18px 20px; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
    h2 { margin-top: 0; font-size: 1.05rem; color: #2f6db5; }
    footer { text-align: center; color: #6b7480; font-size: .85rem; margin: 40px 0; }
  </style>
</head>
<body>
  <header><h1>Nordis <span>Distribution</span> &mdash; Intranet</h1></header>
  <main>
    <div class="grille">
      <div class="carte"><h2>Lecteurs réseau</h2><p>S: Direction &middot; T: Administration &middot; U: IT &middot; V: Commercial &middot; W: Logistique &middot; H: dossier personnel</p></div>
      <div class="carte"><h2>Support informatique</h2><p>Service Informatique &mdash; poste 8 h - 18 h, du lundi au vendredi.</p></div>
      <div class="carte"><h2>Sécurité</h2><p>Mot de passe de 12 caractères minimum, renouvelé tous les 90 jours. Ne le communiquez jamais.</p></div>
    </div>
  </main>
  <footer>Servi par LNX02 (DMZ) &mdash; nginx</footer>
</body>
</html>
EOF
cat > "/etc/nginx/sites-available/${NOM_SITE}" <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${NOM_SERVEUR};
    root ${RACINE_WEB};
    index index.html;
    server_tokens off;
    access_log /var/log/nginx/${NOM_SITE}_access.log;
    access_log syslog:server=${SERVEUR_JOURNAUX}:${PORT_SYSLOG},tag=nginx_access;
    error_log  syslog:server=${SERVEUR_JOURNAUX}:${PORT_SYSLOG},tag=nginx_error;
    location / { try_files \$uri \$uri/ =404; }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sf "/etc/nginx/sites-available/${NOM_SITE}" "/etc/nginx/sites-enabled/${NOM_SITE}"
nginx -t 2>/dev/null
systemctl enable --now nginx >/dev/null
systemctl reload nginx
log OK "Intranet publié : http://$(hostname -I | awk '{print $1}')/"

# ---------- 4. Journaux vers LNX01 ----------
cat > /etc/rsyslog.d/90-nordis-envoi.conf <<EOF
# Généré par 02_lnx02.sh : copie de tous les journaux vers LNX01 (TCP, file d'attente si indisponible)
*.* action(type="omfwd" target="${SERVEUR_JOURNAUX}" port="${PORT_SYSLOG}" protocol="tcp"
           queue.type="LinkedList" queue.filename="vers_lnx01" action.resumeRetryCount="-1")
EOF
rsyslogd -N1 >/dev/null 2>&1
systemctl restart rsyslog
logger -t nordis "Test d'envoi depuis $(hostname) vers LNX01"
log OK "Journaux envoyés à $SERVEUR_JOURNAUX:$PORT_SYSLOG"

# ---------- 5. sudo réservé au groupe sudo ----------
cat > /etc/sudoers.d/10-nordis <<EOF
# Généré par 02_lnx02.sh : seul le groupe local sudo a les droits d'administration
%sudo ALL=(ALL:ALL) ALL
EOF
chmod 440 /etc/sudoers.d/10-nordis
visudo -cf /etc/sudoers.d/10-nordis >/dev/null
log OK "sudo : groupe local sudo uniquement ($(getent group sudo | cut -d: -f4))"

# ---------- 6. SSH par clé ----------
cle_presente=0
if [[ -n "$ADMIN_LOCAL" ]] && [[ -s "/home/$ADMIN_LOCAL/.ssh/authorized_keys" ]]; then cle_presente=1; fi
cat > /etc/ssh/sshd_config.d/10-nordis.conf <<EOF
# Généré par 02_lnx02.sh
PermitRootLogin no
PubkeyAuthentication yes
EOF
if [[ -n "$ADMIN_LOCAL" ]] && id -nG "$ADMIN_LOCAL" | grep -qw sudo; then
    echo "AllowGroups sudo" >> /etc/ssh/sshd_config.d/10-nordis.conf
    log OK "SSH : AllowGroups sudo"
else
    log WARN "SSH : ${ADMIN_LOCAL:-?} n'est pas dans le groupe sudo -> AllowGroups non appliqué (pour ne pas te bloquer)"
fi
if [[ $cle_presente -eq 1 ]]; then
    printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' >> /etc/ssh/sshd_config.d/10-nordis.conf
    log OK "SSH : clé uniquement (mot de passe désactivé)"
else
    log WARN "SSH : aucune clé dans /home/${ADMIN_LOCAL:-?}/.ssh/authorized_keys -> mot de passe laissé actif. Ajoute ta clé puis relance le script."
fi
sshd -t
systemctl restart ssh

log OK "===== LNX02 prêt ====="
log INFO "Tests : curl -I http://localhost | sur LNX01 : ls /srv/journaux/lnx02/"
exit 0
