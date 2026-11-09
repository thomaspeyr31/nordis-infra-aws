<#
.SYNOPSIS
    Centralise les journaux Windows sur SRV02 (Windows Event Forwarding).

.DESCRIPTION
    Deux modes, à lancer dans cet ordre :
      Collecteur (sur SRV02) : active le service Windows Event Collector et crée l'abonnement
                               « Nordis-Securite » (mode initié par la source) : connexions, échecs,
                               verrouillages, gestion des comptes et des groupes, erreurs système.
      GPO        (sur CLI01) : crée GPO_WEF_Sources, liée aux contrôleurs de domaine et aux serveurs :
                               adresse du collecteur + droit de lecture du journal Sécurité pour
                               le compte Service réseau (utilisé par le transfert), puis applique
                               la GPO à distance sur DC01, DC02 et SRV02 (gpupdate via WinRM).
    Résultat consultable sur SRV02 : journal « Événements transférés » (ForwardedEvents).

.PARAMETER Mode
    Collecteur | GPO

.NOTES
    Auteur  : Thomas Peyrusaubes
    Date    : 2026-10-22
    Version : 1.2-aws
    Projet  : Nordis Distribution - Module A2627_5066
    Exécution : en administrateur du domaine.
    AWS : événements rendus en anglais (en-US), langue des images Windows d'AWS.

.EXAMPLE
    C:\Scripts\08_WEF.ps1 -Mode Collecteur     # sur SRV02
    C:\Scripts\08_WEF.ps1 -Mode GPO            # sur CLI01 (ou DC01)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Collecteur', 'GPO')]
    [string]$Mode
)

#region ---------- Variables ----------
$Collecteur       = 'srv02.ad.nordis.test'
$PortWinRM        = 5985
$Rafraichissement = 60                                  # secondes entre deux vérifications des sources
$NomAbonnement    = 'Nordis-Securite'
$NomGpo           = 'GPO_WEF_Sources'
$CiblesGpo        = @('OU=Domain Controllers', 'OU=Serveurs,OU=Ordinateurs,OU=Nordis')   # complétées par le DN du domaine
$Sources          = @('dc01', 'dc02', 'srv02')          # gpupdate à distance après création de la GPO
$Langue           = 'en-US'                             # langue d'affichage des événements transférés

# Événements collectés (journal Sécurité) : ouvertures de session interactives/RDP réussies,
# échecs, verrouillages et déverrouillages, gestion des comptes et des groupes
$EvenementsSecurite = '4625 or EventID=4740 or EventID=4767 or EventID=4720 or EventID=4722 or EventID=4725 or EventID=4726 or EventID=4728 or EventID=4732 or EventID=4756'
# Lecture du journal Sécurité : SYSTEM, Administrateurs, Lecteurs des journaux, Service réseau (S-1-5-20)
$SddlJournalSecurite = 'O:BAG:SYD:(A;;0xf0005;;;SY)(A;;0x5;;;BA)(A;;0x1;;;S-1-5-32-573)(A;;0x1;;;S-1-5-20)'

$DossierLogs = 'C:\Scripts\Logs'
#endregion

#region ---------- Fonctions communes ----------
$script:NbErreurs = 0
New-Item -ItemType Directory -Path $DossierLogs -Force | Out-Null
$FichierLog = Join-Path $DossierLogs ("08_WEF_{0}_{1:yyyyMMdd_HHmmss}.log" -f $Mode, (Get-Date))

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

Write-Journal "===== WEF - mode $Mode ====="

