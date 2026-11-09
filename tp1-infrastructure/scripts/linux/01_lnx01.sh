#!/usr/bin/env bash
# =============================================================================
# Nom         : 01_lnx01.sh
# Auteur      : Thomas Peyrusaubes
# Date        : 2026-10-22
# Version     : 1.3-aws
# Projet      : Nordis Distribution - Module A2627_5066
# Description : Serveur d'infrastructure LNX01 (Debian 13 sur EC2) :
#                 - heure prise sur les contrôleurs de domaine (chrony)
#                 - RAID 5 logiciel (mdadm, 3 volumes EBS) + LVM, montage par UUID
#                 - dossiers personnels des comptes AD sur un volume dédié (/home/AD)
#                 - journaux centralisés (rsyslog en écoute UDP/TCP 514, un dossier par hôte)
#                 - cache de paquets apt-cacher-ng (port 3142)
#                 - mises à jour de sécurité automatiques (unattended-upgrades)
#                 - intégration à l'AD ad.nordis.test (realmd / sssd)
#                 - sudo réservé à un groupe, SSH par clé uniquement et limité aux groupes autorisés
#               Différences avec la version Hyper-V :
#                 - plus de 00_preparation_clone.sh : nom, IP et DNS (FW01) viennent d'AWS
#                   (cloud-init + options DHCP du VPC) ;
#                 - disques de données détectés automatiquement (disques NVMe sur EC2) ;
#                 - compte de jonction « Administrator » (images Windows AWS en anglais) ;
#                 - la clé SSH de « admin » est aussi donnée au compte AD d'administration,
#                   faute de console Hyper-V pour sa 1re connexion.
# Prérequis   : DC01 et DC02 joignables, Unbound de FW01 configuré (redirection ad.nordis.test).
# Usage       : sudo ./01_lnx01.sh      (depuis le compte admin)
# Retour      : 0 = succès, 1 = erreur
# =============================================================================
set -Eeuo pipefail

# ---------- Variables ----------
DOMAINE="ad.nordis.test"
ROYAUME="AD.NORDIS.TEST"
COMPTE_JONCTION="Administrator"             # compte AD autorisé à joindre le domaine
OU_ORDINATEUR="OU=Serveurs,OU=Ordinateurs,OU=Nordis,DC=ad,DC=nordis,DC=test"
NTP_SERVEURS="10.50.10.10 10.50.10.12"      # DC01 DC02 (chaîne FW01 -> DC -> membres)
GROUPE_SUDO_AD="gg-admins-linux"            # groupe AD GG-Admins-Linux (sssd met les noms en minuscules)
GROUPES_AUTORISES="gg-admins-linux grp_it"  # groupes AD autorisés à se connecter
COMPTE_ADMIN_AD="adm-t.peyrusaubes"         # reçoit la clé SSH de admin
ADMIN_LOCAL="${SUDO_USER:-}"                # compte local (admin sur les images Debian d'AWS)

NB_DISQUES_RAID=3
NIVEAU_RAID=5
DEVICE_RAID="/dev/md0"
VG="vg_donnees"
LV_JOURNAUX="lv_journaux";  TAILLE_JOURNAUX="4G";  MONTAGE_JOURNAUX="/srv/journaux"
LV_HOME="lv_home_ad";       TAILLE_HOME="4G";      MONTAGE_HOME="/home/AD"
LV_CACHE="lv_cache_apt";                           MONTAGE_CACHE="/var/cache/apt-cacher-ng"

PORT_SYSLOG=514
PORT_APT_CACHE=3142
DOSSIER_LOGS="/var/log/nordis"
JOURNAL="${DOSSIER_LOGS}/01_lnx01.log"

