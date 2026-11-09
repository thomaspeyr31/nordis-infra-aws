#!/bin/sh
# =============================================================================
# Nom         : fw01_bootstrap.sh
# Auteur      : Thomas Peyrusaubes
# Date        : 2026-10-21
# Version     : 1.0
# Projet      : Nordis Distribution - Module A2627_5066
# Description : Transforme l'instance FreeBSD 15 de FW01 en OPNsense 26.7.
#               AVANT la conversion, écrit une configuration OPNsense adaptée
#               à AWS pour ne pas perdre l'accès au redémarrage :
#                 - WAN = interface qui porte 10.50.0.4 (DHCP AWS)
#                 - LAN = interface qui porte 10.50.0.20 (/28, fixe)
#                 - interface web et SSH ouverts sur le WAN pour TON IP seulement
#                 - SSH root par clé (la même que ec2-user : nordis.pem)
# Usage       : su                      (passer root, pas de mot de passe)
#               sh fw01_bootstrap.sh <ton IP publique>
#   ex.       : sh fw01_bootstrap.sh 203.0.113.10
# Retour      : 0 = conversion lancée (l'instance redémarre toute seule)
#               1 = erreur, rien n'a été modifié
# =============================================================================
set -eu

IP_ADMIN="${1:-}"
IP_WAN="10.50.0.4"
IP_LAN="10.50.0.20"
MASQUE_LAN="28"
VERSION_OPN="26.7"
URL_BOOTSTRAP="https://raw.githubusercontent.com/opnsense/update/master/src/bootstrap/opnsense-bootstrap.sh.in"

erreur() { echo "[ERREUR] $*" >&2; exit 1; }
info()   { echo "[INFO]   $*"; }

# ---------- Vérifications (rien n'est modifié avant la fin de ce bloc) ----------
[ "$(id -u)" = "0" ] || erreur "lance ce script en root : tape 'su' puis relance-le."
[ -n "$IP_ADMIN" ]   || erreur "usage : sh $0 <ton IP publique>  (ex. 203.0.113.10)"
echo "$IP_ADMIN" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || erreur "IP invalide : $IP_ADMIN"
case "$(uname -r)" in 15.*) ;; *) erreur "FreeBSD 15 attendu (trouvé : $(uname -r))." ;; esac

# Interface qui porte une IP donnée
if_de_ip() {
    for i in $(ifconfig -l); do
        if ifconfig "$i" inet 2>/dev/null | grep -q "inet $1 "; then echo "$i"; return 0; fi
    done
    return 0
}

IF_WAN=$(if_de_ip "$IP_WAN")
[ -n "$IF_WAN" ] || erreur "aucune interface ne porte $IP_WAN : vérifie l'ENI WAN de FW01."
IF_LAN=$(if_de_ip "$IP_LAN")
if [ -z "$IF_LAN" ]; then
    # L'interface LAN n'a pas toujours reçu d'IP : on prend l'autre carte ena
    for i in $(ifconfig -l); do
        case "$i" in ena*) [ "$i" != "$IF_WAN" ] && IF_LAN="$i" && break ;; esac
    done
fi
[ -n "$IF_LAN" ] || erreur "interface LAN introuvable : l'ENI LAN est-elle bien attachée ?"
info "WAN = $IF_WAN ($IP_WAN, DHCP)   LAN = $IF_LAN ($IP_LAN/$MASQUE_LAN)"

CLES="/home/ec2-user/.ssh/authorized_keys"
[ -s "$CLES" ] || erreur "clé SSH introuvable dans $CLES"
CLE_B64=$(head -n 1 "$CLES" | openssl base64 -A)
info "clé SSH reprise de ec2-user : $(head -n 1 "$CLES" | cut -c1-40)..."

# ---------- Configuration OPNsense pré-écrite ----------
mkdir -p /conf
[ -f /conf/config.xml ] && cp /conf/config.xml /conf/config.xml.avant-nordis

