# Incidents de production

Ce document sert pendant un incident (où regarder, dans quel ordre) et après (post-mortem sans blâme).
Un post-mortem décrit ce qui s'est passé dans le système et dans nos outils, jamais qui s'est trompé :
on cherche ce qui a rendu l'erreur possible et ce qui l'aurait arrêtée plus tôt.

## Supervision en place

Stack `monitoring/` (`docker compose -f compose.monitoring.yaml up -d`), ports ouverts sur le poste uniquement.

| Outil | Adresse | Sert à |
|---|---|---|
| Mailpit | http://localhost:8025 | lire les mails d'alerte (`[FIRING]`, `[RESOLVED]`) |
| Alertmanager | http://localhost:9093 | alertes actives, poser un silence pendant une intervention |
| Prometheus | http://localhost:9090 | *Alerts*, *Targets*, requêtes PromQL |
| Grafana | http://localhost:3001 | dashboard *TaskFlow : RED et disponibilité* |

| Alerte | Signification | Premier réflexe |
|---|---|---|
| `TaskFlowApiDown` (critical) | `/health` ne répond pas `ok` à travers le front depuis 1 min | `probe_http_status_code` : 502 = le front ne joint pas l'API ; puis `ps` et les logs `fatal` de l'API |
| `TaskFlowMetricsAbsent` (warning) | Prometheus ne lit plus `api:3000/metrics` depuis 2 min | `ps` : l'API tourne-t-elle ? La version déployée a-t-elle `/metrics` ? |
| `TaskFlowHighErrorRate` (warning) | plus de 5 % de réponses 5xx pendant 5 min | logs `level=error` de l'API, état de la base |
| `TaskFlowSlowResponses` (warning) | p95 au-dessus de 500 ms pendant 10 min | panneau Duration par route, base, ressources du poste |
| `Watchdog` | toujours active, routée vers un récepteur vide | si elle disparaît d'Alertmanager, c'est la chaîne d'alerte qui est cassée |

## Méthode de diagnostic

Dans `~/taskflow-prod`. Noter chaque commande et ce qu'elle apprend : c'est la chronologie du post-mortem.