# ---------- Fonctions ----------
mkdir -p "$DOSSIER_LOGS"
log() { printf '%s [%s] %s\n' "$(date '+%F %T')" "$1" "$2" | tee -a "$JOURNAL"; }
echec() { log ERREUR "Ligne $1 : commande en échec. Journal : $JOURNAL"; exit 1; }
trap 'echec $LINENO' ERR
[[ $EUID -eq 0 ]] || { echo "Lance ce script avec sudo."; exit 1; }
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8          # évite les avertissements perl dus à la langue envoyée par le Mac

# Disques de données libres : type « disk », pas le disque système, ni partition ni signature
disques_libres() {
    local racine d
    racine="$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")"
    for d in $(lsblk -dpno NAME,TYPE | awk '$2 == "disk" {print $1}'); do
        [[ "$d" == "/dev/$racine" ]] && continue
        [[ "$(lsblk -no NAME "$d" | wc -l)" -eq 1 ]] || continue
        blkid "$d" >/dev/null 2>&1 && continue
        echo "$d"
    done
}

log INFO "===== LNX01 ($(hostname -f)) : démarrage ====="

# ---------- 1. Paquets ----------
# Dépôts Debian en http : apt-cacher-ng ne peut mettre en cache (ni relayer) que du http.
# Les paquets restent vérifiés par leur signature GPG.
# (images AWS : les adresses réelles sont dans /etc/apt/mirrors/*.list, méthode mirror+file)
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list /etc/apt/mirrors/*.list; do
    if [[ -f "$f" ]]; then sed -i 's|https://|http://|g' "$f"; fi
done
echo "krb5-config krb5-config/default_realm string ${ROYAUME}" | debconf-set-selections
apt-get update -qq
apt-get install -y -qq chrony mdadm lvm2 rsyslog apt-cacher-ng unattended-upgrades apt-listchanges \
    realmd packagekit sssd sssd-tools libnss-sss libpam-sss adcli samba-common-bin krb5-user sudo >/dev/null
# packagekit : realmd s'en sert pour vérifier les paquets (absent des images Debian d'AWS,
# qui n'installent pas les paquets recommandés)
log OK "Paquets installés"

# ---------- 2. Heure (Kerberos exige moins de 5 min d'écart) ----------
sed -i -E 's/^((pool|server) .*)/# \1/' /etc/chrony/chrony.conf
mkdir -p /etc/chrony/sources.d
: > /etc/chrony/sources.d/nordis.sources
for s in $NTP_SERVEURS; do echo "server $s iburst" >> /etc/chrony/sources.d/nordis.sources; done
systemctl restart chrony
log OK "chrony : $NTP_SERVEURS"

# ---------- 3. RAID logiciel ----------
if [[ ! -e "$DEVICE_RAID" ]]; then
    mapfile -t DISQUES < <(disques_libres)
    if [[ ${#DISQUES[@]} -ne $NB_DISQUES_RAID ]]; then
        log ERREUR "$NB_DISQUES_RAID disques libres attendus, ${#DISQUES[@]} trouvés : ${DISQUES[*]:-aucun} (voir lsblk)"
        exit 1
    fi
    mdadm --create "$DEVICE_RAID" --level="$NIVEAU_RAID" --raid-devices="$NB_DISQUES_RAID" \
          --metadata=1.2 --run "${DISQUES[@]}"
    mdadm --detail --scan | grep -F "$DEVICE_RAID" >> /etc/mdadm/mdadm.conf
    update-initramfs -u >/dev/null
    log OK "RAID $NIVEAU_RAID créé : $DEVICE_RAID (${DISQUES[*]})"
else
    log INFO "$DEVICE_RAID existe déjà"
fi

# ---------- 4. LVM + montage par UUID ----------
if ! vgs "$VG" >/dev/null 2>&1; then
    pvcreate -q "$DEVICE_RAID"
    vgcreate -q "$VG" "$DEVICE_RAID"
    lvcreate -q -y -n "$LV_JOURNAUX" -L "$TAILLE_JOURNAUX" "$VG"
    lvcreate -q -y -n "$LV_HOME" -L "$TAILLE_HOME" "$VG"
    lvcreate -q -y -n "$LV_CACHE" -l 100%FREE "$VG"
    mkfs.ext4 -q -L journaux "/dev/$VG/$LV_JOURNAUX"
    mkfs.ext4 -q -L home_ad "/dev/$VG/$LV_HOME"
    mkfs.ext4 -q -L cache_apt "/dev/$VG/$LV_CACHE"
    log OK "LVM : $VG / $LV_JOURNAUX ($TAILLE_JOURNAUX) + $LV_HOME ($TAILLE_HOME) + $LV_CACHE (reste)"
fi

systemctl stop apt-cacher-ng
for paire in "$LV_JOURNAUX:$MONTAGE_JOURNAUX" "$LV_HOME:$MONTAGE_HOME" "$LV_CACHE:$MONTAGE_CACHE"; do
    lv="${paire%%:*}"; point="${paire#*:}"
    uuid="$(blkid -s UUID -o value "/dev/$VG/$lv")"
    mkdir -p "$point"
    if ! grep -q "$uuid" /etc/fstab; then
        echo "UUID=$uuid  $point  ext4  defaults,nofail  0  2" >> /etc/fstab
    fi
done
systemctl daemon-reload
mount -a
chown -R apt-cacher-ng:apt-cacher-ng "$MONTAGE_CACHE"
chmod 755 "$MONTAGE_HOME"
log OK "Montages par UUID : $MONTAGE_JOURNAUX, $MONTAGE_HOME, $MONTAGE_CACHE"

# ---------- 5. rsyslog central ----------
cat > /etc/rsyslog.d/10-nordis-serveur.conf <<EOF
# Généré par 01_lnx01.sh : réception des journaux de toutes les machines
module(load="imudp")
input(type="imudp" port="${PORT_SYSLOG}")
module(load="imtcp")
input(type="imtcp" port="${PORT_SYSLOG}")

template(name="ParHote" type="string" string="${MONTAGE_JOURNAUX}/%HOSTNAME%/%PROGRAMNAME%.log")

if \$fromhost-ip != '127.0.0.1' then {
    action(type="omfile" dynaFile="ParHote" createDirs="on")
    stop
}
EOF
cat > /etc/logrotate.d/nordis-journaux <<EOF
${MONTAGE_JOURNAUX}/*/*.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
EOF
rsyslogd -N1 >/dev/null 2>&1
systemctl enable rsyslog >/dev/null 2>&1
systemctl restart rsyslog
log OK "rsyslog central en écoute sur $PORT_SYSLOG (UDP/TCP) -> $MONTAGE_JOURNAUX/<hôte>/"

