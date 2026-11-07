# RÉSULTATS-BF — Composant Applicatif

> **Projet de groupe :** Master Informatique — DevOps et infrastructures reproductibles (2026-2027)  
> **Enseignant :** Dr Flavien Hervé SOMDA — Groupe 7  
> **Responsable du rôle applicatif :** Soumana DAMA  

---

## 1. Vue d'ensemble du rôle applicatif

Le rôle **Ingénieur applicatif** a la charge de concevoir, déployer et maintenir le service web de consultation des résultats d'examen. Ce service doit impérativement respecter les règles d'architecture imposées par le cahier des charges :

- **Absence d'état (Stateless — R5) :** Aucune session locale, aucun fichier d'état, aucun compteur en mémoire. Tout réside dans la base de données PostgreSQL. Cela rend le passage à l'échelle (scalabilité horizontale) immédiat et sans effet de bord.
- **Sonde de santé active (R4) :** Un point d'entrée dédié `/sante` permettant au répartiteur de charge (HAProxy) de connaître l'état réel du serveur et de sa connectivité base de données.
- **Résilience et bascule automatique (V4) :** Utilisation de la chaîne de connexion multi-hôtes `host=bdd1,bdd2` avec l'attribut `target_session_attrs=read-write` pour suivre automatiquement la primaire en cas de bascule vers `bdd2`.
- **Automatisation & Idempotence (R2) :** Déploiement automatisé via `scripts/app.sh`, rejouable à l'infini sans altération du système.
- **Sécurité et gestion des secrets (R6 & R7) :** Zéro secret dans le code ou dans Git. Les identifiants sont injectés via l'environnement système avec des droits d'accès stricts (`640` `root:www-data`).

---

## 2. Architecture logicielle

```
                  Requêtes HTTP (depuis HAProxy ou client)
                                     │
                                     ▼
                       ┌───────────────────────────┐
                       │   Gunicorn (port 8000)    │  3 workers WSGI
                       │   Service Systemd         │  Ecoute 0.0.0.0 (R8)
                       └─────────────┬─────────────┘
                                     │
                                     ▼
                       ┌───────────────────────────┐
                       │   Flask (app/app.py)      │  Application sans état
                       └─────────────┬─────────────┘
                                     │
                                     ▼
                      psycopg2 (libpq failover)
                     target_session_attrs=read-write
                                     │
                     ┌───────────────┴───────────────┐
                     ▼                               ▼
             ┌───────────────┐               ┌───────────────┐
             │ bdd1 (Primaire)│               │ bdd2 (Replique)│
             │ 192.168.62.31 │               │ 192.168.62.32 │
             └───────────────┘               └───────────────┘
```

---

## 3. Spécification des points d'entrée (API)

L'application expose trois routes HTTP au format JSON :

### 3.1. `/sante` — Sonde de santé pour HAProxy
- **Méthode :** `GET`
- **Objectif :** Contrôler la capacité du nœud à traiter des requêtes métier.
- **Fonctionnement :** Exécute systématiquement un `SELECT 1` sur PostgreSQL.
- **Codes HTTP :**
  - `200 OK` : Base accessible et opérationnelle (`{"statut": "ok"}`).
  - `503 Service Unavailable` : Base indisponible ou coupée (`{"statut": "base indisponible"}`).
- **Impact HAProxy :** Dès réception d'un 503 ou d'un timeout (sonde toutes les 2s), HAProxy retire immédiatement ce nœud du trafic.

### 3.2. `/info` — Observabilité et vérification de la répartition
- **Méthode :** `GET`
- **Objectif :** Identifier le serveur applicatif qui répond à la requête (utilisé lors des scénarios V1 et V2).
- **Réponse exemple (200 OK) :**
  ```json
  {
    "machine": "app1",
    "version": "1.0"
  }
  ```

