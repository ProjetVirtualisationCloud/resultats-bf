# Rôle 3 — Gestion des bases de données

> **Projet :** RÉSULTATS-BF — infrastructure résiliente et scalable sous Vagrant
> **Module :** DevOps et infrastructures reproductibles (2026-2027)
> **Groupe :** 7
> **Responsable du rôle :** Hawa PANANDETIGUI

## 1. Mission et périmètre

Le rôle 3 fournit le stockage PostgreSQL des résultats d'examen et prépare leur
continuité de service. Il couvre :

- l'installation et la configuration de la base primaire `bdd1`;
- le schéma `resultats` et un jeu de données déterministe de 50 000 lignes;
- un compte applicatif en lecture seule et un compte dédié à la réplication;
- le clonage de `bdd1` vers `bdd2` et la réplication physique asynchrone;
- les contrôles d'état et la procédure manuelle de promotion.

Le rôle ne configure pas de gestionnaire de failover automatique, de quorum, de
sauvegarde externe ni de réintégration automatique de l'ancienne primaire.
La réplication n'est pas une sauvegarde : une suppression ou corruption logique
peut également être répliquée.

## 2. Architecture et fichiers

| Machine | Adresse par défaut du groupe 7 | Fonction |
|---|---|---|
| `bdd1` | `192.168.62.31` | Primaire PostgreSQL 16, lecture/écriture |
| `bdd2` | `192.168.62.32` | Réplique physique en standby, lecture seule avant promotion |

Le plan d'adressage réel est généré par le `Vagrantfile` et publié dans
`config/noeuds.yml`. Les scripts utilisent cette source pour trouver le réseau
et l'adresse de `bdd1`.

| Fichier | Responsabilité |
|---|---|
| [`scripts/bdd.sh`](../scripts/bdd.sh) | Installe et configure PostgreSQL sur `bdd1`, crée les rôles, la base, la table et les données. |
| [`scripts/replique.sh`](../scripts/replique.sh) | Clone `bdd1`, configure le cluster standby sur `bdd2` et vérifie le démarrage du flux WAL. |
| [`scripts/commun.sh`](../scripts/commun.sh) | Rend les noms des machines résolvables dans `/etc/hosts`. |
| [`config/noeuds.yml`](../config/noeuds.yml) | Inventaire généré des machines et de leurs adresses. |
| [`.env.exemple`](../.env.exemple) | Modèle des paramètres et secrets locaux. |

## 3. Primaire `bdd1`

Le script `bdd.sh` installe PostgreSQL 16 et configure :

- l'écoute réseau sur `0.0.0.0:5432` sur le réseau privé du projet;
- `wal_level = replica`, `max_wal_senders = 5` et `wal_keep_size = 64MB`;
- des règles `pg_hba.conf` limitées au réseau applicatif et à l'adresse de `bdd2`;
- un rôle applicatif (`DB_UTILISATEUR`) et un rôle de réplication
  (`REPLIC_UTILISATEUR`);
- la base `DB_NOM`, la table `resultats` et jusqu'à 50 000 lignes déterministes.

La table est composée de `matricule` (clé primaire), `nom`, `serie`, `moyenne`
(contrainte de 0 à 20) et `admis`. Les données sont générées localement pour les
essais; elles ne constituent pas un jeu officiel de résultats d'examen. Le rôle
applicatif reçoit uniquement le droit `SELECT` sur cette table.

Le provisionnement est conçu pour être rejoué : les rôles, paramètres, règles
réseau et données sont remis dans l'état attendu sans ajouter de doublons. Les
données présentes ne sont pas supprimées ni remplacées par une nouvelle
génération.

## 4. Réplique `bdd2`

`replique.sh` installe PostgreSQL 16 si nécessaire. Au premier provisionnement,
il utilise `pg_basebackup` avec transfert WAL et option `-R` pour créer une
copie physique cohérente de `bdd1`. La copie est stockée dans
`/var/lib/postgresql/16/replica`; le cluster Debian initial `main` n'est pas
supprimé. Le service PostgreSQL est configuré pour utiliser ce répertoire de
données.

