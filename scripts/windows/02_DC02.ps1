<#
.SYNOPSIS
    Configure DC02 (Server Core) sur AWS : second contrôleur de domaine de ad.nordis.test, DNS intégré.

.DESCRIPTION
    Version AWS du script (une instance EC2 par machine, pas de VLAN ni de DHCP Windows).
    Script en 3 étapes, détectées automatiquement. Relance-le après chaque redémarrage.
      Étape 1 : nom DC02 si besoin (normalement déjà fait par Terraform), redémarrage.
      Étape 2 : DNS client vers DC01, rôles AD DS / DNS, promotion en contrôleur
                supplémentaire (réplication depuis DC01), redémarrage.
      Étape 3 : DNS client, heure (hiérarchie du domaine), redirecteur DNS, audit.

    Différences avec la version Hyper-V :
      - Pas d'IP fixe dans Windows : l'IP 10.50.10.12 est réservée côté AWS (Terraform).
      - Pas de DHCP ni de basculement DHCP : sur AWS, le DHCP est assuré par le VPC.
      - Redirecteur DNS = Unbound sur FW01 (10.50.0.20).

.NOTES
    Auteur  : Thomas Peyrusaubes
    Date    : 2026-10-21
    Version : 1.2-aws
    Projet  : Nordis Distribution - Module A2627_5066
    Exécution : PowerShell en administrateur
                (étapes 1-2 : .\Administrator ; étape 3 : NORDIS\Administrator)

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force ; C:\Scripts\02_DC02.ps1
#>
[CmdletBinding()]
param()

#region ---------- Variables ----------
$NomMachine      = 'DC02'
$AdresseIP       = '10.50.10.12'
$DCPrincipal     = 'DC01'
$IpDCPrincipal   = '10.50.10.10'
$Domaine         = 'ad.nordis.test'
$RedirecteurDNS  = '10.50.0.20'                           # Unbound sur FW01

$SousCategoriesAudit = @{
    'Ouverture de session'        = '{0CCE9215-69AE-11D9-BED3-505054503030}'
    'Verrouillage de compte'      = '{0CCE9217-69AE-11D9-BED3-505054503030}'
    'Gestion des comptes'         = '{0CCE9235-69AE-11D9-BED3-505054503030}'
    'Validation des informations' = '{0CCE923F-69AE-11D9-BED3-505054503030}'
    'Service d''authentification Kerberos' = '{0CCE9242-69AE-11D9-BED3-505054503030}'
}

$DossierLogs = 'C:\Scripts\Logs'
#endregion

#region ---------- Fonctions communes ----------
$script:NbErreurs = 0
New-Item -ItemType Directory -Path $DossierLogs -Force | Out-Null
$FichierLog = Join-Path $DossierLogs ("02_DC02_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function Write-Journal {
    param([string]$Message, [ValidateSet('INFO', 'OK', 'WARN', 'ERREUR')][string]$Niveau = 'INFO')
    $ligne = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Niveau, $Message
    $couleur = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERREUR = 'Red' }[$Niveau]
    Write-Host $ligne -ForegroundColor $couleur
    Add-Content -Path $FichierLog -Value $ligne -Encoding UTF8
}

function Invoke-Etape {
    param([string]$Nom, [scriptblock]$Action)
    # Stop : une erreur « non bloquante » (ex. Install-ADDSDomainController) est aussi comptée comme échec
    $ErrorActionPreference = 'Stop'
    try   { & $Action; Write-Journal "$Nom : OK" 'OK' }
    catch { $script:NbErreurs++; Write-Journal "$Nom : $($_.Exception.Message)" 'ERREUR' }
}

function Exit-Script {
    if ($script:NbErreurs -gt 0) {
        Write-Journal "Terminé avec $($script:NbErreurs) erreur(s). Journal : $FichierLog" 'ERREUR'; exit 1
    }
    Write-Journal "Terminé sans erreur. Journal : $FichierLog" 'OK'; exit 0
}
#endregion