# ---------- 6. Cache APT ----------
systemctl enable --now apt-cacher-ng >/dev/null
echo "Acquire::http::Proxy \"http://127.0.0.1:${PORT_APT_CACHE}\";" > /etc/apt/apt.conf.d/01proxy
log OK "apt-cacher-ng actif (port $PORT_APT_CACHE), LNX01 l'utilise aussi"

# ---------- 7. Mises à jour de sécurité ----------
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
log OK "unattended-upgrades actif (dépôt ${VERSION_CODENAME}-security)"

# ---------- 8. Intégration à l'Active Directory ----------
# Les paquets sont installés à l'étape 1 : realmd n'a pas à les vérifier lui-même
printf '[service]\nassume-packages = yes\n' > /etc/realmd.conf
if ! realm list | grep -q "$DOMAINE"; then
    log INFO "Jonction à $DOMAINE : colle le mot de passe de $COMPTE_JONCTION (celui de DC01)"
    realm join --user="$COMPTE_JONCTION" --computer-ou="$OU_ORDINATEUR" "$DOMAINE"
fi
sed -i 's/^use_fully_qualified_names.*/use_fully_qualified_names = False/' /etc/sssd/sssd.conf
sed -i "s|^fallback_homedir.*|fallback_homedir = ${MONTAGE_HOME}/%u|" /etc/sssd/sssd.conf
systemctl restart sssd
# shellcheck disable=SC2086
realm permit -g $GROUPES_AUTORISES
pam-auth-update --enable mkhomedir >/dev/null
log OK "Joint à $DOMAINE (connexion autorisée : $GROUPES_AUTORISES)"

