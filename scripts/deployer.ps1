<#
  deployer.ps1 - Extension E4 : mise a jour de l'application SANS COUPURE,
  serveur par serveur (deploiement progressif, "rolling update").

  Pour chaque serveur applicatif (liste lue dans config/noeuds.yml) :
    1. le retirer de HAProxy (state maint) sur chaque repartiteur allume ;
    2. attendre quelques secondes la fin des requetes en cours ;
    3. le mettre a jour : vagrant provision appN --provision-with app
       (app.sh recopie app/app.py s'il a change et redemarre le service) ;
    4. attendre que /sante reponde 200 directement sur le serveur ;
    5. le remettre dans HAProxy (state ready), puis passer au suivant.
  Pendant ce temps, les autres serveurs repondent : aucune requete perdue.

  Securites :
    - on ne retire jamais un serveur si aucun AUTRE serveur n'est en bonne sante ;
    - en cas d'echec, le script s'arrete et laisse le serveur HORS service :
      on ne remet jamais un serveur defaillant dans la repartition.

  Exemple (depuis la racine du depot) :
    powershell -ExecutionPolicy Bypass -File scripts\deployer.ps1
#>
param(
    [int]$Attente = 3,          # secondes : fin des requetes en cours apres retrait
    [int]$DelaiSante = 60       # secondes : delai maximal pour que /sante reponde 200
)

$BACKEND = "serveurs_app"       # nom du backend dans config/haproxy.cfg.tpl
$SOCKET  = "/run/haproxy/admin.sock"

function Journal([string]$message) {
    Write-Output ("{0}  {1}" -f (Get-Date -Format "HH:mm:ss"), $message)
}

function Arret([string]$message) {
    Journal "ARRET : $message"
    exit 1
}

# --- 1. Lecture de la source unique de verite (config/noeuds.yml) ------------
$fichier = Join-Path $PSScriptRoot "..\config\noeuds.yml"
if (-not (Test-Path $fichier)) {
    Arret "config/noeuds.yml absent : lancer d'abord 'vagrant status' a la racine du depot"
}
$noeuds = @()
$courant = $null
$port = 8000
foreach ($ligne in Get-Content $fichier) {
    if ($ligne -match '^port_app:\s*(\d+)') {
        $port = [int]$Matches[1]
    } elseif ($ligne -match '^- nom:\s*(\S+)') {
        $courant = @{ nom = $Matches[1].Trim('"', "'") }
        $noeuds += $courant
    } elseif ($courant -and $ligne -match '^\s+(ip|role):\s*(\S+)') {
        $courant[$Matches[1]] = $Matches[2].Trim('"', "'")
    }
}
$apps = @($noeuds | Where-Object { $_.role -eq "app" })
$lbs  = @($noeuds | Where-Object { $_.role -eq "lb" })
if ($apps.Count -lt 2) { Arret "il faut au moins 2 serveurs applicatifs" }

# --- 2. Outils ---------------------------------------------------------------
function EstAllumee([string]$nom) {
    $etat = vagrant status $nom --machine-readable | Select-String ",state,running"
    return [bool]$etat
}

# Envoie une commande au socket d'administration de HAProxy sur un repartiteur.
# HAProxy repond par une ligne vide si tout va bien, par un message sinon.
function Haproxy([string]$lb, [string]$commande) {
    $sortie = vagrant ssh $lb -c "echo '$commande' | sudo nc -U -N $SOCKET"
    if ($LASTEXITCODE -ne 0 -or "$sortie".Trim() -ne "") {
        Arret "commande '$commande' refusee sur ${lb} : $sortie"
    }
}

# Interroge /sante directement sur le serveur (sans passer par HAProxy)
function Sante([string]$ip) {
    $code = & curl.exe -s -o NUL -w "%{http_code}" --max-time 3 "http://${ip}:${port}/sante"
    return ($code -eq "200")
}

# --- 3. Deploiement serveur par serveur --------------------------------------
$actifs = @($lbs | Where-Object { EstAllumee $_.nom })
if ($actifs.Count -eq 0) { Arret "aucun repartiteur allume" }

Journal ("Deploiement progressif : serveurs {0} ; repartiteurs {1}" -f `
    (($apps | ForEach-Object { $_.nom }) -join ", "), (($actifs | ForEach-Object { $_.nom }) -join ", "))
$debut = Get-Date

foreach ($app in $apps) {
    $nom = $app.nom

    $autres = @($apps | Where-Object { $_.nom -ne $nom -and (Sante $_.ip) })
    if ($autres.Count -eq 0) {
        Arret "aucun autre serveur en bonne sante : retirer $nom couperait le service"
    }

    Journal "[$nom] 1/5 retrait du repartiteur (state maint)"
    foreach ($lb in $actifs) { Haproxy $lb.nom "set server $BACKEND/$nom state maint" }

    Journal "[$nom] 2/5 attente de $Attente s (fin des requetes en cours)"
    Start-Sleep -Seconds $Attente

    Journal "[$nom] 3/5 mise a jour (vagrant provision $nom --provision-with app)"
    vagrant provision $nom --provision-with app
    if ($LASTEXITCODE -ne 0) { Arret "mise a jour de $nom en echec : $nom reste HORS service" }

    Journal "[$nom] 4/5 attente de /sante = 200 sur $($app.ip)"
    $limite = (Get-Date).AddSeconds($DelaiSante)
    while (-not (Sante $app.ip)) {
        if ((Get-Date) -gt $limite) {
            Arret "$nom ne repond pas sur /sante apres $DelaiSante s : il reste HORS service"
        }
        Start-Sleep -Seconds 1
    }

    $info = & curl.exe -s --max-time 3 "http://$($app.ip):${port}/info"
    Journal "[$nom] 5/5 remise en service (state ready) : $info"
    foreach ($lb in $actifs) { Haproxy $lb.nom "set server $BACKEND/$nom state ready" }
}

Journal ("Deploiement termine en {0:N0} s : tous les serveurs sont a jour et en service" -f `
    ((Get-Date) - $debut).TotalSeconds)