# demo-api

Le fil rouge des quêtes Docker : une mini-API "catalogue" (`Node` + `Express`
+ `PostgreSQL`) conteneurisée, persistée, mise en réseau et orchestrée avec
**Docker Compose**.

La stack contient 3 services :

| Service | Image | Rôle | Exposé sur l'hôte |
|---|---|---|---|
| `api` | construite depuis `./api` | l'API Express | `http://localhost:8080` |
| `db` | `postgres:16-alpine` | la base, données dans le volume `pgdata` | **non** (réseau interne uniquement) |
| `adminer` | `adminer:4` | client SQL web | `http://localhost:8081` |

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

## Contenu du repo

| Fichier | Rôle |
|---|---|
| `compose.yml` | la stack : `api`, `db`, `adminer`, volume `pgdata`, secret `db_password` |
| `.env.example` | modèle des variables d'interpolation (à copier en `.env`) |
| `api/Dockerfile` | image de l'API (utilisateur non-root, `HEALTHCHECK`) |
| `api/Dockerfile.naive`, `api/Dockerfile.multi` | variantes naïve et multi-étapes |
| `api/server.js` | l'API Express |
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
