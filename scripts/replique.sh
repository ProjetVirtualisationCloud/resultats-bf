#!/usr/bin/env bash
# =============================================================================
# replique.sh - Provisionnement de bdd2 (PostgreSQL 16 en standby).
# Le cluster initial de Debian est conserve : la replique est clonee dans
# un repertoire distinct, puis activee par la configuration du cluster.
# Un cluster existant sans standby.signal n'est jamais ecrase.
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PGVER=16
CLUSTER=main
PGDATA="/var/lib/postgresql/${PGVER}/replica"
PGCONF="/etc/postgresql/${PGVER}/${CLUSTER}/postgresql.conf"
PASSFILE="/var/lib/postgresql/.pgpass-resultats-bf"
STAGING=""
PASS_TMP=""
CONFIG_TMP=""
AUTO_CONF_TMP=""
HBA_TMP=""
CLUSTER_STOPPED=0
REPLICA_INSTALLED=0

cleanup() {
  local status=$?
  if [ -n "$STAGING" ] && [ -d "$STAGING" ]; then
    rm -rf -- "$STAGING"
  fi
  if [ -n "$PASS_TMP" ]; then
    rm -f -- "$PASS_TMP"
  fi
  if [ -n "$CONFIG_TMP" ]; then
    rm -f -- "$CONFIG_TMP"
  fi
  if [ -n "$AUTO_CONF_TMP" ]; then
    rm -f -- "$AUTO_CONF_TMP"
  fi
  if [ -n "$HBA_TMP" ]; then
    rm -f -- "$HBA_TMP"
  fi
  if [ "$status" -ne 0 ] && [ "$CLUSTER_STOPPED" = "1" ]; then
    systemctl start postgresql || echo "[replique] ERREUR : impossible de redemarrer PostgreSQL apres l'echec" >&2
  fi
  exit "$status"
}
trap cleanup EXIT

echo "[replique] $(hostname) : debut du provisionnement"

if [ -z "${REPLIC_UTILISATEUR:-}" ] || [ -z "${REPLIC_MOT_DE_PASSE:-}" ]; then
  echo "[replique] ERREUR : identifiants de replication absents" >&2
  exit 1
fi
if [ -z "${DB_NOM:-}" ] || [ -z "${DB_UTILISATEUR:-}" ]; then
  echo "[replique] ERREUR : identifiants de la base applicative absents" >&2
  exit 1
fi

PRIMARY_IP=$(python3 - <<'PYEOF'
import yaml

with open("/vagrant/config/noeuds.yml") as f:
    noeuds = yaml.safe_load(f)["noeuds"]
primaire = next((n for n in noeuds if n["nom"] == "bdd1" and n["role"] == "bdd"), None)
if primaire is None:
    raise SystemExit("bdd1 introuvable dans config/noeuds.yml")
print(primaire["ip"])
PYEOF
)
RESEAU=$(python3 - <<'PYEOF'
import yaml

with open("/vagrant/config/noeuds.yml") as f:
    print(yaml.safe_load(f)["reseau"])
PYEOF
)

if ! dpkg -s "postgresql-${PGVER}" >/dev/null 2>&1; then
  apt-get install -y -q "postgresql-${PGVER}"
fi

PASS_TMP=$(mktemp /var/lib/postgresql/.resultats-bf-pgpass.XXXXXX)
python3 - "$PASS_TMP" "$PRIMARY_IP" <<'PYEOF'
import os
import sys

def echapper(valeur):
    return valeur.replace("\\", "\\\\").replace(":", "\\:")

chemin, hote = sys.argv[1:]
utilisateur = os.environ["REPLIC_UTILISATEUR"]
mot_de_passe = os.environ["REPLIC_MOT_DE_PASSE"]
with open(chemin, "w", encoding="utf-8") as f:
    f.write(f"{echapper(hote)}:5432:replication:{echapper(utilisateur)}:{echapper(mot_de_passe)}\n")
os.chmod(chemin, 0o600)
PYEOF
chown postgres:postgres "$PASS_TMP"