switch ($Mode) {

    'Collecteur' {
        Invoke-Etape 'WinRM (écoute HTTP 5985)' {
            winrm quickconfig -quiet | Out-Null
        }
        Invoke-Etape 'Service Windows Event Collector' {
            wecutil qc /q | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "wecutil qc a échoué (code $LASTEXITCODE)" }
        }
        Invoke-Etape 'URL HTTP partagée WinRM / Windows Event Collector' {
            # Correctif Microsoft (Server 2016 et suivants) : sans lui, les événements initiés par
            # les sources peuvent ne jamais arriver car WinRM et Wecsvc tournent dans deux processus.
            $sids = foreach ($svc in 'WinRM', 'Wecsvc') {
                $m = (sc.exe showsid $svc) | Select-String -Pattern 'S-1-5-80-[\d-]+'
                if (-not $m) { throw "SID du service $svc introuvable" }
                $m.Matches[0].Value
            }
            $sddl = 'D:' + (($sids | ForEach-Object { "(A;;GX;;;$_)" }) -join '')
            netsh http delete urlacl url=http://+:$PortWinRM/wsman/ | Out-Null
            netsh http add urlacl url=http://+:$PortWinRM/wsman/ sddl=$sddl | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'netsh http add urlacl a échoué' }
            Restart-Service -Name WinRM
        }
        Invoke-Etape "Abonnement $NomAbonnement" {
            $requete = @"
<QueryList>
  <Query Id="0">
    <Select Path="Security">*[System[(EventID=$EvenementsSecurite)]]</Select>
    <Select Path="Security">*[System[EventID=4624] and EventData[Data[@Name='LogonType']='2' or Data[@Name='LogonType']='10']]</Select>
    <Select Path="System">*[System[(Level=1 or Level=2)]]</Select>
  </Query>
</QueryList>
"@
            # DC = Ordinateurs du domaine, DD = Contrôleurs de domaine (alias SDDL)
            $xml = @"
<Subscription xmlns="http://schemas.microsoft.com/2006/03/windows/events/subscription">
  <SubscriptionId>$NomAbonnement</SubscriptionId>
  <SubscriptionType>SourceInitiated</SubscriptionType>
  <Description>Nordis - connexions, verrouillages, comptes et erreurs systeme des serveurs</Description>
  <Enabled>true</Enabled>
  <Uri>http://schemas.microsoft.com/wbem/wsman/1/windows/EventLog</Uri>
  <ConfigurationMode>MinLatency</ConfigurationMode>
  <Query><![CDATA[$requete]]></Query>
  <ReadExistingEvents>true</ReadExistingEvents>
  <TransportName>HTTP</TransportName>
  <ContentFormat>RenderedText</ContentFormat>
  <Locale Language="$Langue"/>
  <LogFile>ForwardedEvents</LogFile>
  <AllowedSourceNonDomainComputers></AllowedSourceNonDomainComputers>
  <AllowedSourceDomainComputers>O:NSG:BAD:P(A;;GA;;;DC)(A;;GA;;;DD)S:</AllowedSourceDomainComputers>
</Subscription>
"@
            $fichier = Join-Path $env:TEMP "$NomAbonnement.xml"
            Set-Content -Path $fichier -Value $xml -Encoding Unicode
            if (@(wecutil es) -contains $NomAbonnement) { wecutil ds $NomAbonnement | Out-Null }
            wecutil cs $fichier | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "wecutil cs a échoué (code $LASTEXITCODE)" }
        }
        Invoke-Etape 'Taille du journal Événements transférés (100 Mo)' {
            wevtutil sl ForwardedEvents /ms:104857600 | Out-Null
        }
        Write-Journal 'Lance maintenant le mode GPO sur CLI01 : il applique aussi la GPO sur les DC et SRV02.'
        Write-Journal "Vérifications : wecutil gr $NomAbonnement  |  Get-WinEvent -LogName ForwardedEvents -MaxEvents 10"
    }

    'GPO' {
        Import-Module ActiveDirectory, GroupPolicy
        $DomaineDN = (Get-ADDomain).DistinguishedName

        Invoke-Etape "$NomGpo : création et liens" {
            $gpo = Get-GPO -Name $NomGpo -ErrorAction SilentlyContinue
            if (-not $gpo) { $gpo = New-GPO -Name $NomGpo -Comment 'Transfert des journaux vers le collecteur WEF (SRV02)' }
            foreach ($c in $CiblesGpo) {
                $cible = "$c,$DomaineDN"
                $liens = (Get-GPInheritance -Target $cible).GpoLinks
                if (-not ($liens | Where-Object DisplayName -eq $NomGpo)) {
                    New-GPLink -Name $NomGpo -Target $cible -LinkEnabled Yes | Out-Null
                }
            }
            $script:IdGpo = $gpo.Id
        }
        Invoke-Etape 'Adresse du collecteur (Gestionnaire d''abonnements cible)' {
            $valeur = "Server=http://$($Collecteur):$PortWinRM/wsman/SubscriptionManager/WEC,Refresh=$Rafraichissement"
            Set-GPRegistryValue -Guid $script:IdGpo -Key 'HKLM\Software\Policies\Microsoft\Windows\EventLog\EventForwarding\SubscriptionManager' `
                                -ValueName '1' -Type String -Value $valeur | Out-Null
        }
        Invoke-Etape 'Lecture du journal Sécurité par le service de transfert' {
            Set-GPRegistryValue -Guid $script:IdGpo -Key 'HKLM\Software\Policies\Microsoft\Windows\EventLog\Security' `
                                -ValueName 'ChannelAccess' -Type String -Value $SddlJournalSecurite | Out-Null
        }
        Write-Journal 'Attente de 60 s : réplication de la GPO vers le SYSVOL de DC02.'
        Start-Sleep -Seconds 60
        Invoke-Etape "Application à distance sur $($Sources -join ', ') (gpupdate + droit sur le journal Sécurité)" {
            # La stratégie « Configurer l'accès au journal » n'est lue qu'au démarrage du service Journal
            # d'événements : on applique aussi le droit tout de suite avec wevtutil (sans redémarrage).
            Invoke-Command -ComputerName $Sources -ArgumentList $SddlJournalSecurite -ScriptBlock {
                param($sddl)
                gpupdate /force /target:computer | Out-Null
                wevtutil sl security "/ca:$sddl"
                if ($LASTEXITCODE -ne 0) { throw "wevtutil a échoué sur $env:COMPUTERNAME" }
            } | Out-Null
        }
        Invoke-Etape "Redémarrage du service de transfert (WinRM) sur $($Sources -join ', ')" {
            Get-Service -ComputerName $Sources -Name WinRM | Restart-Service -Force
        }
        Write-Journal 'Vérifier sur SRV02 dans 2 à 5 min : wecutil gr Nordis-Securite  |  Get-WinEvent -LogName ForwardedEvents -MaxEvents 10'
    }
}

if ($script:NbErreurs -gt 0) {
    Write-Journal "Terminé avec $($script:NbErreurs) erreur(s). Journal : $FichierLog" 'ERREUR'; exit 1
}
Write-Journal "Terminé sans erreur. Journal : $FichierLog" 'OK'
exit 0