cat > /conf/config.xml.modele <<'EOF'
<?xml version="1.0"?>
<opnsense>
  <theme>opnsense</theme>
  <system>
    <optimization>normal</optimization>
    <hostname>fw01</hostname>
    <domain>ad.nordis.test</domain>
    <dnsallowoverride>1</dnsallowoverride>
    <dnsallowoverride_exclude/>
    <group>
      <name>admins</name>
      <description>System Administrators</description>
      <scope>system</scope>
      <gid>1999</gid>
      <member>0</member>
      <priv>page-all</priv>
    </group>
    <user>
      <name>root</name>
      <descr>System Administrator</descr>
      <scope>system</scope>
      <groupname>admins</groupname>
      <password>$2y$10$YRVoF4SgskIsrXOvOQjGieB9XqHPRra9R7d80B3BZdbY/j21TwBfS</password>
      <uid>0</uid>
      <authorizedkeys>@@CLE_B64@@</authorizedkeys>
    </user>
    <timezone>Europe/Paris</timezone>
    <timeservers>0.opnsense.pool.ntp.org 1.opnsense.pool.ntp.org 2.opnsense.pool.ntp.org 3.opnsense.pool.ntp.org</timeservers>
    <webgui>
      <protocol>https</protocol>
      <noroot>1</noroot>
      <nohttpreferercheck>1</nohttpreferercheck>
      <nodnsrebindcheck>1</nodnsrebindcheck>
    </webgui>
    <disablenatreflection>yes</disablenatreflection>
    <usevirtualterminal>1</usevirtualterminal>
    <disableconsolemenu/>
    <powerd_ac_mode>hadp</powerd_ac_mode>
    <powerd_battery_mode>hadp</powerd_battery_mode>
    <powerd_normal_mode>hadp</powerd_normal_mode>
    <bogons>
      <interval>monthly</interval>
    </bogons>
    <pf_share_forward>1</pf_share_forward>
    <lb_use_sticky>1</lb_use_sticky>
    <ssh>
      <group>admins</group>
      <enabled>enabled</enabled>
      <permitrootlogin>1</permitrootlogin>
    </ssh>
  </system>
  <interfaces>
    <wan>
      <enable>1</enable>
      <if>@@IF_WAN@@</if>
      <descr>WAN</descr>
      <spoofmac/>
      <ipaddr>dhcp</ipaddr>
      <blockbogons>1</blockbogons>
      <dhcphostname/>
    </wan>
    <lan>
      <enable>1</enable>
      <if>@@IF_LAN@@</if>
      <descr>LAN</descr>
      <spoofmac/>
      <ipaddr>@@IP_LAN@@</ipaddr>
      <subnet>@@MASQUE_LAN@@</subnet>
    </lan>
  </interfaces>
  <unbound>
    <enable>1</enable>
  </unbound>
  <nat>
    <outbound>
      <mode>automatic</mode>
    </outbound>
  </nat>
  <filter>
  </filter>
  <rrd>
    <enable/>
  </rrd>
  <ntpd>
    <prefer>0.opnsense.pool.ntp.org</prefer>
    <ispool>0.opnsense.pool.ntp.org 1.opnsense.pool.ntp.org 2.opnsense.pool.ntp.org 3.opnsense.pool.ntp.org</ispool>
  </ntpd>
  <OPNsense>
    <Firewall>
      <Filter>
        <rules>
          <rule>
            <enabled>1</enabled>
            <statetype>keep</statetype>
            <state-policy/>
            <sequence>1</sequence>
            <action>pass</action>
            <quick>1</quick>
            <interfacenot>0</interfacenot>
            <interface>lan</interface>
            <direction>in</direction>
            <ipprotocol>inet</ipprotocol>
            <protocol>any</protocol>
            <source_net>10.50.0.0/16</source_net>
            <source_not>0</source_not>
            <source_port/>
            <destination_net>any</destination_net>
            <destination_not>0</destination_not>
            <disablereplyto>0</disablereplyto>
            <log>0</log>
            <allowopts>0</allowopts>
            <nosync>0</nosync>
            <nopfsync>0</nopfsync>
            <statetimeout/>
            <tcpflags_any>0</tcpflags_any>
            <description>Nordis : sous-reseaux du VPC vers partout</description>
          </rule>
          <rule>
            <enabled>1</enabled>
            <statetype>keep</statetype>
            <state-policy/>
            <sequence>100</sequence>
            <action>pass</action>
            <quick>1</quick>
            <interfacenot>0</interfacenot>
            <interface>wan</interface>
            <direction>in</direction>
            <ipprotocol>inet</ipprotocol>
            <protocol>TCP</protocol>
            <source_net>@@IP_ADMIN@@/32</source_net>
            <source_not>0</source_not>
            <source_port/>
            <destination_net>(self)</destination_net>
            <destination_not>0</destination_not>
            <destination_port>443</destination_port>
            <disablereplyto>0</disablereplyto>
            <log>1</log>
            <allowopts>0</allowopts>
            <nosync>0</nosync>
            <nopfsync>0</nopfsync>
            <statetimeout/>
            <tcpflags_any>0</tcpflags_any>
            <description>Nordis : interface web depuis mon IP</description>
          </rule>
          <rule>
            <enabled>1</enabled>
            <statetype>keep</statetype>
            <state-policy/>
            <sequence>101</sequence>
            <action>pass</action>
            <quick>1</quick>
            <interfacenot>0</interfacenot>
            <interface>wan</interface>
            <direction>in</direction>
            <ipprotocol>inet</ipprotocol>
            <protocol>TCP</protocol>
            <source_net>@@IP_ADMIN@@/32</source_net>
            <source_not>0</source_not>
            <source_port/>
            <destination_net>(self)</destination_net>
            <destination_not>0</destination_not>
            <destination_port>22</destination_port>
            <disablereplyto>0</disablereplyto>
            <log>1</log>
            <allowopts>0</allowopts>
            <nosync>0</nosync>
            <nopfsync>0</nopfsync>
            <statetimeout/>
            <tcpflags_any>0</tcpflags_any>
            <description>Nordis : SSH depuis mon IP</description>
          </rule>
        </rules>
        <snatrules/>
        <npt/>
        <onetoone/>
      </Filter>
    </Firewall>
  </OPNsense>
