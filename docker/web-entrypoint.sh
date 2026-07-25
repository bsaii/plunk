#!/bin/sh
set -e

# =============================================================================
# Entrypoint for the standalone web dashboard image (Dockerfile.services)
#
# The Next.js bundle is compiled with the public placeholder URLs baked in, so
# this rewrites them from the environment before the server starts. That keeps
# a single image deployable to any environment — which matters on Cloud Run,
# where the service URL only exists after the first deploy.
# =============================================================================

APP_DIR=/app/apps/web

# Runtime URL configuration (same variables as the all-in-one image).
export API_URI="${API_URI:-http://localhost:8080}"
export DASHBOARD_URI="${DASHBOARD_URI:-http://localhost:3000}"
export LANDING_URI="${LANDING_URI:-https://www.useplunk.com}"
export WIKI_URI="${WIKI_URI:-https://docs.useplunk.com}"

# Mirror them onto the NEXT_PUBLIC_* names so any server-side read at runtime
# sees the same values as the rewritten client bundle.
export NEXT_PUBLIC_API_URI="$API_URI"
export NEXT_PUBLIC_DASHBOARD_URI="$DASHBOARD_URI"
export NEXT_PUBLIC_LANDING_URI="$LANDING_URI"
export NEXT_PUBLIC_WIKI_URI="$WIKI_URI"

export PORT="${PORT:-8080}"

# Set unconditionally rather than defaulted: container runtimes inject HOSTNAME
# as the container ID, and Next.js binds the server to whatever it finds here —
# an address the container does not own, which Cloud Run then reports as a
# container that failed to listen on $PORT.
export HOSTNAME=0.0.0.0

echo "🚀 Starting Plunk web dashboard"
echo "   API_URI=${API_URI}"
echo "   DASHBOARD_URI=${DASHBOARD_URI}"
echo "   LANDING_URI=${LANDING_URI}"
echo "   WIKI_URI=${WIKI_URI}"
echo "   PORT=${PORT}"

if [ "$API_URI" = "http://localhost:8080" ]; then
  echo "   ⚠️  API_URI is unset — the dashboard will call http://localhost:8080."
  echo "      Set API_URI to the URL of the deployed API service."
fi

/app/docker/replace-urls-optimized.sh web "$APP_DIR"

cd "$APP_DIR"
exec node server.js
