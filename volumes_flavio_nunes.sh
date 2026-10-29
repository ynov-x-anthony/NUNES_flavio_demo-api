#!/usr/bin/env bash
# Fil rouge - etape 2 : persistance de demo-api avec un named volume.
# A lancer depuis la racine du repo (contient api/ et db/init.sql).
# Windows : lancer depuis Git Bash ou WSL.

set -euo pipefail

# Git Bash convertit les chemins "/..." en chemins Windows : on desactive
# cette conversion pour que les chemins *dans le conteneur* restent intacts.
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")"

# Chemin absolu de l'hote pour le bind mount (format Windows sous Git Bash).
HOST_DIR="$(pwd -W 2>/dev/null || pwd)"

IMAGE=demo-api:1.0
VOLUME=demo_pgdata
NETWORK=demo_net
DB=demo-db
API=demo-api

step() { echo; echo "===== $* ====="; }

start_db() {
  docker run -d --name "$DB" --network "$NETWORK" \
    -v "$VOLUME":/var/lib/postgresql/data \
    -v "$HOST_DIR/db/init.sql":/docker-entrypoint-initdb.d/init.sql:ro \
    -e POSTGRES_USER=demo -e POSTGRES_PASSWORD=demo -e POSTGRES_DB=demo \
    postgres:16-alpine
}

wait_db() {
  # -h localhost : pendant l'init, postgres ecoute seulement sur le socket
  # unix ; on attend donc le "vrai" serveur, joignable en TCP.
  until docker exec "$DB" pg_isready -U demo -h localhost >/dev/null 2>&1; do
    echo "  base pas encore prete..."
    sleep 1
  done
  echo "  base prete."
}

start_api() {
  docker run -d --name "$API" --network "$NETWORK" -p 8080:3000 \
    -e PGHOST="$DB" \
    "$IMAGE"
}

wait_api() {
  until curl -sf localhost:8080/ready >/dev/null; do
    echo "  API pas encore prete..."
    sleep 1
  done
  echo "  API prete."
}

# Nettoyage d'une execution precedente (le volume est conserve volontairement).
docker rm -f "$API" "$DB" >/dev/null 2>&1 || true
docker network rm "$NETWORK" >/dev/null 2>&1 || true

step "1. Build de l'image $IMAGE"
docker build -t "$IMAGE" ./api

step "2. Creation du named volume $VOLUME"
docker volume create "$VOLUME"

step "Creation du reseau $NETWORK"
docker network create "$NETWORK"

step "3. Lancement de $DB (volume + init.sql en bind lecture seule)"
start_db

step "4. Attente de la base (pg_isready)"
wait_db

step "5. Lancement de $API (8080 -> 3000)"
start_api
wait_api

step "6. Ajout d'un produit"
# Corps envoye via stdin (@-) : sous Git Bash, passer "é" en argument a
# curl le re-encode et casse l'UTF-8.
curl -s -X POST -H 'content-type: application/json' \
  --data-binary @- localhost:8080/products <<'JSON'
{"name":"Casquette Démo","price_cents":1200}
JSON
echo

step "GET /products AVANT suppression de la base"
curl -s localhost:8080/products
echo

step "7. Suppression du conteneur $DB puis recreation sur le meme volume"
docker rm -f "$DB"
start_db
wait_db

echo "Relance de l'API"
docker rm -f "$API"
start_api
wait_api

step "GET /products APRES recreation de la base"
FINAL="$(curl -s localhost:8080/products)"
echo "$FINAL"

if echo "$FINAL" | grep -q "Casquette Démo"; then
  echo ">>> OK : 'Casquette Démo' a survecu a la suppression du conteneur de base."
else
  echo ">>> ECHEC : 'Casquette Démo' introuvable." >&2
fi

step "8. Volume conserve"
docker volume ls | grep "$VOLUME"

step "Nettoyage (conteneurs + reseau, le volume est garde)"
docker rm -f "$API" "$DB"
docker network rm "$NETWORK"

# Pour repartir de zero (init.sql rejoue au prochain demarrage) :
# docker volume rm demo_pgdata
