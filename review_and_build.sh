#!/usr/bin/env bash
# verify-and-rebuild.sh
# Proves whether the running Stack 3 container has the patched code, then
# rebuilds/recreates it if not. Run from the repo root
# (PROMPT-03-PROVIDER-ROUTING-STACK-ARCHITECT/).
set -u

API_SERVICE="api"   # docker-compose service name for Stack 3's API
API_CONTAINER="$(docker compose ps -q "$API_SERVICE" 2>/dev/null || docker-compose ps -q "$API_SERVICE" 2>/dev/null)"

echo "== 1. Does the container even have execute.js? =="
if [ -z "$API_CONTAINER" ]; then
  echo "[FAIL] Could not find a running container for service '$API_SERVICE'. Run 'docker compose ps' and check the service name."
  exit 1
fi
docker exec "$API_CONTAINER" test -f /app/src/routes/execute.js \
  && echo "[FOUND] /app/src/routes/execute.js exists inside the container" \
  || echo "[MISSING] /app/src/routes/execute.js does NOT exist inside the container - image is stale"

echo
echo "== 2. Is it wired into server.js inside the image? =="
docker exec "$API_CONTAINER" grep -l "executeRoutes" /app/src/server.js 2>/dev/null \
  && echo "[FOUND] server.js inside the container requires executeRoutes" \
  || echo "[MISSING] server.js inside the container does NOT mention executeRoutes - image is stale"

echo
echo "== 3. When was the image built vs. when was the host file last edited? =="
IMAGE_ID="$(docker inspect "$API_CONTAINER" --format '{{.Image}}')"
echo "Image created: $(docker inspect "$IMAGE_ID" --format '{{.Created}}')"
echo "Host src/routes/execute.js mtime: $(stat -c '%y' src/routes/execute.js 2>/dev/null || stat -f '%Sm' src/routes/execute.js)"
echo "(if the image predates the file edit, that confirms the stale-image theory)"

echo
echo "== 4. Rebuilding and recreating the api service (no cache) =="
read -p "Proceed with rebuild? [y/N] " CONFIRM
if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
  echo "Aborted - no changes made."
  exit 0
fi

if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
else
  DC="docker-compose"
fi

$DC build --no-cache "$API_SERVICE"
$DC up -d --force-recreate "$API_SERVICE"

echo
echo "== 5. Tailing logs for 5s to confirm clean startup =="
NEW_CONTAINER="$($DC ps -q "$API_SERVICE")"
timeout 5 docker logs -f "$NEW_CONTAINER" || true

echo
echo "== 6. Re-checking the route from inside the container's own network =="
sleep 1
docker exec "$NEW_CONTAINER" node -e "
const http = require('http');
http.get('http://127.0.0.1:8080/help', (res) => {
  let d = '';
  res.on('data', c => d += c);
  res.on('end', () => {
    const has = d.includes('/v1/execute');
    console.log(has ? '[PASS] /help now advertises /v1/execute' : '[FAIL] /help still missing /v1/execute');
  });
});
"

echo
echo "== 7. Hitting /v1/execute directly (expect NOT 404) =="
docker exec "$NEW_CONTAINER" node -e "
const http = require('http');
const body = JSON.stringify({provider:'nonexistent',messages:[{role:'user',content:'ping'}]});
const req = http.request('http://127.0.0.1:8080/v1/execute', {
  method: 'POST',
  headers: {'Content-Type':'application/json','Content-Length': Buffer.byteLength(body)}
}, (res) => {
  console.log('status:', res.statusCode, res.statusCode === 404 ? '[FAIL] still 404' : '[PASS] route exists');
});
req.write(body);
req.end();
"

echo
echo "Done. Now re-run: bash ../stack5-integration-test.sh"
