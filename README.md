# RÉSULTATS-BF — Infrastructure résiliente et scalable avec Vagrant

Plateforme de consultation des résultats d'examen par numéro de matricule.
**Toute l'infrastructure est décrite en code** : une seule commande la reconstruit
sur n'importe quel poste, sans aucun geste manuel.

> Projet de groupe — Master Informatique, module DevOps et infrastructures
> reproductibles — Enseignant : Dr Flavien Hervé SOMDA — Groupe 7 — 2026-2027

---

## 1. Architecture

```
          Hôte : http://localhost:8080   (seul port exposé, R8)
                        │
                   ┌────▼────┐
                   │   lb1   │  HAProxy — répartition + sonde /sante
                   │   .11   │
                   └────┬────┘
           ┌────────────┼────────────┐
      ┌────▼───┐   ┌────▼───┐   ┌────▼───┐
      │  app1  │   │  app2  │ … │  appN  │  serveurs applicatifs sans état
      │  .21   │   │  .22   │   │  .2N   │
      └────┬───┘   └────┬───┘   └────┬───┘
           └────────────┼────────────┘
                   ┌────▼────┐  réplication  ┌─────────┐
                   │  bdd1   │ ────────────► │  bdd2   │
                   │   .31   │   en flux     │   .32   │
                   └─────────┘               └─────────┘
```

Réseau privé hôte-seul du groupe 7 : **192.168.62.0/24** (règle : `192.168.(55+G).0/24`).

| Machine | Rôle | Adresse | RAM |
|---|---|---|---|
| bdd1 | Base de données primaire (PostgreSQL) | 192.168.62.31 | 768 Mo |
| bdd2 | Réplique en flux, promouvable | 192.168.62.32 | 768 Mo |
| app1 … appN | Serveurs applicatifs (N ≥ 2, port 8000) | 192.168.62.21 … | 512 Mo |
| lb1 | Répartiteur de charge HAProxy | 192.168.62.11 | 512 Mo |

**Source unique de vérité.** La table des machines est définie une seule fois dans
le `Vagrantfile`, puis écrite dans `config/noeuds.yml`. Les scripts la lisent dans
les VM : la configuration du répartiteur est **engendrée** à partir d'elle, aucune
adresse n'est écrite en dur.

---

## 2. Prérequis

| Outil | Version testée |
|---|---|
| VirtualBox | 7.2 |
| Vagrant | 2.4.9 |
| Git | 2.5x |
| Box | `bento/ubuntu-24.04` version **202510.26.0** (épinglée) |

Poste de 8 Go de RAM minimum. Le socle (5 VM) consomme environ 3 Go.

---

## 3. Démarrage rapide

```powershell
# 1. Récupérer le dépôt
   git clone https://github.com/ProjetVirtualisationCloud/resultats-bf.git
cd resultats-bf

# 2. Créer le fichier des secrets à partir du modèle (jamais versionné)
copy .env.exemple .env          # sous Linux / macOS : cp .env.exemple .env
```

Ouvrir `.env` et remplacer les deux valeurs `a_remplacer` par des mots de passe
(lettres et chiffres uniquement). Ne rien modifier d'autre.

```powershell
# 3. Construire toute la plateforme (première fois : 20 à 40 minutes)
vagrant up

# 4. Vérifier
vagrant status
curl.exe http://localhost:8080/info
```

Le Vagrantfile s'arrête avec un message clair si `.env` est absent ou si un mot de
passe vaut encore `a_remplacer`.

---

## 4. Opérations courantes

| Besoin | Commande |
|---|---|
| État des machines | `vagrant status` |
| Démarrer une seule machine | `vagrant up lb1` |
| Se connecter à une machine | `vagrant ssh app1` |
| Rejouer le provisionnement (idempotent) | `vagrant provision` |
| Éteindre tout | `vagrant halt` |
| Reconstruire de zéro (R1) | `vagrant destroy -f` puis `vagrant up` |
| Statistiques du répartiteur | navigateur : http://192.168.62.11:8404/stats |

### Ajouter des serveurs applicatifs (R3)

Une seule valeur change : `NB_APP` (2 par défaut, de 2 à 9).

```powershell
# PowerShell (Windows)
$env:NB_APP=4; vagrant up; Remove-Item Env:NB_APP

# Bash (Linux / macOS)
NB_APP=4 vagrant up
```

`vagrant up` crée app3 et app4, puis reprovisionne automatiquement lb1
(`run: "always"`) : la configuration HAProxy est régénérée avec les 4 serveurs.

> **Attention, Windows :** la syntaxe `NB_APP=4 vagrant up` de l'énoncé est une
> syntaxe bash. Sous PowerShell, utiliser `$env:NB_APP=4; ...`.

### Retirer des serveurs applicatifs

Toujours **retirer du répartiteur d'abord**, puis détruire, pour ne perdre aucune requête :

```powershell
vagrant provision lb1                                       # 1. lb1 revient à 2 serveurs
$env:NB_APP=4; vagrant destroy -f app3 app4; Remove-Item Env:NB_APP   # 2. destruction
```


### Extension E1 : répartiteur redondant (lb2 + IP virtuelle)

Un second répartiteur, **lb2**, partage avec lb1 une **IP virtuelle** grâce à keepalived
(protocole VRRP). lb1 (priorité 150) porte l'IP virtuelle ; si lb1 tombe, lb2
(priorité 100) la reprend en quelques secondes. Les visiteurs utilisent toujours la
même adresse.

| Élément | Valeur (groupe 7) |
|---|---|
| IP virtuelle (adresse du service) | `192.168.62.10` |
| lb1 (maître) / lb2 (secours) | `192.168.62.11` / `192.168.62.12` |
| Activation | `AVEC_LB2=1` dans `.env` (6 VM au lieu de 5) |

