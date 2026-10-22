<#
.SYNOPSIS
    Crée les utilisateurs Nordis dans l'Active Directory, avec leur dossier personnel, depuis un CSV ou en interactif.

.DESCRIPTION
    Pour chaque utilisateur :
      - crée le compte dans l'OU de son service (OU créée si absente),
      - l'ajoute à son groupe de service (Grp_*),
      - crée son dossier personnel \\SRV02\Perso$\<login> (droit Modifier pour lui seul) monté en H:,
      - associe le script de connexion lecteurs.bat (lecteurs réseau S: à W:),
      - impose le changement du mot de passe initial à la première connexion.
    Les comptes déjà présents sont ignorés (le script peut être relancé sans risque).
    Code de retour : 0 = succès, 1 = au moins une erreur, 2 = CSV invalide.

.PARAMETER CheminCsv
    Chemin du fichier CSV (séparateur ; ou , détecté automatiquement, encodage UTF-8).

.PARAMETER Interactif
    Saisie d'un utilisateur au clavier au lieu du CSV.

.NOTES
    Auteur  : Thomas Peyrusaubes
    Date    : 2026-10-21
    Version : 1.2-aws (identique à la version Hyper-V, erreurs non bloquantes comptées)
    Projet  : Nordis Distribution - Module A2627_5066
    Exécution : DC01 ou CLI01 (RSAT), avec un compte administrateur du domaine.
                À lancer AVANT 06_GPO.ps1 (politique de mots de passe plus stricte ensuite).

.EXAMPLE
    Set-ExecutionPolicy -Scope Process Bypass -Force ; C:\Scripts\05_Utilisateurs_AD.ps1 -CheminCsv C:\Scripts\utilisateurs_nordis.csv
.EXAMPLE
    .\05_Utilisateurs_AD.ps1 -Interactif
#>
[CmdletBinding(DefaultParameterSetName = 'Csv')]
param(
    [Parameter(ParameterSetName = 'Csv', Mandatory)]
    [string]$CheminCsv,

    [Parameter(ParameterSetName = 'Interactif', Mandatory)]
    [switch]$Interactif
)

#region ---------- Variables ----------
$SuffixeUPN       = 'nordis.fr'                # UPN par défaut en mode interactif : login@nordis.fr
$BaseOUUtilisateurs = 'OU=Nordis'               # OU des services : OU=<Service>,OU=Nordis (complété par le DN du domaine)
$RacinePerso      = '\\SRV02\Perso$'
$LecteurPerso     = 'H:'
$ScriptConnexion  = 'lecteurs.bat'
$ChangerMdp       = $true

# Correspondance colonnes du CSV -> champs (en-têtes de utilisateurs_nordis.csv fourni par la DSI)
$Colonnes = [ordered]@{
    Prenom     = 'Prenom'
    Nom        = 'Nom'
    Service    = 'Service'
    Fonction   = 'Fonction'
    Login      = 'SamAccountName'
    UPN        = 'UserPrincipalName'
    Mail       = 'Mail'
    OU         = 'OU'
    Groupe     = 'Groupe'
    MotDePasse = 'MotDePasseInitial'
}

$DossierLogs = 'C:\Scripts\Logs'
#endregion

#region ---------- Fonctions communes ----------
New-Item -ItemType Directory -Path $DossierLogs -Force | Out-Null
$FichierLog = Join-Path $DossierLogs ("05_Utilisateurs_AD_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))
$Compteurs = @{ Crees = 0; Ignores = 0; Erreurs = 0 }

function Write-Journal {
    param([string]$Message, [ValidateSet('INFO', 'OK', 'WARN', 'ERREUR')][string]$Niveau = 'INFO')
    $ligne = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Niveau, $Message
    $couleur = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERREUR = 'Red' }[$Niveau]
    Write-Host $ligne -ForegroundColor $couleur
    Add-Content -Path $FichierLog -Value $ligne -Encoding UTF8
}
#endregion

Import-Module ActiveDirectory -ErrorAction Stop
$DomaineDN = (Get-ADDomain).DistinguishedName
$OUBase    = "$BaseOUUtilisateurs,$DomaineDN"

function Resolve-OU {
    # Accepte un DN complet (OU=Commercial,OU=Nordis,DC=...) ou un simple nom d'OU de service.
    # L'OU est créée si elle n'existe pas et que son parent existe.
    param([string]$Valeur)
    if ($Valeur -like 'OU=*') {
        $dn = if ($Valeur -like '*DC=*') { $Valeur } else { "$Valeur,$DomaineDN" }
    }
    else {
        $dn = "OU=$Valeur,$OUBase"
    }
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue)) {
        $nom, $parent = $dn -split '(?<!\\),', 2
        $nom = $nom -replace '^OU=', ''
        if (-not (Get-ADObject -Filter "DistinguishedName -eq '$parent'" -ErrorAction SilentlyContinue)) {
            throw "OU parente introuvable : $parent (as-tu lancé 01_DC01.ps1 ?)"
        }
        New-ADOrganizationalUnit -Name $nom -Path $parent -ProtectedFromAccidentalDeletion $true
        Write-Journal "OU créée : $dn"
    }
    return $dn
}

