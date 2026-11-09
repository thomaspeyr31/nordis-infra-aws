<#
.SYNOPSIS
    Crée et lie les stratégies de groupe (GPO) Nordis, puis exporte le rapport HTML des GPO.

.DESCRIPTION
      1. Politique de mot de passe stricte (Default Domain Policy) : 12 caractères, complexité,
         renouvellement 90 jours, historique 24, verrouillage après 5 échecs.
      2. GPO_Commercial_USB (utilisateurs du service Commercial) : clés USB de stockage interdites.
      3. GPO_Postes_AppLocker (postes) : le groupe Grp_Commercial ne peut pas lancer de .exe depuis
         son profil ou une clé USB, ni aucun .msi -> installation de logiciels impossible.
      4. GPO_WSUS (domaine) : Windows Update pointe vers SRV02 (WSUS).
      5. Export du rapport HTML de toutes les GPO (livrable n°4).

.NOTES
    Auteur  : Thomas Peyrusaubes
    Date    : 2026-10-21
    Version : 1.2-aws (identique à la version Hyper-V, erreurs non bloquantes comptées)
    Projet  : Nordis Distribution - Module A2627_5066
    Exécution : DC01, compte administrateur du domaine, APRÈS 05_Utilisateurs_AD.ps1
                (la politique passe à 12 caractères : les mots de passe du CSV en font 11).
    AWS : tant que WSUS n'est pas installé sur SRV02, les machines ne reçoivent plus de mises à jour
          (normal : elles attendent SRV02:8530).

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force ; C:\Scripts\06_GPO.ps1
#>
[CmdletBinding()]
param()

#region ---------- Variables ----------
$Domaine            = 'ad.nordis.test'
$OUCommercial       = 'OU=Commercial,OU=Nordis'
$OUPostes           = 'OU=Postes,OU=Ordinateurs,OU=Nordis'
$GroupeCommercial   = 'Grp_Commercial'

$PolitiqueMdp = [ordered]@{
    MinimumPasswordLength = 12
    PasswordComplexity    = 1
    MaximumPasswordAge    = 90
    MinimumPasswordAge    = 1
    PasswordHistorySize   = 24
    LockoutBadCount       = 5
    ResetLockoutCount     = 15
    LockoutDuration       = 15
}

$GpoUSB             = 'GPO_Commercial_USB'
$GpoAppLocker       = 'GPO_Postes_AppLocker'
$GpoWSUS            = 'GPO_WSUS'
$UrlWSUS            = 'http://srv02.ad.nordis.test:8530'
$HeureInstallMAJ    = 19          # après la fermeture des bureaux (18 h)

$DossierRapports    = 'C:\Scripts\Rapports'
$DossierLogs        = 'C:\Scripts\Logs'
#endregion

#region ---------- Fonctions communes ----------
$script:NbErreurs = 0
New-Item -ItemType Directory -Path $DossierLogs, $DossierRapports -Force | Out-Null
$FichierLog = Join-Path $DossierLogs ("06_GPO_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

function Write-Journal {
    param([string]$Message, [ValidateSet('INFO', 'OK', 'WARN', 'ERREUR')][string]$Niveau = 'INFO')
    $ligne = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Niveau, $Message
    $couleur = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERREUR = 'Red' }[$Niveau]
    Write-Host $ligne -ForegroundColor $couleur
    Add-Content -Path $FichierLog -Value $ligne -Encoding UTF8
}

function Invoke-Etape {
    param([string]$Nom, [scriptblock]$Action)
    # Stop : une erreur « non bloquante » (ex. Set-GPRegistryValue) est aussi comptée comme échec
    $ErrorActionPreference = 'Stop'
    try   { & $Action; Write-Journal "$Nom : OK" 'OK' }
    catch { $script:NbErreurs++; Write-Journal "$Nom : $($_.Exception.Message)" 'ERREUR' }
}

function Get-GpoLiee {
    # Crée la GPO si besoin et la lie à la cible si elle ne l'est pas déjà
    param([string]$Nom, [string]$Cible, [string]$Commentaire)
    $gpo = Get-GPO -Name $Nom -ErrorAction SilentlyContinue
    if (-not $gpo) { $gpo = New-GPO -Name $Nom -Comment $Commentaire }
    $liens = (Get-GPInheritance -Target $Cible).GpoLinks
    if (-not ($liens | Where-Object DisplayName -eq $Nom)) {
        New-GPLink -Name $Nom -Target $Cible -LinkEnabled Yes | Out-Null
    }
    return $gpo
}
#endregion

Import-Module ActiveDirectory, GroupPolicy
$DomaineDN = (Get-ADDomain).DistinguishedName
Write-Journal '===== Stratégies de groupe Nordis ====='

