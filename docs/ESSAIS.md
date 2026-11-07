# RÉSULTATS-BF — Guide du Rôle Essais & Observabilité

> **Projet :** RÉSULTATS-BF — Infrastructure résiliente et scalable sous Vagrant  
> **Module :** DevOps et infrastructures reproductibles (2026-2027) — Dr Flavien Hervé SOMDA  
> **Groupe :** Groupe 7  
> **Responsable du rôle :** Brigitte DAMBRE  

---

## 1. Mission et périmètre du rôle 4

Le rôle **Ingénieur essais et observabilité** a la responsabilité critique de **valider expérimentalement** l'ensemble de l'infrastructure produite par l'équipe. Il apporte les **preuves chiffrées** que le système est résilient, scalable et conforme aux exigences du cahier des charges :

- **Exécution des 6 scénarios officiels d'évaluation (V1 à V6).**
- **Mesure des métriques clés :** Disponibilité (%), requêtes perdues, durée d'interruption (RTO/MTTR < 5 s exigées), débit et temps de réponse.
- **Collecte des données brutes** dans le dossier [`mesures/`](../mesures/).
- **Rédaction des fiches d'analyse** expliquant les mécanismes techniques observés (détection HAProxy, reprise libpq, bascule VRRP).

---

## 2. Outils de mesure et environnement de test

### 2.1. L'outil de surveillance : `tests/surveiller.ps1`
Ce script PowerShell interroge une URL en boucle toutes les 200 ms (ou délai choisi) avec un timeout strict, horodate chaque requête, détecte les transitions d'état et calcule automatiquement le bilan :

```powershell
# Exemple d'appel :
powershell -ExecutionPolicy Bypass -File tests\surveiller.ps1 `
    -Url http://localhost:8080/info -Duree 60 -Fichier mesures\V2-panne-app1.txt
