#!/bin/bash
# =============================================================================
# Nom         : nordis-tunnel.sh
# Auteur      : Thomas Peyrusaubes
# Date        : 2026-11-09
# Version     : 1.0
# Projet      : Nordis Distribution - outil commun aux TP 1 et 2
# Description : Accès d'administration à Nordis depuis le poste de l'administrateur.
#               Un seul processus remplace les deux terminaux de tunnel :
#                 - EC2 Instance Connect Endpoint → SSH de FW01 (ProxyCommand)
#                 - redirections de ports vers l'interface web de FW01, le RDP des
#                   serveurs Windows et le SSH des serveurs Linux
#               Reconnexion automatique toutes les 5 s en cas de coupure (coupure
#               réseau, plantage de la CLI AWS, tunnel arrivé à sa durée maximale).
# Prérequis   : AWS CLI configurée, clé ~/.ssh/nordis.pem, instances démarrées
# Usage       : outils/nordis-tunnel.sh        (Ctrl+C pour arrêter)
#               puis : https://localhost:8443 · ssh -i ~/.ssh/nordis.pem -p 2201 admin@127.0.0.1
# Retour      : 1 = endpoint introuvable ; sinon tourne jusqu'à Ctrl+C
# =============================================================================
set -u

REGION="eu-west-3"
CLE_SSH="$HOME/.ssh/nordis.pem"
FW01_LAN="10.50.0.20"
DUREE_MAX=3600   # imposé par la politique IAM : sans cette option, OpenTunnel est refusé

export AWS_PAGER=""

EICE=$(aws ec2 describe-instance-connect-endpoints --region "$REGION" \
    --filters "Name=tag:Name,Values=eice-nordis" \
    --query 'InstanceConnectEndpoints[0].InstanceConnectEndpointId' --output text)
if [ -z "$EICE" ] || [ "$EICE" = "None" ]; then
    echo "[ERREUR] EC2 Instance Connect Endpoint « eice-nordis » introuvable (réseau, droits AWS ?)" >&2
    exit 1
fi

echo "[INFO]   endpoint $EICE"
echo "[INFO]   FW01 web  : https://localhost:8443          FW01 SSH : ssh -i $CLE_SSH -p 2222 root@127.0.0.1"
echo "[INFO]   RDP       : DC01 13389 · CLI01 23389 · DC02 33389 · SRV02 43389"
echo "[INFO]   SSH Linux : LNX01 -p 2201 · LNX02 -p 2202 (admin@127.0.0.1)"

while true; do
    echo "$(date +%H:%M:%S) connexion..."
    ssh -i "$CLE_SSH" -N \
        -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=2 \
        -o ExitOnForwardFailure=yes \
        -o ProxyCommand="aws ec2-instance-connect open-tunnel --region $REGION --instance-connect-endpoint-id $EICE --private-ip-address $FW01_LAN --remote-port 22 --max-tunnel-duration $DUREE_MAX" \
        -L 2222:"$FW01_LAN":22 -L 8443:127.0.0.1:443 \
        -L 13389:10.50.10.10:3389 -L 23389:10.50.99.10:3389 \
        -L 33389:10.50.10.12:3389 -L 43389:10.50.10.11:3389 \
        -L 2201:10.50.10.20:22 -L 2202:10.50.20.21:22 \
        root@"$FW01_LAN"
    echo "$(date +%H:%M:%S) coupé, nouvelle tentative dans 5 s"
    sleep 5
done
