#!/usr/bin/env bash
#
# One-time GCP setup for the Plunk deploy pipeline. Idempotent — safe to re-run
# after editing deploy/config.env.
#
#   yarn deploy:setup
#
# Creates: the enabled APIs, the Artifact Registry repo (with a cleanup policy),
# a build service account and a runtime service account with the roles each
# needs, and empty Secret Manager secrets for the values Cloud Run injects.
#
# It does NOT put any secret values in place — it creates the containers and
# tells you which ones are still empty.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/deploy/config.env"

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }
step() { printf '\n=== %s\n' "$*"; }

[[ -f "$CONFIG_FILE" ]] || die "$CONFIG_FILE not found.
  cp deploy/config.example.env deploy/config.env"

# shellcheck disable=SC1090
set -a; source "$CONFIG_FILE"; set +a

for required in PROJECT_ID REGION AR_REPO; do
  [[ -n "${!required:-}" ]] || die "$required is not set in $CONFIG_FILE"
done

command -v gcloud >/dev/null || die "gcloud not found."
gcloud auth print-access-token >/dev/null 2>&1 || die "not authenticated. Run: gcloud auth login"

step "Enabling APIs"
gcloud services enable \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  --project="$PROJECT_ID"

step "Checking worker pool availability in $REGION"
# Worker pools are the surface the queue consumer deploys to, and they are
# available in fewer regions than services. Failing here is much clearer than
# failing halfway through the first deploy.
if ! gcloud run worker-pools list --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  die "'gcloud run worker-pools' is unavailable for region $REGION.
Either the region does not offer worker pools yet, or your gcloud is too old
(run: gcloud components update). Pick a supported region in deploy/config.env."
fi
echo "ok"

step "Artifact Registry: $AR_REPO"
if gcloud artifacts repositories describe "$AR_REPO" \
    --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "already exists"
else
  gcloud artifacts repositories create "$AR_REPO" \
    --repository-format=docker \
    --location="$REGION" \
    --project="$PROJECT_ID" \
    --description="Plunk service images"
fi

# Without a cleanup policy this repo grows by three images per deploy forever.
POLICY_FILE="$(mktemp)"
trap 'rm -f "$POLICY_FILE"' EXIT
cat > "$POLICY_FILE" <<'EOF'
[
  {
    "name": "keep-recent-tagged",
    "action": {"type": "Keep"},
    "mostRecentVersions": {"keepCount": 10}
  },
  {
    "name": "delete-old-untagged",
    "action": {"type": "Delete"},
    "condition": {"tagState": "untagged", "olderThan": "30d"}
  }
]
EOF
gcloud artifacts repositories set-cleanup-policies "$AR_REPO" \
  --location="$REGION" --project="$PROJECT_ID" --policy="$POLICY_FILE"

# --- Service accounts --------------------------------------------------------
# Two identities, deliberately: the build can write images and deploy, but has
# no reason to read your database credentials at runtime; the runtime identity
# can read secrets but cannot push images or change deployments.
create_sa() {
  local email="$1" display="$2" id="${1%%@*}"
  if gcloud iam service-accounts describe "$email" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "  $email already exists"
  else
    gcloud iam service-accounts create "$id" \
      --display-name="$display" --project="$PROJECT_ID"
  fi
}

grant() {
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:$1" --role="$2" --condition=None --quiet >/dev/null
  echo "  $2 → $1"
}

if [[ -n "${BUILD_SA:-}" ]]; then
  step "Build service account"
  create_sa "$BUILD_SA" "Plunk Cloud Build"
  grant "$BUILD_SA" roles/artifactregistry.writer
  grant "$BUILD_SA" roles/run.admin
  grant "$BUILD_SA" roles/iam.serviceAccountUser
  # Required because cloudbuild.yaml sets logging: CLOUD_LOGGING_ONLY.
  grant "$BUILD_SA" roles/logging.logWriter
fi

if [[ -n "${RUNTIME_SA:-}" ]]; then
  step "Runtime service account"
  create_sa "$RUNTIME_SA" "Plunk Cloud Run runtime"
  grant "$RUNTIME_SA" roles/secretmanager.secretAccessor
  if [[ -n "${CLOUDSQL_INSTANCES:-}" ]]; then
    grant "$RUNTIME_SA" roles/cloudsql.client
  fi
fi

# --- Secrets -----------------------------------------------------------------
step "Secret Manager"
EMPTY_SECRETS=()
# Names are parsed out of the API_SECRETS/WORKER_SECRETS maps in config.env so
# there is only one place to add a secret.
for entry in ${API_SECRETS//,/ } ${WORKER_SECRETS//,/ }; do
  ref="${entry#*=}"          # plunk-jwt-secret:latest
  name="${ref%%:*}"          # plunk-jwt-secret
  [[ -n "$name" ]] || continue
  if gcloud secrets describe "$name" --project="$PROJECT_ID" >/dev/null 2>&1; then
    if ! gcloud secrets versions list "$name" --project="$PROJECT_ID" \
         --filter='state=ENABLED' --format='value(name)' | grep -q .; then
      EMPTY_SECRETS+=("$name")
    fi
  else
    gcloud secrets create "$name" --replication-policy=automatic --project="$PROJECT_ID"
    EMPTY_SECRETS+=("$name")
  fi
done

echo
echo "Done."
if (( ${#EMPTY_SECRETS[@]} > 0 )); then
  echo
  echo "These secrets have no value yet — the deploy will succeed but instances"
  echo "will crash on startup until they do:"
  for name in "${EMPTY_SECRETS[@]}"; do
    echo "  printf '%s' 'VALUE' | gcloud secrets versions add $name --project=$PROJECT_ID --data-file=-"
  done
fi
echo
echo "Next: review deploy/env/*.yaml, then run 'yarn deploy --only web' as a first test."