L'authentification persistante utilise
`/var/lib/postgresql/.pgpass-resultats-bf`, détenu par `postgres` et lisible
uniquement par lui. Le mot de passe n'est pas inscrit dans la commande
`pg_basebackup` ni dans la chaîne de connexion persistante. `standby.signal`
indique au serveur de démarrer en récupération et de suivre le primaire.

`bdd2` écoute sur `0.0.0.0:5432` et son `pg_hba.conf` autorise le compte
applicatif depuis le réseau privé du projet. Ces paramètres sont appliqués et
rechargés de façon idempotente; l'accès fonctionne donc aussi après la promotion
de `bdd2`.

Au rejeu, le script conserve une copie existante portant `standby.signal`. Si
`bdd2` a été promue (le marqueur a disparu et `pg_is_in_recovery() = f`), le
script indique que la reconfiguration en réplique est ignorée et termine sans
modifier son rôle ni ses données. Si le répertoire existe sans marqueur mais que
le serveur n'est pas joignable comme primaire, le script échoue explicitement :
ne pas supprimer ou remplacer les données avant d'avoir inspecté l'état.

La réplication est asynchrone : en cas de panne brutale de `bdd1`, les dernières
transactions peuvent ne pas encore être arrivées sur `bdd2`.

## 5. Configuration locale et démarrage

À la racine du dépôt, créer `.env` à partir du modèle et renseigner les secrets
locaux. Ne jamais afficher, committer ou partager ce fichier :

```powershell
Copy-Item .env.exemple .env
```

Les paramètres `DB_MOT_DE_PASSE` et `REPLIC_MOT_DE_PASSE` doivent être renseignés
et respecter les contraintes documentées dans le [README](../README.md).
Le fichier `.env` est exclu de Git.

Démarrer les deux bases depuis PowerShell :

```powershell
vagrant up bdd1 bdd2
```

`bdd2` dépend du service PostgreSQL de `bdd1`. Si le provisionnement de la
réplique est lancé alors que `bdd1` ne répond pas, le script s'arrête avec une
erreur plutôt que de créer un standby incomplet.

## 6. Vérifier la base et la réplication

Vérifier le nombre de lignes sur la primaire :

```powershell
vagrant ssh bdd1 -c "sudo -u postgres psql -d resultats -tAc 'SELECT count(*) FROM resultats;'"
```

Résultat attendu après une initialisation neuve : `50000`.

Vérifier que `bdd1` voit `bdd2` en streaming :

```powershell
vagrant ssh bdd1 -c "sudo -u postgres psql -x -c 'SELECT client_addr, state, sync_state FROM pg_stat_replication;'"
```

Résultat attendu : `client_addr` correspond à l'adresse de `bdd2` et `state`
vaut `streaming`.

Vérifier le récepteur WAL et le mode standby sur `bdd2` :

```powershell
vagrant ssh bdd2 -c "sudo -u postgres psql -x -c 'SELECT status, sender_host FROM pg_stat_wal_receiver;'"
vagrant ssh bdd2 -c "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery();'"
vagrant ssh bdd2 -c "sudo -u postgres psql -d resultats -tAc 'SELECT count(*) FROM resultats;'"
```

Résultats attendus : `status = streaming`, `pg_is_in_recovery() = t` et
`50000` lignes après le rattrapage initial.

## 7. Promotion manuelle et limites de bascule

La promotion de `bdd2` est une opération manuelle, à effectuer seulement après
avoir confirmé que l'ancienne primaire est arrêtée ou isolée du réseau. Sans
cette précaution, deux serveurs indépendants pourraient accepter des écritures
(split-brain).

1. Pour mesurer l'interruption de bout en bout depuis l'hôte, ouvrir deux
   fenêtres PowerShell. Dans la première, démarrer la sonde avant la bascule :

   ```powershell
   powershell -ExecutionPolicy Bypass -File tests\surveiller.ps1 `
       -Url "http://localhost:8080/resultat?matricule=BF00001" `
       -Duree 120 -Fichier mesures\V4-bascule-db.txt
   ```

   La commande s'exécute pendant 120 secondes. Si la mesure n'est pas requise,
   passer directement à l'étape suivante.