</opnsense>
EOF

sed -e "s|@@CLE_B64@@|${CLE_B64}|" \
    -e "s|@@IF_WAN@@|${IF_WAN}|" \
    -e "s|@@IF_LAN@@|${IF_LAN}|" \
    -e "s|@@IP_LAN@@|${IP_LAN}|" \
    -e "s|@@MASQUE_LAN@@|${MASQUE_LAN}|" \
    -e "s|@@IP_ADMIN@@|${IP_ADMIN}|g" \
    /conf/config.xml.modele > /conf/config.xml
rm -f /conf/config.xml.modele
grep -q "@@" /conf/config.xml && erreur "substitution incomplète dans /conf/config.xml"
cp /conf/config.xml /root/config.xml.nordis
info "configuration OPNsense écrite dans /conf/config.xml (copie : /root/config.xml.nordis)"

# Réglages de démarrage propres à EC2 (pilote réseau ena, disques NVMe) :
# OPNsense réécrit loader.conf mais conserve loader.conf.local.
cp /boot/loader.conf /boot/loader.conf.local
info "réglages EC2 conservés dans /boot/loader.conf.local"

# ---------- Conversion en OPNsense ----------
# Le jeu d'options DHCP donne FW01 lui-même (10.50.0.20) comme DNS : tant
# qu'OPNsense n'est pas installé, on utilise le DNS d'AWS.
echo "nameserver 169.254.169.253" > /etc/resolv.conf
info "téléchargement de opnsense-bootstrap..."
fetch -o /tmp/opnsense-bootstrap.sh.in "$URL_BOOTSTRAP"
info "conversion en OPNsense $VERSION_OPN : 10 à 20 minutes, puis redémarrage automatique."
info "Ta session SSH va se couper : c'est normal."
sh /tmp/opnsense-bootstrap.sh.in -r "$VERSION_OPN" -y
