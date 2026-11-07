# RÉSULTATS-BF — Guide du Rôle Données & Réplication

> **Projet :** RÉSULTATS-BF — Infrastructure résiliente et scalable sous Vagrant  
> **Module :** DevOps et infrastructures reproductibles (2026-2027) — Dr Flavien Hervé SOMDA  
> **Groupe :** Groupe 7  
> **Responsable du composant Données :** Hawa PANANDETIGUI  

---

## 1. Vue d'ensemble du périmètre Données

Le rôle **Ingénieur données** a la responsabilité de garantir la haute disponibilité, l'intégrité et la persistance des résultats d'examen (50 000 candidats burkinabè). Ce périmètre comprend :

1. La base primaire **`bdd1`** (`192.168.62.31`) hébergeant les données d'origine.
2. La réplique en flux **`bdd2`** (`192.168.62.32`) assurant la redondance continue en mode Standby.
3. La procédure de bascule (**Failover**) en cas de défaillance de la primaire (Scénario V4).

---

## 2. État actuel & Ce qui a déjà été préparé sur `bdd1`

Grâce aux travaux déjà initialisés dans [`scripts/bdd.sh`](../scripts/bdd.sh), la machine primaire **`bdd1`** est **déjà 100 % configurée** pour la réplication :

- **PostgreSQL 16** écoute sur `0.0.0.0:5432`.
- Les 50 000 enregistrements déterministes sont insérés dans la base `resultats`.
- **Paramètres de réplication activés dans `postgresql.auto.conf` :**
  ```sql
  wal_level = 'replica'
  max_wal_senders = 5
  wal_keep_size = '64'
  ```
- **Rôle de réplication dédié créé :**
  ```sql
  CREATE ROLE "replicateur" REPLICATION LOGIN PASSWORD '${REPLIC_MOT_DE_PASSE}';
  ```
- **Sécurité réseau dans `pg_hba.conf` :**  
  L'adresse IP de `bdd2` (`192.168.62.32/32`) est explicitement autorisée avec la méthode d'authentification `scram-sha-256`.

---

## 3. Provisionnement de `bdd2`

[`scripts/replique.sh`](../scripts/replique.sh) installe PostgreSQL 16 si besoin,
puis clone `bdd1` avec `pg_basebackup` et `-R` pour créer `standby.signal`.
La copie est placée dans `/var/lib/postgresql/16/replica`; le cluster Debian
initial (`/var/lib/postgresql/16/main`) n'est pas purgé. Le fichier
`.pgpass-resultats-bf`, lisible uniquement par `postgres`, permet à la réplique
de s'authentifier aussi après le provisionnement.

Le script est rejouable : il conserve une réplique qui a déjà
`standby.signal`, et ne refait pas de copie complète. Si le répertoire `replica`
existe sans ce marqueur (par exemple après une promotion), il s'arrête sans
écraser les données. Pour reconstruire volontairement `bdd2`, inspecter d'abord
son état puis la détruire et la recréer avec Vagrant.

---

## 4. Guide d'exécution et de validation

### 4.1. Démarrer la réplique
Depuis PowerShell sur l'hôte :

```powershell
vagrant up bdd2
```

---

### 4.2. Commandes de vérification de la réplication

#### Test 1 : Contrôle du flux depuis `bdd1`
Vérifier que `bdd1` a bien un processus émetteur (*walsender*) vers `bdd2` :

```powershell
vagrant ssh bdd1 -c "sudo -u postgres psql -x -c 'SELECT client_addr, state, sync_state, replay_lsn FROM pg_stat_replication;'"
```
**Résultat attendu :**
- `client_addr` : `192.168.62.32`
- `state` : `streaming`

Contrôle complémentaire côté réplique :

```powershell
vagrant ssh bdd2 -c "sudo -u postgres psql -x -c 'SELECT status, sender_host, received_lsn FROM pg_stat_wal_receiver;'"
```
**Résultat attendu :** `status` vaut `streaming`.

#### Test 2 : Contrôle de l'état Standby sur `bdd2`
Vérifier que `bdd2` est bien en mode récupération continue (lecture seule) :

```powershell
vagrant ssh bdd2 -c "sudo -u postgres psql -c 'SELECT pg_is_in_recovery();'"
```
**Résultat attendu :**
```text
 pg_is_in_recovery 
-------------------
 t
(1 row)
```
*(Le `t` signifie True).*

#### Test 3 : Vérification de la présence des 50 000 lignes sur `bdd2`
```powershell
vagrant ssh bdd2 -c "sudo -u postgres psql -d resultats -c 'SELECT count(*) FROM resultats;'"
```
**Résultat attendu :** `50000`.

---

## 5. Procédure de Bascule (Failover — Scénario V4)

Le scénario V4 de Brigitte consiste à simuler la perte brutale de la primaire `bdd1` et à vérifier que le service reste disponible.

### Étape 1 : Simulation du crash de `bdd1`
```powershell
vagrant halt bdd1
```

### Étape 2 : Promotion de `bdd2` en nouvelle primaire
Depuis `bdd2`, exécuter la fonction SQL de promotion :

```powershell
vagrant ssh bdd2 -c "sudo -u postgres psql -c 'SELECT pg_promote();'"
```
PostgreSQL supprime alors `standby.signal` et passe immédiatement en lecture-écriture.

### Étape 3 : Constat côté applicatif
Le service Flask configuré par Soumana DAMA utilise la chaîne :
`host=bdd1,bdd2 target_session_attrs=read-write`

Les nouvelles connexions peuvent sélectionner `bdd2` lorsqu'il est promu et que
`bdd1` est indisponible. Ce mécanisme ne promeut pas la base automatiquement et
ne garantit pas qu'une requête en cours survive à la panne. La promotion est
manuelle; ne pas redémarrer l'ancienne primaire avant d'avoir défini comment la
réintégrer, afin d'éviter deux primaires indépendantes (split-brain).

---

## 6. Récapitulatif des règles à respecter

- **R1 (Reproductibilité) :** La destruction (`vagrant destroy -f bdd2`) puis recréation (`vagrant up bdd2`) doit réinitialiser la réplique sans accroc.
- **R2 (Idempotence) :** Une réplique existante est conservée; un répertoire présent sans `standby.signal` entraîne un arrêt explicite plutôt qu'un écrasement.
- **R6 (Secrets) :** Les mots de passe sont reçus par variables d'environnement (`REPLIC_MOT_DE_PASSE`), jamais écrits en dur.
