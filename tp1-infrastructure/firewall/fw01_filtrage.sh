#!/bin/sh
# =============================================================================
# Nom         : fw01_filtrage.sh
# Auteur      : Thomas Peyrusaubes
# Date        : 2026-10-22
# Version     : 1.0
# Projet      : Nordis Distribution - Module A2627_5066
# Description : Filtrage entre sous-réseaux sur FW01 (OPNsense), selon le DAT.
#               Sur AWS, tous les sous-réseaux arrivent sur l'interface LAN de FW01 :
#               les règles sont donc posées sur LAN et distinguées par réseau source.
#                 - Management (10.50.99.0/24) et Serveurs (10.50.10.0/24) : tout
#                 - Postes (10.50.30/40/50.0/24) : FW01 DNS/NTP, DC (ports AD),
#                   SRV02 (SMB 445, WSUS 8530), LNX02 (80), Internet hors RFC 1918 (80, 443)
#                 - DMZ (10.50.20.0/24) : LNX01 (cache APT 3142, syslog 514), FW01 DNS/NTP,
#                   Internet hors RFC 1918 (80, 443)
#                 - tout le reste : bloqué et journalisé
#               L'ancienne règle « 10.50.0.0/16 vers partout » est désactivée.
# Sécurité    : retour automatique à la configuration précédente au bout de 3 min,
#               sauf confirmation : touch /tmp/filtrage_ok
# Usage       : depuis le Mac (tunnel actif sur le port 2222) :
#               ssh -i ~/.ssh/nordis.pem -p 2222 root@127.0.0.1 'sh -s' < fw01_filtrage.sh
# Retour      : 0 = règles appliquées (à confirmer), 1 = erreur, rien n'a été modifié
# =============================================================================
set -eu

DELAI_RETOUR=180
SAUVEGARDE=/conf/config.xml.avant-filtrage
SCRIPT_PHP=/tmp/nordis_filtrage.php

erreur() { echo "[ERREUR] $*" >&2; exit 1; }
info()   { echo "[INFO]   $*"; }

[ "$(id -u)" = "0" ] || erreur "à lancer en root"
[ -f /usr/local/opnsense/mvc/script/load_phalcon.php ] || erreur "OPNsense introuvable"

cp /conf/config.xml "$SAUVEGARDE"
rm -f /tmp/filtrage_ok
info "configuration sauvegardée dans $SAUVEGARDE"

cat > "$SCRIPT_PHP" <<'EOF'
<?php
require_once('/usr/local/opnsense/mvc/script/load_phalcon.php');

use OPNsense\Core\Config;
use OPNsense\Firewall\Alias;
use OPNsense\Firewall\Filter;

function echec($msg) { fwrite(STDERR, "[ERREUR] $msg\n"); exit(1); }

function verifier($modele, $quoi) {
    $msgs = $modele->performValidation();
    if (count($msgs) > 0) {
        foreach ($msgs as $m) { fwrite(STDERR, "  $quoi : " . $m->getField() . ' : ' . $m->getMessage() . "\n"); }
        echec("validation refusée ($quoi)");
    }
}

// ---------- 1. Alias ----------
$aliases = [
    ['NORDIS_RFC1918', 'network', "10.0.0.0/8\n172.16.0.0/12\n192.168.0.0/16", 'Réseaux privés RFC 1918'],
    ['NORDIS_DC',      'host',    "10.50.10.10\n10.50.10.12",                  'Contrôleurs de domaine DC01 DC02'],
    ['NORDIS_POSTES',  'network', "10.50.30.0/24\n10.50.40.0/24\n10.50.50.0/24", 'Postes (ex-VLAN 30 40 50)'],
    ['PORTS_AD',       'port',    "53\n88\n123\n135\n389\n445\n464\n636\n3268\n3269\n9389\n49152:65535", 'Ports Active Directory'],
    ['PORTS_SRV02',    'port',    "445\n8530",                                 'SMB et WSUS sur SRV02'],
    ['PORTS_WEB',      'port',    "80\n443",                                   'HTTP et HTTPS'],
];
$mdlAlias = new Alias();
$existants = [];
foreach ($mdlAlias->aliases->alias->iterateItems() as $a) { $existants[] = (string)$a->name; }
foreach ($aliases as [$nom, $type, $contenu, $desc]) {
    if (in_array($nom, $existants)) { echo "[INFO]   alias $nom déjà présent\n"; continue; }
    $n = $mdlAlias->aliases->alias->Add();
    $n->setNodes(['enabled' => '1', 'name' => $nom, 'type' => $type, 'content' => $contenu, 'description' => $desc]);
    echo "[OK]     alias $nom\n";
}
verifier($mdlAlias, 'alias');
$mdlAlias->serializeToConfig();
Config::getInstance()->save();