if [ -e "$PGDATA" ] || [ -L "$PGDATA" ]; then
  if [ ! -f "${PGDATA}/standby.signal" ]; then
    if pg_isready -h /var/run/postgresql -p 5432 -t 3 >/dev/null 2>&1; then
      if PROMOTION_STATE=$(sudo -u postgres psql -h /var/run/postgresql -p 5432 -tAc "SELECT pg_is_in_recovery()" 2>/dev/null) &&
         [ "$PROMOTION_STATE" = "f" ]; then
        echo "[replique] bdd2 promue primaire : reconfiguration en replique ignoree"
        exit 0
      fi
    fi
    echo "[replique] ERREUR : ${PGDATA} existe sans standby.signal." >&2
    echo "[replique] Aucune donnee n'a ete remplacee. Inspecter l'etat du cluster avant toute reconstruction." >&2
    exit 1
  fi
  echo "[replique] Une copie standby existe deja."
else
  if ! pg_isready -h "$PRIMARY_IP" -p 5432 -t 3 >/dev/null; then
    echo "[replique] ERREUR : bdd1 (${PRIMARY_IP}:5432) ne repond pas." >&2
    exit 1
  fi

  systemctl stop postgresql
  CLUSTER_STOPPED=1
  STAGING=$(mktemp -d "/var/lib/postgresql/${PGVER}/.replica.XXXXXX")
  chown postgres:postgres "$STAGING"
  chmod 700 "$STAGING"

  echo "[replique] Clonage initial depuis bdd1 (${PRIMARY_IP})..."
  sudo -u postgres env PGPASSFILE="$PASS_TMP" pg_basebackup \
    --no-password \
    --host="$PRIMARY_IP" \
    --port=5432 \
    --username="$REPLIC_UTILISATEUR" \
    --pgdata="$STAGING" \
    --format=plain \
    --wal-method=stream \
    --write-recovery-conf \
    --checkpoint=fast \
    --progress

  mv "$STAGING" "$PGDATA"
  STAGING=""
  REPLICA_INSTALLED=1
fi

PASS_CHANGED=0
if ! cmp -s "$PASS_TMP" "$PASSFILE" 2>/dev/null; then
  install -o postgres -g postgres -m 600 "$PASS_TMP" "$PASSFILE"
  PASS_CHANGED=1
fi

CONFIG_CHANGED=0
AUTO_CONF="${PGDATA}/postgresql.auto.conf"
CONFIG_TMP=$(mktemp)
AUTO_CONF_TMP=$(mktemp)
python3 - "$PGCONF" "$CONFIG_TMP" "$AUTO_CONF" "$AUTO_CONF_TMP" "$PGDATA" "$PRIMARY_IP" "$REPLIC_UTILISATEUR" "$PASSFILE" <<'PYEOF'
import os
import re
import stat
import sys

conf_path, conf_tmp, auto_path, auto_tmp, pgdata, host, user, passfile = sys.argv[1:]
begin = "# BEGIN resultats-bf replica"
end = "# END resultats-bf replica"

def managed(content, block):
    pattern = re.compile(r"(?m)^" + re.escape(begin) + r"\n.*?^" + re.escape(end) + r"\n?", re.S)
    content = pattern.sub("", content)
    return content.rstrip() + "\n\n" + begin + "\n" + block.rstrip() + "\n" + end + "\n"

with open(conf_path, encoding="utf-8") as f:
    conf = f.read()
conf = managed(conf, f"data_directory = '{pgdata}'\nlisten_addresses = '0.0.0.0'\nhot_standby = on")
with open(conf_tmp, "w", encoding="utf-8") as f:
    f.write(conf)

def conninfo_quote(value):
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"

conninfo = " ".join((
    f"host={conninfo_quote(host)}",
    "port=5432",
    f"user={conninfo_quote(user)}",
    f"passfile={conninfo_quote(passfile)}",
    "application_name=bdd2",
))
config_value = "'" + conninfo.replace("\\", "\\\\").replace("'", "\\'") + "'"

with open(auto_path, encoding="utf-8") as f:
    auto = f.read()
auto = re.sub(r"(?m)^\s*primary_conninfo\s*=.*\n?", "", auto)
auto = auto.rstrip() + f"\n\nprimary_conninfo = {config_value}\n"
with open(auto_tmp, "w", encoding="utf-8") as f:
    f.write(auto)

for temporary, target in ((conf_tmp, conf_path), (auto_tmp, auto_path)):
    old = os.stat(target)
    os.chmod(temporary, stat.S_IMODE(old.st_mode))
    os.chown(temporary, old.st_uid, old.st_gid)
