<#
  surveiller.ps1 - Interroge une adresse en continu et mesure les interruptions.
  Sert aux scenarios V1 (repartition), V2 (panne d'un serveur applicatif),
  V4 (panne de la base) et V6 (panne du repartiteur).
  Ecrit chaque reponse horodatee, puis un bilan : requetes perdues,
  disponibilite, nombre et duree des coupures.

  Exemple (scenario V6) :
    powershell -ExecutionPolicy Bypass -File tests\surveiller.ps1 `
        -Url http://192.168.62.10/repartiteur -Duree 60 -Fichier mesures\V6-brut.txt
#>
param(
    [string]$Url = "http://192.168.62.10/repartiteur",
    [int]$Duree = 60,           # duree totale de la mesure, en secondes
    [int]$Intervalle = 200,     # pause entre deux requetes, en millisecondes
    [string]$Fichier = ""       # fichier de sortie (facultatif)
)

# Ecrit une ligne a l'ecran et, si demande, dans le fichier (UTF-8, fins LF)
function Ecrire([string]$ligne) {
    Write-Output $ligne
    if ($Fichier) { [System.IO.File]::AppendAllText($Fichier, $ligne + "`n") }
}

if ($Fichier) {
    # chemin absolu : .NET ne connait pas le dossier courant de PowerShell
    $Fichier = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $Fichier))
    [System.IO.File]::WriteAllText($Fichier, "")
}

$fin          = (Get-Date).AddSeconds($Duree)
$total        = 0
$echecs       = 0
$precedente   = $null     # reponse precedente
$dernierOk    = $null     # instant de la derniere reponse correcte
$enCoupure    = $false    # vrai pendant une serie d'echecs
$debutCoupure = $null     # derniere reponse correcte AVANT la coupure en cours
$coupures     = @()       # duree (s) de chaque coupure terminee
$changements  = @()       # liste des changements de reponse

Ecrire ("Mesure du {0} - {1}" -f (Get-Date -Format "dd/MM/yyyy HH:mm:ss"), $Url)
Ecrire ("Une requete toutes les {0} ms pendant {1} s (delai maximal 0,5 s par requete)" -f $Intervalle, $Duree)
Ecrire ""

while ((Get-Date) -lt $fin) {
    $instant = Get-Date
    # --fail : une reponse HTTP d'erreur (4xx, 5xx, ex. 503) compte comme ECHEC
    $reponse = & curl.exe -s --fail --connect-timeout 0.3 -m 0.5 $Url
    $ok = ($LASTEXITCODE -eq 0) -and ("$reponse".Trim() -ne "")
    $total++

    if ($ok) {
        $reponse = "$reponse".Trim()
        if ($enCoupure) {
            # fin d'une coupure : de la derniere reponse correcte avant,
            # a cette premiere reponse correcte apres
            $coupures += ($instant - $debutCoupure).TotalSeconds
            $enCoupure = $false
        }
        $dernierOk = $instant
    } else {
        $reponse = "ECHEC"
        $echecs++
        if (-not $enCoupure) {
            $enCoupure = $true
            $debutCoupure = if ($dernierOk) { $dernierOk } else { $instant }
        }
    }

    $heure = $instant.ToString("HH:mm:ss.fff")
    if ($null -ne $precedente -and $reponse -ne $precedente) {
        $changements += ("{0}  {1} -> {2}" -f $heure, $precedente, $reponse)
        Ecrire ("{0}  {1}     <== changement" -f $heure, $reponse)
    } else {
        Ecrire ("{0}  {1}" -f $heure, $reponse)
    }
    $precedente = $reponse
    Start-Sleep -Milliseconds $Intervalle
}

# --- Bilan --------------------------------------------------------------------
Ecrire ""
Ecrire "================ BILAN ================"
Ecrire ("Requetes envoyees    : {0}" -f $total)
Ecrire ("Requetes en echec    : {0}" -f $echecs)
if ($total -gt 0) {
    Ecrire ("Disponibilite        : {0:N2} %" -f (100.0 * ($total - $echecs) / $total))
}
Ecrire "Changements observes :"
if ($changements.Count -eq 0) { Ecrire "  (aucun)" }
foreach ($c in $changements) { Ecrire ("  " + $c) }
if ($coupures.Count -gt 0) {
    $cumul = ($coupures | Measure-Object -Sum).Sum
    $max   = ($coupures | Measure-Object -Maximum).Maximum
    Ecrire ("Coupures             : {0} (la plus longue : {1:N2} s ; cumul : {2:N2} s)" -f $coupures.Count, $max, $cumul)
    Ecrire  "                       duree d'une coupure = de la derniere reponse correcte"
    Ecrire  "                       avant les echecs a la premiere reponse correcte apres"
}
if ($enCoupure) {
    Ecrire "Interruption         : service non retabli avant la fin de la mesure"
} elseif ($echecs -eq 0) {
    Ecrire "Interruption         : aucune requete perdue"
}