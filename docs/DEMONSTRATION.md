# Démonstration (L4) : aide-mémoire

Déroulé de la soutenance (20 minutes) : sur une machine vierge, destruction puis
reconstruction en direct, puis **trois scénarios tirés au sort** par l'enseignant.
Chaque membre doit savoir exécuter et expliquer **toutes** les commandes ci-dessous.

Toutes les commandes se lancent dans PowerShell, à la racine du dépôt `resultats-bf`.
Pour mesurer, l'outil `tests\surveiller.ps1` interroge le service environ 4 fois par
seconde et affiche un bilan (requêtes perdues, disponibilité, coupures).

---

## 0. Avant la soutenance

| Vérification | Commande | Attendu |
|---|---|---|
| Fichier des secrets présent | `Test-Path .env` | `True` |
| Box présente | `vagrant box list` | `bento/ubuntu-24.04 (virtualbox, 202510.26.0)` |
| Aucune VM ancienne | `vagrant status` | `not created` partout |

## 1. Reconstruction (R1, V5)

```powershell
vagrant destroy -f
Measure-Command { vagrant up | Out-Default }
curl.exe http://localhost:8080/info
curl.exe "http://localhost:8080/resultat?matricule=BF00001"
```
Attendu : aucune erreur, puis une réponse JSON. Durée mesurée : 11 à 14 min.
Si une VM dépasse le délai de démarrage (`Timed out`), la relancer seule : `vagrant up app2`.

## 2. Exigences

| N° | Commande | Ce qu'il faut montrer |
|---|---|---|
| R2 | `vagrant provision` (deux fois) | Messages « inchangé / rien à faire », aucune erreur |
| R3 | `$env:NB_APP=4; vagrant up; Remove-Item Env:NB_APP` | `vagrant ssh lb1 -c "grep -c 'server app' /etc/haproxy/haproxy.cfg"` affiche 4 |
| R4 | voir V2 | Serveur écarté en ~2 s (< 5 s) |
| R5 | `powershell -ExecutionPolicy Bypass -File tests\verifier-replication.ps1` | `BILAN : R5 VERIFIEE` |
| R6 | voir V4 | Procédure de bascule, durée mesurée |
| R7 | `git log -p \| Select-String "a_remplacer"` ; `git status` | Aucun mot de passe réel ; `.env` jamais listé |
| R8 | `vagrant port lb1` | Seul lb1 expose un port applicatif (80 → 8080) |

## 3. Scénarios

**Fenêtre 1** = mesure, **fenêtre 2** = action (toutes deux dans `resultats-bf`).

| N° | Fenêtre 1 (mesure) | Fenêtre 2 (action) | Attendu |
|---|---|---|---|
| V1 | `1..20 \| % { (curl.exe -s http://localhost:8080/info \| ConvertFrom-Json).machine } \| Group-Object` | — | 10 / 10, écart < 20 % |
| V2 | `...surveiller.ps1 -Url http://localhost:8080/info -Duree 90` | `vagrant halt app1` puis `vagrant up app1` | ≤ 1 requête perdue, aucune erreur au-delà de 5 s |
| V3 | `vagrant ssh bdd2 -c "ab -n 2000 -c 50 'http://192.168.62.11/resultat?matricule=BF00001'"` | avec N=2 puis N=4 | Débit mesuré et expliqué (processeur partagé) |
| V4 | `...surveiller.ps1 -Url "http://localhost:8080/resultat?matricule=BF00001" -Duree 240` | `vagrant halt bdd1` ; `curl.exe -i http://localhost:8080/sante` (503) ; `vagrant ssh bdd2 -c "sudo -u postgres psql -c 'SELECT pg_promote();'"` | 503 propre, puis reprise (~22 s) |
| V5 | voir § 1 | — | Reconstruction sans intervention |
| V6 | `...surveiller.ps1 -Url http://192.168.62.10/repartiteur -Duree 60` | `vagrant halt lb1` (E1 activée : `AVEC_LB2=1` dans `.env`, `vagrant up lb1 lb2`) | lb1 → lb2 en ~1 s, même adresse |
| E4 | `...surveiller.ps1 -Url http://localhost:8080/info -Duree 150` | changer `VERSION` dans `app\app.py`, puis `powershell -ExecutionPolicy Bypass -File scripts\deployer.ps1` | Version qui change serveur par serveur, 0 échec |

`...surveiller.ps1` = `powershell -ExecutionPolicy Bypass -File tests\surveiller.ps1`

**Après V4** : ne jamais redémarrer bdd1 telle quelle (deux primaires) :
`vagrant destroy -f bdd1 bdd2` puis `vagrant up bdd1 bdd2`.

## 4. Questions probables

| Question | Réponse courte |
|---|---|
| Où est la source unique de vérité ? | Table `NOEUDS` du Vagrantfile → `config/noeuds.yml` → configurations HAProxy et keepalived engendrées par `lb.sh` |
| Pourquoi `timeout check 3s` ? | `/sante` attend 2 s sur bdd1 en panne ; avec 1 s, tous les serveurs seraient écartés à tort |
| Pourquoi la promotion est-elle manuelle ? | Sans arbitre, une bascule automatique risque deux primaires (split-brain) |
| Pourquoi le débit baisse-t-il avec 4 serveurs ? | Toutes les VM partagent le processeur du PC ; même `/info` (sans base) baisse |
| Comment E4 évite-t-il les erreurs ? | Le serveur est retiré de HAProxy (`state maint`) **avant** sa mise à jour |
