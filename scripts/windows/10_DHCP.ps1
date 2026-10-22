<#
.SYNOPSIS
    DHCP Windows sur DC01 et DC02 : étendues des postes et basculement (équilibrage 50/50).

.DESCRIPTION
    Version AWS : démonstration de la compétence du sujet (DHCP + failover entre les 2 DC).
    Sur AWS, les adresses sont distribuées par le VPC (et réservées par Terraform) : les étendues
    sont configurées et répliquées, mais aucun poste ne les utilise (pas de relais DHCP possible
    vers ces sous-réseaux). L'écart est justifié dans le DAT.
      1. Rôle DHCP sur DC01 et DC02 (DC02 à distance), groupes de sécurité DHCP.
      2. Autorisation des 2 serveurs dans l'Active Directory.
      3. Étendues du DAT (postes admin, commercial, logistique), bail 8 jours,
         options : passerelle .1 (routeur du VPC), DNS FW01, domaine ad.nordis.test.
      4. Relation de basculement DC01-DC02 en équilibrage de charge 50/50.
    Code de retour : 0 = succès, 1 = au moins une erreur.

.NOTES
    Auteur  : Thomas Peyrusaubes
    Date    : 2026-10-22
    Version : 1.2-aws
    Projet  : Nordis Distribution - Module A2627_5066
    Exécution : DC01, en NORDIS\Administrator.

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force ; C:\Scripts\10_DHCP.ps1
#>
[CmdletBinding()]
param()

#region ---------- Variables ----------
$Domaine        = 'ad.nordis.test'
$Serveurs       = [ordered]@{ 'dc01.ad.nordis.test' = '10.50.10.10'; 'dc02.ad.nordis.test' = '10.50.10.12' }
$Principal      = 'dc01.ad.nordis.test'
$Partenaire     = 'dc02.ad.nordis.test'
$ServeurDNS     = '10.50.0.20'                     # FW01 (Unbound)
$DureeBail      = New-TimeSpan -Days 8
$NomFailover    = 'DC01-DC02'
$RepartitionPct = 50
$Etendues = @(
    @{ Nom = 'Postes-Administration'; Reseau = '10.50.30.0'; Debut = '10.50.30.100'; Fin = '10.50.30.200'; Passerelle = '10.50.30.1' }
    @{ Nom = 'Postes-Commercial';     Reseau = '10.50.40.0'; Debut = '10.50.40.100'; Fin = '10.50.40.200'; Passerelle = '10.50.40.1' }
    @{ Nom = 'Postes-Logistique';     Reseau = '10.50.50.0'; Debut = '10.50.50.100'; Fin = '10.50.50.200'; Passerelle = '10.50.50.1' }
)
$DossierLogs = 'C:\Scripts\Logs'
#endregion

#region ---------- Fonctions communes ----------
$script:NbErreurs = 0
New-Item -ItemType Directory -Path $DossierLogs -Force | Out-Null
$FichierLog = Join-Path $DossierLogs ("10_DHCP_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function Write-Journal {
    param([string]$Message, [ValidateSet('INFO', 'OK', 'WARN', 'ERREUR')][string]$Niveau = 'INFO')
    $ligne = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Niveau, $Message
    $couleur = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERREUR = 'Red' }[$Niveau]
    Write-Host $ligne -ForegroundColor $couleur
    Add-Content -Path $FichierLog -Value $ligne -Encoding UTF8
}

function Invoke-Etape {
    param([string]$Nom, [scriptblock]$Action)
    # Stop : une erreur « non bloquante » est aussi comptée comme échec
    $ErrorActionPreference = 'Stop'
    try   { & $Action; Write-Journal "$Nom : OK" 'OK' }
    catch { $script:NbErreurs++; Write-Journal "$Nom : $($_.Exception.Message)" 'ERREUR' }
}
#endregion

Write-Journal '===== DHCP Nordis (démonstration AWS) ====='

