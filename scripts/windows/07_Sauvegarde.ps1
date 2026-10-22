<#
.SYNOPSIS
    Sauvegarde planifiée des données utilisateurs de SRV02, avec rotation et restauration.

.DESCRIPTION
    Modes :
      Sauvegarder : copie Perso et Partages (droits NTFS inclus) dans E:\Sauvegardes\<date_heure>,
                    puis supprime les sauvegardes au-delà de la rétention.
      Installer   : copie ce script dans C:\Scripts et crée la tâche planifiée quotidienne (compte SYSTEM).
      Restaurer   : remet un fichier ou un dossier depuis une sauvegarde (la plus récente par défaut).
    Code de retour : 0 = succès, 1 = erreur.

.PARAMETER Mode
    Sauvegarder (par défaut) | Installer | Restaurer

.PARAMETER Element
    Restaurer : chemin relatif dans la sauvegarde, ex. 'Partages\Commercial\devis.txt'.

.PARAMETER Sauvegarde
    Restaurer : nom du dossier de sauvegarde (ex. 20261019_1900) ou 'derniere'.

.PARAMETER Destination
    Restaurer : dossier cible. Par défaut, l'emplacement d'origine.

.NOTES
    Auteur  : Thomas Peyrusaubes
    Date    : 2026-10-22
    Version : 1.2-aws
    Projet  : Nordis Distribution - Module A2627_5066
    Exécution : SRV02, en administrateur.
    Limite : la sauvegarde est sur le même volume miroir (E:) que les données. Sur AWS, elle se complète
             par des instantanés EBS des volumes de SRV02 (copie hors de l'instance).

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force ; C:\Scripts\07_Sauvegarde.ps1 -Mode Installer
.EXAMPLE
    C:\Scripts\07_Sauvegarde.ps1 -Mode Restaurer -Element 'Partages\Commercial\devis.txt'
#>
[CmdletBinding()]
param(
    [ValidateSet('Sauvegarder', 'Installer', 'Restaurer')]
    [string]$Mode = 'Sauvegarder',
    [string]$Element,
    [string]$Sauvegarde = 'derniere',
    [string]$Destination
)

#region ---------- Variables ----------
$Sources = [ordered]@{
    Perso    = 'E:\Perso'
    Partages = 'E:\Partages'
}
$DossierSauvegardes = 'E:\Sauvegardes'
$Retention          = 7                 # nombre de sauvegardes conservées
$NomTache           = 'Nordis - Sauvegarde quotidienne'
$HeureTache         = '19:00'           # après la fermeture des bureaux
$DossierInstall     = 'C:\Scripts'
$DossierLogs        = 'C:\Scripts\Logs'
#endregion

#region ---------- Fonctions communes ----------
$script:NbErreurs = 0
New-Item -ItemType Directory -Path $DossierLogs -Force | Out-Null
$Horodatage = Get-Date -Format 'yyyyMMdd_HHmm'
$FichierLog = Join-Path $DossierLogs "07_Sauvegarde_$($Mode)_$Horodatage.log"

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

function Invoke-Robocopy {
    param([string]$Source, [string]$Cible, [string[]]$Options)
    robocopy $Source $Cible @Options /R:1 /W:1 /NP /NDL /LOG+:"$FichierLog.robocopy.txt" | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy a échoué (code $LASTEXITCODE), voir $FichierLog.robocopy.txt" }
}
#endregion

Write-Journal "===== Sauvegarde Nordis - mode $Mode ====="

switch ($Mode) {

    'Sauvegarder' {
        $cible = Join-Path $DossierSauvegardes $Horodatage
        # $cle et non $nom : $Nom est le paramètre d'Invoke-Etape et le masquerait dans le bloc
        foreach ($cle in $Sources.Keys) {
            Invoke-Etape "Copie $cle ($($Sources[$cle]))" {
                if (-not (Test-Path $Sources[$cle])) { throw "source introuvable" }
                Invoke-Robocopy -Source $Sources[$cle] -Cible (Join-Path $cible $cle) -Options @('/E', '/B', '/COPY:DATS', '/DCOPY:DAT')
            }
        }
        Invoke-Etape "Rotation (conserver $Retention sauvegardes)" {
            Get-ChildItem -Path $DossierSauvegardes -Directory | Sort-Object Name -Descending |
                Select-Object -Skip $Retention | Remove-Item -Recurse -Force
        }
        if ($script:NbErreurs -eq 0) {
            $taille = (Get-ChildItem -Path $cible -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
            Write-Journal ("Sauvegarde {0} : {1:N1} Mo" -f $cible, ($taille / 1MB))
        }
    }

    'Installer' {
        Invoke-Etape "Copie du script dans $DossierInstall" {
            New-Item -ItemType Directory -Path $DossierInstall -Force | Out-Null
            # Déjà lancé depuis C:\Scripts : rien à copier
            if ((Split-Path $PSCommandPath -Parent) -ne $DossierInstall) {
                Copy-Item -Path $PSCommandPath -Destination $DossierInstall -Force
            }
        }
        Invoke-Etape "Tâche planifiée '$NomTache' ($HeureTache)" {
            $cheminScript = Join-Path $DossierInstall (Split-Path $PSCommandPath -Leaf)
            $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                         -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$cheminScript`" -Mode Sauvegarder"
            $declench  = New-ScheduledTaskTrigger -Daily -At $HeureTache
            $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
            $reglages  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
            Register-ScheduledTask -TaskName $NomTache -Action $action -Trigger $declench `
                                   -Principal $principal -Settings $reglages -Force | Out-Null
        }
        Write-Journal "Test immédiat : Start-ScheduledTask -TaskName '$NomTache'"
    }

    'Restaurer' {
        Invoke-Etape "Restauration de '$Element'" {
            if (-not $Element) { throw 'précise -Element, ex. Partages\Commercial\devis.txt' }
            $dossierSauv = if ($Sauvegarde -eq 'derniere') {
                Get-ChildItem -Path $DossierSauvegardes -Directory | Sort-Object Name -Descending | Select-Object -First 1
            } else { Get-Item -Path (Join-Path $DossierSauvegardes $Sauvegarde) }
            if (-not $dossierSauv) { throw 'aucune sauvegarde trouvée' }

            $source = Join-Path $dossierSauv.FullName $Element
            if (-not (Test-Path $source)) { throw "absent de la sauvegarde $($dossierSauv.Name) : $Element" }

            if (-not $Destination) {
                $racine, $reste = $Element -split '\\', 2
                if (-not $Sources.Contains($racine)) { throw "le chemin doit commencer par : $($Sources.Keys -join ' ou ')" }
                $cheminOrigine = if ($reste) { Join-Path $Sources[$racine] $reste } else { $Sources[$racine] }
                $Destination = Split-Path $cheminOrigine -Parent
            }
            $item = Get-Item -Path $source
            if ($item.PSIsContainer) {
                Invoke-Robocopy -Source $source -Cible (Join-Path $Destination $item.Name) -Options @('/E', '/B', '/COPY:DATS')
            }
            else {
                Invoke-Robocopy -Source $item.DirectoryName -Cible $Destination -Options @($item.Name, '/B', '/COPY:DATS')
            }
            Write-Journal "Restauré depuis $($dossierSauv.Name) vers $Destination"
        }
    }
}

if ($script:NbErreurs -gt 0) {
    Write-Journal "Terminé avec $($script:NbErreurs) erreur(s). Journal : $FichierLog" 'ERREUR'; exit 1
}
Write-Journal "Terminé sans erreur. Journal : $FichierLog" 'OK'
exit 0
