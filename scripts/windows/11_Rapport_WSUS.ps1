<#
.SYNOPSIS
    Rapport d'état WSUS (livrable n°5) : état des mises à jour de chaque ordinateur, en HTML imprimable en PDF.

.DESCRIPTION
    Se connecte au serveur WSUS (SRV02) et produit une page HTML :
      - serveur, date, dernière synchronisation, produits et classifications suivis ;
      - nombre de mises à jour connues et approuvées ;
      - pour chaque ordinateur : système, dernier rapport, mises à jour installées, à installer,
        en attente de redémarrage, en échec, et pourcentage de conformité.
    Le fichier HTML s'imprime en PDF depuis n'importe quel navigateur (Ctrl/Cmd + P).
    Code de retour : 0 = succès, 1 = erreur.

.PARAMETER ServeurWSUS
    Nom du serveur WSUS (par défaut srv02.ad.nordis.test).

.PARAMETER Destination
    Dossier du rapport. Par défaut : le dossier du Mac partagé dans la session RDP, sinon C:\Scripts\Rapports.

.NOTES
    Auteur  : Thomas Peyrusaubes
    Date    : 2026-10-22
    Version : 1.0
    Projet  : Nordis Distribution - Module A2627_5066
    Exécution : CLI01 (console WSUS installée par 04_CLI01.ps1) ou SRV02, en administrateur du domaine.

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force ; C:\Scripts\11_Rapport_WSUS.ps1
#>
[CmdletBinding()]
param(
    [string]$ServeurWSUS = 'srv02.ad.nordis.test',
    [int]$Port = 8530,
    [string]$Destination
)

#region ---------- Variables ----------
$DossierPartageMac = '\\tsclient\infra_nordis_aws\Livrables'
$DossierLocal      = 'C:\Scripts\Rapports'
$Organisation      = 'Nordis Distribution'
#endregion

$ErrorActionPreference = 'Stop'
try {
    if (-not $Destination) {
        $Destination = if (Test-Path (Split-Path $DossierPartageMac -Parent)) { $DossierPartageMac } else { $DossierLocal }
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    [void][Reflection.Assembly]::LoadWithPartialName('Microsoft.UpdateServices.Administration')
    $wsus = [Microsoft.UpdateServices.Administration.AdminProxy]::GetUpdateServer($ServeurWSUS, $false, $Port)
    $abonnement = $wsus.GetSubscription()
    $derniere   = $abonnement.GetLastSynchronizationInfo()
    $produits   = ($abonnement.GetUpdateCategories() | ForEach-Object Title) -join ', '
    $classes    = ($abonnement.GetUpdateClassifications() | ForEach-Object Title) -join ', '
    $langues    = ($wsus.GetConfiguration().GetEnabledUpdateLanguages()) -join ', '

    $etendue = New-Object Microsoft.UpdateServices.Administration.UpdateScope
    $etendue.ApprovedStates = [Microsoft.UpdateServices.Administration.ApprovedStates]::LatestRevisionApproved
    $nbApprouvees = $wsus.GetUpdateCount($etendue)
    $nbConnues    = $wsus.GetUpdateCount((New-Object Microsoft.UpdateServices.Administration.UpdateScope))

    $lignes = foreach ($o in ($wsus.GetComputerTargets() | Sort-Object FullDomainName)) {
        $r = $o.GetUpdateInstallationSummary()
        $aInstaller = $r.NotInstalledCount + $r.DownloadedCount
        $total = $r.InstalledCount + $aInstaller + $r.FailedCount + $r.InstalledPendingRebootCount
        $pct = if ($total -gt 0) { [math]::Round(100 * $r.InstalledCount / $total) } else { 100 }
        [pscustomobject]@{
            'Ordinateur'          = $o.FullDomainName
            'Système'             = $o.OSDescription
            'Adresse IP'          = $o.IPAddress
            'Dernier rapport'     = '{0:dd/MM/yyyy HH:mm}' -f $o.LastReportedStatusTime.ToLocalTime()
            'Installées'          = $r.InstalledCount
            'À installer'         = $aInstaller
            'Redémarrage attendu' = $r.InstalledPendingRebootCount
            'Échecs'              = $r.FailedCount
            'Conformité'          = "$pct %"
        }
    }
    $nbConformes = @($lignes | Where-Object Conformité -eq '100 %').Count

    $css = @"
body { font-family: Segoe UI, Arial, sans-serif; margin: 32px; color: #16202b; }
h1 { font-size: 22px; margin-bottom: 4px; } h2 { font-size: 16px; margin-top: 28px; }
p.sous { color: #555; margin-top: 0; }
table { border-collapse: collapse; width: 100%; font-size: 12px; }
th, td { border: 1px solid #c9ced6; padding: 6px 8px; text-align: left; }
th { background: #eef1f5; }
td:last-child { font-weight: bold; }
.resume td:first-child { width: 260px; background: #f7f8fa; font-weight: bold; }
"@
    $resume = @(
        [pscustomobject]@{ Élément = 'Serveur WSUS';                 Valeur = "$ServeurWSUS (port $Port)" }
        [pscustomobject]@{ Élément = 'Dernière synchronisation';     Valeur = ('{0:dd/MM/yyyy HH:mm} - {1}' -f $derniere.EndTime.ToLocalTime(), $derniere.Result) }
        [pscustomobject]@{ Élément = 'Produits suivis';              Valeur = $produits }
        [pscustomobject]@{ Élément = 'Classifications';              Valeur = $classes }
        [pscustomobject]@{ Élément = 'Langues';                      Valeur = $langues }
        [pscustomobject]@{ Élément = 'Mises à jour connues / approuvées'; Valeur = "$nbConnues / $nbApprouvees" }
        [pscustomobject]@{ Élément = 'Ordinateurs à 100 %';          Valeur = "$nbConformes sur $(@($lignes).Count)" }
    )
    $date = Get-Date
    $html = ConvertTo-Html -Title "Rapport d'état WSUS - $Organisation" -Head "<style>$css</style>" -Body @(
        "<h1>Rapport d'état WSUS - $Organisation</h1>"
        "<p class='sous'>Généré le $('{0:dd/MM/yyyy à HH:mm}' -f $date) par $env:USERDOMAIN\$env:USERNAME depuis $env:COMPUTERNAME</p>"
        '<h2>Synthèse</h2>'
        ($resume | ConvertTo-Html -Fragment) -replace '<table>', "<table class='resume'>" -replace '<tr><th>.*?</th></tr>', ''
        '<h2>État des ordinateurs</h2>'
        ($lignes | ConvertTo-Html -Fragment)
    )
    $fichier = Join-Path $Destination ('Rapport_WSUS_{0:yyyyMMdd_HHmm}.html' -f $date)
    $html | Set-Content -Path $fichier -Encoding UTF8
    $lignes | Format-Table Ordinateur, Installées, 'À installer', Échecs, Conformité -AutoSize | Out-Host
    Write-Host "Rapport : $fichier" -ForegroundColor Green
    Write-Host 'Ouvre-le dans un navigateur puis imprime-le en PDF (Ctrl/Cmd + P).' -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "ERREUR : $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
