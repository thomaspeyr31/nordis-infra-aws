<#
.SYNOPSIS
    Configure CLI01 sur AWS : poste d'administration (sous-réseau management), joint au domaine, outils RSAT.

.DESCRIPTION
    Version AWS du script (une instance EC2 par machine).
    Script en 3 étapes, détectées automatiquement. Relance-le après chaque redémarrage.
      Étape 1 : nom CLI01 si besoin (normalement déjà fait par Terraform), redémarrage.
      Étape 2 : DNS client vers DC01 / DC02, jonction au domaine (le poste arrive dans
                OU=Postes grâce à redircmp), redémarrage.
      Étape 3 : outils RSAT (AD, GPO, DNS, fichiers + FSRM, console WSUS).

    Différences avec la version Hyper-V :
      - CLI01 est un Windows Server 2025 avec bureau (Windows 11 n'est pas proposé
        sur EC2 sans licence dédiée) : RSAT s'installe en rôles Windows (Install-WindowsFeature),
        sans passer par Windows Update.
      - Pas d'IP fixe dans Windows : l'IP 10.50.99.10 est réservée côté AWS (Terraform).
      - Pas de console DHCP : sur AWS, le DHCP est assuré par le VPC.

.NOTES
    Auteur  : Thomas Peyrusaubes
    Date    : 2026-10-21
    Version : 1.2-aws
    Projet  : Nordis Distribution - Module A2627_5066
    Exécution : PowerShell en administrateur
                (étapes 1-2 : .\Administrator de CLI01 ; étape 3 : NORDIS\Administrator)

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force ; C:\Scripts\04_CLI01.ps1
#>
[CmdletBinding()]
param()

#region ---------- Variables ----------
$NomMachine  = 'CLI01'
$AdresseIP   = '10.50.99.10'
$ServeursDNS = @('10.50.10.10', '10.50.10.12')   # DC01, DC02
$Domaine     = 'ad.nordis.test'
$OutilsRSAT  = @(
    'RSAT-AD-Tools'        # Utilisateurs et ordinateurs AD, Centre d'administration AD, module PowerShell
    'GPMC'                 # Gestion des stratégies de groupe
    'RSAT-DNS-Server'      # Console DNS
    'RSAT-File-Services'   # Gestion des fichiers, FSRM, DFS
    'UpdateServices-UI'    # Console WSUS
)
$DossierLogs = 'C:\Scripts\Logs'
#endregion

#region ---------- Fonctions communes ----------
$script:NbErreurs = 0
New-Item -ItemType Directory -Path $DossierLogs -Force | Out-Null
$FichierLog = Join-Path $DossierLogs ("04_CLI01_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function Write-Journal {
    param([string]$Message, [ValidateSet('INFO', 'OK', 'WARN', 'ERREUR')][string]$Niveau = 'INFO')
    $ligne = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Niveau, $Message
    $couleur = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERREUR = 'Red' }[$Niveau]
    Write-Host $ligne -ForegroundColor $couleur
    Add-Content -Path $FichierLog -Value $ligne -Encoding UTF8
}

function Invoke-Etape {
    param([string]$Nom, [scriptblock]$Action)
    # Stop : une erreur « non bloquante » (ex. Add-Computer) est aussi comptée comme échec
    $ErrorActionPreference = 'Stop'
    try   { & $Action; Write-Journal "$Nom : OK" 'OK' }
    catch { $script:NbErreurs++; Write-Journal "$Nom : $($_.Exception.Message)" 'ERREUR' }
}

function Get-IdentifiantPropre {
    # Fenêtre de saisie, puis retrait des espaces / retours à la ligne invisibles
    # ajoutés par le copier-coller depuis le Mac (Windows App).
    param([string]$Message)
    $saisie = Get-Credential -Message $Message
    if (-not $saisie) { throw 'saisie annulée' }
    $mdp = ConvertTo-SecureString $saisie.GetNetworkCredential().Password.Trim() -AsPlainText -Force
    New-Object System.Management.Automation.PSCredential($saisie.UserName.Trim(), $mdp)
}

function Exit-Script {
    if ($script:NbErreurs -gt 0) {
        Write-Journal "Terminé avec $($script:NbErreurs) erreur(s). Journal : $FichierLog" 'ERREUR'; exit 1
    }
    Write-Journal "Terminé sans erreur. Journal : $FichierLog" 'OK'; exit 0
}
#endregion

$systeme = Get-CimInstance Win32_ComputerSystem
$etape = if ($env:COMPUTERNAME -ne $NomMachine) { 1 } elseif (-not $systeme.PartOfDomain) { 2 } else { 3 }
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
            throw "cette machine n'a pas l'IP $AdresseIP : vérifie que tu es bien sur CLI01"
        }
    }
    Invoke-Etape "DNS client : DC01 puis DC02 ($($ServeursDNS -join ', '))" {
        $carte = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
        Set-DnsClientServerAddress -InterfaceIndex $carte.ifIndex -ServerAddresses $ServeursDNS
        Set-DnsClient -InterfaceIndex $carte.ifIndex -ConnectionSpecificSuffix $Domaine
        Clear-DnsClientCache
        Resolve-DnsName "_ldap._tcp.dc._msdcs.$Domaine" -Type SRV | Out-Null
    }
    if ($script:NbErreurs -eq 0) {
        $cred = Get-IdentifiantPropre -Message "Administrateur du domaine (NORDIS\Administrator)"
        Write-Journal 'Jonction au domaine : redémarrage automatique.' 'WARN'
        Write-Journal 'Reconnecte-toi ensuite en NORDIS\Administrator (mot de passe de DC01) puis relance ce script.' 'WARN'
        Invoke-Etape "Jonction à $Domaine (OU=Postes)" {
            Add-Computer -DomainName $Domaine -Credential $cred -Restart -Force
        }
    }
    Exit-Script
}

# ---------- Étape 3 ----------
Invoke-Etape "Outils RSAT ($($OutilsRSAT -join ', '))" {
    $resultat = Install-WindowsFeature -Name $OutilsRSAT -IncludeAllSubFeature
    if (-not $resultat.Success) { throw "installation incomplète (code : $($resultat.ExitCode))" }
}

Invoke-Etape 'Vérification : lecture de l''annuaire depuis CLI01' {
    Import-Module ActiveDirectory
    $nb = @(Get-ADUser -Filter * -SearchBase "OU=Nordis,$((Get-ADDomain).DistinguishedName)").Count
    Write-Journal "$nb comptes trouvés dans OU=Nordis"
}

Write-Journal 'CLI01 prêt : les consoles sont dans le menu Démarrer > Windows Tools (Outils Windows).'
Write-Journal 'Bonne pratique : administre le domaine depuis CLI01 avec ton compte adm-t.peyrusaubes.'
Exit-Script
