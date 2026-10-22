<#
.SYNOPSIS
    Configure DC01 sur AWS : contrôleur de domaine principal (AD DS, DNS) de ad.nordis.test.

.DESCRIPTION
    Version AWS du script (une instance EC2 par machine, pas de VLAN ni de DHCP Windows).
    Script en 3 étapes, détectées automatiquement. Relance-le après chaque redémarrage.
      Étape 1 : nom DC01 si besoin (normalement déjà fait par Terraform), redémarrage.
      Étape 2 : rôles AD DS / DNS, nouvelle forêt ad.nordis.test, redémarrage.
      Étape 3 : DNS client, heure (FW01 + AWS), redirecteur DNS, zone inverse,
                OU, groupes (AGDLP), compte d'administration, audit de sécurité.

    Différences avec la version Hyper-V :
      - Pas d'IP fixe dans Windows : l'IP 10.50.10.10 est réservée sur l'interface
        réseau AWS (Terraform), elle ne change jamais.
      - Pas de rôle DHCP : sur AWS, le DHCP est assuré par le VPC (jeu d'options DHCP).
      - Passerelle, DNS et NTP de FW01 = 10.50.0.20 (et non 10.50.10.1).

.NOTES
    Auteur  : Thomas Peyrusaubes
    Date    : 2026-10-21
    Version : 1.2-aws
    Projet  : Nordis Distribution - Module A2627_5066
    Exécution : PowerShell en administrateur
                (étape 3 : NORDIS\Administrator, même mot de passe que l'Administrator local)

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force ; C:\Scripts\01_DC01.ps1
#>
[CmdletBinding()]
param()

#region ---------- Variables ----------
$NomMachine      = 'DC01'
$AdresseIP       = '10.50.10.10'
$Domaine         = 'ad.nordis.test'
$NetBIOS         = 'NORDIS'
$SourcesNTP      = '10.50.0.20,0x8 169.254.169.123,0x8'   # FW01, puis Amazon Time Sync en secours
$RedirecteurDNS  = '10.50.0.20'                           # Unbound sur FW01
$ReseauInverse   = '10.50.0.0/16'
$ZoneInverse     = '50.10.in-addr.arpa'

$OURacine        = 'Nordis'
$Services = @(
    @{ OU = 'Direction';      Groupe = 'Grp_Direction';      Partage = 'Direction' }
    @{ OU = 'Administration'; Groupe = 'Grp_Administration'; Partage = 'Administration' }
    @{ OU = 'Informatique';   Groupe = 'Grp_IT';             Partage = 'IT' }
    @{ OU = 'Commercial';     Groupe = 'Grp_Commercial';     Partage = 'Commercial' }
    @{ OU = 'Logistique';     Groupe = 'Grp_Logistique';     Partage = 'Logistique' }
)
$GroupeDirection   = 'Grp_Direction'          # accès aux 5 dossiers
$PrefixeDL         = 'DL-'                    # DL-<Partage>-RW / DL-<Partage>-RO (dossier d'exploitation)
$SuffixeRW         = '-RW'
$SuffixeRO         = '-RO'
$GroupeAdminsLinux = 'GG-Admins-Linux'        # sudo sur les serveurs Linux (support de cours)
$CompteAdmin       = 'adm-t.peyrusaubes'      # convention adm-<login> : ton compte d'administration
$SuffixeUPN        = 'nordis.fr'              # UPN des utilisateurs du CSV (prenom.nom@nordis.fr)

# Audit (GUID = indépendant de la langue de Windows)
$SousCategoriesAudit = @{
    'Ouverture de session'          = '{0CCE9215-69AE-11D9-BED3-505054503030}'
    'Verrouillage de compte'        = '{0CCE9217-69AE-11D9-BED3-505054503030}'
    'Gestion des comptes'           = '{0CCE9235-69AE-11D9-BED3-505054503030}'
    'Validation des informations'   = '{0CCE923F-69AE-11D9-BED3-505054503030}'
    'Service d''authentification Kerberos' = '{0CCE9242-69AE-11D9-BED3-505054503030}'
}

$DossierLogs = 'C:\Scripts\Logs'
#endregion

#region ---------- Fonctions communes ----------
$script:NbErreurs = 0
New-Item -ItemType Directory -Path $DossierLogs -Force | Out-Null
$FichierLog = Join-Path $DossierLogs ("01_DC01_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function Write-Journal {
    param([string]$Message, [ValidateSet('INFO', 'OK', 'WARN', 'ERREUR')][string]$Niveau = 'INFO')
    $ligne = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Niveau, $Message
    $couleur = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERREUR = 'Red' }[$Niveau]
    Write-Host $ligne -ForegroundColor $couleur
    Add-Content -Path $FichierLog -Value $ligne -Encoding UTF8
}

function Invoke-Etape {
    param([string]$Nom, [scriptblock]$Action)
    # Stop : une erreur « non bloquante » (ex. Install-ADDSForest) est aussi comptée comme échec
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

# ---------- Détection de l'étape ----------
$roleDomaine = (Get-CimInstance Win32_ComputerSystem).DomainRole    # 4/5 = contrôleur de domaine
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
            throw "cette machine n'a pas l'IP $AdresseIP : vérifie que tu es bien sur DC01"
        }
    }
    Invoke-Etape 'Rôles AD DS et DNS' {
        Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools | Out-Null
    }
    if ($script:NbErreurs -eq 0) {
        $dsrm = Read-Host 'Mot de passe DSRM (restauration des services d''annuaire)' -AsSecureString
        Write-Journal "Création de la forêt $Domaine : redémarrage automatique (5 à 10 min)." 'WARN'
        Write-Journal "Reconnecte-toi ensuite en $NetBIOS\Administrator (même mot de passe) puis relance ce script." 'WARN'
        Invoke-Etape "Forêt $Domaine" {
            # L'avertissement « adresse IP dynamique » est normal sur AWS : l'IP est réservée côté AWS.
            Install-ADDSForest -DomainName $Domaine -DomainNetbiosName $NetBIOS -InstallDns `
                               -SafeModeAdministratorPassword $dsrm -Force | Out-Null
        }
    }
    Exit-Script
}

# ---------- Étape 3 : configuration ----------
Import-Module ActiveDirectory, DnsServer
$DomaineDN = (Get-ADDomain).DistinguishedName

Invoke-Etape 'DNS client : DC01 s''interroge lui-même' {
    $carte = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    Set-DnsClientServerAddress -InterfaceIndex $carte.ifIndex -ServerAddresses '127.0.0.1'
    Set-DnsClient -InterfaceIndex $carte.ifIndex -ConnectionSpecificSuffix $Domaine
}

Invoke-Etape "Heure : synchronisation sur FW01 puis Amazon Time Sync" {
    w32tm /config /manualpeerlist:"$SourcesNTP" /syncfromflags:manual /reliable:yes /update | Out-Null
    Restart-Service w32time
    w32tm /resync /force | Out-Null
}

Invoke-Etape "DNS : redirecteur vers FW01 ($RedirecteurDNS)" {
    Set-DnsServerForwarder -IPAddress $RedirecteurDNS
}

Invoke-Etape "DNS : zone inverse $ZoneInverse" {
    if (-not (Get-DnsServerZone -Name $ZoneInverse -ErrorAction SilentlyContinue)) {
        Add-DnsServerPrimaryZone -NetworkId $ReseauInverse -ReplicationScope Forest -DynamicUpdate Secure
    }
}

# --- Unités d'organisation ---
function New-OUSiAbsente {
    param([string]$Nom, [string]$Parent)
    $dn = "OU=$Nom,$Parent"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $Nom -Path $Parent -ProtectedFromAccidentalDeletion $true
    }
    return $dn
}

Invoke-Etape 'OU : arborescence Nordis' {
    # Convention du dossier d'exploitation et du CSV : OU=<Service>,OU=Nordis,DC=ad,DC=nordis,DC=test
    $script:OUNordis       = New-OUSiAbsente -Nom $OURacine        -Parent $DomaineDN
    foreach ($s in $Services) { New-OUSiAbsente -Nom $s.OU -Parent $script:OUNordis | Out-Null }
    $script:OUGroupes      = New-OUSiAbsente -Nom 'Groupes'         -Parent $script:OUNordis
    $script:OUOrdinateurs  = New-OUSiAbsente -Nom 'Ordinateurs'     -Parent $script:OUNordis
    $script:OUPostes       = New-OUSiAbsente -Nom 'Postes'          -Parent $script:OUOrdinateurs
    $script:OUServeurs     = New-OUSiAbsente -Nom 'Serveurs'        -Parent $script:OUOrdinateurs
    $script:OUAdmins       = New-OUSiAbsente -Nom 'Comptes_Admin'   -Parent $script:OUNordis
    $script:OUService      = New-OUSiAbsente -Nom 'Comptes_Service' -Parent $script:OUNordis
}

Invoke-Etape "Suffixe UPN $SuffixeUPN (logins prenom.nom@$SuffixeUPN du CSV)" {
    if ((Get-ADForest).UPNSuffixes -notcontains $SuffixeUPN) {
        Set-ADForest -Identity (Get-ADForest) -UPNSuffixes @{ Add = $SuffixeUPN }
    }
}

# --- Groupes (AGDLP : comptes -> groupes globaux -> groupes domaine local -> permissions) ---
function New-GroupeSiAbsent {
    param([string]$Nom, [string]$Etendue, [string]$Chemin, [string]$Description)
    if (-not (Get-ADGroup -Filter "Name -eq '$Nom'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $Nom -SamAccountName $Nom -GroupCategory Security -GroupScope $Etendue `
                    -Path $Chemin -Description $Description
    }
}