Invoke-Etape 'Rôle DHCP sur DC01 et DC02' {
    foreach ($s in $Serveurs.Keys) {
        $r = Install-WindowsFeature -Name DHCP -IncludeManagementTools -ComputerName $s
        if (-not $r.Success) { throw "installation incomplète sur $s" }
    }
}

Invoke-Etape 'Groupes de sécurité DHCP et redémarrage du service' {
    Invoke-Command -ComputerName @($Serveurs.Keys) -ScriptBlock {
        netsh dhcp add securitygroups | Out-Null
        Restart-Service DHCPServer
        # Indique au Gestionnaire de serveur que la configuration post-installation est faite
        Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\ServerManager\Roles\12' -Name ConfigurationState -Value 2 -ErrorAction SilentlyContinue
    }
}

Invoke-Etape 'Autorisation des 2 serveurs dans l''AD' {
    $autorises = @(Get-DhcpServerInDC).DnsName
    foreach ($s in $Serveurs.Keys) {
        if ($autorises -notcontains $s) { Add-DhcpServerInDC -DnsName $s -IPAddress $Serveurs[$s] }
    }
}

foreach ($e in $Etendues) {
    Invoke-Etape "Étendue $($e.Nom) ($($e.Reseau), bail 8 jours)" {
        if (-not (Get-DhcpServerv4Scope -ComputerName $Principal -ScopeId $e.Reseau -ErrorAction SilentlyContinue)) {
            Add-DhcpServerv4Scope -ComputerName $Principal -Name $e.Nom -StartRange $e.Debut -EndRange $e.Fin `
                                  -SubnetMask 255.255.255.0 -LeaseDuration $DureeBail -State Active
        }
        Set-DhcpServerv4OptionValue -ComputerName $Principal -ScopeId $e.Reseau -Router $e.Passerelle `
                                    -DnsServer $ServeurDNS -DnsDomain $Domaine -Force
    }
}

Invoke-Etape 'Mise à jour DNS dynamique par le DHCP' {
    foreach ($s in $Serveurs.Keys) {
        Set-DhcpServerv4DnsSetting -ComputerName $s -DynamicUpdates Always -DeleteDnsRROnLeaseExpiry $true
    }
}

Invoke-Etape "Basculement $NomFailover (équilibrage $RepartitionPct %)" {
    if (-not (Get-DhcpServerv4Failover -ComputerName $Principal -Name $NomFailover -ErrorAction SilentlyContinue)) {
        # Secret partagé généré aléatoirement : il n'est saisi ni stocké nulle part ailleurs
        $secret = -join ((48..57) + (65..90) + (97..122) | Get-Random -Count 24 | ForEach-Object { [char]$_ })
        Add-DhcpServerv4Failover -ComputerName $Principal -Name $NomFailover -PartnerServer $Partenaire `
                                 -ScopeId ($Etendues | ForEach-Object { $_.Reseau }) `
                                 -LoadBalancePercent $RepartitionPct -SharedSecret $secret -Force | Out-Null
    }
}

Invoke-Etape 'Vérification : étendues répliquées sur DC02' {
    $surDC02 = @(Get-DhcpServerv4Scope -ComputerName $Partenaire).ScopeId.IPAddressToString
    $manquantes = @($Etendues | Where-Object { $surDC02 -notcontains $_.Reseau })
    if ($manquantes.Count -gt 0) { throw "étendues absentes de DC02 : $($manquantes.Reseau -join ', ')" }
}

Write-Journal 'Vérifications : Get-DhcpServerv4Failover | Get-DhcpServerv4Scope -ComputerName dc02 | Get-DhcpServerInDC'
if ($script:NbErreurs -gt 0) {
    Write-Journal "Terminé avec $($script:NbErreurs) erreur(s). Journal : $FichierLog" 'ERREUR'; exit 1
}
Write-Journal "Terminé sans erreur. Journal : $FichierLog" 'OK'
exit 0
