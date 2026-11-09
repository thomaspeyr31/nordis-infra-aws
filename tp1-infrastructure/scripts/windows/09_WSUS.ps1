<#
.SYNOPSIS
    Installe et configure WSUS sur SRV02 (Server Core), puis suit l'état des clients.

.DESCRIPTION
    Mode Installer (par défaut) :
      1. Rôle WSUS avec base interne Windows (WID) et outils PowerShell.
      2. Post-installation : contenu des mises à jour stocké sur E:\WSUS (volume miroir).
      3. Pool IIS WsusPool : limite mémoire levée (évite les plantages de la console).
      4. Pare-feu Windows : port 8530 ouvert pour le profil Domaine.
      5. Source Microsoft Update, langues français + anglais.
      6. Synchronisation des catégories, puis produits et classifications limités :
         Windows Server 2025 (« Microsoft Server Operating System-24H2 »),
         mises à jour critiques et de sécurité. Synchronisation automatique 1 fois par jour.
      7. Règle d'approbation automatique (critiques + sécurité -> tous les ordinateurs).
      8. Lancement de la synchronisation complète (en arrière-plan, plusieurs heures).
    Mode Etat :
      Affiche l'état de la synchronisation, applique la règle d'approbation et donne,
      pour chaque ordinateur, le pourcentage de mises à jour installées.
    Code de retour : 0 = succès, 1 = au moins une erreur.

.PARAMETER Mode
    Installer (par défaut) | Etat

.NOTES
    Auteur  : Thomas Peyrusaubes
    Date    : 2026-10-22
    Version : 1.2-aws
    Projet  : Nordis Distribution - Module A2627_5066
    Exécution : SRV02, en NORDIS\Administrator.
                Les clients sont dirigés vers WSUS par la GPO_WSUS (06_GPO.ps1).
    AWS : les serveurs viennent d'images AWS en anglais, d'où l'anglais en plus du français.

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force ; C:\Scripts\09_WSUS.ps1
.EXAMPLE
    C:\Scripts\09_WSUS.ps1 -Mode Etat
#>
[CmdletBinding()]
param(
    [ValidateSet('Installer', 'Etat')]
    [string]$Mode = 'Installer'
)

#region ---------- Variables ----------
$DossierContenu   = 'E:\WSUS'
$PortWSUS         = 8530
$Langues          = @('fr', 'en')
$Produits         = @('Microsoft Server Operating System-24H2')     # Windows Server 2025
$Classifications  = @('Critical Updates', 'Security Updates')
$HeureSyncUTC     = 1                                               # 1 h UTC = 3 h à Paris (heure d'été)
$NomRegle         = 'Nordis - critiques et sécurité'
$NomRegleParefeu  = 'Nordis - WSUS HTTP 8530'
$DelaiCategories  = 45                                              # minutes max pour la 1re synchro
$DossierLogs      = 'C:\Scripts\Logs'
#endregion

#region ---------- Fonctions communes ----------
$script:NbErreurs = 0
New-Item -ItemType Directory -Path $DossierLogs -Force | Out-Null
$FichierLog = Join-Path $DossierLogs ("09_WSUS_{0}_{1:yyyyMMdd_HHmmss}.log" -f $Mode, (Get-Date))

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

function Exit-Script {
    if ($script:NbErreurs -gt 0) {
        Write-Journal "Terminé avec $($script:NbErreurs) erreur(s). Journal : $FichierLog" 'ERREUR'; exit 1
    }
    Write-Journal "Terminé sans erreur. Journal : $FichierLog" 'OK'; exit 0
}

function Get-RegleApprobation {
    # Crée (ou reprend) la règle d'approbation automatique et la règle sur classifications + produits
    $regle = $script:Wsus.GetInstallApprovalRules() | Where-Object Name -eq $NomRegle
    if (-not $regle) { $regle = $script:Wsus.CreateInstallApprovalRule($NomRegle) }
    $classes = New-Object Microsoft.UpdateServices.Administration.UpdateClassificationCollection
    $script:Wsus.GetUpdateClassifications() | Where-Object Title -in $Classifications | ForEach-Object { [void]$classes.Add($_) }
    $categories = New-Object Microsoft.UpdateServices.Administration.UpdateCategoryCollection
    $script:Wsus.GetUpdateCategories() | Where-Object Title -in $Produits | ForEach-Object { [void]$categories.Add($_) }
    $groupes = New-Object Microsoft.UpdateServices.Administration.ComputerTargetGroupCollection
    [void]$groupes.Add($script:Wsus.GetComputerTargetGroup([Microsoft.UpdateServices.Administration.ComputerTargetGroupId]::AllComputers))
    $regle.SetUpdateClassifications($classes)
    $regle.SetCategories($categories)
    $regle.SetComputerTargetGroups($groupes)
    $regle.Enabled = $true
    $regle.Save()
    return $regle
}
#endregion