PYEOF

if ! cmp -s "$CONFIG_TMP" "$PGCONF"; then
  install -o root -g root -m 644 "$CONFIG_TMP" "$PGCONF"
  CONFIG_CHANGED=1
fi
if ! cmp -s "$AUTO_CONF_TMP" "$AUTO_CONF"; then
  install -o postgres -g postgres -m 600 "$AUTO_CONF_TMP" "$AUTO_CONF"
  CONFIG_CHANGED=1
fi
rm -f "$CONFIG_TMP" "$AUTO_CONF_TMP"

PGHBA="/etc/postgresql/${PGVER}/${CLUSTER}/pg_hba.conf"
HBA_TMP=$(mktemp "${PGHBA}.XXXXXX")
HBA_CHANGED=$(python3 - "$PGHBA" "$HBA_TMP" "$DB_NOM" "$DB_UTILISATEUR" "$RESEAU" <<'PYEOF'
import os
import re
import stat
import sys

path, temporary, database, user, network = sys.argv[1:]
begin = "# BEGIN resultats-bf application"
end = "# END resultats-bf application"
block = (
    f"{begin}\n"
    f"host    {database}    {user}    {network}.0/24    scram-sha-256\n"
    f"{end}\n"
)

with open(path, encoding="utf-8") as f:
    original = f.read()
pattern = re.compile(r"(?m)^" + re.escape(begin) + r"\n.*?^" + re.escape(end) + r"\n?", re.S)
updated = pattern.sub("", original).rstrip() + "\n\n" + block

if updated == original:
    print("0")
else:
    metadata = os.stat(path)
    with open(temporary, "w", encoding="utf-8") as f:
        f.write(updated)
    os.chmod(temporary, stat.S_IMODE(metadata.st_mode))
    os.chown(temporary, metadata.st_uid, metadata.st_gid)
    os.replace(temporary, path)
    print("1")
PYEOF
)

if [ "$REPLICA_INSTALLED" = "1" ] || [ "$PASS_CHANGED" = "1" ] || [ "$CONFIG_CHANGED" = "1" ]; then
  systemctl restart postgresql
elif [ "$HBA_CHANGED" = "1" ]; then
  if systemctl is-active --quiet postgresql; then
    systemctl reload postgresql
  else
    systemctl start postgresql
  fi
else
  systemctl start postgresql
fi
rm -f -- "$HBA_TMP"
HBA_TMP=""
CLUSTER_STOPPED=0
systemctl enable --quiet postgresql

RECOVERY=""
RECEIVER=""
LISTEN=""
for _ in $(seq 1 30); do
  if RECOVERY=$(sudo -u postgres psql -h /var/run/postgresql -p 5432 -tAc "SELECT pg_is_in_recovery()" 2>/dev/null) &&
     [ "$RECOVERY" = "t" ]; then
    LISTEN=$(sudo -u postgres psql -h /var/run/postgresql -p 5432 -tAc "SHOW listen_addresses" 2>/dev/null || true)
    if [ "$REPLICA_INSTALLED" = "0" ]; then
      break
    fi
    RECEIVER=$(sudo -u postgres psql -h /var/run/postgresql -p 5432 -tAc "SELECT status FROM pg_stat_wal_receiver" 2>/dev/null || true)
    if [ "$RECEIVER" = "streaming" ]; then
      break
    fi
  fi
  sleep 1
done
if [ "$RECOVERY" != "t" ]; then
  echo "[replique] ERREUR : PostgreSQL n'est pas demarre en mode standby." >&2
  exit 1
fi
if [ "$REPLICA_INSTALLED" = "1" ] && [ "$RECEIVER" != "streaming" ]; then
  echo "[replique] ERREUR : la copie a demarre, mais le flux WAL depuis bdd1 n'est pas actif." >&2
  exit 1
fi
if [ "$LISTEN" != "0.0.0.0" ]; then
  echo "[replique] ERREUR : PostgreSQL n'ecoute pas sur le reseau (listen_addresses=${LISTEN:-indisponible})." >&2
  exit 1
fi

echo "[replique] $(hostname) : standby operationnel, pg_is_in_recovery() = true, listen_addresses = ${LISTEN}"
