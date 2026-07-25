#!/usr/bin/env bash
#
# Wire up push-to-deploy: a Cloud Build trigger that runs the same
# cloudbuild.yaml as `yarn deploy` whenever you push to a branch.
#
#   ./scripts/setup-cloud-build-trigger.sh
#
# This is the replacement for deploy keys. Nothing is stored in the repo, no
# key material is copied anywhere, and access is revocable from GitHub's UI —
# the Cloud Build GitHub App holds the grant, per repository.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/deploy/config.env"

die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }
step() { printf '\n=== %s\n' "$*"; }

[[ -f "$CONFIG_FILE" ]] || die "$CONFIG_FILE not found."
# shellcheck disable=SC1090
set -a; source "$CONFIG_FILE"; set +a

for required in PROJECT_ID REGION AR_REPO GITHUB_OWNER GITHUB_REPO; do
  [[ -n "${!required:-}" ]] || die "$required is not set in $CONFIG_FILE"
done

: "${TRIGGER_NAME:=plunk-deploy}"
: "${TRIGGER_BRANCH:=^production$}"
: "${CONNECTION_NAME:=github}"

command -v gcloud >/dev/null || die "gcloud not found."

step "Checking the GitHub connection"
# The GitHub App install is an OAuth handshake — it cannot be scripted, and
# pretending otherwise produces a confusing failure three commands later.
if ! gcloud builds connections describe "$CONNECTION_NAME" \
     --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  cat <<EOF

No Cloud Build connection named '$CONNECTION_NAME' in $REGION.

Create it once in the console (it installs the Cloud Build GitHub App on your
account and asks which repositories to grant):

  https://console.cloud.google.com/cloud-build/repositories/2nd-gen?project=$PROJECT_ID

Choose region '$REGION' and name the connection '$CONNECTION_NAME', then re-run
this script.
EOF
  exit 1
fi
echo "ok"

step "Linking $GITHUB_OWNER/$GITHUB_REPO"
if gcloud builds repositories describe "$GITHUB_REPO" \
     --connection="$CONNECTION_NAME" --region="$REGION" \
     --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "already linked"
else
  gcloud builds repositories create "$GITHUB_REPO" \
    --connection="$CONNECTION_NAME" \
    --region="$REGION" \
    --project="$PROJECT_ID" \
    --remote-uri="https://github.com/${GITHUB_OWNER}/${GITHUB_REPO}.git"
fi

REPO_PATH="projects/${PROJECT_ID}/locations/${REGION}/connections/${CONNECTION_NAME}/repositories/${GITHUB_REPO}"

# Same substitutions the manual script passes, minus _TAG: the trigger uses the
# commit that fired it, so every automatic deploy is traceable to a commit.
SUBS="_REGION=${REGION}"
SUBS+=";;_AR_REPO=${AR_REPO}"
SUBS+=";;_TAG=\$SHORT_SHA"
SUBS+=";;_TARGETS=api,worker,web"
SUBS+=";;_API_SERVICE=${API_SERVICE:-plunk-api}"
SUBS+=";;_WEB_SERVICE=${WEB_SERVICE:-plunk-web}"
SUBS+=";;_WORKER_POOL=${WORKER_POOL:-plunk-worker}"
SUBS+=";;_WORKER_INSTANCES=${WORKER_INSTANCES:-1}"
SUBS+=";;_MIGRATE_JOB=${MIGRATE_JOB:-}"
SUBS+=";;_RUN_MIGRATIONS=true"
SUBS+=";;_RUNTIME_SA=${RUNTIME_SA:-}"
SUBS+=";;_VPC_CONNECTOR=${VPC_CONNECTOR:-}"
SUBS+=";;_CLOUDSQL_INSTANCES=${CLOUDSQL_INSTANCES:-}"
SUBS+=";;_API_SECRETS=${API_SECRETS:-}"
SUBS+=";;_WORKER_SECRETS=${WORKER_SECRETS:-}"

step "Creating trigger $TRIGGER_NAME on $TRIGGER_BRANCH"
CREATE=(gcloud builds triggers create github
  --name="$TRIGGER_NAME"
  --region="$REGION"
  --project="$PROJECT_ID"
  --repository="$REPO_PATH"
  --branch-pattern="$TRIGGER_BRANCH"
  --build-config=cloudbuild.yaml
  --substitutions="^;;^${SUBS}"
)
if [[ -n "${BUILD_SA:-}" ]]; then
  CREATE+=(--service-account="projects/${PROJECT_ID}/serviceAccounts/${BUILD_SA}")
fi

if gcloud builds triggers describe "$TRIGGER_NAME" \
     --region="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "Trigger '$TRIGGER_NAME' already exists. Delete it to recreate:"
  echo "  gcloud builds triggers delete $TRIGGER_NAME --region=$REGION --project=$PROJECT_ID"
  exit 0
fi

"${CREATE[@]}"

cat <<EOF

Done. Pushes matching $TRIGGER_BRANCH now build and deploy automatically.

  Watch:   https://console.cloud.google.com/cloud-build/builds;region=${REGION}?project=${PROJECT_ID}
  Test:    gcloud builds triggers run $TRIGGER_NAME --region=$REGION --branch=BRANCH

'yarn deploy' still works and runs the identical config — useful for deploying a
branch, or a dirty tree, without pushing.
EOF