function New-UtilisateurNordis {
    param(
        [string]$Prenom, [string]$Nom, [string]$Service, [string]$Fonction,
        [string]$Login, [string]$UPN, [string]$Mail, [string]$OU, [string]$Groupe,
        [System.Security.SecureString]$MotDePasse
    )
    # Stop : une erreur « non bloquante » (ex. Add-ADGroupMember) est aussi comptée comme échec
    $ErrorActionPreference = 'Stop'
    try {
        if (-not $Login) { throw 'login vide' }
        if (Get-ADUser -Filter "SamAccountName -eq '$Login'" -ErrorAction SilentlyContinue) {
            Write-Journal "$Login existe déjà : ignoré" 'WARN'; $Compteurs.Ignores++; return
        }
        if (-not $UPN)  { $UPN = "$Login@$SuffixeUPN" }
        $cheminOU = Resolve-OU -Valeur $(if ($OU) { $OU } else { $Service })

        $parametres = @{
            Name                  = "$Prenom $Nom"
            DisplayName           = "$Prenom $Nom"
            GivenName             = $Prenom
            Surname               = $Nom
            SamAccountName        = $Login
            UserPrincipalName     = $UPN
            Path                  = $cheminOU
            AccountPassword       = $MotDePasse
            ChangePasswordAtLogon = $ChangerMdp
            Enabled               = $true
            ScriptPath            = $ScriptConnexion
        }
        if ($Mail)     { $parametres.EmailAddress = $Mail }
        if ($Fonction) { $parametres.Title = $Fonction }
        if ($Service)  { $parametres.Department = $Service }
        New-ADUser @parametres

        if ($Groupe) {
            if (Get-ADGroup -Filter "Name -eq '$Groupe'" -ErrorAction SilentlyContinue) {
                Add-ADGroupMember -Identity $Groupe -Members $Login
            }
            else { Write-Journal "$Login : groupe $Groupe introuvable" 'WARN' }
        }

        # Dossier personnel
        if (Test-Path $RacinePerso) {
            $dossier = Join-Path $RacinePerso $Login
            New-Item -ItemType Directory -Path $dossier -Force | Out-Null
            $sid = (Get-ADUser -Identity $Login).SID
            $acl = Get-Acl -Path $dossier
            $regle = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($regle)
            Set-Acl -Path $dossier -AclObject $acl
            Set-ADUser -Identity $Login -HomeDirectory $dossier -HomeDrive $LecteurPerso
        }
        else { Write-Journal "$Login : $RacinePerso inaccessible, dossier personnel non créé" 'WARN' }

        Write-Journal "$Login créé ($Service / $Groupe)" 'OK'
        $Compteurs.Crees++
    }
    catch {
        Write-Journal "$Login : $($_.Exception.Message)" 'ERREUR'
        $Compteurs.Erreurs++
    }
}

Write-Journal "===== Création des utilisateurs ($($PSCmdlet.ParameterSetName)) ====="

if ($Interactif) {
    do {
        $p = @{}
        foreach ($champ in 'Prenom', 'Nom', 'Service', 'Fonction', 'Login', 'Groupe') {
            $p[$champ] = (Read-Host $champ).Trim()
        }
        $p['MotDePasse'] = Read-Host 'Mot de passe initial' -AsSecureString
        New-UtilisateurNordis @p
        $encore = Read-Host 'Créer un autre utilisateur ? (o/N)'
    } while ($encore -match '^[oOyY]')
}
else {
    if (-not (Test-Path $CheminCsv)) { Write-Journal "CSV introuvable : $CheminCsv" 'ERREUR'; exit 2 }
    $premiere = Get-Content -Path $CheminCsv -TotalCount 1 -Encoding UTF8
    $separateur = if ($premiere -match ';') { ';' } else { ',' }
    $lignes = @(Import-Csv -Path $CheminCsv -Delimiter $separateur -Encoding UTF8)
    if ($lignes.Count -eq 0) { Write-Journal 'CSV vide' 'ERREUR'; exit 2 }

    $entetes = $lignes[0].PSObject.Properties.Name
    $manquantes = @('Prenom', 'Nom', 'Login', 'MotDePasse' | Where-Object { $entetes -notcontains $Colonnes[$_] })
    if ($manquantes.Count -gt 0) {
        Write-Journal "Colonnes absentes : $($manquantes -join ', '). En-têtes trouvés : $($entetes -join ', ')" 'ERREUR'
        Write-Journal 'Adapte la table $Colonnes en haut du script.' 'ERREUR'
        exit 2
    }

    # Contrôle : les mots de passe du CSV respectent-ils la politique du domaine ?
    $longueurMin = (Get-ADDefaultDomainPasswordPolicy).MinPasswordLength
    $tropCourts = @($lignes | Where-Object { "$($_.($Colonnes.MotDePasse))".Length -lt $longueurMin })
    if ($tropCourts.Count -gt 0) {
        Write-Journal "$($tropCourts.Count) mot(s) de passe du CSV font moins de $longueurMin caractères (politique du domaine)." 'ERREUR'
        Write-Journal 'Lance ce script AVANT 06_GPO.ps1, ou allonge les mots de passe initiaux du CSV.' 'ERREUR'
        exit 2
    }

    foreach ($l in $lignes) {
        $v = @{}
        foreach ($champ in $Colonnes.Keys) {
            $col = $Colonnes[$champ]
            $v[$champ] = if ($entetes -contains $col) { "$($l.$col)".Trim() } else { '' }
        }
        $mdp = ConvertTo-SecureString -String $v.MotDePasse -AsPlainText -Force
        New-UtilisateurNordis -Prenom $v.Prenom -Nom $v.Nom -Service $v.Service -Fonction $v.Fonction `
                              -Login $v.Login -UPN $v.UPN -Mail $v.Mail -OU $v.OU -Groupe $v.Groupe -MotDePasse $mdp
    }
}

$bilan = "Bilan : $($Compteurs.Crees) créé(s), $($Compteurs.Ignores) ignoré(s), $($Compteurs.Erreurs) erreur(s). Journal : $FichierLog"
if ($Compteurs.Erreurs -gt 0) { Write-Journal $bilan 'ERREUR'; exit 1 }
Write-Journal $bilan 'OK'
exit 0
