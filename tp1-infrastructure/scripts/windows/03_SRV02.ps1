<#
.SYNOPSIS
    Configure SRV02 (Server Core) sur AWS : serveur de fichiers (Storage Spaces miroir, FSRM, partages AGDLP).

.DESCRIPTION
    Version AWS du script (une instance EC2 par machine, pas de VLAN ni de DHCP Windows).
    Script en 3 étapes, détectées automatiquement. Relance-le après chaque redémarrage.
      Étape 1 : nom SRV02 si besoin (normalement déjà fait par Terraform), redémarrage.
      Étape 2 : DNS client vers DC01 / DC02, jonction au domaine dans OU=Serveurs, redémarrage.
      Étape 3 : rôles Fichiers + FSRM, pool Storage Spaces en miroir sur les 2 volumes EBS
                de 30 Go (volume E:), dossiers par service + Perso$ + Sauvegardes,
                droits NTFS et SMB (AGDLP), quotas FSRM, pare-feu Windows (partage de fichiers),
                script de connexion lecteurs.bat (S: T: U: V: W:) dans NETLOGON.

    Différences avec la version Hyper-V :
      - Pas d'IP fixe dans Windows : l'IP 10.50.10.11 est réservée côté AWS (Terraform).
      - DNS client = DC01 puis DC02 (un membre du domaine interroge les DC ; ils redirigent
        eux-mêmes vers FW01 pour Internet).
      - Les 2 disques du miroir sont des volumes EBS (vus comme disques NVMe par Windows).
      - Les espaces invisibles ajoutés par le copier-coller du mot de passe sont retirés.

.NOTES
    Auteur  : Thomas Peyrusaubes
    Date    : 2026-10-21
    Version : 1.2-aws
    Projet  : Nordis Distribution - Module A2627_5066
    Exécution : PowerShell en administrateur
                (étapes 1-2 : .\Administrator de SRV02 ; étape 3 : NORDIS\Administrator)

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force ; C:\Scripts\03_SRV02.ps1
#>
[CmdletBinding()]
param()

#region ---------- Variables ----------
$NomMachine       = 'SRV02'
$AdresseIP        = '10.50.10.11'
$ServeursDNS      = @('10.50.10.10', '10.50.10.12')   # DC01, DC02
$Domaine          = 'ad.nordis.test'
$NetBIOS          = 'NORDIS'
$OUServeurs       = 'OU=Serveurs,OU=Ordinateurs,OU=Nordis'

$NomPool          = 'Pool-Donnees'
$NomDisqueVirtuel = 'Donnees-Miroir'
$LettreDonnees    = 'E'
$RacinePartages   = "$($LettreDonnees):\Partages"
$RacinePerso      = "$($LettreDonnees):\Perso"
$RacineSauvegarde = "$($LettreDonnees):\Sauvegardes"
$PartagePerso     = 'Perso$'

$Services = @(
    @{ Partage = 'Direction';      Groupe = 'Grp_Direction';      Lecteur = 'S:' }
    @{ Partage = 'Administration'; Groupe = 'Grp_Administration'; Lecteur = 'T:' }
    @{ Partage = 'IT';             Groupe = 'Grp_IT';             Lecteur = 'U:' }
    @{ Partage = 'Commercial';     Groupe = 'Grp_Commercial';     Lecteur = 'V:' }
    @{ Partage = 'Logistique';     Groupe = 'Grp_Logistique';     Lecteur = 'W:' }
)
$GroupeDirection  = 'Grp_Direction'
$PrefixeDL        = 'DL-'                  # DL-<Partage>-RW / DL-<Partage>-RO
$SuffixeRW        = '-RW'
$SuffixeRO        = '-RO'

$ModeleQuotaPartage = 'Nordis - Partage 5 Go'
$TailleQuotaPartage = 5GB
$ModeleQuotaPerso   = 'Nordis - Perso 1 Go'
$TailleQuotaPerso   = 1GB

$ScriptConnexion  = 'lecteurs.bat'

# SID universels (indépendants de la langue de Windows)
$SidAdmins        = 'S-1-5-32-544'
$SidSysteme       = 'S-1-5-18'
$SidUtilAuth      = 'S-1-5-11'
$GroupePareFeuSMB = '@FirewallAPI.dll,-28502'   # « Partage de fichiers et d'imprimantes »

$DossierLogs = 'C:\Scripts\Logs'
#endregion