```powershell
# Activer E1 : mettre AVEC_LB2=1 dans .env, puis
vagrant up lb1 lb2

# Quel répartiteur porte l'IP virtuelle ?
curl.exe http://192.168.62.10/repartiteur        # répond lb1 (ou lb2 après une panne)

# Page d'état de HAProxy (titre : lb1 ou lb2)
# navigateur : http://192.168.62.10:8404/stats
```

> Avec E1, utiliser l'IP virtuelle `http://192.168.62.10/` plutôt que
> `http://localhost:8080` : le port 8080 n'est exposé que par lb1 et disparaît si lb1 tombe.

### Mesurer une interruption de service

L'outil `tests/surveiller.ps1` interroge une adresse environ 4 fois par seconde, horodate
chaque réponse et calcule un bilan : requêtes perdues, disponibilité, durée d'interruption.
Une réponse HTTP d'erreur (par exemple 503) compte comme un échec. Précision : environ ± 0,5 s.

```powershell
powershell -ExecutionPolicy Bypass -File tests\surveiller.ps1 `
    -Url http://192.168.62.10/info -Duree 60 -Fichier mesures\exemple.txt
```

| Paramètre | Rôle | Défaut |
|---|---|---|
| `-Url` | Adresse interrogée | `http://192.168.62.10/repartiteur` |
| `-Duree` | Durée de la mesure (s) | 60 |
| `-Intervalle` | Pause entre deux requêtes (ms) | 200 |
| `-Fichier` | Fichier de sortie (preuve brute) | aucun |
---

## 5. Organisation du dépôt

```
resultats-bf/
├── Vagrantfile              Description de toutes les VM (source unique de vérité)
├── README.md                Ce mode d'emploi
├── .env.exemple             Modèle des secrets et réglages (versionné, sans vrai mot de passe)
├── .env                     Secrets réels (NON versionné, créé par chaque membre)
├── .gitattributes           Force les fins de ligne LF (scripts exécutés sous Linux)
├── .gitignore               Exclut .env, .vagrant/, config/noeuds.yml, __pycache__/
├── config/
│   ├── haproxy.cfg.tpl      Modèle de configuration HAProxy
│   ├── keepalived.conf.tpl  Modèle de configuration keepalived (extension E1)
│   └── noeuds.yml           Engendré par le Vagrantfile (non versionné)
├── scripts/
│   ├── commun.sh            Toutes les VM : paquets de base, /etc/hosts
│   ├── bdd.sh               bdd1 : PostgreSQL primaire et 50 000 lignes
│   ├── replique.sh          bdd2 : réplique en flux
│   ├── app.sh               app1..N : service applicatif (gunicorn + systemd)
│   └── lb.sh                lb1, lb2 : HAProxy et keepalived, configuration engendrée
├── app/
│   ├── app.py               Service HTTP : /resultat, /sante, /info
│   └── README.md            Documentation du composant applicatif
├── tests/
│   └── surveiller.ps1       Mesure des interruptions (scénarios V1, V2, V4, V6)
├── docs/
│   ├── DONNEES.md           Base de données, réplication, bascule
│   └── ESSAIS.md            Protocole des scénarios V1 à V6
└── mesures/                 Résultats bruts et analyses des scénarios
---

## 6. Règles de l'équipe

1. **Aucun secret dans Git.** Avant chaque commit : `git status` ne doit jamais lister `.env`.
2. **Fins de ligne LF.** Dans VS Code : paramètre *Files: Eol* = `\n` et
   *Insert Final Newline* activé. Contrôle : `git ls-files --eol` doit afficher `i/lf`.
3. **Tout script doit être idempotent** : le rejouer deux fois ne change rien.
   Interdit : ajouter des lignes avec `>>` sans vérifier qu'elles existent déjà.
4. **Tout service écoute sur `0.0.0.0`**, jamais sur `127.0.0.1` ni sur le nom de la
   machine (Vagrant associe ce nom à une adresse locale 127.0.x.x).
5. **Messages de commit explicites** : dire ce qui change.
6. **Une fois par semaine** : `vagrant destroy -f` puis `vagrant up` sur le poste
   d'un autre membre.

---

## 7. Équipe et rôles

| Rôle | Membre | Périmètre |
|---|---|---|
| Architecte réseau et répartition | BANCE François Xavier | Vagrantfile, plan d'adressage, HAProxy, sonde de santé, extension E1 |
| Ingénieur applicatif | DAMA Soumana | Service HTTP, absence d'état, gestion des erreurs de base |
| Ingénieur données | PANANDETIGUI  Hawa | PostgreSQL, jeu de données, réplication, bascule |
| Ingénieur essais et observabilité | DAMBRE  Brigitte | Scénarios V1 à V6, mesures, rédaction des résultats |

---

## 8. Avancement

| Élément | État |
|---|---|
| Vagrantfile, réseau privé, source unique de vérité | Fait |
| Répartiteur HAProxy, configuration engendrée, sonde /sante | Fait |
| Base de données bdd1 (50 000 lignes) | Fait |
| Réplication bdd1 → bdd2 | Fait (testée) |
| Procédure de bascule (promotion manuelle de bdd2) | Testée ; correction en cours (accès de l'application à bdd2) |
| Service applicatif | Fait |
| Extension E1 : lb2 + IP virtuelle | Fait ; bascule mesurée (V6) |
| Deuxième extension | À faire |
| Scénarios V1 à V5 | À faire |
| Scénario V6 : panne du répartiteur | Fait : 1,00 s d'interruption (`mesures/V6-analyse.txt`) |