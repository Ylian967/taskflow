# Sécurité de TaskFlow

Ce document décrit les contrôles de sécurité du projet, les choix de durcissement, le triage des alertes et les
exceptions acceptées. Il est mis à jour à chaque changement de règle ou d'exception.

## 1. Les contrôles et leur place dans le pipeline

| Contrôle | Outil | Où | Déclencheur | Ce qu'il protège |
|---|---|---|---|---|
| Secrets avant commit | gitleaks | `.pre-commit-config.yaml` | chaque `git commit` en local | un mot de passe ou un jeton qui partirait dans l'historique |
| Secrets dans l'historique | gitleaks 8.30.1 (somme SHA-256 vérifiée) | `security.yml` › `secrets` | PR, push sur `main`, chaque lundi | un secret déjà commité, même effacé depuis |
| Dépendances (SCA) | `npm audit --audit-level=high` | `security.yml` › `dependances` (api, front) | PR, push sur `main`, chaque lundi | une bibliothèque avec une CVE connue |
| Dépendances (mises à jour) | Dependabot | `.github/dependabot.yml` | chaque semaine + alertes de sécurité | des dépendances qui vieillissent sans que personne ne le voie |
| Code source (SAST) | Semgrep 1.184.0 (`p/javascript`, `p/nodejsscan`) | `security.yml` › `sast` | PR, push sur `main`, chaque lundi | injection SQL, XSS, `eval`, exécution de commandes dans notre code |
| Application qui tourne (DAST) | OWASP ZAP 2.17.0, baseline | `security.yml` › `dast` | PR, push sur `main`, chaque lundi | en-têtes manquants, fuites d'information, cookies, vus de l'extérieur |
| Images Docker | Trivy (CRITICAL corrigeables) | `release.yml` › `images` | chaque release | une CVE dans l'image de base ou un outil embarqué, avant publication |
| Infrastructure | `tofu plan` sur les PR, dérive chaque lundi | `iac.yml` | PR sur `infra/`, chaque lundi | un staging modifié à la main ou un changement d'infra non relu |

Le passage chaque lundi compte autant que le passage sur les PR : une dépendance saine aujourd'hui peut recevoir une
CVE la semaine prochaine sans que personne ne touche au code.

Tous les workflows sont en lecture seule par défaut (`permissions: contents: read`) et leurs actions tierces sont
épinglées par SHA, avec la version en commentaire (Dependabot les met à jour).

## 2. Durcissement HTTP (en-têtes du front)

Le Nginx du front est le point d'entrée HTTP de l'application : c'est là que les en-têtes sont posés
(`front/nginx.conf`, bloc `server`), avec `always` pour qu'ils soient aussi présents sur les erreurs.

| En-tête / directive | Valeur | Pourquoi |
|---|---|---|
| `Content-Security-Policy` | `default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'` | Le navigateur n'exécute que ce qui vient de notre origine : une injection de script ne peut ni s'exécuter ni charger de code d'ailleurs. Le build Vite n'a ni script ni style inline, donc pas de `'unsafe-inline'`. |
| `X-Content-Type-Options` | `nosniff` | Le navigateur ne devine pas le type d'un fichier (un texte servi ne sera pas exécuté comme script). |
| `X-Frame-Options` | `DENY` | Anti-clickjacking, doublé par `frame-ancestors 'none'` pour les navigateurs récents. |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | L'URL complète ne part pas vers les autres sites. |
| `Permissions-Policy` | `camera=(), microphone=(), geolocation=(), payment=(), usb=()` | Fonctions du navigateur inutiles à TaskFlow : interdites, même si un script les demandait. |
| `Cross-Origin-Opener-Policy`, `-Resource-Policy`, `-Embedder-Policy` | `same-origin`, `same-origin`, `require-corp` | Isolation de la page par rapport aux autres origines (attaques de type Spectre). |
| `server_tokens off` | | L'en-tête `Server` dit `nginx` sans la version. |
| `proxy_hide_header X-Powered-By` | | Retire `X-Powered-By: Express` des réponses de l'API. |

