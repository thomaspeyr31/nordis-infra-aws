#!/bin/sh
# =============================================================================
# Nom         : fw01_dns.sh
# Auteur      : Thomas Peyrusaubes
# Date        : 2026-11-09
# Version     : 1.0
# Projet      : Nordis Distribution - TP DNS maîtrisé
# Description : Règles anti-contournement DNS sur FW01 (OPNsense), interface LAN.
#               Posées AVANT les règles du TP 1 (10 et 11 autorisent « tout » pour
#               Management et Serveurs) : OPNsense applique la première règle qui correspond.
#                 1  DNS (53) vers Unbound sur FW01            : autorisé
#                 2  DNS (53) vers l'extérieur de 10.50.0.0/16  : bloqué, journalisé
#                 3  DoT (853) vers l'extérieur                 : bloqué, journalisé
#                 4  HTTPS (443) vers les résolveurs DoH publics : bloqué, journalisé
#               Alias créé : DoH_publics (1.1.1.1, 1.0.0.1, 8.8.8.8, 8.8.4.4).
#               Idempotent : un alias ou une règle déjà présents (même nom, même
#               description) sont ignorés. Pendant le TP, ces règles ont été créées dans
#               l'interface web ; ce script permet de les reproduire à l'identique.
#               La configuration d'Unbound (DoT, DNSSEC, blocklists) se fait dans
#               l'interface web : voir tp2-dns-securise/README.md, partie 2.
# Prérequis   : TP 1 en place (fw01_filtrage.sh appliqué)
# Sécurité    : retour automatique à la configuration précédente au bout de 3 min,
#               sauf confirmation : touch /tmp/dns_ok
# Usage       : depuis le poste d'administration (outils/nordis-tunnel.sh lancé) :
#               ssh -i ~/.ssh/nordis.pem -p 2222 root@127.0.0.1 'sh -s' < fw01_dns.sh
# Retour      : 0 = règles appliquées (à confirmer), 1 = erreur, rien n'a été modifié
# =============================================================================
set -eu

DELAI_RETOUR=180
SAUVEGARDE=/conf/config.xml.avant-dns
SCRIPT_PHP=/tmp/nordis_dns.php

erreur() { echo "[ERREUR] $*" >&2; exit 1; }
info()   { echo "[INFO]   $*"; }

[ "$(id -u)" = "0" ] || erreur "à lancer en root"
[ -f /usr/local/opnsense/mvc/script/load_phalcon.php ] || erreur "OPNsense introuvable"

cp /conf/config.xml "$SAUVEGARDE"
rm -f /tmp/dns_ok
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
    ['DoH_publics', 'host', "1.1.1.1\n1.0.0.1\n8.8.8.8\n8.8.4.4", 'Résolveurs DoH publics'],
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
    [1, 'Nordis : DNS vers Unbound',    '10.50.0.0/16', '(self)',       0, 'TCP/UDP', '53',  'pass',  0],
    [2, 'Nordis : DNS direct interdit', '10.50.0.0/16', '10.50.0.0/16', 1, 'TCP/UDP', '53',  'block', 1],
    [3, 'Nordis : DoT direct interdit', '10.50.0.0/16', '10.50.0.0/16', 1, 'TCP/UDP', '853', 'block', 1],
    [4, 'Nordis : DoH par IP interdit', '10.50.0.0/16', 'DoH_publics',  0, 'TCP/UDP', '443', 'block', 1],
];
$mdlFiltre = new Filter();
$descriptions = [];
foreach ($mdlFiltre->rules->rule->iterateItems() as $r) { $descriptions[] = (string)$r->description; }
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

info "écriture de l'alias et des règles..."
if ! /usr/local/bin/php "$SCRIPT_PHP"; then
    cp "$SAUVEGARDE" /conf/config.xml
    rm -f "$SCRIPT_PHP"
    erreur "écriture refusée : configuration d'origine remise en place, rien n'est appliqué"
fi
rm -f "$SCRIPT_PHP"

# Retour automatique si la nouvelle configuration n'est pas confirmée
daemon -f /bin/sh -c "sleep $DELAI_RETOUR; if [ ! -f /tmp/dns_ok ]; then cp $SAUVEGARDE /conf/config.xml; configctl filter refresh_aliases; configctl filter reload; logger -t nordis 'règles DNS non confirmées : retour à la configuration précédente'; fi"

info "application..."
configctl filter refresh_aliases >/dev/null
configctl filter reload >/dev/null
echo "[OK]     règles DNS appliquées. Teste depuis LNX01 (dig @8.8.8.8 doit échouer), puis confirme dans les $DELAI_RETOUR s :"
echo "         ssh -i ~/.ssh/nordis.pem -p 2222 root@127.0.0.1 touch /tmp/dns_ok"
echo "         Sans confirmation, FW01 revient tout seul à la configuration précédente."
exit 0