$roleDomaine = (Get-CimInstance Win32_ComputerSystem).DomainRole
$etape = if ($env:COMPUTERNAME -ne $NomMachine) { 1 } elseif ($roleDomaine -lt 4) { 2 } else { 3 }
Write-Journal "===== $NomMachine (AWS) - étape $etape / 3 ====="

if ($etape -eq 1) {
    Invoke-Etape "Renommage en $NomMachine" { Rename-Computer -NewName $NomMachine -Force }
    if ($script:NbErreurs -eq 0) {
        Write-Journal 'Redémarrage dans 10 s. Reconnecte-toi puis relance ce script.' 'WARN'
        Start-Sleep -Seconds 10; Restart-Computer -Force
    }
    Exit-Script
}

if ($etape -eq 2) {
    Invoke-Etape "Vérification de l'IP AWS ($AdresseIP)" {
        if (-not (Get-NetIPAddress -AddressFamily IPv4 -IPAddress $AdresseIP -ErrorAction SilentlyContinue)) {
            throw "cette machine n'a pas l'IP $AdresseIP : vérifie que tu es bien sur DC02"
        }
    }
    Invoke-Etape "DNS client : DC01 ($IpDCPrincipal) pour trouver le domaine" {
        $carte = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
        Set-DnsClientServerAddress -InterfaceIndex $carte.ifIndex -ServerAddresses $IpDCPrincipal
        Clear-DnsClientCache
        Resolve-DnsName "_ldap._tcp.dc._msdcs.$Domaine" -Type SRV | Out-Null
    }
    Invoke-Etape 'Rôles AD DS et DNS' {
        Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools | Out-Null
    }
    if ($script:NbErreurs -eq 0) {
        $cred = Get-Credential -Message "Administrateur du domaine (NORDIS\Administrator)"
        $dsrm = Read-Host 'Mot de passe DSRM de DC02 (14 caractères, majuscule, chiffre, symbole)' -AsSecureString
        Write-Journal 'Promotion en contrôleur de domaine : redémarrage automatique (5 à 10 min).' 'WARN'
        Write-Journal 'Reconnecte-toi ensuite en NORDIS\Administrator puis relance ce script.' 'WARN'
        Invoke-Etape "Promotion de $NomMachine (réplication depuis $DCPrincipal)" {
            # L'avertissement « adresse IP dynamique » est normal sur AWS : l'IP est réservée côté AWS.
            Install-ADDSDomainController -DomainName $Domaine -InstallDns -Credential $cred `
                                         -ReplicationSourceDC "$DCPrincipal.$Domaine" `
                                         -SafeModeAdministratorPassword $dsrm -Force | Out-Null
        }
    }
    Exit-Script
}

# ---------- Étape 3 ----------
Import-Module DnsServer

Invoke-Etape 'DNS client : DC01 puis lui-même' {
    $carte = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    Set-DnsClientServerAddress -InterfaceIndex $carte.ifIndex -ServerAddresses $IpDCPrincipal, '127.0.0.1'
    Set-DnsClient -InterfaceIndex $carte.ifIndex -ConnectionSpecificSuffix $Domaine
}

Invoke-Etape 'Heure : hiérarchie du domaine (DC01)' {
    w32tm /config /syncfromflags:domhier /update | Out-Null
    Restart-Service w32time
    w32tm /resync /force | Out-Null
}

Invoke-Etape "DNS : redirecteur vers FW01 ($RedirecteurDNS)" {
    Set-DnsServerForwarder -IPAddress $RedirecteurDNS
}

Invoke-Etape 'Audit : connexions et verrouillages de comptes' {
    foreach ($nom in $SousCategoriesAudit.Keys) {
        auditpol /set /subcategory:"$($SousCategoriesAudit[$nom])" /success:enable /failure:enable | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "auditpol a échoué pour $nom" }
    }
}

Write-Journal 'Vérification de la réplication : repadmin /replsummary'
Exit-Script