### 3.3. `/resultat` — Consultation d'un candidat
- **Méthode :** `GET /resultat?matricule=<MATRICULE>`
- **Objectif :** Renvoyer les informations d'un élève à partir de son numéro de matricule.
- **Sécurité :** Requête SQL paramétrée avec `%s` (protection totale contre les injections SQL).
- **Codes HTTP :**
  - `200 OK` : Candidat trouvé :
    ```json
    {
      "matricule": "BF00001",
      "nom": "TRAORE Fatou",
      "serie": "C",
      "moyenne": 13.7,
      "admis": true
    }
    ```
  - `400 Bad Request` : Paramètre `matricule` manquant dans l'URL.
  - `404 Not Found` : Matricule inexistant dans la base.
  - `503 Service Unavailable` : Panne de base de données (jamais de page blanche ni d'erreur 500 générique).

---

## 4. Détail du provisionnement (`scripts/app.sh`)

Le script de provisionnement est exécuté lors de `vagrant up appX` ou `vagrant provision appX`. Il est strictement **idempotent** :

1. **Installation des paquets :**
   Installe en une passe `python3-flask`, `python3-psycopg2` et `gunicorn` sans poser de question (`DEBIAN_FRONTEND=noninteractive`). L'installation est ignorée si les paquets sont déjà présents.
2. **Déploiement du code source :**
   Copie `app/app.py` vers `/opt/resultats-bf/app.py` uniquement si le fichier a été modifié (`cmp -s`).
3. **Configuration sécurisée de l'environnement :**
   Génère `/etc/resultats-bf/app.env` avec les identifiants transmis par Vagrant (`DB_NOM`, `DB_UTILISATEUR`, `DB_MOT_DE_PASSE`). Les droits sont verrouillés à `640` avec appartenance au groupe `www-data`.
4. **Service Systemd (`resultats-bf.service`) :**
   - Exécute Gunicorn avec **3 workers** (dimensionné pour 1 CPU virtuel).
   - Écoute sur `0.0.0.0:8000` (exigence R8).
   - Exécution sous l'utilisateur système restreint `www-data`.
   - Option `Restart=always` avec délai de reprise de 2 secondes.

---

## 5. Contribution conjointe à l'infrastructure de données (`bdd1`)

Afin de pouvoir tester et valider le service applicatif en conditions réelles, le rôle applicatif a également initialisé et validé la brique base de données :
- Démarrage et provisionnement de `bdd1` via [`scripts/bdd.sh`](../scripts/bdd.sh).
- Validation de l'insertion déterministe des **50 000 lignes** de résultats (matricules `BF00001` à `BF50000`).
- Préparation de l'environnement pour la réplication d'Hawa (`scripts/replique.sh`) : rôle `replicateur` créé, `wal_level = replica`, écoute `0.0.0.0`, permissions `pg_hba.conf` configurées.

---

## 6. Guide des commandes, tests et résultats réels

### 6.1. Commandes de déploiement

Pour déployer et démarrer l'infrastructure minimale permettant de valider le composant applicatif, exécuter dans l'ordre :

```powershell
# 1. Démarrer la base de données primaire (PostgreSQL 16 + 50 000 lignes)
vagrant up bdd1

# 2. Démarrer le premier serveur applicatif (Gunicorn + Flask)
vagrant up app1
```

---

### 6.2. Commandes de test exécutées

Depuis le terminal PowerShell de la machine hôte :

```powershell
# Test 1 : Sonde de santé (contrôle la connectivité avec PostgreSQL)
vagrant ssh app1 -c "curl -s http://127.0.0.1:8000/sante"

# Test 2 : Requête métier sur un vrai candidat dans la base
vagrant ssh app1 -c "curl -s 'http://127.0.0.1:8000/resultat?matricule=BF00001'"

# Test 3 : Route info (observabilité de la machine pour la répartition)
vagrant ssh app1 -c "curl -s http://127.0.0.1:8000/info"
```

---

### 6.3. Résultats réels obtenus (Sortie du terminal)

Voici la trace réelle de l'exécution sur l'environnement de développement :

![Capture d'écran des tests applicatifs](../mesures/test-app1-resultats.png)

```powershell
PS C:\Users\user\Desktop\resultats-bf-dama> # Test 1 : La sonde de santé (doit afficher {"statut": "ok"} car la base répond !)
>> vagrant ssh app1 -c "curl -s http://127.0.0.1:8000/sante"
>>
>> # Test 2 : Requête sur un vrai candidat dans la base
>> vagrant ssh app1 -c "curl -s 'http://127.0.0.1:8000/resultat?matricule=BF00001'"
>>
>> # Test 3 : Route info
>> vagrant ssh app1 -c "curl -s http://127.0.0.1:8000/info"
{"statut":"ok"}
{"admis":false,"matricule":"BF00001","moyenne":1.37,"nom":"TRAORE Fatou","serie":"F"}
{"machine":"app1","version":"1.0"}
PS C:\Users\user\Desktop\resultats-bf-dama> 
```

#### Analyse des résultats obtenus :
1. **`/sante` ➔ `{"statut":"ok"}` (HTTP 200) :**  
   Preuve que l'application a réussi à exécuter `SELECT 1` sur `bdd1` (`192.168.62.31:5432`) à travers le réseau privé hôte-seul.
2. **`/resultat?matricule=BF00001` ➔ `{"admis":false,"matricule":"BF00001","moyenne":1.37,"nom":"TRAORE Fatou","serie":"F"}` (HTTP 200) :**  
   Preuve que le composant applicatif extrait correctement les données métier typées (nom, série, moyenne en nombre décimal, statut d'admission en booléen) depuis la base PostgreSQL.
3. **`/info` ➔ `{"machine":"app1","version":"1.0"}` (HTTP 200) :**  
   Preuve que le nom d'hôte est dynamique et permettra à l'ingénieur observabilité de valider le round-robin du répartiteur de charge HAProxy.

---

### 6.4. Tests des cas limites et erreurs HTTP

```powershell
# Cas d'un matricule inexistant -> Attendu : HTTP 404
vagrant ssh app1 -c "curl -s -i 'http://127.0.0.1:8000/resultat?matricule=BF99999'"
# Sortie :
# HTTP/1.1 404 NOT FOUND
# {"erreur":"matricule 'BF99999' inconnu"}

# Cas du paramètre manquant -> Attendu : HTTP 400
vagrant ssh app1 -c "curl -s -i 'http://127.0.0.1:8000/resultat'"
# Sortie :
# HTTP/1.1 400 BAD REQUEST
# {"erreur":"parametre matricule manquant"}
```

---

### 6.5. Commandes d'administration et de diagnostic

```powershell
# Vérifier l'état du service systemd sur app1
vagrant ssh app1 -c "systemctl status resultats-bf"

# Consulter les journaux en direct de l'application
vagrant ssh app1 -c "journalctl -u resultats-bf -f"

# Redémarrer manuellement le service applicatif
vagrant ssh app1 -c "sudo systemctl restart resultats-bf"

# Rejouer le provisionnement de l'application (test d'idempotence)
vagrant provision app1
```

---

## 7. Conformité aux exigences du projet

| Règle | Intitulé | Prise en compte dans le rôle applicatif |
|---|---|---|
| **R1** | Reproductibilité | Entièrement automatisé dans `scripts/app.sh`, reconstruction sans geste manuel. |
| **R2** | Idempotence | Détection des modifications (`cmp`), pas de redémarrages ni d'écritures superflus. |
| **R3** | Scalabilité horizontale | Les serveurs app1..N sont totalement interchangeables, aucun couplage. |
| **R4** | Sonde de santé réelle | `/sante` exécute un `SELECT 1` obligatoire en base de données. |
| **R5** | Absence d'état | Zéro session locale, zéro cache en mémoire, zéro fichier disque persistant. |
| **R6** | Sécurité des secrets | Identifiants transmis par `EnvironmentFile` système, non stockés dans Git. |
| **R7** | Non-codage en dur | Paramètres de base lus via variables d'environnement (`os.environ`). |
| **R8** | Isolation réseau | Écoute sur `0.0.0.0:8000` sur le réseau privé hôte-seul `192.168.62.0/24`. |