# 1. Politique de mot de passe : modifiée dans la Default Domain Policy (sinon elle écraserait nos valeurs)
Invoke-Etape 'Politique de mot de passe (Default Domain Policy)' {
    $idDDP   = '{31B2F340-016D-11D2-945F-00C04FB984F9}'
    $racine  = "\\$Domaine\SYSVOL\$Domaine\Policies\$idDDP"
    $inf     = "$racine\MACHINE\Microsoft\Windows NT\SecEdit\GptTmpl.inf"
    $lignes  = [System.Collections.Generic.List[string]]@(Get-Content -Path $inf -Encoding Unicode)

    foreach ($cle in $PolitiqueMdp.Keys) {
        $nouvelle = "$cle = $($PolitiqueMdp[$cle])"
        $index = -1
        for ($i = 0; $i -lt $lignes.Count; $i++) { if ($lignes[$i] -match "^\s*$cle\s*=") { $index = $i; break } }
        if ($index -ge 0) { $lignes[$index] = $nouvelle; continue }
        $section = -1
        for ($i = 0; $i -lt $lignes.Count; $i++) { if ($lignes[$i] -match '^\[System Access\]') { $section = $i; break } }
        if ($section -ge 0) { $lignes.Insert($section + 1, $nouvelle) }
        else { $lignes.Add('[System Access]'); $lignes.Add($nouvelle) }
    }
    Set-Content -Path $inf -Value $lignes -Encoding Unicode

    # Incrément de version pour que les DC appliquent la modification
    $gptIni  = "$racine\GPT.INI"
    $contenu = Get-Content -Path $gptIni
    $version = [int](($contenu | Select-String -Pattern '^Version=(\d+)').Matches[0].Groups[1].Value) + 1
    ($contenu -replace '^Version=\d+', "Version=$version") | Set-Content -Path $gptIni -Encoding ASCII
    Set-ADObject -Identity "CN=$idDDP,CN=Policies,CN=System,$DomaineDN" -Replace @{ versionNumber = $version }

    # Application immédiate sur l'objet domaine (mêmes valeurs)
    Set-ADDefaultDomainPasswordPolicy -Identity $Domaine `
        -MinPasswordLength $PolitiqueMdp.MinimumPasswordLength -ComplexityEnabled $true `
        -MaxPasswordAge (New-TimeSpan -Days $PolitiqueMdp.MaximumPasswordAge) `
        -MinPasswordAge (New-TimeSpan -Days $PolitiqueMdp.MinimumPasswordAge) `
        -PasswordHistoryCount $PolitiqueMdp.PasswordHistorySize `
        -LockoutThreshold $PolitiqueMdp.LockoutBadCount `
        -LockoutDuration (New-TimeSpan -Minutes $PolitiqueMdp.LockoutDuration) `
        -LockoutObservationWindow (New-TimeSpan -Minutes $PolitiqueMdp.ResetLockoutCount)
}

# 2. USB interdit pour les utilisateurs du Commercial
Invoke-Etape "$GpoUSB -> $OUCommercial" {
    $gpo = Get-GpoLiee -Nom $GpoUSB -Cible "$OUCommercial,$DomaineDN" -Commentaire 'Interdit les clés USB de stockage au service Commercial'
    $cle = 'HKCU\Software\Policies\Microsoft\Windows\RemovableStorageDevices\{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}'
    Set-GPRegistryValue -Guid $gpo.Id -Key $cle -ValueName 'Deny_Read'  -Type DWord -Value 1 | Out-Null
    Set-GPRegistryValue -Guid $gpo.Id -Key $cle -ValueName 'Deny_Write' -Type DWord -Value 1 | Out-Null
    Set-GPRegistryValue -Guid $gpo.Id -Key $cle -ValueName 'Deny_Execute' -Type DWord -Value 1 | Out-Null
}

# 3. AppLocker : installation de logiciels interdite au Commercial
Invoke-Etape "$GpoAppLocker -> $OUPostes" {
    $gpo = Get-GpoLiee -Nom $GpoAppLocker -Cible "$OUPostes,$DomaineDN" -Commentaire 'Interdit .exe (profil, USB) et .msi au groupe Grp_Commercial'
    $sidCommercial = (Get-ADGroup -Identity $GroupeCommercial).SID.Value
    $sidTous       = 'S-1-1-0'
    $id = { '{0}' -f [guid]::NewGuid() }
    $xml = @"
<AppLockerPolicy Version="1">
  <RuleCollection Type="Exe" EnforcementMode="Enabled">
    <FilePathRule Id="$(& $id)" Name="Tous - autoriser" Description="Comportement normal pour les autres services" UserOrGroupSid="$sidTous" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$(& $id)" Name="Commercial - bloquer exe du profil" Description="Telechargements, Bureau, AppData" UserOrGroupSid="$sidCommercial" Action="Deny">
      <Conditions><FilePathCondition Path="%OSDRIVE%\Users\*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$(& $id)" Name="Commercial - bloquer exe amovibles" Description="Cles USB" UserOrGroupSid="$sidCommercial" Action="Deny">
      <Conditions><FilePathCondition Path="%REMOVABLE%\*" /></Conditions>
    </FilePathRule>
  </RuleCollection>
  <RuleCollection Type="Msi" EnforcementMode="Enabled">
    <FilePathRule Id="$(& $id)" Name="Tous - autoriser msi" Description="" UserOrGroupSid="$sidTous" Action="Allow">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>
    <FilePathRule Id="$(& $id)" Name="Commercial - bloquer msi" Description="Aucune installation" UserOrGroupSid="$sidCommercial" Action="Deny">
      <Conditions><FilePathCondition Path="*" /></Conditions>
    </FilePathRule>
  </RuleCollection>
</AppLockerPolicy>
"@
    $fichier = Join-Path $env:TEMP 'nordis_applocker.xml'
    Set-Content -Path $fichier -Value $xml -Encoding UTF8
    Set-AppLockerPolicy -XmlPolicy $fichier -Ldap "LDAP://CN=$($gpo.Id.ToString('B')),CN=Policies,CN=System,$DomaineDN"
    # Service Identité de l'application (obligatoire pour qu'AppLocker s'applique) en automatique
    Set-GPRegistryValue -Guid $gpo.Id -Key 'HKLM\SYSTEM\CurrentControlSet\Services\AppIDSvc' -ValueName 'Start' -Type DWord -Value 2 | Out-Null
}

# 4. Windows Update -> WSUS (SRV02)
Invoke-Etape "$GpoWSUS -> domaine" {
    $gpo = Get-GpoLiee -Nom $GpoWSUS -Cible $DomaineDN -Commentaire 'Mises à jour Windows via WSUS (SRV02)'
    $wu  = 'HKLM\Software\Policies\Microsoft\Windows\WindowsUpdate'
    $au  = "$wu\AU"
    $valeurs = @(
        @{ Cle = $wu; Nom = 'WUServer';       Type = 'String'; Valeur = $UrlWSUS }
        @{ Cle = $wu; Nom = 'WUStatusServer'; Type = 'String'; Valeur = $UrlWSUS }
        @{ Cle = $wu; Nom = 'SetPolicyDrivenUpdateSourceForFeatureUpdates'; Type = 'DWord'; Valeur = 1 }
        @{ Cle = $wu; Nom = 'SetPolicyDrivenUpdateSourceForQualityUpdates'; Type = 'DWord'; Valeur = 1 }
        @{ Cle = $wu; Nom = 'SetPolicyDrivenUpdateSourceForDriverUpdates';  Type = 'DWord'; Valeur = 1 }
        @{ Cle = $wu; Nom = 'SetPolicyDrivenUpdateSourceForOtherUpdates';   Type = 'DWord'; Valeur = 1 }
        @{ Cle = $au; Nom = 'UseWUServer';          Type = 'DWord'; Valeur = 1 }
        @{ Cle = $au; Nom = 'NoAutoUpdate';         Type = 'DWord'; Valeur = 0 }
        @{ Cle = $au; Nom = 'AUOptions';            Type = 'DWord'; Valeur = 4 }
        @{ Cle = $au; Nom = 'ScheduledInstallDay';  Type = 'DWord'; Valeur = 0 }
        @{ Cle = $au; Nom = 'ScheduledInstallTime'; Type = 'DWord'; Valeur = $HeureInstallMAJ }
        @{ Cle = $au; Nom = 'DetectionFrequencyEnabled'; Type = 'DWord'; Valeur = 1 }
        @{ Cle = $au; Nom = 'DetectionFrequency';   Type = 'DWord'; Valeur = 1 }
    )
    foreach ($v in $valeurs) {
        Set-GPRegistryValue -Guid $gpo.Id -Key $v.Cle -ValueName $v.Nom -Type $v.Type -Value $v.Valeur | Out-Null
    }
}

Invoke-Etape 'Application immédiate (gpupdate)' { gpupdate /force | Out-Null }

# 5. Rapport HTML (livrable)
Invoke-Etape 'Export du rapport HTML des GPO' {
    $script:Rapport = Join-Path $DossierRapports ("Rapport_GPO_{0:yyyyMMdd}.html" -f (Get-Date))
    Get-GPOReport -All -ReportType Html -Path $script:Rapport
    Write-Journal "Rapport : $script:Rapport"
}

if ($script:NbErreurs -gt 0) {
    Write-Journal "Terminé avec $($script:NbErreurs) erreur(s). Journal : $FichierLog" 'ERREUR'; exit 1
}
Write-Journal "Terminé sans erreur. Journal : $FichierLog" 'OK'
exit 0
