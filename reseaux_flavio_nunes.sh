#!/usr/bin/env bash
# Fil rouge - etape 3 : isoler la base derriere l'API.
# A lancer depuis la racine du repo (contient api/ et db/init.sql).
# Windows : lancer depuis Git Bash ou WSL.
#
#   hote --8080--> [demo_front] demo-api [demo_back] --> demo-db (aucun port publie)

set -euo pipefail

# Git Bash convertit les chemins "/..." en chemins Windows : on desactive
# cette conversion pour que les chemins *dans le conteneur* restent intacts.
export MSYS_NO_PATHCONV=1

cd "$(dirname "$0")"

# Chemin absolu de l'hote pour le bind mount (format Windows sous Git Bash).
HOST_DIR="$(pwd -W 2>/dev/null || pwd)"

IMAGE=demo-api:1.0
FRONT=demo_front
BACK=demo_back
DB=demo-db
API=demo-api

step() { echo; echo "===== $* ====="; }

ips() {
  echo "--- $1"
  docker inspect -f '{{range $net, $conf := .NetworkSettings.Networks}}{{$net}}: {{$conf.IPAMConfig}} {{$conf.IPAddress}}{{"\n"}}{{end}}' "$1"
}

# Nettoyage d'une execution precedente (-v : supprime aussi le volume anonyme
# que l'image postgres cree via son VOLUME).
docker rm -fv "$API" "$DB" >/dev/null 2>&1 || true
docker network rm "$FRONT" "$BACK" >/dev/null 2>&1 || true

step "Build de l'image $IMAGE"
docker build -q -t "$IMAGE" ./api

step "Creation des reseaux personnalises $FRONT et $BACK"
docker network create "$FRONT"
docker network create "$BACK"
docker network ls --filter name=demo_

step "Lancement de $DB sur $BACK uniquement, sans -p"
docker run -d --name "$DB" --network "$BACK" \
  -v "$HOST_DIR/db/init.sql":/docker-entrypoint-initdb.d/init.sql:ro \
  -e POSTGRES_USER=demo -e POSTGRES_PASSWORD=demo -e POSTGRES_DB=demo \
  postgres:16-alpine

# -h localhost : pendant l'init, postgres ecoute seulement sur le socket unix.
until docker exec "$DB" pg_isready -U demo -h localhost >/dev/null 2>&1; do
  echo "  base pas encore prete..."
  sleep 1
done
echo "  base prete."

step "Lancement de $API sur $BACK + $FRONT, publie sur 8080"
docker run -d --name "$API" --network "$BACK" -p 8080:3000 \
  -e PGHOST="$DB" \
  "$IMAGE"
docker network connect "$FRONT" "$API"

until curl -sf localhost:8080/ready >/dev/null; do
  echo "  API pas encore prete..."
  sleep 1
done
echo "  API prete."

step "Ports publies (demo-db ne doit rien publier)"
docker ps --filter name=demo- --format '{{.Names}}\t{{.Ports}}'

step "1. $API resout $DB par son nom (DNS interne via $BACK)"
docker exec "$API" getent hosts "$DB"

step "2. Conteneur tiers sur $FRONT seulement -> $DB:5432 (echec attendu)"
if docker run --rm --network "$FRONT" alpine nc -zv -w 3 "$DB" 5432; then
  echo ">>> PROBLEME : $DB est joignable depuis $FRONT"
else
  echo ">>> OK : $DB injoignable depuis $FRONT (aucun reseau commun)"
fi

step "3. Adresses IPv4 par reseau"
ips "$DB"
ips "$API"

step "4. curl -s localhost:8080/products"
curl -s localhost:8080/products
echo

step "Nettoyage"
docker rm -fv "$API" "$DB"
docker network rm "$FRONT" "$BACK"
