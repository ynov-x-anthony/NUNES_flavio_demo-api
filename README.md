# demo-api

Le fil rouge des quêtes Docker : une mini-API "catalogue" (`Node` + `Express`
+ `PostgreSQL`) conteneurisée, persistée, mise en réseau et orchestrée avec
**Docker Compose**, avec un second service métier indépendant (`notifier`).

La stack contient 4 services :

| Service | Image | Rôle | Réseaux | Exposé sur l'hôte |
|---|---|---|---|---|
| `api` | `ghcr.io/ynov-x-anthony/nunes_flavio_demo-api/api` (build `./api`) | l'API Express | `front`, `back` | `http://localhost:8080` |
| `notifier` | `ghcr.io/ynov-x-anthony/nunes_flavio_demo-api/notifier` (build `./notifier`) | reçoit un événement à chaque produit créé et logge une notification | `back` | **non** |
| `db` | `postgres:16-alpine` | la base, données dans le volume `pgdata` | `back` | **non** |
| `adminer` | `adminer:4` | client SQL web | `front`, `back` | `http://localhost:8081` |

## Prérequis

- **Docker Engine + Compose v2** : `docker compose version` doit répondre
  `v2.x` ou plus (pas l'ancien binaire `docker-compose` v1).
- macOS / Windows : **Docker Desktop** (sous Windows, backend WSL 2 ; lancer
  les commandes depuis WSL ou Git Bash).
- `git`, `curl` (sous PowerShell, utiliser `curl.exe`).

## Démarrage

```bash
# 1. Variables d'interpolation (ports, utilisateur, nom de la base)
cp .env.example .env

# 2. Mot de passe de la base, passé par Docker Secrets (jamais commité)
mkdir -p secrets
printf 'change-moi' > secrets/db_password.txt

# 3. Construire et lancer la stack
docker compose up -d --build
```

### URLs

| URL | Quoi |
|---|---|
| http://localhost:8080/products | liste des produits |
| http://localhost:8080/health | liveness de l'API |
| http://localhost:8080/ready | readiness (teste la connexion à la base) |
| http://localhost:8081 | Adminer : système `PostgreSQL`, serveur `db`, utilisateur `demo`, base `demo`, mot de passe = contenu de `secrets/db_password.txt` |

Les ports se changent dans `.env` (`API_PORT`, `ADMINER_PORT`).

## Variables et secrets

- **`.env`** (copié depuis `.env.example`, ignoré par Git) : sert uniquement à
  l'interpolation `${...}` de `compose.yml` (utilisateur, base, ports).
- **Mot de passe de la base** : il n'est ni dans `.env` ni dans `compose.yml`.
  Il est déclaré comme secret Compose (`secrets: db_password`, fichier
  `./secrets/db_password.txt`, ignoré par Git) et monté dans les conteneurs
  sur `/run/secrets/db_password` :
  - `db` le lit via `POSTGRES_PASSWORD_FILE` (convention de l'image postgres) ;
  - `api` le lit via `PGPASSWORD_FILE` (supporté par `api/db.js`).

  Résultat : `docker compose exec api printenv` ne montre aucun mot de passe.

## Ordre de démarrage

`db` a un `healthcheck` (`pg_isready`) ; `api` attend qu'il passe grâce à
`depends_on: { db: { condition: service_healthy } }`. Tous les services ont
`restart: unless-stopped`, au cas où la base redémarre en cours de vie.

## Repartir de zéro

```bash
docker compose down      # supprime conteneurs + réseau, GARDE le volume (données conservées)
docker compose down -v   # supprime aussi le volume pgdata : données perdues, init.sql rejoué au prochain up
```

`db/init.sql` n'est joué qu'au tout premier démarrage (volume vide) : après
l'avoir modifié, il faut un `down -v` pour qu'il soit pris en compte.

## Test effectué

Testé avec Docker Desktop (Windows 11, Git Bash), Docker Compose v5.5.1 :

```bash
docker compose up -d --build
docker compose ps
curl -s localhost:8080/products
curl -s -X POST -H 'content-type: application/json' \
  -d '{"name":"Gourde","price_cents":900}' localhost:8080/products
docker compose down
docker compose up -d
curl -s localhost:8080/products     # "Gourde" est toujours là
```

Extrait de `docker compose ps` :

```
SERVICE   IMAGE                       STATUS                    PORTS
adminer   adminer:4                   Up 13 seconds             0.0.0.0:8081->8080/tcp, [::]:8081->8080/tcp
api       nunes_flavio_demo-api-api   Up 8 seconds (healthy)    0.0.0.0:8080->3000/tcp, [::]:8080->3000/tcp
db        postgres:16-alpine          Up 14 seconds (healthy)   5432/tcp
```

`db` n'a aucun port publié (`5432/tcp` vient seulement du `EXPOSE` de
l'image) : seule l'API y accède, par le nom `db`.

`GET /products` après `down` puis `up` :

```json
[{"id":4,"name":"Gourde","price_cents":900,"created_at":"2026-10-29T09:39:44.120Z"},
 {"id":3,"name":"T-shirt conteneur","price_cents":1990,"created_at":"2026-10-29T09:39:39.354Z"},
 {"id":2,"name":"Mug Docker","price_cents":990,"created_at":"2026-10-29T09:39:39.354Z"},
 {"id":1,"name":"Sticker Demo","price_cents":150,"created_at":"2026-10-29T09:39:39.354Z"}]
```

## Analyse de vulnérabilités (Trivy) et CI

Scan local de l'image multi-étapes (sans installer Trivy) :

```bash
docker build -f api/Dockerfile.multi -t demo-api:multi ./api
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  aquasec/trivy:latest image --severity HIGH,CRITICAL --ignore-unfixed demo-api:multi
```

| | Base | HIGH/CRITICAL |
|---|---|---|
| [scan-avant.txt](scan-avant.txt) | `node:22.11-alpine` (alpine 3.20.3) | **54** (49 HIGH, 5 CRITICAL) |
| [scan-apres.txt](scan-apres.txt) | `node:22.23.4-alpine3.24` (alpine 3.24.3) | **0** |

Corrections appliquées :

- **OS** : base bumpée vers `node:22.23.4-alpine3.24` + `apk upgrade --no-cache` (21 CVE alpine → 0).
- **Dépendances de l'app** : `npm audit fix` (`body-parser` 1.20.9, `proxy-addr` 2.0.8, `qs` 6.15.4/6.16.2), `package-lock.json` commité (2 CVE → 0).
- **npm/npx/corepack supprimés de l'image finale** : inutiles à l'exécution (on ne lance que `node`), ils embarquaient 31 CVE.

La CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) build `api/Dockerfile.multi` à chaque push (main et tags `v*`) puis lance `aquasecurity/trivy-action` avec `severity: CRITICAL,HIGH`, `ignore-unfixed: true` et `exit-code: '1'` : le job échoue dès qu'une CVE corrigeable réapparaît.

## Microservices : le service notifier

`notifier` est un service à part entière : son propre dossier, son propre
`package.json`, son propre `Dockerfile` (base épinglée, multi-étapes, `USER
node`, `HEALTHCHECK`), sa propre image. Il expose `GET /health` et
`POST /notify` (logge le corps reçu, répond `202`).

Après chaque `POST /products` réussi, `api` appelle
`http://notifier:4000/notify` : `notifier` est le **nom du service**, résolu
par le DNS interne du réseau `back`. L'appel est **best-effort** : non
attendu, avec un timeout de 2 s, il ne fait jamais échouer la requête.

Vérification locale :

```bash
docker compose up -d --build
curl -s -X POST localhost:8080/products -H "Content-Type: application/json" \
  -d '{"name":"Clavier meca","price_cents":5900}'
docker compose logs notifier | tail -5
```

```
{"id":5,"name":"Clavier meca","price_cents":5900,"created_at":"2026-10-29T10:00:16.404Z"}
notifier-1  | [notifier] started on port 4000
notifier-1  | [notifier] nouveau produit : {"id":5,"name":"Clavier meca","price_cents":5900}
```

Panne de `notifier` (`docker compose stop notifier`) : `POST /products`
répond toujours `201`, l'API logge simplement
`{"level":"error","msg":"notify failed","err":"The operation was aborted due to timeout"}`.

`notifier` n'a pas de `ports:` et n'est que sur `back` : un conteneur du
réseau `front` ne le résout même pas (`nc: bad address 'notifier'`).

## CI/CD : deux images publiées, puis déploiement

[.github/workflows/ci.yml](.github/workflows/ci.yml) :

- **job `image`** (matrix `service: [api, notifier]`) : chaque service est
  buildé depuis son propre contexte, scanné par Trivy (`HIGH,CRITICAL`,
  `ignore-unfixed`, gate `exit-code: 1` sur les tags `v*`), puis, sur un tag,
  l'image scannée est poussée telle quelle sur
  `ghcr.io/ynov-x-anthony/nunes_flavio_demo-api/<service>:<tag>`.
- **job `deploy`** (`needs: image`, tags `v*` seulement) : `docker compose pull`
  puis `docker compose up -d`, suivis d'un test de fumée (`/version`,
  `POST /products`, notification reçue dans les logs de `notifier`).