#region ---------- Fonctions communes ----------
$script:NbErreurs = 0
New-Item -ItemType Directory -Path $DossierLogs -Force | Out-Null
$FichierLog = Join-Path $DossierLogs ("03_SRV02_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

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

function Get-NomDepuisSid {
    param([string]$Sid)
    (New-Object System.Security.Principal.SecurityIdentifier($Sid)).Translate([System.Security.Principal.NTAccount]).Value
}

function Set-DroitsNTFS {
    # Remplace les droits du dossier (héritage coupé) par la liste fournie
    param([string]$Chemin, [object[]]$Regles)
    $acl = Get-Acl -Path $Chemin
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($r in @($acl.Access)) { $acl.RemoveAccessRuleSpecific($r) | Out-Null }
    foreach ($r in $Regles) {
        $heritage = if ($r.DossierSeul) { 'None' } else { 'ContainerInherit,ObjectInherit' }
        $regle = New-Object System.Security.AccessControl.FileSystemAccessRule($r.Identite, $r.Droits, $heritage, 'None', 'Allow')
        $acl.AddAccessRule($regle)
    }
    Set-Acl -Path $Chemin -AclObject $acl
}

function Exit-Script {
    if ($script:NbErreurs -gt 0) {
        Write-Journal "Terminé avec $($script:NbErreurs) erreur(s). Journal : $FichierLog" 'ERREUR'; exit 1
    }
    Write-Journal "Terminé sans erreur. Journal : $FichierLog" 'OK'; exit 0
}
#endregion

$DomaineDN = ($Domaine.Split('.') | ForEach-Object { "DC=$_" }) -join ','
$systeme   = Get-CimInstance Win32_ComputerSystem
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
            throw "cette machine n'a pas l'IP $AdresseIP : vérifie que tu es bien sur SRV02"
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
        Invoke-Etape "Jonction à $Domaine (OU=Serveurs)" {
            Add-Computer -DomainName $Domaine -OUPath "$OUServeurs,$DomaineDN" -Credential $cred -Restart -Force
        }
    }
    Exit-Script
}

# ---------- Étape 3 ----------
$NomAdmins   = Get-NomDepuisSid $SidAdmins
$NomUtilAuth = Get-NomDepuisSid $SidUtilAuth
$IdAdmins    = New-Object System.Security.Principal.SecurityIdentifier($SidAdmins)
$IdSysteme   = New-Object System.Security.Principal.SecurityIdentifier($SidSysteme)

Invoke-Etape 'Rôles Serveur de fichiers + FSRM' {
    Install-WindowsFeature -Name FS-FileServer, FS-Resource-Manager -IncludeManagementTools | Out-Null
}

Invoke-Etape "Storage Spaces : pool $NomPool (2 volumes EBS)" {
    if (-not (Get-StoragePool -FriendlyName $NomPool -ErrorAction SilentlyContinue)) {
        # Volumes EBS neufs : on les met en ligne s'ils sont hors ligne ou en lecture seule
        Get-Disk | Where-Object { -not $_.IsBoot -and $_.PartitionStyle -eq 'RAW' } | ForEach-Object {
            if ($_.IsOffline)  { Set-Disk -Number $_.Number -IsOffline $false }
            if ($_.IsReadOnly) { Set-Disk -Number $_.Number -IsReadOnly $false }
        }
        $disques = @(Get-PhysicalDisk -CanPool $true)
        if ($disques.Count -lt 2) {
            $detail = (Get-PhysicalDisk | ForEach-Object { "$($_.FriendlyName) $([math]::Round($_.Size / 1GB)) Go : $($_.CannotPoolReason)" }) -join ' | '
            throw "il faut 2 disques libres pour un miroir (trouvés : $($disques.Count)). Disques : $detail"
        }
        $sousSysteme = Get-StorageSubSystem | Where-Object FriendlyName -like 'Windows Storage*' | Select-Object -First 1
        New-StoragePool -FriendlyName $NomPool -StorageSubSystemFriendlyName $sousSysteme.FriendlyName -PhysicalDisks $disques | Out-Null
    }
}