# ---------- 9. sudo réservé à des groupes ----------
cat > /etc/sudoers.d/10-nordis <<EOF
# Généré par 01_lnx01.sh : seuls ces groupes ont sudo
%sudo ALL=(ALL:ALL) ALL
%${GROUPE_SUDO_AD} ALL=(ALL:ALL) ALL
EOF
chmod 440 /etc/sudoers.d/10-nordis
visudo -cf /etc/sudoers.d/10-nordis >/dev/null
log OK "sudo : groupes sudo (local) et $GROUPE_SUDO_AD (AD)"

# ---------- 10. Clé SSH du compte AD d'administration ----------
if [[ -n "$ADMIN_LOCAL" ]] && [[ -s "/home/$ADMIN_LOCAL/.ssh/authorized_keys" ]] && id "$COMPTE_ADMIN_AD" >/dev/null 2>&1; then
    dossier="${MONTAGE_HOME}/${COMPTE_ADMIN_AD}"
    install -d -m 700 -o "$COMPTE_ADMIN_AD" -g "$(id -gn "$COMPTE_ADMIN_AD")" "$dossier" "$dossier/.ssh"
    install -m 600 -o "$COMPTE_ADMIN_AD" -g "$(id -gn "$COMPTE_ADMIN_AD")" \
            "/home/$ADMIN_LOCAL/.ssh/authorized_keys" "$dossier/.ssh/authorized_keys"
    log OK "Clé SSH installée pour $COMPTE_ADMIN_AD ($dossier)"
else
    log WARN "Clé SSH non installée pour $COMPTE_ADMIN_AD (compte AD introuvable ou pas de clé chez ${ADMIN_LOCAL:-?})"
fi

# ---------- 11. SSH par clé ----------
cle_presente=0
if [[ -n "$ADMIN_LOCAL" ]] && [[ -s "/home/$ADMIN_LOCAL/.ssh/authorized_keys" ]]; then cle_presente=1; fi
cat > /etc/ssh/sshd_config.d/10-nordis.conf <<EOF
# Généré par 01_lnx01.sh
PermitRootLogin no
PubkeyAuthentication yes
EOF
# Connexion SSH limitée aux groupes d'administration (si le compte local est bien dans « sudo »)
if [[ -n "$ADMIN_LOCAL" ]] && id -nG "$ADMIN_LOCAL" | grep -qw sudo; then
    echo "AllowGroups sudo ${GROUPES_AUTORISES}" >> /etc/ssh/sshd_config.d/10-nordis.conf
    log OK "SSH : AllowGroups sudo ${GROUPES_AUTORISES}"
else
    log WARN "SSH : ${ADMIN_LOCAL:-?} n'est pas dans le groupe sudo -> AllowGroups non appliqué (pour ne pas te bloquer)"
fi
if [[ $cle_presente -eq 1 ]]; then
    printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' >> /etc/ssh/sshd_config.d/10-nordis.conf
    log OK "SSH : clé uniquement (mot de passe désactivé)"
else
    log WARN "SSH : aucune clé dans /home/${ADMIN_LOCAL:-?}/.ssh/authorized_keys -> mot de passe laissé actif."
fi
sshd -t
systemctl restart ssh

log OK "===== LNX01 prêt ====="
log INFO "Tests : cat /proc/mdstat | lsblk -f | chronyc sources | realm list | id ${COMPTE_ADMIN_AD} | ss -lntu | grep -E '514|3142'"
exit 0
