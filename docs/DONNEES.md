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

Au rejeu, le script conserve une copie existante portant `standby.signal`.
Si le répertoire de données existe sans ce marqueur (notamment après promotion),
le script échoue explicitement et ne remplace pas les données. La reconstruction
nécessite une intervention volontaire : vérifier l'état, puis détruire et
recréer la VM `bdd2`.

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

1. Arrêter ou isoler `bdd1` et vérifier qu'il ne peut plus accepter de connexions.
2. Promouvoir `bdd2` :

   ```powershell
   vagrant ssh bdd2 -c "sudo -u postgres psql -c 'SELECT pg_promote();'"
   ```

3. Vérifier que `bdd2` est primaire :

   ```powershell
   vagrant ssh bdd2 -c "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery();'"
   ```

   Résultat attendu : `f`. Vérifier ensuite une connexion applicative et les
   opérations autorisées.

La promotion ne déplace pas d'adresse IP, ne redémarre pas les applications et
ne réintègre pas automatiquement l'ancienne primaire. L'application utilise une
liste de hôtes PostgreSQL avec `target_session_attrs=read-write`; elle peut
sélectionner un hôte déjà promu pour de nouvelles connexions, mais cela ne
constitue ni une détection/promotion automatique ni une garantie de reprise
transparente des requêtes en cours.

Ne pas redémarrer l'ancienne primaire comme si elle était encore à jour. Sa
réintégration exige une procédure distincte, par exemple la reconstruire en
réplique à partir de la primaire désormais active, après vérification des
données et décision explicite de l'équipe.

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
  contient pas des données promues à préserver. Ensuite seulement :

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