**Piège évité** : `add_header` n'est pas hérité. Une `location` qui pose son propre `add_header` perd tous ceux du
niveau `server`, CSP comprise. Le `Cache-Control` des fichiers de `/assets/` est donc calculé par un `map` (niveau
`http`), et la `location /assets/` n'a aucun `add_header`.

Vérifié le 20/11/2026 :

- `curl -I` sur `/`, `/health`, `/api/tasks`, un fichier de `/assets/` et une 404 dans `/assets/` : tous les en-têtes,
  CSP comprise ; plus de version de Nginx ni de `X-Powered-By`.
- ZAP baseline : 8 WARN avant, **0 WARN, 0 FAIL** après (2 IGNORE justifiés ci-dessous).
- Navigateur : page chargée, tâche créée et cochée, aucune violation de CSP dans la console.

## 3. Dépendances

`npm audit --audit-level=high` bloque la PR dès qu'une faille high ou critical existe, **devDependencies
comprises** : elles s'exécutent dans le CI et au build, et le front n'a que des devDependencies (le bundle servi en
production est fabriqué par elles).

État au 20/11/2026, après correction : `npm audit` → 0 vulnérabilité dans `api` et `front`.

## 4. Triage des alertes (20/11/2026)

Questions posées pour chaque alerte : atteignable en production ? donnée utilisateur en jeu ? impact ? décision
(corriger, issue, exception datée) ?