Invoke-Etape "Storage Spaces : disque virtuel miroir -> $($LettreDonnees):" {
    if (-not (Get-VirtualDisk -FriendlyName $NomDisqueVirtuel -ErrorAction SilentlyContinue)) {
        New-VirtualDisk -StoragePoolFriendlyName $NomPool -FriendlyName $NomDisqueVirtuel `
                        -ResiliencySettingName Mirror -ProvisioningType Fixed -UseMaximumSize | Out-Null
        Get-VirtualDisk -FriendlyName $NomDisqueVirtuel | Get-Disk |
            Initialize-Disk -PartitionStyle GPT -PassThru |
            New-Partition -DriveLetter $LettreDonnees -UseMaximumSize |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel 'DONNEES' -Confirm:$false | Out-Null
    }
}

Invoke-Etape 'Dossiers et droits NTFS (AGDLP)' {
    foreach ($s in $Services) {
        $chemin = Join-Path $RacinePartages $s.Partage
        New-Item -ItemType Directory -Path $chemin -Force | Out-Null
        $dlRW = New-Object System.Security.Principal.NTAccount($NetBIOS, "$PrefixeDL$($s.Partage)$SuffixeRW")
        $dlRO = New-Object System.Security.Principal.NTAccount($NetBIOS, "$PrefixeDL$($s.Partage)$SuffixeRO")
        Set-DroitsNTFS -Chemin $chemin -Regles @(
            @{ Identite = $IdSysteme; Droits = 'FullControl' }
            @{ Identite = $IdAdmins;  Droits = 'FullControl' }
            @{ Identite = $dlRW;      Droits = 'Modify' }
            @{ Identite = $dlRO;      Droits = 'ReadAndExecute' }
        )
    }
    New-Item -ItemType Directory -Path $RacinePerso, $RacineSauvegarde -Force | Out-Null
    # Perso : chaque utilisateur reçoit Modifier sur SON dossier (05_Utilisateurs_AD.ps1)
    Set-DroitsNTFS -Chemin $RacinePerso -Regles @(
        @{ Identite = $IdSysteme; Droits = 'FullControl' }
        @{ Identite = $IdAdmins;  Droits = 'FullControl' }
    )
    Set-DroitsNTFS -Chemin $RacineSauvegarde -Regles @(
        @{ Identite = $IdSysteme; Droits = 'FullControl' }
        @{ Identite = $IdAdmins;  Droits = 'FullControl' }
    )
}

Invoke-Etape 'Partages SMB (énumération basée sur l''accès)' {
    foreach ($s in $Services) {
        if (-not (Get-SmbShare -Name $s.Partage -ErrorAction SilentlyContinue)) {
            New-SmbShare -Name $s.Partage -Path (Join-Path $RacinePartages $s.Partage) `
                         -FullAccess $NomAdmins -ChangeAccess "$NetBIOS\$PrefixeDL$($s.Partage)$SuffixeRW" `
                         -ReadAccess "$NetBIOS\$PrefixeDL$($s.Partage)$SuffixeRO" `
                         -FolderEnumerationMode AccessBased -CachingMode None | Out-Null
        }
    }
    if (-not (Get-SmbShare -Name $PartagePerso -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name $PartagePerso -Path $RacinePerso -FullAccess $NomAdmins -ChangeAccess $NomUtilAuth `
                     -FolderEnumerationMode AccessBased -CachingMode None | Out-Null
    }
}

Invoke-Etape 'Pare-feu Windows : partage de fichiers (SMB 445)' {
    Enable-NetFirewallRule -Group $GroupePareFeuSMB
}

Invoke-Etape 'Quotas FSRM' {
    if (-not (Get-FsrmQuotaTemplate -Name $ModeleQuotaPartage -ErrorAction SilentlyContinue)) {
        New-FsrmQuotaTemplate -Name $ModeleQuotaPartage -Size $TailleQuotaPartage | Out-Null
    }
    if (-not (Get-FsrmQuotaTemplate -Name $ModeleQuotaPerso -ErrorAction SilentlyContinue)) {
        New-FsrmQuotaTemplate -Name $ModeleQuotaPerso -Size $TailleQuotaPerso | Out-Null
    }
    foreach ($s in $Services) {
        $chemin = Join-Path $RacinePartages $s.Partage
        if (-not (Get-FsrmQuota -Path $chemin -ErrorAction SilentlyContinue)) {
            New-FsrmQuota -Path $chemin -Template $ModeleQuotaPartage | Out-Null
        }
    }
    # Quota automatique : chaque nouveau dossier perso reçoit 1 Go
    if (-not (Get-FsrmAutoQuota -Path $RacinePerso -ErrorAction SilentlyContinue)) {
        New-FsrmAutoQuota -Path $RacinePerso -Template $ModeleQuotaPerso | Out-Null
    }
}

Invoke-Etape "Script de connexion $ScriptConnexion (NETLOGON)" {
    $lignes = @(
        '@echo off'
        'REM Lecteurs reseau Nordis - genere par 03_SRV02.ps1'
        'REM La Direction recoit les 5 lecteurs, les autres celui de leur service.'
        'whoami /groups > "%TEMP%\nordis_groupes.txt"'
        'set DIRECTION=0'
        "findstr /i /c:`"$GroupeDirection`" `"%TEMP%\nordis_groupes.txt`" >nul && set DIRECTION=1"
    )
    foreach ($s in $Services) {
        $lignes += "call :lecteur $($s.Groupe) $($s.Lecteur) $($s.Partage)"
    }
    $lignes += @(
        'del "%TEMP%\nordis_groupes.txt" >nul 2>&1'
        'goto :eof'
        ''
        ':lecteur'
        'findstr /i /c:"%1" "%TEMP%\nordis_groupes.txt" >nul'
        'if not errorlevel 1 goto monter'
        'if "%DIRECTION%"=="1" goto monter'
        'goto :eof'
        ':monter'
        'net use %2 /delete /y >nul 2>&1'
        "net use %2 \\$NomMachine\%3 /persistent:no >nul"
        'goto :eof'
    )
    Set-Content -Path "\\$Domaine\NETLOGON\$ScriptConnexion" -Value $lignes -Encoding ASCII
}

$volume = Get-Volume -DriveLetter $LettreDonnees -ErrorAction SilentlyContinue
if ($volume) { Write-Journal "Volume $($LettreDonnees): : $([math]::Round($volume.Size / 1GB, 1)) Go (miroir)" }
Write-Journal "Partages : $((Get-SmbShare | Where-Object { -not $_.Special }).Name -join ', ')"
Write-Journal 'Étape suivante : 05_Utilisateurs_AD.ps1 sur DC01 (comptes, dossiers perso, lecteurs.bat).'
Exit-Script
