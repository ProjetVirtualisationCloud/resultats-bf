#!/usr/bin/env bash
# =============================================================================
# app.sh — Provisionnement des serveurs applicatifs (app1 … appN)
#   1. Installe Python 3, Flask, psycopg2 et gunicorn (en une seule commande).
#   2. Déploie app/app.py dans /opt/resultats-bf/.
#   3. Écrit les secrets dans /etc/resultats-bf/app.env (droits 640,
#      propriétaire root:www-data) — jamais dans le dépôt Git (R7).
#   4. Crée le service systemd resultats-bf et le démarre sur 0.0.0.0:8000.
# Idempotent (R2) : rejouer deux fois ne change rien et n'échoue pas.
# =============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "[app] $(hostname) : début"

# --- 1. Paquets (installation groupée, une seule fois) -----------------------
if ! dpkg -s python3-flask python3-psycopg2 gunicorn >/dev/null 2>&1; then
  apt-get install -y -q python3-flask python3-psycopg2 gunicorn
fi

# --- 2. Répertoire de l'application ------------------------------------------
install -d -m 755 /opt/resultats-bf

# Ne recopier app.py que s'il a changé (idempotence + pas de redémarrage inutile)
MODIFIE=0
if ! cmp -s /vagrant/app/app.py /opt/resultats-bf/app.py 2>/dev/null; then
  install -m 644 /vagrant/app/app.py /opt/resultats-bf/app.py
  echo "[app] app.py mis à jour"
  MODIFIE=1
fi

# --- 3. Fichier des secrets (droits 640, lu par www-data via EnvironmentFile) -
install -d -m 750 /etc/resultats-bf
# Écriture dans un fichier temporaire d'abord, puis comparaison
cat > /tmp/resultats-bf-app.env <<ENV
DB_NOM=${DB_NOM}
DB_UTILISATEUR=${DB_UTILISATEUR}
DB_MOT_DE_PASSE=${DB_MOT_DE_PASSE}
ENV
if ! cmp -s /tmp/resultats-bf-app.env /etc/resultats-bf/app.env 2>/dev/null; then
  install -o root -g www-data -m 640 \
    /tmp/resultats-bf-app.env /etc/resultats-bf/app.env
  echo "[app] variables d'environnement mises à jour"
  MODIFIE=1
fi
rm -f /tmp/resultats-bf-app.env

# --- 4. Service systemd -------------------------------------------------------
# 3 workers sur une VM à 1 CPU : bon compromis pour les mesures de charge (V3)
cat > /tmp/resultats-bf.service <<UNIT
[Unit]
Description=RESULTATS-BF — service applicatif
After=network.target

[Service]
EnvironmentFile=/etc/resultats-bf/app.env
WorkingDirectory=/opt/resultats-bf
ExecStart=/usr/bin/gunicorn --workers 3 --bind 0.0.0.0:8000 app:app
Restart=always
RestartSec=2
User=www-data
Group=www-data

[Install]
WantedBy=multi-user.target
UNIT

SERVICE=/etc/systemd/system/resultats-bf.service
if ! cmp -s /tmp/resultats-bf.service "$SERVICE" 2>/dev/null; then
  install -m 644 /tmp/resultats-bf.service "$SERVICE"
  systemctl daemon-reload
  echo "[app] service systemd mis à jour"
  MODIFIE=1
fi
rm -f /tmp/resultats-bf.service

# --- 5. Activation et démarrage (redémarre seulement si quelque chose a changé)
systemctl enable --quiet resultats-bf
if [ "$MODIFIE" = "1" ] || ! systemctl is-active --quiet resultats-bf; then
  systemctl restart resultats-bf
  echo "[app] service redémarré"
else
  echo "[app] service inchangé : rien à faire"
fi

echo "[app] $(hostname) : terminé — http://$(hostname -I | awk '{print $2}'):8000/sante"