// ---------- 2. Règles ----------
// séquence, description, source, destination, destination inversée, protocole, port, action, journal
$regles = [
    [10, 'Nordis : Management vers tout',          '10.50.99.0/24', 'any',            0, 'any',     '',            'pass',  0],
    [11, 'Nordis : Serveurs vers tout',            '10.50.10.0/24', 'any',            0, 'any',     '',            'pass',  0],
    [20, 'Nordis : Postes vers FW01 DNS',          'NORDIS_POSTES', '(self)',         0, 'TCP/UDP', '53',          'pass',  0],
    [21, 'Nordis : Postes vers FW01 NTP',          'NORDIS_POSTES', '(self)',         0, 'UDP',     '123',         'pass',  0],
    [22, 'Nordis : Postes vers DC (ports AD)',     'NORDIS_POSTES', 'NORDIS_DC',      0, 'TCP/UDP', 'PORTS_AD',    'pass',  0],
    [23, 'Nordis : Postes vers SRV02 SMB WSUS',    'NORDIS_POSTES', '10.50.10.11',    0, 'TCP',     'PORTS_SRV02', 'pass',  0],
    [24, 'Nordis : Postes vers LNX02 intranet',    'NORDIS_POSTES', '10.50.20.21',    0, 'TCP',     '80',          'pass',  0],
    [25, 'Nordis : Postes vers Internet web',      'NORDIS_POSTES', 'NORDIS_RFC1918', 1, 'TCP',     'PORTS_WEB',   'pass',  0],
    [30, 'Nordis : DMZ vers LNX01 cache APT',      '10.50.20.0/24', '10.50.10.20',    0, 'TCP',     '3142',        'pass',  0],
    [31, 'Nordis : DMZ vers LNX01 syslog',         '10.50.20.0/24', '10.50.10.20',    0, 'TCP/UDP', '514',         'pass',  0],
    [32, 'Nordis : DMZ vers FW01 DNS',             '10.50.20.0/24', '(self)',         0, 'TCP/UDP', '53',          'pass',  0],
    [33, 'Nordis : DMZ vers FW01 NTP',             '10.50.20.0/24', '(self)',         0, 'UDP',     '123',         'pass',  0],
    [34, 'Nordis : DMZ vers Internet web',         '10.50.20.0/24', 'NORDIS_RFC1918', 1, 'TCP',     'PORTS_WEB',   'pass',  0],
    [90, 'Nordis : bloquer et journaliser le reste', 'any',         'any',            0, 'any',     '',            'block', 1],
];
$mdlFiltre = new Filter();
$descriptions = [];
foreach ($mdlFiltre->rules->rule->iterateItems() as $r) {
    $d = (string)$r->description;
    $descriptions[] = $d;
    if ($d === 'Nordis : sous-reseaux du VPC vers partout' && (string)$r->enabled === '1') {
        $r->enabled = '0';
        echo "[OK]     ancienne règle « 10.50.0.0/16 vers partout » désactivée\n";
    }
}
foreach ($regles as [$seq, $desc, $src, $dst, $dstNot, $proto, $port, $action, $log]) {
    if (in_array($desc, $descriptions)) { echo "[INFO]   règle déjà présente : $desc\n"; continue; }
    $n = $mdlFiltre->rules->rule->Add();
    $n->setNodes([
        'enabled' => '1', 'sequence' => (string)$seq, 'action' => $action, 'quick' => '1',
        'interface' => 'lan', 'direction' => 'in', 'ipprotocol' => 'inet', 'protocol' => $proto,
        'source_net' => $src, 'destination_net' => $dst, 'destination_not' => (string)$dstNot,
        'destination_port' => $port, 'log' => (string)$log, 'description' => $desc,
    ]);
    echo "[OK]     règle $seq : $desc\n";
}
verifier($mdlFiltre, 'règles');
$mdlFiltre->serializeToConfig();
Config::getInstance()->save();
echo "[OK]     configuration enregistrée\n";
EOF

info "écriture des alias et des règles..."
if ! /usr/local/bin/php "$SCRIPT_PHP"; then
    cp "$SAUVEGARDE" /conf/config.xml
    rm -f "$SCRIPT_PHP"
    erreur "écriture refusée : configuration d'origine remise en place, rien n'est appliqué"
fi
rm -f "$SCRIPT_PHP"

# Retour automatique si la nouvelle configuration n'est pas confirmée
daemon -f /bin/sh -c "sleep $DELAI_RETOUR; if [ ! -f /tmp/filtrage_ok ]; then cp $SAUVEGARDE /conf/config.xml; configctl filter refresh_aliases; configctl filter reload; logger -t nordis 'filtrage non confirmé : retour à la configuration précédente'; fi"

info "application des alias et des règles..."
configctl filter refresh_aliases >/dev/null
configctl filter reload >/dev/null
info "règles actives : $(pfctl -sr 2>/dev/null | grep -c 'label')"
echo "[OK]     filtrage appliqué. Teste, puis confirme dans les $DELAI_RETOUR s :"
echo "         ssh -i ~/.ssh/nordis.pem -p 2222 root@127.0.0.1 touch /tmp/filtrage_ok"
echo "         Sans confirmation, FW01 revient tout seul à la configuration précédente."
exit 0
