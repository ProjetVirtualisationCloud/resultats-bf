<#
  verifier-replication.ps1 - Exigence R5 : une ecriture sur bdd1 est visible sur bdd2.
  1. bdd2 est une replique (pg_is_in_recovery = t) ;
  2. insertion d'une ligne de test sur bdd1 (primaire) ;
  3. lecture de cette ligne sur bdd2 ;
  4. tentative d'ecriture sur bdd2 : refusee (lecture seule) ;
  5. suppression sur bdd1, puis verification sur bdd2.
  Chaque resultat est ecrit DANS la VM, dans /vagrant/mesures/R5-replication.txt
  (dossier partage), puis le bilan est lu dans ce fichier.

  Exemple (depuis la racine du depot, bdd1 et bdd2 allumees) :
    powershell -ExecutionPolicy Bypass -File tests\verifier-replication.ps1
#>
param([string]$Base = "resultats")   # valeur de DB_NOM dans .env

$f = "mesures/R5-replication.txt"
$m = "R5TEST" + (Get-Date -Format "HHmmss")
Set-Content -Encoding UTF8 $f ("Verification R5 du {0} - ligne de test : {1}" -f (Get-Date -Format "dd/MM/yyyy HH:mm:ss"), $m)
$sortie = "2>&1 | tee -a /vagrant/$f"

# Requetes SQL : chaines entre $$...$$ (aucune apostrophe)
$q1 = 'SELECT pg_is_in_recovery()'
$q2 = 'INSERT INTO resultats (matricule, nom, serie, moyenne, admis) VALUES ($$' + $m + '$$, $$Test replication R5$$, $$D$$, 12.50, true)'
$q3 = 'SELECT matricule || $$ ; $$ || nom FROM resultats WHERE matricule = $$' + $m + '$$'
$q4 = 'INSERT INTO resultats (matricule, nom, serie, moyenne, admis) VALUES ($$' + $m + 'X$$, $$X$$, $$D$$, 10, true)'
$q5 = 'DELETE FROM resultats WHERE matricule = $$' + $m + '$$'
$q6 = 'SELECT count(*) FROM resultats WHERE matricule = $$' + $m + '$$'

Write-Output "1/5 bdd2 est-elle une replique ?"
vagrant ssh bdd2 -c "echo '1. bdd2 replique (pg_is_in_recovery) :' >> /vagrant/$f; sudo -u postgres psql -d $Base -tAc '$q1' $sortie"
Write-Output "2/5 insertion sur bdd1"
vagrant ssh bdd1 -c "echo '2. insertion sur bdd1 :' >> /vagrant/$f; sudo -u postgres psql -d $Base -tAc '$q2' $sortie"
Start-Sleep -Seconds 1
Write-Output "3/5 lecture sur bdd2"
vagrant ssh bdd2 -c "echo '3. lecture sur bdd2 :' >> /vagrant/$f; sudo -u postgres psql -d $Base -tAc '$q3' $sortie"
Write-Output "4/5 ecriture tentee sur bdd2 (doit etre refusee)"
vagrant ssh bdd2 -c "echo '4. ecriture tentee sur bdd2 :' >> /vagrant/$f; sudo -u postgres psql -d $Base -tAc '$q4' $sortie"
Write-Output "5/5 suppression sur bdd1 et verification sur bdd2"
vagrant ssh bdd1 -c "echo '5. suppression sur bdd1 :' >> /vagrant/$f; sudo -u postgres psql -d $Base -tAc '$q5' $sortie"
Start-Sleep -Seconds 1
vagrant ssh bdd2 -c "echo '   lignes restantes sur bdd2 :' >> /vagrant/$f; sudo -u postgres psql -d $Base -tAc '$q6' $sortie"

# --- Bilan, lu dans le fichier -----------------------------------------------
$c = Get-Content $f -Raw
$ok = ($c -match '(?m)^t\s*$') -and ($c -match 'INSERT 0 1') -and
      ($c -match "$m ; Test replication R5") -and ($c -match 'read-only') -and
      ($c -match 'DELETE 1') -and ($c -match '(?m)lignes restantes sur bdd2 :\s*\r?\n0\s*$')
if ($ok) {
    $bilan = "BILAN : R5 VERIFIEE - l'ecriture sur bdd1 est visible sur bdd2, qui reste en lecture seule."
} else {
    $bilan = "BILAN : R5 NON VERIFIEE - voir le detail ci-dessus."
}
Add-Content -Encoding UTF8 $f ""
Add-Content -Encoding UTF8 $f $bilan
Write-Output ""
Get-Content $f
