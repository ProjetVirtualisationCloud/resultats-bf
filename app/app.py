#!/usr/bin/env python3
# =============================================================================
# app.py — Service applicatif RÉSULTATS-BF
# Trois points d'entrée : /resultat  /sante  /info
# Sans état : ni session, ni fichier local, ni compteur en mémoire.
# Tout vit dans la base — c'est ce qui rend l'ajout d'un serveur trivial.
# =============================================================================
import os
import socket
from flask import Flask, request, jsonify
import psycopg2

app = Flask(__name__)

# Paramètres lus dans l'environnement (jamais écrits en dur — R7).
# host=bdd1,bdd2 + target_session_attrs=read-write : psycopg2/libpq essaie
# bdd1 d'abord ; après une bascule (V4), il bascule sur bdd2 automatiquement.
DB_PARAMS = {
    "dbname":               os.environ.get("DB_NOM",          "resultats"),
    "user":                 os.environ.get("DB_UTILISATEUR",  "app_resultats"),
    "password":             os.environ.get("DB_MOT_DE_PASSE", ""),
    "host":                 "bdd1,bdd2",
    "target_session_attrs": "read-write",  # suit la primaire après bascule
    "connect_timeout":      "2",           # 2 s max — sinon HAProxy attend
}


def get_conn():
    """Ouvre une connexion PostgreSQL. Lève une exception si indisponible."""
    return psycopg2.connect(**DB_PARAMS)


# --- /sante -------------------------------------------------------------------
@app.route("/sante")
def sante():
    """200 si la base répond (SELECT 1), 503 sinon — sonde HAProxy (R4).
    Ne renvoie JAMAIS 200 par principe : la requête SQL est obligatoire."""
    try:
        conn = get_conn()
        cur  = conn.cursor()
        cur.execute("SELECT 1")
        cur.close()
        conn.close()
        return jsonify({"statut": "ok"}), 200
    except Exception:
        return jsonify({"statut": "base indisponible"}), 503


# --- /info --------------------------------------------------------------------
@app.route("/info")
def info():
    """Renvoie le nom d'hôte — permet d'observer la répartition (V1, V2)."""
    return jsonify({"machine": socket.gethostname(), "version": "1.0"}), 200


# --- /resultat ----------------------------------------------------------------
@app.route("/resultat")
def resultat():
    """Cherche un candidat par matricule.
    400 si le paramètre est absent.
    404 si le matricule est inconnu.
    503 si la base est indisponible — jamais une page blanche (V4)."""
    matricule = request.args.get("matricule")
    if not matricule:
        return jsonify({"erreur": "parametre matricule manquant"}), 400
    try:
        conn = get_conn()
        cur  = conn.cursor()
        cur.execute(
            "SELECT matricule, nom, serie, moyenne, admis"
            "  FROM resultats WHERE matricule = %s",
            (matricule,),
        )
        row = cur.fetchone()
        cur.close()
        conn.close()
    except Exception as e:
        return jsonify({"erreur": "base indisponible", "detail": str(e)}), 503
    if row is None:
        return jsonify({"erreur": f"matricule {matricule!r} inconnu"}), 404
    return jsonify({
        "matricule": row[0],
        "nom":       row[1],
        "serie":     row[2],
        "moyenne":   float(row[3]),
        "admis":     bool(row[4]),
    }), 200