2. Pendant que la sonde tourne, arrêter `bdd1` et promouvoir `bdd2` dans la
   seconde fenêtre. Vérifier d'abord que `bdd1` ne peut plus accepter de
   connexions :

   ```powershell
   vagrant halt bdd1
   vagrant ssh bdd2 -c "sudo -u postgres psql -c 'SELECT pg_promote();'"
   ```

3. Vérifier que `bdd2` est primaire :

   ```powershell
   vagrant ssh bdd2 -c "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery();'"
   vagrant ssh bdd2 -c "sudo -u postgres psql -d resultats -tAc 'SELECT count(*) FROM resultats;'"
   ```

   Résultats attendus : `f` et `50000` lignes.

4. Vérifier l'accès applicatif après la promotion :

   ```powershell
   vagrant ssh bdd2 -c "sudo -u postgres psql -tAc 'SHOW listen_addresses'"
   vagrant ssh app1 -c "curl -s -i http://127.0.0.1:8000/sante"
   ```

   La première commande doit afficher `0.0.0.0`; la seconde doit répondre
   `HTTP 200` avec `{"statut":"ok"}`.

   Le bilan de `surveiller.ps1` fournit la durée d'interruption observée. La
   sonde compte les réponses HTTP en erreur comme des échecs. La mesure est à
   exécuter et archiver pendant la validation; elle n'est pas présumée réussie
   par la seule présence de cette procédure.

La promotion ne déplace pas d'adresse IP, ne redémarre pas les applications et
ne réintègre pas automatiquement l'ancienne primaire. L'application utilise une
liste d'hôtes PostgreSQL avec `target_session_attrs=read-write`; elle peut
sélectionner un hôte déjà promu pour de nouvelles connexions, mais cela ne
constitue ni une détection/promotion automatique ni une garantie de reprise
transparente des requêtes en cours.

Après la promotion, l'application se reconnecte seule à `bdd2` : chaque processus
de l'application retient la dernière base primaire qui a répondu et l'essaie en
premier. Seule sa première connexion après la panne attend `bdd1` pendant
`connect_timeout` (2 s) ; les suivantes vont directement à `bdd2`
(voir `app/app.py`, fonction `get_conn`).

Ne pas redémarrer l'ancienne primaire après la promotion : elle peut repartir
primaire avec des données périmées, créant deux primaires (split-brain), et
un processus de l'application qui redémarre essaie `bdd1` en premier. Il faut reconstruire les deux VM plutôt
que redémarrer seulement `bdd1`. Après avoir décidé explicitement du sort des
données écrites depuis la bascule et sauvegardé celles à préserver, la procédure
de retour à l'état initial est :

```powershell
vagrant destroy -f bdd1 bdd2
vagrant up bdd1 bdd2
```

Cette reconstruction repart des données qui auront été provisionnées sur
`bdd1`; toute donnée présente uniquement sur l'ancienne `bdd2` doit être
préservée avant la destruction. La procédure ne réintègre pas l'ancienne
primaire et ne constitue pas un failback sans perte.

## 8. Rejeu, reconstruction et diagnostic

- Rejouer le provisionnement d'une VM démarrée :

  ```powershell
  vagrant provision bdd1
  vagrant provision bdd2
  ```

- Consulter les services et journaux :

  ```powershell
  vagrant ssh bdd1 -c "sudo systemctl status postgresql --no-pager"
  vagrant ssh bdd2 -c "sudo journalctl -u postgresql -n 50 --no-pager"
  ```

- Si `bdd2` est volontairement à reconstruire, confirmer d'abord qu'elle ne
  contient pas des données promues à préserver. Après une promotion, ne pas
  recréer uniquement `bdd2` depuis l'ancienne `bdd1` : appliquer la procédure
  de reconstruction des deux VM de la section 7. Pour une réplique non promue,
  la reconstruction seule de `bdd2` reste possible :

  ```powershell
  vagrant destroy -f bdd2
  vagrant up bdd2
  ```

