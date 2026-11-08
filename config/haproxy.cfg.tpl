# =============================================================================
# /etc/haproxy/haproxy.cfg - FICHIER GENERE AUTOMATIQUEMENT par scripts/lb.sh
#   Modele  : config/haproxy.cfg.tpl
#   Source  : config/noeuds.yml (source unique de verite, ecrite par le Vagrantfile)
# Ne pas modifier a la main : toute modification serait ecrasee au prochain
# 'vagrant up' ou 'vagrant provision'.
# =============================================================================

global
    log /dev/log local0
    maxconn 4096
    user haproxy
    group haproxy
    daemon
    # Socket d'administration : permet de retirer un serveur proprement (E4)
    stats socket /run/haproxy/admin.sock mode 660 level admin

defaults
    mode http
    log global
    option httplog
    option dontlognull
    # Delai maximal pour etablir une connexion vers un serveur applicatif
    timeout connect 2s
    timeout client 30s
    timeout server 30s
          # Delai maximal de reponse a une sonde de sante, une fois connecte.
       # 3 s car /sante peut attendre 2 s sur bdd1 en panne avant d'essayer bdd2
       # (minimum de libpq) : avec 1 s, tous les serveurs seraient ecartes a tort
       # apres la bascule de la base (V4). La connexion de la sonde reste limitee
       # a min(timeout connect, inter) = 1 s : un serveur eteint est ecarte en ~2 s.
       timeout check 3s
    # En cas d'echec de connexion : 2 nouvelles tentatives,
    # sur un AUTRE serveur (redispatch) -> moins de requetes perdues (V2)
    retries 2
    option redispatch

# --- Point d'entree : seul port expose vers l'hote (8080 -> 80, R8) ----------
frontend entree_web
    bind 0.0.0.0:80
    # GET /repartiteur : renvoie le nom du repartiteur qui a repondu.
    # Sert a observer la bascule lb1 -> lb2 (scenario V6), sans serveur applicatif.
    http-request return status 200 content-type text/plain lf-string "%[hostname]" if { path /repartiteur }
    default_backend serveurs_app

# --- Serveurs applicatifs -----------------------------------------------------
backend serveurs_app
    # Tourniquet : chaque serveur recoit une requete a tour de role (V1)
    balance roundrobin
    # Sonde de sante (R4) : GET /sante doit repondre 200, sinon serveur ecarte
    option httpchk
    http-check send meth GET uri /sante
    http-check expect status 200
    # Sonde toutes les 1 s ; ecarte apres 2 echecs (~2 s < 5 s exiges) ;
    # reintegre apres 2 succes
    default-server inter 1s fall 2 rise 2
    # Liste generee depuis noeuds.yml (aucune adresse en dur) :
@SERVEURS@

# --- Page de statistiques : http://<ip lb1>:8404/stats (reseau prive) ---------
listen statistiques
    bind 0.0.0.0:8404
    stats enable
    stats uri /stats
    stats refresh 2s
    # Affiche le nom de la machine (lb1 ou lb2) en tete de page
    stats show-node