Write-Journal "===== WSUS sur $env:COMPUTERNAME - mode $Mode ====="

if ($Mode -eq 'Installer') {
    Invoke-Etape 'Rôle WSUS (base interne WID + outils PowerShell)' {
        if (-not (Test-Path 'E:\')) { throw 'volume E: introuvable : lance d''abord 03_SRV02.ps1' }
        $resultat = Install-WindowsFeature -Name UpdateServices-Services, UpdateServices-WidDB, UpdateServices-API -IncludeManagementTools
        if (-not $resultat.Success) { throw "installation incomplète (code : $($resultat.ExitCode))" }
    }

    Invoke-Etape "Post-installation : contenu dans $DossierContenu" {
        $setup = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Update Services\Server\Setup' -ErrorAction SilentlyContinue
        if ($setup.ContentDir -ne $DossierContenu) {
            New-Item -ItemType Directory -Path $DossierContenu -Force | Out-Null
            & "$env:ProgramFiles\Update Services\Tools\wsusutil.exe" postinstall "CONTENT_DIR=$DossierContenu" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "wsusutil postinstall a échoué (code $LASTEXITCODE)" }
        }
    }

    Invoke-Etape 'IIS : pool WsusPool sans limite mémoire' {
        $appcmd = "$env:windir\System32\inetsrv\appcmd.exe"
        & $appcmd set apppool WsusPool /recycling.periodicRestart.privateMemory:0 /queueLength:2000 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "appcmd a échoué (code $LASTEXITCODE)" }
    }

    Invoke-Etape "Pare-feu Windows : port $PortWSUS (profil Domaine)" {
        if (-not (Get-NetFirewallRule -DisplayName $NomRegleParefeu -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $NomRegleParefeu -Direction Inbound -Protocol TCP `
                                -LocalPort $PortWSUS -Action Allow -Profile Domain | Out-Null
        }
    }

    Invoke-Etape "Source Microsoft Update, langues $($Langues -join ' + ')" {
        $script:Wsus = Get-WsusServer
        Set-WsusServerSynchronization -SyncFromMU | Out-Null
        $config = $script:Wsus.GetConfiguration()
        $config.AllUpdateLanguagesEnabled = $false
        $config.SetEnabledUpdateLanguages([string[]]$Langues)
        $config.OobeInitialized = $true            # assistant de 1re configuration considéré comme fait
        # Métadonnées seulement : les clients téléchargent les fichiers chez Microsoft Update.
        # Sans ce réglage, les mises à jour cumulatives (plusieurs Go chacune) remplissent E:
        # et bloquent les partages (constaté le 22/10 : E: plein en 1 h).
        $config.HostBinariesOnMicrosoftUpdate = $true
        $config.Save()
    }

    Invoke-Etape "Synchronisation des catégories (jusqu'à $DelaiCategories min)" {
        $abonnement = $script:Wsus.GetSubscription()
        $dejaFait = $script:Wsus.GetUpdateCategories() | Where-Object Title -in $Produits
        if (-not $dejaFait) {
            $abonnement.StartSynchronizationForCategoryOnly()
            $fin = (Get-Date).AddMinutes($DelaiCategories)
            Start-Sleep -Seconds 15
            while ($abonnement.GetSynchronizationStatus() -ne 'NotProcessing') {
                if ((Get-Date) -gt $fin) { throw 'délai dépassé : relance le script plus tard' }
                $p = $abonnement.GetSynchronizationProgress()
                Write-Journal ("  catégories : {0} / {1}" -f $p.ProcessedItems, $p.TotalItems)
                Start-Sleep -Seconds 30
            }
            $resultat = $abonnement.GetLastSynchronizationInfo().Result
            if ("$resultat" -ne 'Succeeded') { throw "synchronisation des catégories : $resultat" }
        }
    }

    Invoke-Etape "Produits ($($Produits -join ', ')) et classifications ($($Classifications -join ', '))" {
        $abonnement = $script:Wsus.GetSubscription()
        $categories = New-Object Microsoft.UpdateServices.Administration.UpdateCategoryCollection
        $script:Wsus.GetUpdateCategories() | Where-Object Title -in $Produits | ForEach-Object { [void]$categories.Add($_) }
        if ($categories.Count -ne $Produits.Count) {
            $proches = ($script:Wsus.GetUpdateCategories() | Where-Object Title -like '*Server Operating System*').Title -join ' | '
            throw "produit introuvable. Produits serveur proposés : $proches"
        }
        $classes = New-Object Microsoft.UpdateServices.Administration.UpdateClassificationCollection
        $script:Wsus.GetUpdateClassifications() | Where-Object Title -in $Classifications | ForEach-Object { [void]$classes.Add($_) }
        if ($classes.Count -ne $Classifications.Count) { throw 'classification introuvable' }
        $abonnement.SetUpdateCategories($categories)
        $abonnement.SetUpdateClassifications($classes)
        $abonnement.SynchronizeAutomatically = $true
        $abonnement.SynchronizeAutomaticallyTimeOfDay = New-TimeSpan -Hours $HeureSyncUTC
        $abonnement.NumberOfSynchronizationsPerDay = 1
        $abonnement.Save()
    }

    Invoke-Etape "Règle d'approbation automatique « $NomRegle »" { Get-RegleApprobation | Out-Null }

    Invoke-Etape 'Lancement de la synchronisation complète (en arrière-plan)' {
        $abonnement = $script:Wsus.GetSubscription()
        if ($abonnement.GetSynchronizationStatus() -eq 'NotProcessing') { $abonnement.StartSynchronization() }
    }

    Write-Journal 'La synchronisation continue seule (souvent 1 à 3 h). Suivi : C:\Scripts\09_WSUS.ps1 -Mode Etat'
    Exit-Script
}

# ---------- Mode Etat ----------
Invoke-Etape 'Connexion à WSUS' { $script:Wsus = Get-WsusServer }

Invoke-Etape 'Synchronisation' {
    $abonnement = $script:Wsus.GetSubscription()
    $statut = $abonnement.GetSynchronizationStatus()
    if ("$statut" -ne 'NotProcessing') {
        $p = $abonnement.GetSynchronizationProgress()
        Write-Journal ("  en cours : {0} / {1} éléments" -f $p.ProcessedItems, $p.TotalItems) 'WARN'
    }
    else {
        $info = $abonnement.GetLastSynchronizationInfo()
        Write-Journal ("  dernière synchronisation : {0:dd/MM HH:mm} (UTC) - {1}" -f $info.EndTime, $info.Result)
    }
}

Invoke-Etape 'Application de la règle d''approbation' {
    if ("$($script:Wsus.GetSubscription().GetSynchronizationStatus())" -eq 'NotProcessing') {
        (Get-RegleApprobation).ApplyRule()
    }
    else { Write-Journal '  reportée : synchronisation encore en cours' 'WARN' }
}

Invoke-Etape 'État des ordinateurs' {
    $ordinateurs = @($script:Wsus.GetComputerTargets())
    if ($ordinateurs.Count -eq 0) {
        Write-Journal '  aucun ordinateur inscrit : sur le client, gpupdate /force puis usoclient StartScan' 'WARN'
    }
    foreach ($o in $ordinateurs) {
        $r = $o.GetUpdateInstallationSummary()
        $total = $r.InstalledCount + $r.NotInstalledCount + $r.DownloadedCount + $r.FailedCount + $r.InstalledPendingRebootCount
        $pct = if ($total -gt 0) { [math]::Round(100 * $r.InstalledCount / $total) } else { 100 }
        Write-Journal ("  {0,-26} {1,3} %  (installées {2}, à installer {3}, redémarrage {4}, échecs {5}) - dernier rapport {6:dd/MM HH:mm}" -f `
            $o.FullDomainName, $pct, $r.InstalledCount, ($r.NotInstalledCount + $r.DownloadedCount),
            $r.InstalledPendingRebootCount, $r.FailedCount, $o.LastReportedStatusTime)
    }
}

Exit-Script