```

### 2.2. Prérequis avant de démarrer
Toute l'infrastructure doit être démarrée proprement :
```powershell
vagrant up
```
*(5 machines virtuelles : `lb1`, `app1`, `app2`, `bdd1`, `bdd2`).*

---

## 3. Protocole détaillé des Scénarios V1 à V6

---

### Scénario V1 — Répartition de charge nominale (Round-Robin)

- **Objectif :** Vérifier que HAProxy répartit équitablement les requêtes HTTP entre les serveurs applicatifs sans état.
- **Protocole :**
  Exécuter une série de 100 requêtes consécutives sur la route `/info` exposée sur l'hôte :
  ```powershell
  # Exécuter depuis PowerShell :
  1..100 | ForEach-Object {
      (curl.exe -s http://localhost:8080/info | ConvertFrom-Json).machine
  } | Group-Object | Select-Object Name, Count, @{Name="Pourcentage"; Expression={ "$($_.Count) %" }} | Format-Table -AutoSize
  ```
- **Résultat attendu :**
  - Répartition proche de **50 % sur `app1` et 50 % sur `app2`**.
  - 100 % de réponses HTTP 200 OK (0 erreur).
- **Fichier de preuve :** Enregistrer la sortie dans `mesures/V1-repartition.txt`.

---

### Scénario V2 — Panne d'un serveur applicatif (Haute disponibilité)

- **Objectif :** Mesurer le temps d'éviction d'un serveur applicatif défaillant et l'absence de coupure pour l'utilisateur final.
- **Protocole :**
  1. Lancer la surveillance en continu en tâche de fond :
     ```powershell
     powershell -ExecutionPolicy Bypass -File tests\surveiller.ps1 `
         -Url http://localhost:8080/info -Duree 90 -Intervalle 200 -Fichier mesures\V2-panne-app1.txt
     ```
  2. Après 5 secondes, couper brutalement `app1` :
     ```powershell
     vagrant halt app1
     ```
  3. Constater le comportement :
     - HAProxy interroge `/sante` toutes les 1 s (`inter 1s`).
     - Après 2 échecs (`fall 2`, soit ~2 s), `app1` est déclarée DOWN.
     - Grâce aux paramètres `retries 2` et `option redispatch`, les requêtes en vol vers `app1` sont redirigées vers `app2` sans générer d'erreur 503 visible pour le visiteur.
  4. Rallumer `app1` :
     ```powershell
     vagrant up app1
     ```
     - Observer sa réintégration automatique dans le pool après 2 sondes réussies (`rise 2`).
- **Résultat attendu :**
  - Interruption ressentie : **0 seconde** (ou < 2 s).
  - Taux de disponibilité : **> 99 %**.
- **Fichier de preuve :** `mesures/V2-panne-app1.txt` + fiche d'analyse `mesures/V2-analyse.txt`.

---

### Scénario V3 — Montée en charge et scalabilité horizontale (R3)

- **Objectif :** Démontrer que l'infrastructure s'adapte à l'augmentation du trafic par simple ajout de machines sans coupure de service.
- **Protocole :**
  1. Mesurer le temps de réponse et le débit nominal avec 2 serveurs applicatifs (`app1`, `app2`).
  2. Augmenter le nombre d'instances à 4 avec la variable `NB_APP` :
     ```powershell
     $env:NB_APP=4; vagrant up; Remove-Item Env:NB_APP
     ```
  3. Vérifier que `lb1` a été automatiquement reprovisionné (`run: "always"`) sans redémarrage brutal :
     ```powershell
     vagrant ssh lb1 -c "grep -E 'server app[0-9]' /etc/haproxy/haproxy.cfg"
     ```
     *(Doit afficher les 4 serveurs `app1`, `app2`, `app3`, `app4`).*
  4. Envoyer une salve de requêtes sur `/info` :
     ```powershell
     1..100 | ForEach-Object { (curl.exe -s http://localhost:8080/info | ConvertFrom-Json).machine } | Group-Object | Format-Table Name, Count
     ```
     *(Les requêtes doivent désormais se répartir équitablement sur les 4 nœuds à ~25 % chacun).*
  5. Réduire proprement à 2 serveurs :
     ```powershell
     vagrant provision lb1
     $env:NB_APP=4; vagrant destroy -f app3 app4; Remove-Item Env:NB_APP
     ```
- **Fichier de preuve :** `mesures/V3-scalabilite.txt`.

---

### Scénario V4 — Panne de la base de données primaire et bascule (Failover)

- **Objectif :** Valider la résilience du service en cas de panne de la base primaire `bdd1` et la bascule automatique du trafic applicatif sur `bdd2`.
- **Protocole :**
  1. Lancer la surveillance sur une requête métier avec matricule :
     ```powershell
     powershell -ExecutionPolicy Bypass -File tests\surveiller.ps1 `
         -Url "http://localhost:8080/resultat?matricule=BF00001" -Duree 90 -Intervalle 300 -Fichier mesures\V4-bascule-bdd.txt
     ```
  2. Couper la base primaire `bdd1` :
     ```powershell
     vagrant halt bdd1
     ```
  3. Constater :
     - La sonde `/sante` échoue (renvoie 503).
     - La route `/resultat` renvoie `{"erreur": "base indisponible"}` sans exposer d'exception brute PostgreSQL (respect de l'exigence V4).
  4. Exécuter la promotion manuelle de `bdd2` (procédure d'Hawa) :
     ```powershell
     vagrant ssh bdd2 -c "sudo -u postgres psql -c 'SELECT pg_promote();'"
     ```
  5. Constater la reprise automatique :
     - Grâce à `host=bdd1,bdd2` et `target_session_attrs=read-write` dans `app.py`, la bibliothèque PostgreSQL bascule automatiquement les connexions sur `bdd2` dès qu'elle accepte les écritures.
     - Les requêtes `/resultat` redeviennent fonctionnelles (HTTP 200 OK) sans qu'aucun serveur applicatif n'ait été redémarré.
- **Résultat attendu :**
  - Pas d'erreur technique brute fuitée.
  - Reprise automatique après promotion.
- **Fichier de preuve :** `mesures/V4-bascule-bdd.txt` + fiche d'analyse `mesures/V4-analyse.txt`.

---

### Scénario V5 — Reproductibilité de zéro (Disaster Recovery — R1)

- **Objectif :** Démontrer que toute la plateforme est reproductible à partir de zéro sans aucun geste manuel.
- **Protocole :**
  1. Détruire l'intégralité des VM :
     ```powershell
     vagrant destroy -f
     ```
  2. Chronométrer la reconstruction totale :
     ```powershell
     $chrono = Measure-Command { vagrant up }
     Write-Output ("Temps total de reconstruction : {0:N1} minutes" -f $chrono.TotalMinutes)
     ```
  3. Vérifier le bon état automatique :
     - `vagrant status` : Toutes les VM `running`.
     - 50 000 lignes présentes dans `bdd1`.
     - `curl.exe http://localhost:8080/sante` ➔ `{"statut": "ok"}`.
- **Fichier de preuve :** `mesures/V5-reproductibilite.txt`.

---

### Scénario V6 — Panne du répartiteur de charge (Extension E1)

- **Objectif :** Valider la haute disponibilité du niveau de répartition avec 2 répartiteurs (`lb1` actif, `lb2` standby) partageant une IP virtuelle VRRP (`192.168.62.10`).
- **Protocole :**
  *(Déjà testé et analysé par François Xavier dans `mesures/V6-analyse.txt`).*
  1. Démarrer avec l'extension active (`AVEC_LB2=1` dans `.env`).
  2. Lancer la surveillance sur l'adresse virtuelle :
     ```powershell
     powershell -ExecutionPolicy Bypass -File tests\surveiller.ps1 `
         -Url http://192.168.62.10/repartiteur -Duree 120 -Fichier mesures\V6-brut-halt-lb1.txt
     ```
  3. Couper `lb1` (`vagrant halt lb1`).
  4. Constater le basculement instantané de la VIP vers `lb2` en **1,00 seconde** (2 requêtes perdues sur 621, **99,68 % de disponibilité**).
- **Fichier de preuve :** Déjà présent dans `mesures/V6-analyse.txt` et `mesures/V6-brut-halt-lb1.txt`.

---

## 4. Modèle de fiche d'analyse (À rédiger pour chaque scénario)

Pour chaque test dans `mesures/`, Brigitte doit formaliser une fiche d'analyse sur ce modèle :

```text
==========================================================================
Scenario VX - Intitule du scenario - Mesure du JJ/MM/AAAA
Poste : Nom de la machine hôte (processeur, RAM, OS)
==========================================================================

1. Protocole et Commandes executees
-----------------------------------
[Description exacte des actions et commandes PowerShell]

2. Resultats chiffres
---------------------
- Requetes envoyees      : XXX
- Requetes reussies      : XXX
- Requetes en echec      : X
- Disponibilite globale  : XX,XX %
- Duree d'interruption   : X,XX s (exigence : < 5 s)

3. Analyse technique
--------------------
[Explication de ce qui s'est passé sous le capot : sondes, signaux, VRRP...]

4. Conclusion
-------------
CONFORME aux exigences du cahier des charges (R1, R2, R4...).
```

---

## 5. Synthèse des résultats et mise à jour du projet

Une fois les scénarios V1 à V5 exécutés :
1. Mettre à jour le tableau final de conformité dans le rapport de soutenance.
2. Éditer le tableau d'avancement de la section 8 du [`README.md`](../README.md) :
   ```markdown
   | Scénarios V1 à V6 | Fait (résultats documentés dans mesures/) |
   ```
3. Commiter et pousser sur votre branche `feature/observabilite-brigitte`.

