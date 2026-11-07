#!/usr/bin/env bash
# =============================================================================
# bdd.sh — Provisionnement de bdd1 (PostgreSQL primaire)
#   1. Installe PostgreSQL 16.
#   2. Configure listen_addresses = '0.0.0.0' et paramètres de réplication
#      (wal_level, max_wal_senders) — prêts pour replique.sh (bdd2).
#   3. Met à jour pg_hba.conf via marqueurs (idempotent, pas de doublons).
#   4. Crée les rôles, la base, la table resultats et 50 000 lignes.
# Idempotent (R2) : rejoué deux fois, il ne modifie rien et n'échoue pas.
# ATTENTION : PGDATA est dans /var/lib/postgresql — JAMAIS dans /vagrant (piège 3).
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PGVER=16

echo "[bdd] $(hostname) : début"

# Réseau privé lu depuis la source unique de vérité (cohérence avec lb.sh)
RESEAU=$(python3 -c \
  "import yaml; print(yaml.safe_load(open('/vagrant/config/noeuds.yml'))['reseau'])")

# --- 1. Installation (seulement si absent) ------------------------------------
RESTART_PG=0
if ! dpkg -s "postgresql-${PGVER}" >/dev/null 2>&1; then
  apt-get install -y -q "postgresql-${PGVER}"
  RESTART_PG=1
fi
systemctl start postgresql

# --- 2. Paramètres postgresql.conf via ALTER SYSTEM (idempotent) --------------
# ALTER SYSTEM écrit dans postgresql.auto.conf — rejouer ne change rien
# si les valeurs sont déjà les bonnes. listen_addresses exige un restart.
LISTEN_ACTUEL=$(sudo -u postgres psql -tAc "SHOW listen_addresses;" | tr -d ' ')
if [ "$LISTEN_ACTUEL" != "0.0.0.0" ]; then
  RESTART_PG=1
fi

sudo -u postgres psql -q <<'SQL'
ALTER SYSTEM SET listen_addresses  = '0.0.0.0';
ALTER SYSTEM SET wal_level         = 'replica';
ALTER SYSTEM SET max_wal_senders   = 5;
ALTER SYSTEM SET wal_keep_size     = '64';
SQL

# --- 3. pg_hba.conf : accès applicatif et réplication (marqueurs) -------------
python3 - <<PYEOF
import re

db_nom      = "${DB_NOM}"
db_user     = "${DB_UTILISATEUR}"
replic_user = "${REPLIC_UTILISATEUR}"
reseau      = "${RESEAU}"
pgver       = "${PGVER}"

bloc = (
    "# DEBUT resultats-bf (genere, ne pas modifier)\n"
    f"host    {db_nom:<16} {db_user:<20} {reseau}.0/24    scram-sha-256\n"
    f"host    replication      {replic_user:<20} {reseau}.32/32   scram-sha-256\n"
    "# FIN resultats-bf\n"
)

hba = f"/etc/postgresql/{pgver}/main/pg_hba.conf"
with open(hba) as f:
    contenu = f.read()
contenu = re.sub(r"# DEBUT resultats-bf.*?# FIN resultats-bf\n", "", contenu, flags=re.S)
with open(hba, "w") as f:
    f.write(contenu.rstrip("\n") + "\n" + bloc)
print("[bdd] pg_hba.conf mis a jour")
PYEOF

# --- 4. Redémarrage ou rechargement selon les besoins ------------------------
if [ "$RESTART_PG" = "1" ]; then
  systemctl restart postgresql
  echo "[bdd] PostgreSQL redémarré (nouvelle configuration)"
else
  systemctl reload postgresql
  echo "[bdd] PostgreSQL rechargé (pg_hba.conf)"
fi
systemctl enable --quiet postgresql

# --- 5. Rôle applicatif et rôle réplication (idempotents) --------------------
sudo -u postgres psql -q <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_UTILISATEUR}') THEN
    CREATE ROLE "${DB_UTILISATEUR}" LOGIN PASSWORD '${DB_MOT_DE_PASSE}';
    RAISE NOTICE 'role ${DB_UTILISATEUR} cree';
  ELSE
    ALTER ROLE "${DB_UTILISATEUR}" PASSWORD '${DB_MOT_DE_PASSE}';
  END IF;
END \$\$;

DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${REPLIC_UTILISATEUR}') THEN
    CREATE ROLE "${REPLIC_UTILISATEUR}" REPLICATION LOGIN
      PASSWORD '${REPLIC_MOT_DE_PASSE}';
    RAISE NOTICE 'role ${REPLIC_UTILISATEUR} cree';
  ELSE
    ALTER ROLE "${REPLIC_UTILISATEUR}" PASSWORD '${REPLIC_MOT_DE_PASSE}';
  END IF;
END \$\$;
SQL

# --- 6. Base de données (idempotent) -----------------------------------------
sudo -u postgres psql -tAc \
  "SELECT 1 FROM pg_database WHERE datname='${DB_NOM}'" | grep -q 1 || \
  sudo -u postgres psql -q \
    -c "CREATE DATABASE \"${DB_NOM}\" OWNER \"${DB_UTILISATEUR}\";"
echo "[bdd] base '${DB_NOM}' prête"

# --- 7. Table et données (idempotent) ----------------------------------------
sudo -u postgres psql -q -d "${DB_NOM}" <<SQL

-- Table (IF NOT EXISTS : idempotent)
CREATE TABLE IF NOT EXISTS resultats (
    matricule TEXT         PRIMARY KEY,
    nom       TEXT         NOT NULL,
    serie     TEXT         NOT NULL,
    moyenne   NUMERIC(4,2) NOT NULL CHECK (moyenne BETWEEN 0 AND 20),
    admis     BOOLEAN      NOT NULL
);

-- 50 000 lignes déterministes (même résultat à chaque vagrant up — R1).
-- i * 137 mod 2001 est une permutation uniforme (137 et 2001 sont coprimes).
-- WHERE NOT EXISTS : insérées seulement si la table est vide (idempotent).
INSERT INTO resultats (matricule, nom, serie, moyenne, admis)
SELECT
    'BF' || lpad(i::text, 5, '0'),
    (ARRAY['OUEDRAOGO','TRAORE','SAWADOGO','COMPAORE','ZONGO',
           'KABORE','SOME','DAO','DIALLO','SANOGO',
           'BARRY','COULIBALY','GUIRO','TIENDREBEOGO'])[(i % 14) + 1]
    || ' ' ||
    (ARRAY['Adama','Fatou','Moussa','Aissata','Ibrahim','Aminata',
           'Boureima','Mariam','Seydou','Rasmata',
           'Dramane','Salimata','Idrissa','Roukiatou'])[(i % 14) + 1],
    (ARRAY['A','C','D','F'])[((i * 7) % 4) + 1],
    round(((i * 137 % 2001) / 100.0)::numeric, 2),
    (i * 137 % 2001) >= 1000
FROM generate_series(1, 50000) AS s(i)
WHERE NOT EXISTS (SELECT 1 FROM resultats LIMIT 1);

-- Droits SELECT pour l'application (idempotent)
GRANT SELECT ON resultats TO "${DB_UTILISATEUR}";
SQL

NB=$(sudo -u postgres psql -d "${DB_NOM}" -tAc "SELECT count(*) FROM resultats")
echo "[bdd] $(hostname) : terminé — ${NB} lignes dans resultats, écoute 0.0.0.0:5432"
