#!/usr/bin/env bash
#
# Smoke test for the web dashboard image built from Dockerfile.services.
#
# Runs the image the way Cloud Run will and checks the failure modes that leave
# the container "running" but the dashboard broken — missing static assets,
# a bind address the container does not own, or an un-rewritten API URL.
#
# Usage:
#   scripts/smoke-test-web-image.sh <image>
#   IMAGE=… scripts/smoke-test-web-image.sh
#
# Exits non-zero on the first failed check; the container log is dumped on failure.

set -uo pipefail

IMAGE="${1:-${IMAGE:-}}"
if [ -z "$IMAGE" ]; then
  echo "usage: $0 <image>   (or set IMAGE=…)" >&2
  exit 2
fi

# Deliberately not 8080: Cloud Run only guarantees it sets $PORT, so serving on a
# non-default port is part of what this verifies.
PORT="${SMOKE_PORT:-8099}"
MEMORY="${SMOKE_MEMORY:-512m}"
CONTAINER="plunk-web-smoke-$$"

# Distinctive hostname so the URL-rewrite checks cannot pass by coincidence.
TEST_API="https://smoke-api.plunk-test.invalid"
TEST_DASHBOARD="http://localhost:${PORT}"

PLACEHOLDER_API="https://next-api.useplunk.com"

failures=0

pass() { printf '  \033[32m✔\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$1"; failures=$((failures + 1)); }
info() { printf '  \033[2m·\033[0m %s\n' "$1"; }

cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "▶ Smoke testing ${IMAGE}"
echo

# --- Static image checks ------------------------------------------------------
echo "Image"

arch=$(docker image inspect "$IMAGE" --format '{{.Architecture}}/{{.Os}}' 2>/dev/null)
if [ "$arch" = "amd64/linux" ]; then
  pass "architecture is ${arch}"
else
  fail "architecture is '${arch}', Cloud Run requires amd64/linux"
fi

# --- Start the container ------------------------------------------------------
# No -e HOSTNAME on purpose: Docker injects it as the container ID, which is the
# exact condition that makes Next.js bind to an address the container does not own.
echo
echo "Startup"

if ! docker run -d --name "$CONTAINER" \
  --memory "$MEMORY" --cpus 1 \
  -p "${PORT}:${PORT}" \
  -e PORT="$PORT" \
  -e API_URI="$TEST_API" \
  -e DASHBOARD_URI="$TEST_DASHBOARD" \
  "$IMAGE" >/dev/null; then
  fail "container failed to start"
  exit 1
fi

deadline=$((SECONDS + 90))
ready=0
while [ "$SECONDS" -lt "$deadline" ]; do
  if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
    fail "container exited during startup"
    docker logs "$CONTAINER" 2>&1 | tail -40
    exit 1
  fi
  if curl -fsS -o /dev/null "http://localhost:${PORT}/" 2>/dev/null; then
    ready=1
    break
  fi
  sleep 1
done

if [ "$ready" -eq 1 ]; then
  pass "listening on \$PORT=${PORT} and reachable from outside the container"
else
  fail "never became reachable on port ${PORT} within 90s"
  docker logs "$CONTAINER" 2>&1 | tail -40
  exit 1
fi

if docker logs "$CONTAINER" 2>&1 | grep -q 'URL replacement complete'; then
  pass "entrypoint ran the URL replacement"
else
  fail "entrypoint did not report a completed URL replacement"
fi

# --- HTTP surface -------------------------------------------------------------
echo
echo "HTTP"

check_status() {
  local path="$1" expected="$2" label="$3"
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' "http://localhost:${PORT}${path}")
  if [ "$code" = "$expected" ]; then
    pass "${label} → ${code}"
  else
    fail "${label} → ${code} (expected ${expected})"
  fi
}

check_status "/" 200 "GET /"
check_status "/auth/login" 200 "GET /auth/login"
check_status "/favicon.ico" 200 "GET /favicon.ico (proves public/ was copied)"

chunk=$(curl -sS "http://localhost:${PORT}/" | grep -o '/_next/static/[^"]*\.js' | head -1)
if [ -n "$chunk" ]; then
  check_status "$chunk" 200 "GET ${chunk} (proves .next/static was copied)"
else
  fail "no /_next/static/*.js reference found in the served HTML"
fi

# --- Runtime URL replacement --------------------------------------------------
echo
echo "Runtime configuration"

leftover=$(docker exec "$CONTAINER" grep -rl "$PLACEHOLDER_API" /app/apps/web/.next 2>/dev/null | head -3)
if [ -z "$leftover" ]; then
  pass "no placeholder URLs left in the build output"
else
  fail "placeholder URLs still present, e.g.: ${leftover}"
fi

# Strongest check: find a served asset that should carry the injected API URL and
# fetch it over HTTP, so this proves the rewrite reached what the browser gets —
# not merely that something on disk changed.
rewritten=$(docker exec "$CONTAINER" sh -c \
  "grep -rl '${TEST_API}' /app/apps/web/.next/static 2>/dev/null | head -1")
if [ -n "$rewritten" ]; then
  asset_path="/_next/static/${rewritten#/app/apps/web/.next/static/}"
  if curl -sS "http://localhost:${PORT}${asset_path}" | grep -q "$TEST_API"; then
    pass "served asset carries the injected API_URI (${asset_path})"
  else
    fail "asset ${asset_path} does not serve the injected API_URI"
  fi
else
  fail "injected API_URI found in no static asset — the rewrite did not apply"
fi

# --- Runtime posture ----------------------------------------------------------
echo
echo "Runtime posture"

uid=$(docker exec "$CONTAINER" id -u 2>/dev/null)
if [ "$uid" = "1001" ]; then
  pass "runs as non-root (uid ${uid})"
else
  fail "runs as uid '${uid}', expected 1001"
fi

info "memory: $(docker stats --no-stream --format '{{.MemUsage}}' "$CONTAINER" 2>/dev/null) (limit ${MEMORY})"

# --- Result -------------------------------------------------------------------
echo
if [ "$failures" -eq 0 ]; then
  echo "✅ All checks passed — safe to push and deploy."
  echo
  echo "   Not covered here (only reproducible after deploy):"
  echo "   · the API's DASHBOARD_URI must byte-match the dashboard origin, or CORS blocks every request"
  echo "   · default *.run.app hostnames put the auth cookie on a Public Suffix List domain, and browsers drop it"
  exit 0
fi

echo "❌ ${failures} check(s) failed. Container log:"
docker logs "$CONTAINER" 2>&1 | tail -40
exit 1