| Alerte | Outil | Sévérité | Vrai ou faux positif ? | Décision |
|---|---|---|---|---|
| `body-parser` < 1.20.9 : déni de service par octets en trop après un corps compressé (GHSA-27r3-jxmh-p828) | npm audit (api) | high | **vrai**, et en **production** (dépendance d'Express) | corrigé : `npm audit fix` → 1.20.9 |
| `vitest`, `@vitest/coverage-v8`, `tinypool` : pollution de prototype menant à l'exécution de code (GHSA-5gmw-xhrv-c9v3, GHSA-85c8-ppgw-ccpr) | npm audit (api, front) | critical | **vrai**, mais **devDependency** : pas dans l'image de production, exécuté dans le CI | corrigé : vitest et coverage-v8 2 → 5 (montée majeure, tests unitaires, d'intégration et couverture verts) |
| `vite` < 8 (et `esbuild`) | npm audit (front) | high | **vrai**, devDependency qui **fabrique le bundle de production** | corrigé : vite 5 → 8 ; build, tests et parcours navigateur vérifiés |
| `minimatch`, `glob`, `test-exclude`, `vite-node`, `@vitest/mocker` | npm audit | moderate | vrais, dépendances des outils de test | corrigés par les montées ci-dessus |
| Content Security Policy (CSP) Header Not Set [10038] | ZAP | Medium | **vrai** | corrigé (en-tête Nginx), règle en FAIL |
| Missing Anti-clickjacking Header [10020] | ZAP | Medium | **vrai** | corrigé, règle en FAIL |
| X-Content-Type-Options Header Missing [10021] | ZAP | Low | **vrai** | corrigé, règle en FAIL |
| Permissions Policy Header Not Set [10063] | ZAP | Low | **vrai** | corrigé, règle en FAIL |
| Server Leaks Version Information [10036] | ZAP | Low | **vrai** (`nginx/1.30.x` annoncé) | corrigé (`server_tokens off`), règle en FAIL |
| Cross-Origin-Embedder-Policy Header Missing [90004] | ZAP | Low | **vrai** | corrigé (COOP, COEP, CORP), règle en WARN |
| Storable and Cacheable Content [10049] | ZAP | Info | **faux positif** : les assets Vite sont mis en cache 1 an exprès (nom avec hash) | IGNORE justifié |
| Modern Web Application [10109] | ZAP | Info | **faux positif** : constate seulement que c'est une application à une page | IGNORE justifié |
| Semgrep (`p/javascript`, `p/nodejsscan`) | Semgrep | - | 182 règles sur 14 fichiers : 0 résultat | rien à faire |
| gitleaks, 47 commits | gitleaks | - | aucun secret trouvé | rien à faire |

Les PR Dependabot ouvertes pour ces mêmes montées (vitest, coverage-v8, vite) deviennent sans objet une fois cette
correction fusionnée.

## 5. Registre des exceptions

Toute alerte ignorée est inscrite ici : quoi, pourquoi, qui, et quand la revoir. Une exception sans date de revue
n'est pas acceptée.

### ZAP — [`.zap/rules.tsv`](../.zap/rules.tsv)

| Règle | Action | Justification | Décidé par | Le | Revue |
|---|---|---|---|---|---|
| 10049 Storable and Cacheable Content | IGNORE | Informatif. Les fichiers de `/assets/` ont un nom avec hash et sont mis en cache 1 an volontairement ; `index.html` est en `no-cache`. Aucune donnée utilisateur n'est mise en cache (les réponses de l'API sont en `no-cache`). | Ylian Merrir | 20/11/2026 | 20/02/2027 |
| 10109 Modern Web Application | IGNORE | Informatif : ZAP constate une application à une page et conseille son spider Ajax. Pas une faille. | Ylian Merrir | 20/11/2026 | 20/02/2027 |

Les règles d'en-têtes corrigées (10038, 10020, 10021, 10063, 10036, 10037) sont en **FAIL** : si un en-tête
disparaît, la PR est bloquée.

### gitleaks

Aucune exception (pas de `.gitleaks.toml`). Si un faux positif apparaît, il sera ajouté dans un `.gitleaks.toml`
(chemin ou empreinte précise, jamais une règle désactivée en entier) et inscrit ici.

### Semgrep

Aucune exception. Un faux positif se neutralise ligne par ligne avec `// nosemgrep: <id-de-la-règle>` et s'inscrit
ici avec sa justification.

## 6. Limites connues

- La **baseline ZAP est passive** : elle analyse les réponses mais n'envoie aucune attaque. Elle ne trouve ni
  injection SQL, ni XSS stockée, ni contrôle d'accès cassé. Le scan actif (`zap-full-scan.py`) ou un test d'API
  (`zap-api-scan.py`) sur un environnement jetable couvrirait mieux, au prix de plusieurs minutes.
- TaskFlow **n'a pas d'authentification** : n'importe qui ayant accès au réseau peut lire et modifier les tâches.
  Les contrôles ci-dessus ne compensent pas ce manque.
- Le DAST scanne la **stack de dev** (`compose.yaml`, HTTP sur :8080), pas la production : le TLS et le proxy de
  la prod (`compose.prod.yaml`) ne sont pas testés par ZAP.
- `npm audit` et Trivy ne connaissent que les **CVE publiées** : une faille non encore déclarée passe.
- Semgrep utilise des **règles publiques génériques** : pas d'analyse de flux entre fichiers comme CodeQL.
- L'API n'a pas de limite de taille de corps ni `app.disable('x-powered-by')` : l'en-tête est retiré par Nginx, mais
  pas à la source (à traiter dans une PR dédiée).

## 7. En cas de secret exposé

1. **Révoquer** le secret tout de suite (changer le mot de passe, révoquer le jeton) : le retirer de Git ne suffit
   pas, il a pu être copié.
2. Remplacer la valeur là où elle sert (`.env` des serveurs, secrets GitHub) et redéployer.
3. Nettoyer l'historique si nécessaire (`git filter-repo`), en sachant que les clones et les forks existants le
   gardent.
4. Écrire un post-mortem dans [`INCIDENTS.md`](INCIDENTS.md).