1. **Alerte** : laquelle, depuis quand, quelle cible (Alertmanager, Prometheus > *Alerts*).
2. **Dashboard** : depuis quand la disponibilité est tombée, la version a-t-elle changé ?
3. **Symptôme** : `curl -sk https://taskflow.localhost/health`, et la page dans le navigateur.
4. **Conteneurs** : `docker compose -f compose.prod.yaml ps` (`Restarting` = l'application meurt au démarrage).
5. **Logs** du service suspect, en ne gardant que l'anormal :
   `docker compose -f compose.prod.yaml logs --no-log-prefix --since 15m api | jq -c 'select(.level != "info")'`
6. **Cause racine** : la prouver. Ce que reçoit le conteneur (`docker inspect <conteneur> --format '{{range .Config.Env}}{{println .}}{{end}}'`,
   en masquant les secrets), ce que contient la configuration (`.env`, compose), ce qui a changé et quand (`ls -la`, `diff`).

Redéployer une ancienne image ne répare que ce qui est **dans** l'image. Une panne de configuration (`.env`)
survit à un rollback.

## Modèle de post-mortem

Copier ce modèle pour chaque incident, du plus récent au plus ancien.

```markdown
## Incident n° N - Titre court

**Gravité** : faible / moyenne / élevée
**Détection** : alerte <nom> / utilisateur / autre - délai entre le début et la détection : X min
**Durée** : début hh:mm - fin hh:mm (durée totale = temps de rétablissement)
**Rédaction** : ...

### Résumé
### Chronologie (heure, UTC ou locale : préciser)
### Cause racine (5 pourquoi)
### Ce qui a bien fonctionné
### Ce qui a moins bien fonctionné
### Actions
| Action | Type | Issue | Statut |
| --- | --- | --- | --- |
```

---

## Incident n° 1 - L'API redémarre en boucle : `DATABASE_URL` mal nommée dans le `.env` de la prod

**Gravité** : élevée (toute l'API indisponible)
**Détection** : alerte `TaskFlowApiDown` par mail - 1 min 28 s après le changement
**Durée** : 20/11/2026, de 10:58:48 à 11:01:45 UTC (11:58:48 à 12:01:45 heure de Paris), soit **2 min 57 s**
**Rédaction** : Ylian Merrir

### Résumé

Une modification du fichier `.env` de la production a renommé la variable `DATABASE_URL` en `DATABASE_UR`.
Recréée avec cette configuration, l'API ne trouvait plus l'adresse de la base, se rabattait sur sa valeur par
défaut (`localhost:5432`) et s'arrêtait au démarrage, en boucle. Pendant près de 3 minutes, la page d'accueil
s'affichait mais **toutes les actions** (lister, créer, cocher, supprimer une tâche) répondaient `502 Bad Gateway`.
Aucune donnée perdue.

### Chronologie (UTC, le 20/11/2026)

Heures relevées dans les outils, sauf celles marquées ≈ (étapes du diagnostic, à quelques secondes près).

| Heure | Événement | Source |
|---|---|---|
| 10:58:48 | `.env` modifié (`DATABASE_URL` → `DATABASE_UR`), l'API est recréée avec ce fichier | date du fichier `.env` |
| 10:58:50 | Premier log de l'API : `level: fatal`, « Démarrage impossible : ECONNREFUSED » ; puis redémarrages en boucle | `logs api` |
| 10:59:00 | La sonde blackbox voit `/health` en **502** (`probe_success` = 0) | Prometheus |
| 10:59:05 | `TaskFlowApiDown` passe *pending* (`for: 1m`) | Prometheus > *Alerts* |
| 11:00:05 | `TaskFlowApiDown` passe *firing* | Prometheus > *Alerts* |
| **11:00:16** | **Premier signal : mail `[FIRING:1] TaskFlowApiDown prod`** | Mailpit |
| 11:00:26 | Diagnostic : `probe_http_status_code` = 502 (le front répond, l'API non) ; `curl /health` → 502, page d'accueil → 200 | Prometheus, curl |
| ≈ 11:00:40 | `ps` : api `Restarting (1)`, 11 redémarrages, image `23aff37` inchangée ; db, front, proxy *healthy* | `docker compose ps`, `docker inspect` |
| ≈ 11:00:50 | Logs : uniquement `fatal ... ECONNREFUSED`, alors que la base est *healthy* : l'API vise la mauvaise adresse | `logs api` |
| ≈ 11:01:05 | Preuve : le conteneur ne reçoit pas `DATABASE_URL` ; le `.env` contient `DATABASE_UR`, seule différence avec `.env.bak` (même valeur) | `docker inspect`, `diff` |
| 11:01:23 | Correction : variable renommée en `DATABASE_URL`, API recréée (`up -d --force-recreate --wait api`) | terminal |
| 11:01:42 | API *healthy* | `docker compose ps` |
| 11:01:45 | Sonde verte (`probe_success` = 1) : **fin de l'indisponibilité** | Prometheus |
| 11:01:50 | `/health` → `ok`, `db: up` ; création d'une tâche → 201 | curl |
| 11:02:16 | Mail `[RESOLVED] TaskFlowApiDown prod` ; `.env.bak` supprimé (il contenait le mot de passe en clair) | Mailpit |

| Indicateur | Valeur |
|---|---|
| Temps de détection (changement → mail) | **1 min 28 s** (dont 1 min voulue par `for: 1m`) |
| Temps de rétablissement, MTTR (début → sonde verte) | **2 min 57 s** |
| Temps de réparation (mail → sonde verte) | 1 min 29 s |

### Comment l'alerte et le dashboard ont aidé

- L'alerte est partie du **symptôme utilisateur** (la sonde passe par le front, comme un navigateur) : elle a
  prévenu sans que personne ne regarde l'écran, et a nommé la cible (`http://front/health`).
- `probe_http_status_code` = 502 a orienté tout de suite vers « le front ne joint plus l'API » plutôt que vers
  le front ou le proxy.
- L'image dans `ps` était la **même version qu'avant** (`23aff37`) : la cause n'était pas une nouvelle release,
  donc inutile de tenter un rollback. Le panneau « Version en ligne » de Grafana aurait dû le montrer, mais il
  était vide : la prod n'expose pas encore `taskflow_build_info` (partie A pas encore déployée).
- Le panneau « Erreurs 5xx » ne montrait presque rien : une API qui ne démarre pas ne mesure rien, et ses
  métriques disparaissent avec elle. C'est pour ça que la disponibilité est sondée de l'extérieur (boîte noire).

### Cause racine (5 pourquoi)

1. **Pourquoi l'application répondait-elle 502 ?** Le Nginx du front ne joignait plus l'API, qui n'était jamais
   démarrée : elle s'arrêtait au lancement, en boucle.
2. **Pourquoi l'API s'arrêtait-elle ?** Elle n'arrivait pas à se connecter à la base (`ECONNREFUSED`) : elle
   visait `localhost:5432`, c'est-à-dire son propre conteneur, où aucune base n'écoute.
3. **Pourquoi visait-elle `localhost` ?** Elle ne recevait pas `DATABASE_URL`, et `config.js` prend alors une
   valeur par défaut faite pour le poste de développement.
4. **Pourquoi ne recevait-elle pas `DATABASE_URL` ?** Le `.env` de la production contenait `DATABASE_UR` à la
   place : une modification manuelle du fichier a tronqué le nom de la variable.
5. **Pourquoi cette modification a-t-elle pu partir en production ?** Rien ne vérifie le `.env` : ni comparaison
   avec `.env.example` au déploiement, ni contrôle au démarrage de l'API, qui accepte en production une valeur par
   défaut prévue pour le développement. L'erreur n'a été vue qu'une fois les utilisateurs touchés.

### Ce qui a bien fonctionné

- Détection automatique en 1 min 28 s, par mail, avec la bonne cible et la bonne gravité.
- Le log `fatal` donnait le bon indice (`Vérifiez DATABASE_URL`).
- La méthode (alerte → symptôme → conteneurs → logs → preuve) a mené à la cause en environ 1 minute, sans
  hypothèse hasardeuse ni rollback inutile.
- La base n'a jamais été touchée : aucune donnée perdue.
- Le mail `[RESOLVED]` a confirmé le retour à la normale sans avoir à surveiller l'écran.

### Ce qui a moins bien fonctionné

- L'API démarre en production sans `DATABASE_URL` au lieu de refuser avec un message clair : la valeur par défaut
  de développement a transformé une variable manquante en `ECONNREFUSED`, moins évident à lire.
- Le `.env` peut être modifié et appliqué sans aucun contrôle.
- `up -d --force-recreate api` a aussi recréé le conteneur de la base (dépendance) : sans conséquence ici, mais
  inutile. `--no-deps` aurait limité la correction à l'API.
- Une seule notification, par mail : un incident *critical* devrait aussi arriver là où l'équipe regarde.
- `TaskFlowMetricsAbsent` sonnait déjà avant l'incident (la prod `23aff37` n'expose pas encore `/metrics`) :
  une alerte qui sonne pour rien habitue à ignorer les mails. À résoudre en déployant la partie A.

### Actions

| Action | Type | Issue | Statut |
| --- | --- | --- | --- |
| En production (`APP_ENV=production`), l'API refuse de démarrer si `DATABASE_URL` est absente, avec un message qui la nomme ; test dans `tests/config.test.js` | prévention | [#7](https://github.com/Ylian967/taskflow/issues/7) | à faire |
| `deploy.sh` compare les noms de variables de `.env` et de `.env.example`, et s'arrête s'il en manque une | prévention | à créer | à faire |
| Ajouter au tableau « Premier réflexe » de `TaskFlowApiDown` : 502 = front sans API, puis `ps` et logs `fatal` | processus | - | fait (ce document) |
| Déployer `/metrics` (partie A) pour que `TaskFlowMetricsAbsent` ne sonne que pour une vraie panne | détection | - | à faire |
| Envoyer les alertes *critical* aussi vers un canal d'équipe (Discord ou Slack, webhook lu dans un fichier hors de Git) | détection | à créer | à faire |
