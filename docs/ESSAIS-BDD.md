# Essais des bases de données — pour Brigitte

## Contexte

Vérifications effectuées le **9 novembre 2026** sur les VM VirtualBox du
projet. `bdd1` et `bdd2` ont été démarrées, `bdd2` reprovisionnée avec la
configuration d'accès applicatif, puis `app1` provisionnée pour tester la
connexion. Aucun secret n'est consigné dans ce compte rendu.

## Commandes SQL et résultats

Les commandes suivantes ont été exécutées depuis PowerShell, à la racine du
dépôt.

### Nombre de lignes

```powershell
vagrant ssh bdd1 -c "sudo -u postgres psql -d resultats -tAc 'SELECT count(*) FROM resultats;'"
vagrant ssh bdd2 -c "sudo -u postgres psql -d resultats -tAc 'SELECT count(*) FROM resultats;'"
```

Résultat observé sur chacune des deux bases : `50000`.

### État et écoute de `bdd2`

```powershell
vagrant ssh bdd2 -c "sudo -u postgres psql -tAc 'SELECT pg_is_in_recovery();'"
vagrant ssh bdd2 -c "sudo -u postgres psql -tAc 'SELECT status FROM pg_stat_wal_receiver;'"
vagrant ssh bdd2 -c "sudo -u postgres psql -tAc 'SHOW listen_addresses;'"
```

Résultats : `pg_is_in_recovery() = t` (bdd2 est en standby),
`status = streaming` et `listen_addresses = 0.0.0.0`.

### Flux de réplication vu depuis `bdd1`

```powershell
vagrant ssh bdd1 -c "sudo -u postgres psql -tAc 'SELECT client_addr || chr(9) || state FROM pg_stat_replication;'"
```

Résultat observé : `192.168.62.32/32`, état `streaming`.

### Reprovisionnement de `bdd2`

```powershell
vagrant provision bdd2
```

Le reprovisionnement a réussi. Le script a confirmé que la copie standby
existante était conservée et que le standby était opérationnel.

### Vérification depuis l'application

La connexion TCP de l'application vers `bdd2`, avec les identifiants applicatifs
déjà configurés sur `app1`, a réussi. La requête `SELECT count(*) FROM
resultats` a renvoyé `50000`.

```powershell
vagrant ssh app1 -c "curl -s -i --max-time 10 http://127.0.0.1:8000/sante"
```

Résultat observé : `HTTP/1.1 200 OK` et `{"statut":"ok"}`.

## Limite de cet essai

Ces tests valident la topologie normale : `bdd1` est restée primaire et `bdd2`
est restée en standby. **Aucune promotion de `bdd2` ni mesure d'interruption
V4 n'a été effectuée dans cet essai.**