Invoke-Etape 'Groupes globaux (G) et domaine local (DL)' {
    foreach ($s in $Services) {
        $dlRW = "$PrefixeDL$($s.Partage)$SuffixeRW"
        $dlRO = "$PrefixeDL$($s.Partage)$SuffixeRO"
        New-GroupeSiAbsent -Nom $s.Groupe -Etendue Global -Chemin $script:OUGroupes -Description "Service $($s.OU)"
        New-GroupeSiAbsent -Nom $dlRW -Etendue DomainLocal -Chemin $script:OUGroupes -Description "Modification du dossier $($s.Partage)"
        New-GroupeSiAbsent -Nom $dlRO -Etendue DomainLocal -Chemin $script:OUGroupes -Description "Lecture seule du dossier $($s.Partage)"
        Add-ADGroupMember -Identity $dlRW -Members $s.Groupe
        if ($s.Groupe -ne $GroupeDirection) { Add-ADGroupMember -Identity $dlRW -Members $GroupeDirection }
    }
    New-GroupeSiAbsent -Nom $GroupeAdminsLinux -Etendue Global -Chemin $script:OUGroupes -Description 'Administrateurs sudo des serveurs Linux'
}

Invoke-Etape "Compte d'administration $CompteAdmin" {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$CompteAdmin'" -ErrorAction SilentlyContinue)) {
        $mdp = Read-Host "Mot de passe de $CompteAdmin" -AsSecureString
        New-ADUser -Name $CompteAdmin -SamAccountName $CompteAdmin -UserPrincipalName "$CompteAdmin@$Domaine" `
                   -Path $script:OUAdmins -AccountPassword $mdp -Enabled $true `
                   -DisplayName "$CompteAdmin (administration)" `
                   -Description 'Compte d''administration (ne pas utiliser pour les tâches courantes)'
    }
    $adminsDuDomaine = Get-ADGroup -Identity "$((Get-ADDomain).DomainSID.Value)-512"   # SID = indépendant de la langue
    Add-ADGroupMember -Identity $adminsDuDomaine -Members $CompteAdmin
    Add-ADGroupMember -Identity $GroupeAdminsLinux -Members $CompteAdmin
}

Invoke-Etape 'Nouveaux ordinateurs rangés dans OU=Postes' {
    redircmp $script:OUPostes | Out-Null
}

Invoke-Etape 'Corbeille Active Directory' {
    if (-not (Get-ADOptionalFeature -Filter "Name -eq 'Recycle Bin Feature'").EnabledScopes) {
        Enable-ADOptionalFeature -Identity 'Recycle Bin Feature' -Scope ForestOrConfigurationSet `
                                 -Target $Domaine -Confirm:$false
    }
}

Invoke-Etape 'Audit : connexions et verrouillages de comptes' {
    foreach ($nom in $SousCategoriesAudit.Keys) {
        auditpol /set /subcategory:"$($SousCategoriesAudit[$nom])" /success:enable /failure:enable | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "auditpol a échoué pour $nom" }
    }
}

Write-Journal 'Étape suivante : DC02 (02_DC02.ps1 version AWS).'
Exit-Script