Une destruction/recréation de `bdd2` relance un clonage complet depuis `bdd1`.
Ne pas détruire `bdd1` pour résoudre un problème de réplication sans avoir
préalablement sauvegardé ou validé les données à conserver.

## 9. Résultats des tests d'intégration

Tests exécutés sur VirtualBox **7.2.22**, Vagrant **2.4.9** et
`bento/ubuntu-24.04` **202510.26.0**, le **7 novembre 2026**. Les deux VM ont
été provisionnées depuis le dépôt avec le fichier `.env` local. Aucun secret
n'est inclus dans les résultats ci-dessous.

| Vérification | Résultat observé |
|---|---|
| Provisionnement de `bdd1` | Réussi; la base contient 50 000 lignes. |
| Rejeu de `bdd1` | Réussi; la table existante est conservée et le total reste 50 000. |
| Clonage initial de `bdd2` | Réussi; le script confirme `pg_is_in_recovery() = true`. |
| Flux primaire vers réplique | Réussi; `pg_stat_replication.state = streaming`, en mode asynchrone. |
| Récepteur WAL de `bdd2` | Réussi; `pg_stat_wal_receiver.status = streaming`. |
| Jeu de données de `bdd2` | Réussi; les 50 000 lignes sont présentes. |
| Rejeu de `bdd2` | Réussi; la copie standby existante est détectée et conservée sans nouveau clonage. |
| Droits applicatifs | Réussi; `SELECT` autorisé, `INSERT` non autorisé. Une tentative d'écriture a été rejetée par PostgreSQL. |
| Réplication d'une modification | Réussi; une ligne temporaire insérée puis supprimée sur `bdd1` est apparue puis a disparu de `bdd2`. La ligne de test a été nettoyée. |
| Promotion manuelle | Réussi avec `bdd1` arrêtée; `pg_promote()` renvoie `t`, puis `pg_is_in_recovery() = f` et `transaction_read_only = off` sur `bdd2`. |
| Retour à la topologie primaire/réplique | Réussi; `bdd2` a été reconstruite depuis `bdd1`, puis les états `streaming` et les 50 000 lignes ont été revérifiés. |

À la fin des tests, `bdd1` est primaire, `bdd2` est en streaming et les deux VM
sont en marche. Ces essais valident le provisionnement et la promotion manuelle
du rôle données; ils ne valident pas la reprise automatique de l'application
ni une bascule automatique, qui ne sont pas implémentées.

### 9.1. Vérification complémentaire de `bdd1`, `bdd2` et de l'application

Vérifications effectuées le **9 novembre 2026** après le reprovisionnement de
`bdd2` avec la correction de son accès applicatif. `app1` a été provisionnée
pour contrôler la connexion réelle. Aucun secret n'est affiché.

| Vérification | Résultat observé |
|---|---|
| Données de `bdd1` | `SELECT count(*) FROM resultats` renvoie `50000`. |
| Données de `bdd2` | `SELECT count(*) FROM resultats` renvoie `50000`. |
| État de `bdd2` | `pg_is_in_recovery() = t`; `listen_addresses = 0.0.0.0`. |
| Flux de réplication | `pg_stat_replication` sur `bdd1` indique `192.168.62.32/32`, état `streaming`; `pg_stat_wal_receiver` sur `bdd2` indique aussi `streaming`. |
| Provisionnement rejoué de `bdd2` | Réussi; le script confirme que la copie standby existante est conservée et que le standby est opérationnel. |
| Connexion TCP de l'application vers `bdd2` | Réussie avec les identifiants de l'application; la requête `SELECT count(*) FROM resultats` renvoie `50000`. |
| Sonde de santé depuis `app1` | `HTTP 200` et `{"statut":"ok"}`. |

Cette vérification confirme le fonctionnement de la topologie primaire/réplique
et l'accès réseau à `bdd2`. Elle n'inclut pas une promotion : `bdd1` est restée
primaire, `bdd2` est restée en standby et n'a pas été arrêtée.