> **Déploiement simulé.** Faute de VM cible, le job `deploy` s'exécute sur le
> runner GitHub lui-même (option prévue par l'énoncé). Il reproduit ce que
> ferait le serveur : repo cloné, `.env` + secret créés, login GHCR,
> `docker compose pull && docker compose up -d` sur les images du tag. Sur un
> vrai serveur, les mêmes commandes passeraient par `appleboy/ssh-action`
> (secrets `DEPLOY_HOST`, `DEPLOY_USER`, `DEPLOY_SSH_KEY`) :
>
> ```bash
> cd /opt/demo-api && git pull
> TAG=v1.5.0 docker compose pull && TAG=v1.5.0 docker compose up -d
> docker image prune -f
> ```

Limites : Compose reste mono-hôte (`--scale notifier=3` ne dépasse pas la
machine et ne répartit pas le trafic). Pour du multi-hôte, de l'auto-réparation
sur un autre nœud ou des rolling updates : Docker Swarm
(`docker stack deploy`) ou Kubernetes.

## Contenu du repo

| Fichier | Rôle |
|---|---|
| `compose.yml` | la stack : `api`, `notifier`, `db`, `adminer`, réseaux `front`/`back`, volume `pgdata`, secret `db_password` |
| `.env.example` | modèle des variables d'interpolation (à copier en `.env`) |
| `api/Dockerfile` | image de l'API (utilisateur non-root, `HEALTHCHECK`) |
| `api/Dockerfile.naive` | variante naïve |
| `api/Dockerfile.multi` | image multi-étapes, scannée par Trivy en CI |
| `.github/workflows/ci.yml` | CI/CD : matrix `api`/`notifier` (build, scan, push GHCR) + `deploy` |
| `scan-avant.txt`, `scan-apres.txt` | rapports Trivy avant / après correction |
| `api/server.js` | l'API Express (appelle `notifier` en best-effort) |
| `notifier/` | second service : `server.js`, `package.json`, `Dockerfile` |
| `api/db.js` | connexion PostgreSQL, pilotée par variables d'environnement (`PGPASSWORD_FILE` pour le secret) |
| `db/init.sql` | création de la table `products` + données de démo |
| `volumes_flavio_nunes.sh` | étape 2 : persistance avec un named volume |
| `reseaux_flavio_nunes.sh` | étape 3 : isolation réseau de la base |

## Les routes de l'API

| Méthode | Route | Effet |
|---|---|---|
| `GET` | `/` | infos application + version |
| `GET` | `/version` | numéro de version courant |
| `GET` | `/health` | liveness, ne touche pas la base |
| `GET` | `/ready` | readiness, teste la connexion à la base |
| `GET` | `/products` | liste des produits |
| `POST` | `/products` | crée un produit : `{ "name": "...", "price_cents": 1234 }` |
